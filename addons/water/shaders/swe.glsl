#[compute]
#version 450
// Water-only adaptation of Rust nearshore: hydrostatic Rusanov, MUSCL bed
// reconstruction + matching source, SSP-RK2, FFT elevation/momentum relaxation.
// Shared donor draining additionally protects dry-front positivity.
layout(local_size_x=8,local_size_y=8) in;
layout(set=0,binding=0,std430) buffer States { vec4 states[]; };
layout(set=0,binding=1,std430) readonly buffer Terrain { vec2 terrain[]; };
layout(set=0,binding=2,std430) buffer FluxX { vec4 flux_x[]; };
layout(set=0,binding=3,std430) buffer FluxZ { vec4 flux_z[]; };
layout(set=0,binding=4,std430) buffer Control { uint stats[]; };
layout(set=0,binding=5,std430) readonly buffer FFT { vec2 fft_now[]; };
layout(set=0,binding=6,std430) readonly buffer PreviousFFT { vec2 fft_before[]; };
layout(push_constant,std430) uniform Params {
    vec4 physics; // dx,dz,g,Manning
    vec4 spectral; // FFT N,length,height_gain*input_gain,FFT enabled
    vec4 region; // world origin x/z, cos(yaw), sin(yaw)
    vec4 extent; // width,depth,relaxation width fraction,rate s^-1
    ivec4 grid; // SWE N,compute stage,second order,FFT edge bits -X,+X,-Z,+Z
    vec4 timing; // requested tick seconds,unused...
    ivec4 roles; // input,output,original,RK stage (0 Euler,1 predict,2 correct)
} p;
const float DRY=0.00001;
int cells() { return p.grid.x*p.grid.x; }
int idx(ivec2 c) { return c.y*p.grid.x+c.x; }
bool inside(ivec2 c) { return all(greaterThanEqual(c,ivec2(0)))&&all(lessThan(c,ivec2(p.grid.x))); }
bool valid(ivec2 c) { return inside(c)&&terrain[idx(c)].y>0.5; }
float bed(ivec2 c) { return terrain[idx(clamp(c,ivec2(0),ivec2(p.grid.x-1)))].x; }
vec3 state(ivec2 c) { return states[p.roles.x*cells()+idx(c)].xyz; }
vec2 velocity(vec3 q) { return q.yz/max(q.x,0.005); }
float dt() { return uintBitsToFloat(stats[3]); }
float elapsed() { return uintBitsToFloat(stats[2]); }
bool open_face(ivec2 c, int axis,float side) {
    ivec2 n=c; n[axis]+=int(side);
    return !inside(n)&&(p.grid.w&(1<<(axis*2+(side>0.0 ? 1 : 0))))!=0;
}
vec3 ghost(ivec2 c,int axis,float side) {
    vec3 q=state(c);
    if(!open_face(c,axis,side)) q[axis+1]=-q[axis+1];
    return q;
}
vec3 physical(vec3 q,int axis) {
    vec3 f=q*velocity(q)[axis]; f[axis+1]+=0.5*p.physics.z*q.x*q.x; return f;
}
vec3 rusanov(vec3 a,vec3 b,int axis) {
    float speed=max(abs(velocity(a)[axis])+sqrt(p.physics.z*a.x),abs(velocity(b)[axis])+sqrt(p.physics.z*b.x));
    return 0.5*(physical(a,axis)+physical(b,axis)-speed*(b-a));
}
vec3 limited(vec3 a,vec3 b) { return 0.5*(sign(a)+sign(b))*min(min(1.3*abs(a),1.3*abs(b)),0.5*abs(a+b)); }
struct Reconstruction { vec3 value; vec3 slope; float bottom; float bed_slope; };
Reconstruction reconstruct(ivec2 c,int axis) {
    vec3 q=state(c); float z=bed(c);
    Reconstruction r=Reconstruction(vec3(q.x+z,velocity(q)),vec3(0),z,0.0);
    ivec2 d=ivec2(0); d[axis]=1;
    if(p.grid.z==0||!valid(c-d)||!valid(c+d)||min(q.x,min(state(c-d).x,state(c+d).x))<0.02) return r;
    vec3 left=vec3(state(c-d).x+bed(c-d),velocity(state(c-d))),right=vec3(state(c+d).x+bed(c+d),velocity(state(c+d)));
    r.slope=limited(r.value-left,right-r.value);
    r.bed_slope=limited(vec3(z-bed(c-d)),vec3(bed(c+d)-z)).x;
    if(q.x-0.5*abs(r.slope.x-r.bed_slope)<0.005) { r.slope=vec3(0); r.bed_slope=0.0; }
    return r;
}
vec3 reconstructed_flux(ivec2 c,ivec2 n,int axis) {
    Reconstruction a=reconstruct(c,axis), b=reconstruct(n,axis);
    vec3 va=a.value+0.5*a.slope,vb=b.value-0.5*b.slope;
    float top=max(a.bottom+0.5*a.bed_slope,b.bottom-0.5*b.bed_slope);
    float ha=max(va.x-top,0.0),hb=max(vb.x-top,0.0);
    return rusanov(vec3(ha,va.yz*ha),vec3(hb,vb.yz*hb),axis);
}
vec3 boundary_flux(ivec2 c,int axis,float side) {
    vec3 a=state(c),b=ghost(c,axis,side);
    return side>0.0 ? rusanov(a,b,axis) : rusanov(b,a,axis);
}
vec3 face(ivec2 c,int axis,float side) {
    ivec2 n=c; n[axis]+=int(side);
    if(!valid(n)) return boundary_flux(c,axis,side);
    int i=idx(side>0.0 ? c : n);
    return axis==0 ? flux_x[i].xyz : flux_z[i].xyz;
}
float draining(ivec2 c) {
    if(!valid(c)) return 1.0;
    float outgoing=(max(face(c,0,1.0).x,0.0)+max(-face(c,0,-1.0).x,0.0))/p.physics.x
                  +(max(face(c,1,1.0).x,0.0)+max(-face(c,1,-1.0).x,0.0))/p.physics.y;
    return min(1.0,state(c).x/max(dt()*outgoing,0.00000001));
}
float pressure_correction(ivec2 c,int axis,float side) {
    Reconstruction a=reconstruct(c,axis);
    vec3 va=a.value+0.5*side*a.slope;
    float za=a.bottom+0.5*side*a.bed_slope;
    ivec2 n=c; n[axis]+=int(side);
    float top=za;
    if(valid(n)) { Reconstruction b=reconstruct(n,axis); top=max(top,b.bottom-0.5*side*b.bed_slope); }
    float raw=max(va.x-za,0.0),h=max(va.x-top,0.0);
    return 0.5*p.physics.z*(raw*raw-h*h);
}
float bed_source(ivec2 c,int axis) {
    Reconstruction a=reconstruct(c,axis);
    float hl=max(a.value.x-0.5*a.slope.x-a.bottom+0.5*a.bed_slope,0.0);
    float hr=max(a.value.x+0.5*a.slope.x-a.bottom-0.5*a.bed_slope,0.0);
    return -0.5*p.physics.z*(hl+hr)*a.bed_slope;
}
float fft_at(ivec2 c,int channel,float alpha) {
    int n=int(p.spectral.x); c=((c%n)+n)%n;
    int i=channel*n*n+c.y*n+c.x;
    return mix(fft_before[i].x,fft_now[3*n*n+i].x,alpha);
}
vec3 incident(ivec2 c,float alpha) {
    if(p.spectral.w<0.5) return vec3(0);
    vec2 local=(vec2(c)+0.5-vec2(p.grid.x)*0.5)*p.physics.xy;
    vec2 world=p.region.xy+vec2(p.region.z*local.x+p.region.w*local.y,-p.region.w*local.x+p.region.z*local.y);
    vec2 grid=(world/p.spectral.y+0.5)*p.spectral.x;
    ivec2 base=ivec2(floor(grid)); vec2 f=fract(grid); vec3 input_wave;
    for(int k=0;k<3;k++) input_wave[k]=mix(mix(fft_at(base,k,alpha),fft_at(base+ivec2(1,0),k,alpha),f.x),mix(fft_at(base+ivec2(0,1),k,alpha),fft_at(base+ivec2(1,1),k,alpha),f.x),f.y);
    input_wave*=p.spectral.z;
    // World X/Z momentum into yawed region axes, NOT choppiness displacement.
    input_wave.yz=vec2(p.region.z*input_wave.y-p.region.w*input_wave.z,p.region.w*input_wave.y+p.region.z*input_wave.z);
    float depth=max(-bed(c),0.1);
    float safety=min(1.0,min(0.5*depth/max(abs(input_wave.x),0.000001),8.0*depth/max(length(input_wave.yz),0.000001)));
    return input_wave*safety;
}
float edge_weight(ivec2 c) {
    vec2 uv=(vec2(c)+0.5)/float(p.grid.x); float w=0.0;
    for(int axis=0;axis<2;axis++) {
        if((p.grid.w&(1<<(axis*2)))!=0) w=max(w,1.0-smoothstep(0.0,p.extent.z,uv[axis]));
        if((p.grid.w&(1<<(axis*2+1)))!=0) w=max(w,smoothstep(1.0-p.extent.z,1.0,uv[axis]));
    }
    return w;
}
void main() {
    ivec2 c=ivec2(gl_GlobalInvocationID.xy); int stage=p.grid.y;
    bool first=all(equal(c,ivec2(0)));
    if(stage==0) { if(first) { stats[2]=floatBitsToUint(0.0); stats[3]=floatBitsToUint(0.0); } return; }
    if(stage==1) { if(first) stats[0]=floatBitsToUint(0.0); return; }
    if(stage==3) {
        if(first) stats[3]=floatBitsToUint(min(max(p.timing.x-elapsed(),0.0),min(0.2/max(uintBitsToFloat(stats[0]),0.00001),0.2/p.extent.w)));
        return;
    }
    if(stage==6) { if(first&&dt()>0.0) { stats[2]=floatBitsToUint(elapsed()+dt()); stats[6]++; } return; }
    if(stage==7) {
        if(first) {
            float accepted=p.grid.x==0 ? p.timing.x : elapsed();
            stats[1]=floatBitsToUint(uintBitsToFloat(stats[1])+accepted);
            stats[5]=floatBitsToUint(uintBitsToFloat(stats[5])+max(p.timing.x-accepted,0.0));
            stats[8]=floatBitsToUint(accepted);
        }
        return;
    }
    if(stage==9) {
        if(first&&p.timing.y>0.5&&p.timing.z>0.0)
            stats[9]=floatBitsToUint(fract(uintBitsToFloat(stats[9])+uintBitsToFloat(stats[8])/p.timing.z));
        return;
    }
    if(!inside(c)) return;
    int i=idx(c);
    if(stage==8) {
        vec3 wave=valid(c) ? incident(c,1.0) : vec3(0);
        float h=valid(c) ? max(wave.x-bed(c),0.0) : 0.0;
        vec2 momentum=wave.yz*min(1.0,8.0*h/max(length(wave.yz),0.000001));
        if(h<=0.003) momentum=vec2(0);
        for(int role=0;role<3;role++) states[role*cells()+i]=vec4(h,momentum,0);
        return;
    }
    if(stage==2) {
        if(!valid(c)||elapsed()>=p.timing.x) return;
        vec3 q=state(c); vec2 rates=abs(velocity(q))+sqrt(p.physics.z*max(q.x,0.0));
        for(int axis=0;axis<2;axis++) {
            Reconstruction r=reconstruct(c,axis);
            for(int side=-1;side<=1;side+=2) {
                vec3 v=r.value+0.5*float(side)*r.slope;
                float h=max(v.x-r.bottom-0.5*float(side)*r.bed_slope,0.0);
                rates[axis]=max(rates[axis],abs(v[axis+1])+sqrt(p.physics.z*h));
            }
        }
        // Foam has its own bounded inertia; do not use water-only CFL for it.
        if(p.timing.y>0.5) rates=max(rates,vec2(12.0));
        atomicMax(stats[0],floatBitsToUint(rates.x/p.physics.x+rates.y/p.physics.y));
        return;
    }
    if(stage==4) {
        if(!valid(c)||dt()<=0.0) return;
        flux_x[i]=vec4(valid(c+ivec2(1,0)) ? reconstructed_flux(c,c+ivec2(1,0),0) : boundary_flux(c,0,1.0),0);
        flux_z[i]=vec4(valid(c+ivec2(0,1)) ? reconstructed_flux(c,c+ivec2(0,1),1) : boundary_flux(c,1,1.0),0);
        return;
    }
    if(stage!=5) return;
    if(!valid(c)) { states[p.roles.y*cells()+i]=vec4(0); return; }
    vec3 previous=state(c),q=previous;
    if(dt()>0.0) {
        for(int axis=0;axis<2;axis++) {
            vec3 lo=face(c,axis,-1.0),hi=face(c,axis,1.0);
            ivec2 d=ivec2(0); d[axis]=1;
            hi*=hi.x>=0.0 ? draining(c) : draining(c+d);
            lo*=lo.x<=0.0 ? draining(c) : draining(c-d);
            hi[axis+1]+=pressure_correction(c,axis,1.0);
            lo[axis+1]+=pressure_correction(c,axis,-1.0);
            q-=dt()*(hi-lo)/p.physics[axis];
            q[axis+1]+=dt()*bed_source(c,axis)/p.physics[axis];
        }
        float edge=edge_weight(c)*p.extent.w;
        if(edge>0.0) {
            float alpha=clamp((elapsed()+(p.roles.w==2 ? dt() : 0.0))/p.timing.x,0.0,1.0);
            vec3 wave=incident(c,alpha),target=vec3(max(wave.x-bed(c),0.0),wave.yz);
            if(p.grid.z>0) q+=dt()*edge*(target-previous);
            else q=mix(q,target,1.0-exp(-dt()*edge));
        }
        float friction=p.physics.z*p.physics.w*p.physics.w*length(velocity(previous))/pow(max(previous.x,0.005),1.333333333);
        if(p.grid.z>0) q.yz-=min(dt()*friction,1.0)*previous.yz;
        else q.yz/=1.0+dt()*friction;
        if(p.roles.w==2) q=0.5*(states[p.roles.z*cells()+i].xyz+q);
        if(any(isnan(q))||any(isinf(q))) { atomicAdd(stats[4],1); q=vec3(0); }
        if(q.x < -0.00001) atomicAdd(stats[4],1);
        q.x=max(q.x,0.0);
        if(q.x<=DRY) q.yz=vec2(0);
        q.yz*=min(1.0,12.0/max(length(velocity(q)),0.000001));
    }
    states[p.roles.y*cells()+i]=vec4(q,0);
}
