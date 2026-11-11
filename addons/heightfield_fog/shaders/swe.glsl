#[compute]
#version 450
layout(local_size_x=8, local_size_y=8, local_size_z=1) in;
layout(set=0,binding=0,std430) readonly buffer InputState { vec4 state[]; };
layout(set=0,binding=1,std430) writeonly buffer OutputState { vec4 next_state[]; };
layout(set=0,binding=2,std430) readonly buffer Terrain { vec2 terrain[]; };
layout(set=0,binding=3,std430) buffer FluxX { vec4 flux_x[]; };
layout(set=0,binding=4,std430) buffer FluxZ { vec4 flux_z[]; };
layout(set=0,binding=5,std430) buffer Diagnostics { uint stats[]; };
layout(r32f,set=0,binding=6) uniform writeonly image2D height_output;
layout(push_constant,std430) uniform Params {
    vec4 physics; // dx, dz, reduced gravity m/s², drag 1/s
    vec4 step; // requested dt, impulse radius m, impulse speed m/s, stage
    ivec4 grid; // width, height, event count, unused
    vec4 events[4]; // box-local feet XYZ; W signed radial strength [-1, 1]
} p;
const float DRY = 0.00001;
int index_of(ivec2 c) { return c.y*p.grid.x+c.x; }
bool valid(ivec2 c) {
    return all(greaterThanEqual(c,ivec2(0))) && all(lessThan(c,p.grid.xy)) && terrain[index_of(c)].y>0.5;
}
float bed(ivec2 c) { vec2 b=terrain[index_of(c)]; return b.x/max(b.y,0.00001); }
vec3 load_state(ivec2 c) {
    vec3 u=state[index_of(c)].xyz;
    vec2 pos=(vec2(c)+0.5-vec2(p.grid.xy)*0.5)*p.physics.xy;
    if(u.x>DRY) {
        for(int i=0;i<p.grid.z;i++) {
            vec2 offset=pos-p.events[i].xz;
            float r=length(offset);
            float weight=(1.0-smoothstep(0.0,p.step.y,r))*(1.0-smoothstep(0.2,1.5,abs(bed(c)-p.events[i].y)));
            // Momentum impulse only: never remove or add layer mass.
            u.yz+=u.x*p.step.z*p.events[i].w*weight*offset/max(r,0.00001);
        }
    }
    return u;
}
vec3 neighbor(ivec2 c, ivec2 n, int axis) {
    if(valid(n)) return load_state(n);
    vec3 u=load_state(c); u[axis+1]=-u[axis+1]; return u;
}
vec3 hydro(vec3 u, float b, float interface_bed) {
    float h=max(0.0,u.x+b-interface_bed);
    return vec3(h,u.yz*(u.x>DRY ? h/u.x : 0.0));
}
vec3 physical_flux(vec3 u,int axis) {
    vec2 velocity=u.x>DRY ? u.yz/u.x : vec2(0);
    vec3 f=u*velocity[axis];
    f[axis+1]+=0.5*p.physics.z*u.x*u.x;
    return f;
}
vec3 interface_flux(ivec2 c,ivec2 n,int axis) {
    vec3 a=load_state(c), b=neighbor(c,n,axis);
    float ba=bed(c), bb=valid(n)?bed(n):ba;
    float top=max(ba,bb);
    a=hydro(a,ba,top); b=hydro(b,bb,top);
    float va=a.x>DRY ? a[axis+1]/a.x : 0.0;
    float vb=b.x>DRY ? b[axis+1]/b.x : 0.0;
    float speed=max(abs(va)+sqrt(p.physics.z*a.x),abs(vb)+sqrt(p.physics.z*b.x));
    return 0.5*(physical_flux(a,axis)+physical_flux(b,axis)-speed*(b-a));
}
float dt() { return min(p.step.x,0.45/max(uintBitsToFloat(stats[0]),0.00001)); }
// Boundary faces not stored by a valid neighbor are reflecting walls.
vec3 left_flux(ivec2 c,int axis) {
    ivec2 n=c-(axis==0?ivec2(1,0):ivec2(0,1));
    if(valid(n)) return axis==0 ? flux_x[index_of(n)].xyz : flux_z[index_of(n)].xyz;
    vec3 u=load_state(c), ghost=neighbor(c,n,axis);
    float speed=(u.x>DRY ? abs(u[axis+1]/u.x):0.0)+sqrt(p.physics.z*u.x);
    return 0.5*(physical_flux(ghost,axis)+physical_flux(u,axis)-speed*(u-ghost));
}
float draining(ivec2 c) {
    if(!valid(c)) return 1.0;
    int i=index_of(c);
    float outgoing=(max(flux_x[i].x,0.0)+max(-left_flux(c,0).x,0.0))/p.physics.x
                  +(max(flux_z[i].x,0.0)+max(-left_flux(c,1).x,0.0))/p.physics.y;
    return min(1.0,load_state(c).x/max(dt()*outgoing,0.0000001));
}
float pressure_correction(ivec2 c,ivec2 n) {
    float h=load_state(c).x;
    float bs=valid(n)?max(bed(c),bed(n)):bed(c);
    float hs=max(0.0,h+bed(c)-bs);
    return 0.5*p.physics.z*(h*h-hs*hs);
}
void main() {
    ivec2 c=ivec2(gl_GlobalInvocationID.xy);
    if(any(greaterThanEqual(c,p.grid.xy))) return;
    int i=index_of(c), stage=int(p.step.w);
    if(stage==0) { if(i==0) stats[0]=floatBitsToUint(0.0); return; }
    if(stage==1) {
        if(!valid(c)) return;
        vec3 u=load_state(c);
        float wave=sqrt(p.physics.z*max(u.x,0.0));
        vec2 v=u.x>DRY ? abs(u.yz/u.x) : vec2(0);
        atomicMax(stats[0],floatBitsToUint((v.x+wave)/p.physics.x+(v.y+wave)/p.physics.y));
        atomicMax(stats[4],floatBitsToUint(max(u.x,0.0)));
        return;
    }
    if(stage==2) {
        if(!valid(c)) { flux_x[i]=vec4(0); flux_z[i]=vec4(0); return; }
        flux_x[i]=vec4(interface_flux(c,c+ivec2(1,0),0),0);
        flux_z[i]=vec4(interface_flux(c,c+ivec2(0,1),1),0);
        return;
    }
    float timestep=dt();
    if(i==0) {
        stats[1]=floatBitsToUint(uintBitsToFloat(stats[1])+timestep);
        stats[2]=floatBitsToUint(timestep);
        if(timestep<p.step.x*0.999) atomicAdd(stats[5],1);
    }
    if(!valid(c)) { next_state[i]=vec4(0); imageStore(height_output,c,vec4(0)); return; }
    vec3 u=load_state(c);
    float theta=draining(c);
    vec3 right=flux_x[i].xyz, left=left_flux(c,0), up=flux_z[i].xyz, down=left_flux(c,1);
    right*=right.x>=0.0 ? theta:draining(c+ivec2(1,0));
    left*=left.x<=0.0 ? theta:draining(c-ivec2(1,0));
    up*=up.x>=0.0 ? theta:draining(c+ivec2(0,1));
    down*=down.x<=0.0 ? theta:draining(c-ivec2(0,1));
    right.y+=pressure_correction(c,c+ivec2(1,0)); left.y+=pressure_correction(c,c-ivec2(1,0));
    up.z+=pressure_correction(c,c+ivec2(0,1)); down.z+=pressure_correction(c,c-ivec2(0,1));
    u-=timestep*((right-left)/p.physics.x+(up-down)/p.physics.y);
    if(any(isnan(u)) || any(isinf(u))) { atomicAdd(stats[3],1); u=vec3(0); }
    u.x=max(u.x,0.0); // roundoff guard; donor draining preserves mass before this clamp
    u.yz*=exp(-max(p.physics.w,0.0)*timestep);
    if(u.x<=DRY) u.yz=vec2(0);
    next_state[i]=vec4(u,0);
    imageStore(height_output,c,vec4(u.x,0,0,0));
}
