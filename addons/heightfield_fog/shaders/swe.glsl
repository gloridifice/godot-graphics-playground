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
layout(set=0,binding=7,std430) readonly buffer WindParams {
    vec4 velocity; // box-local X/Z background velocity; state momentum is relative to it
    vec4 world; // world origin X/Z, initial base height + offset, horizontal-top flag
    vec4 basis; // local X/Z basis projected onto world X/Z
    vec4 shape; // height amplitude, initial max thickness, noise UV scale, wind stretch
    vec4 noise; // world wind direction X/Z, noise offset X/Z
} wind;
layout(set=0,binding=8) uniform sampler2D noise_map;
layout(rgba32f,set=0,binding=9) uniform writeonly image2D wind_phase_output;
struct Movement {
    vec4 start; // local feet XYZ, body radius
    vec4 end; // local feet XYZ, coupling rate 1/s
    vec4 motion; // local velocity X/Z, elapsed seconds, wake strength
};
layout(set=0,binding=10,std430) readonly buffer MovementParams {
    ivec4 counts;
    Movement samples[];
} movement;
layout(push_constant,std430) uniform Params {
    vec4 physics; // dx, dz, reduced gravity m/s², drag 1/s
    vec4 step; // requested dt, impulse radius m, impulse speed m/s, stage
    ivec4 grid; // width, height, event count, unused
    vec4 events[4]; // box-local feet XYZ; W signed radial strength [-1, 1]
    vec4 gravity_config; // pressure threshold m, second-order reconstruction flag, unused ZW
} p;
const float DRY = 0.00001;
int index_of(ivec2 c) { return c.y*p.grid.x+c.x; }
bool inside(ivec2 c) {
    return all(greaterThanEqual(c,ivec2(0))) && all(lessThan(c,p.grid.xy));
}
bool valid(ivec2 c) { return inside(c) && terrain[index_of(c)].y>0.5; }
vec2 world_vector(vec2 local) { return wind.basis.xy*local.x+wind.basis.zw*local.y; }
vec2 drift() { return vec2(uintBitsToFloat(stats[6]),uintBitsToFloat(stats[7])); }
float bed(ivec2 c) { vec2 b=terrain[index_of(c)]; return b.x/max(b.y,0.00001); }
float square(float x) { return x*x; }
// Operator-split, bounded body/air momentum exchange. The swept sample avoids gaps
// between physics contacts; the layer mass is untouched. No perpetual visual mask.
vec3 move_body(ivec2 c) {
    vec3 u=state[index_of(c)].xyz;
    if(u.x<=DRY) return u;
    vec2 pos=(vec2(c)+0.5-vec2(p.grid.xy)*0.5)*p.physics.xy;
    for(int i=0;i<movement.counts.x;i++) {
        Movement m=movement.samples[i];
        vec2 travel=m.end.xz-m.start.xz;
        float t=clamp(dot(pos-m.start.xz,travel)/max(dot(travel,travel),0.000001),0.0,1.0);
        vec3 center=mix(m.start.xyz,m.end.xyz,t);
        // Near-ground interaction only: no force on a separate floor or from above it.
        float vertical=1.0-smoothstep(0.15,0.8,abs(bed(c)-center.y));
        if(vertical<=0.0) continue;
        float speed=length(m.motion.xy), radius=m.start.w;
        vec2 forward=m.motion.xy/max(speed,0.000001);
        vec2 side=vec2(-forward.y,forward.x);
        vec2 offset=(pos-center.xz)/radius;
        float a=dot(offset,forward), b=dot(offset,side);
        if(abs(a)>5.0 || abs(b)>3.5) continue;
        float front=exp(-square((a-0.5)/0.95)-square(b/1.15))*smoothstep(-0.2,0.5,a);
        float flank=exp(-square(a/1.15)-square((abs(b)-0.85)/0.65));
        float wake=exp(-square((a+1.5)/1.5)-square(b/1.6))*(1.0-smoothstep(-0.3,0.2,a));
        vec2 field=vec2(0.9*front+0.55*m.motion.w*wake,0.65*sign(b)*flank);
        // Opposite circulations: entrain the flanks into the near wake, with a
        // forward-dragged center and local recirculation, not radial explosions.
        for(int s=-1;s<=1;s+=2) {
            vec2 q=vec2(a+1.4,b-float(s)*0.9);
            field+=0.35*m.motion.w*float(-s)*vec2(-q.y,q.x)*exp(-dot(q,q)/0.8);
        }
        float envelope=max(front,max(flank,m.motion.w*wake));
        if(envelope<0.001) continue;
        vec2 target=speed*(forward*field.x+side*field.y)/envelope;
        // A long sweep visits each cell for only a fraction of its elapsed time.
        float exposure=m.motion.z*min(1.0,2.0*radius/max(length(travel),0.000001));
        float blend=1.0-exp(-m.end.w*vertical*envelope*exposure);
        vec2 absolute_velocity=u.yz/u.x+wind.velocity.xy;
        u.yz+=u.x*blend*(target-absolute_velocity);
    }
    return u;
}
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
vec3 hydro(vec3 u, float b, float interface_bed) {
    float h=max(0.0,u.x+b-interface_bed);
    return vec3(h,u.yz*(u.x>DRY ? h/u.x : 0.0));
}
vec3 minmod(vec3 a,vec3 b) {
    return 0.5*(sign(a)+sign(b))*min(abs(a),abs(b));
}
vec3 primitive(ivec2 c) {
    vec3 u=load_state(c);
    return vec3(u.x+bed(c),u.x>DRY ? u.yz/u.x : vec2(0.0));
}
vec3 face_state(ivec2 c,int axis,float side) {
    vec3 u=load_state(c);
    if(p.gravity_config.y<0.5 || u.x<=DRY) return u;
    ivec2 offset=axis==0 ? ivec2(1,0) : ivec2(0,1);
    ivec2 lo=c-offset, hi=c+offset;
    // No stencil across holes, box boundaries or a dry shoreline.
    if(!valid(lo) || !valid(hi)) return u;
    if(load_state(lo).x<=DRY || load_state(hi).x<=DRY) return u;
    // Reconstruct free surface and relative velocity, not depth alone, to preserve a resting lake.
    vec3 center=primitive(c), left=primitive(lo), right=primitive(hi);
    vec3 slope=minmod(0.5*(right-left),minmod(2.0*(center-left),2.0*(right-center)));
    vec3 face=center+side*0.5*slope;
    float adjacent=load_state(side>0.0 ? hi : lo).x;
    // Bound reconstructed depth by its adjacent cell averages, including at the gravity threshold.
    float h=clamp(face.x-bed(c),min(u.x,adjacent),max(u.x,adjacent));
    return vec3(h,h*face.yz);
}
float active_depth(float h) { return max(h-p.gravity_config.x,0.0); }
float pressure(float h) { float a=active_depth(h); return 0.5*p.physics.z*a*a; }
float wave_speed(float h) { return sqrt(p.physics.z*active_depth(h)); }
vec3 physical_flux(vec3 u,int axis) {
    vec2 velocity=u.x>DRY ? u.yz/u.x : vec2(0);
    vec3 f=u*(velocity[axis]+wind.velocity[axis]);
    f[axis+1]+=pressure(u.x);
    return f;
}
vec3 numerical_flux(vec3 a,vec3 b,int axis) {
    float va=(a.x>DRY ? a[axis+1]/a.x : 0.0)+wind.velocity[axis];
    float vb=(b.x>DRY ? b[axis+1]/b.x : 0.0)+wind.velocity[axis];
    float advection=max(abs(va),abs(vb));
    float speed=max(abs(va)+wave_speed(a.x),abs(vb)+wave_speed(b.x));
    vec3 diffusion=speed*(b-a);
    // Gravity waves diffuse only excess depth; resting sub-threshold mist must not creep.
    // Inertial transport still acts on the entire layer, including player impulses.
    diffusion.x=advection*(b.x-a.x)+(speed-advection)*(active_depth(b.x)-active_depth(a.x));
    return 0.5*(physical_flux(a,axis)+physical_flux(b,axis)-diffusion);
}
// Extend support height across an open perimeter; never fill invalid cells.
// Sample the same world-space tile as initialization, with continuous GPU-integrated drift.
float incoming_depth(ivec2 c,int axis,float side) {
    vec2 local=(vec2(c)+0.5-vec2(p.grid.xy)*0.5)*p.physics.xy;
    local[axis]+=side*0.5*p.physics[axis];
    vec2 pos=wind.world.xy+world_vector(local)+wind.noise.zw-drift();
    vec2 across=vec2(-wind.noise.y,wind.noise.x);
    vec2 q=vec2(dot(pos,wind.noise.xy)/wind.shape.w,dot(pos,across));
    float signal=textureLod(noise_map,q*wind.shape.z,0.0).r*2.0-1.0;
    float h=max(wind.world.z+wind.shape.x*signal-(wind.world.w>0.5 ? bed(c) : 0.0),0.0);
    return wind.shape.y>0.0 ? min(h,wind.shape.y) : h;
}
// All box edges and missing-support faces share this rule, including enclosed holes.
vec3 boundary_flux(ivec2 c,int axis,float side) {
    vec3 u=load_state(c);
    vec3 f;
    if(abs(wind.velocity[axis])<=0.000001) {
        // Zero/cross wind: dry exterior at the same bed height, with outflow only.
        f=side>0.0 ? numerical_flux(u,vec3(0.0),axis) : numerical_flux(vec3(0.0),u,axis);
        if(f.x*side<0.0) f=vec3(0.0);
        return f;
    }
    if(wind.velocity[axis]*side<0.0) {
        // Prescribed fresh inflow has no player/gravity perturbation momentum.
        f=vec3(wind.velocity[axis]*incoming_depth(c,axis,side),0.0,0.0);
        f[axis+1]=pressure(u.x);
    } else {
        // Free outflow: carry disturbances out instead of reflecting them.
        f=physical_flux(u,axis);
        if(f.x*side<0.0) { f=vec3(0.0); f[axis+1]=pressure(u.x); }
    }
    return f;
}
vec3 interface_flux(ivec2 c,ivec2 n,int axis) {
    if(!valid(n)) return boundary_flux(c,axis,1.0);
    vec3 a=face_state(c,axis,1.0), b=face_state(n,axis,-1.0);
    float ba=bed(c), bb=bed(n);
    float top=max(ba,bb);
    return numerical_flux(hydro(a,ba,top),hydro(b,bb,top),axis);
}
float dt() { return min(p.step.x,(p.gravity_config.y>0.5 ? 0.3 : 0.45)/max(uintBitsToFloat(stats[0]),0.00001)); }
// Box edges and missing support share the same open boundary rule: never reflect.
vec3 left_flux(ivec2 c,int axis) {
    ivec2 n=c-(axis==0?ivec2(1,0):ivec2(0,1));
    if(valid(n)) return axis==0 ? flux_x[index_of(n)].xyz : flux_z[index_of(n)].xyz;
    return boundary_flux(c,axis,-1.0);
}
float draining(ivec2 c) {
    if(!valid(c)) return 1.0;
    int i=index_of(c);
    float outgoing=(max(flux_x[i].x,0.0)+max(-left_flux(c,0).x,0.0))/p.physics.x
                  +(max(flux_z[i].x,0.0)+max(-left_flux(c,1).x,0.0))/p.physics.y;
    return min(1.0,load_state(c).x/max(dt()*outgoing,0.0000001));
}
float pressure_correction(ivec2 c,ivec2 n,int axis,float side) {
    float h=face_state(c,axis,side).x;
    float bs=valid(n)?max(bed(c),bed(n)):bed(c);
    float hs=max(0.0,h+bed(c)-bs);
    return pressure(h)-pressure(hs);
}
void main() {
    ivec2 c=ivec2(gl_GlobalInvocationID.xy);
    if(any(greaterThanEqual(c,p.grid.xy))) return;
    int i=index_of(c), stage=int(p.step.w);
    if(stage==5) { next_state[i]=valid(c) ? vec4(move_body(c),0.0) : vec4(0.0); return; }
    if(stage==0) { if(i==0) stats[0]=floatBitsToUint(0.0); return; }
    if(stage==4) {
        if(i==0) {
            vec2 phase=drift()+world_vector(wind.velocity.xy)*uintBitsToFloat(stats[2]);
            stats[6]=floatBitsToUint(phase.x); stats[7]=floatBitsToUint(phase.y);
            imageStore(wind_phase_output,ivec2(0),vec4(phase,0.0,0.0));
        }
        return;
    }
    if(stage==1) {
        if(!valid(c)) return;
        vec3 u=load_state(c);
        float h=u.x;
        // Fresh boundary peaks can be taller than the current edge state.
        for(int axis=0;axis<2;axis++) {
            ivec2 offset=axis==0 ? ivec2(1,0) : ivec2(0,1);
            if(wind.velocity[axis]>0.000001 && !valid(c-offset)) h=max(h,incoming_depth(c,axis,-1.0));
            if(wind.velocity[axis]<-0.000001 && !valid(c+offset)) h=max(h,incoming_depth(c,axis,1.0));
        }
        float wave=wave_speed(h);
        vec2 v=abs((u.x>DRY ? u.yz/u.x : vec2(0))+wind.velocity.xy);
        vec2 rates=v+vec2(wave);
        if(p.gravity_config.y>0.5) {
            // CFL includes reconstructed velocities/depths, not only cell averages.
            for(int axis=0;axis<2;axis++) {
                vec3 a=face_state(c,axis,-1.0), b=face_state(c,axis,1.0);
                float va=(a.x>DRY ? a[axis+1]/a.x : 0.0)+wind.velocity[axis];
                float vb=(b.x>DRY ? b[axis+1]/b.x : 0.0)+wind.velocity[axis];
                rates[axis]=max(rates[axis],max(abs(va)+wave_speed(a.x),abs(vb)+wave_speed(b.x)));
            }
        }
        atomicMax(stats[0],floatBitsToUint(rates.x/p.physics.x+rates.y/p.physics.y));
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
    right.y+=pressure_correction(c,c+ivec2(1,0),0,1.0); left.y+=pressure_correction(c,c-ivec2(1,0),0,-1.0);
    up.z+=pressure_correction(c,c+ivec2(0,1),1,1.0); down.z+=pressure_correction(c,c-ivec2(0,1),1,-1.0);
    u-=timestep*((right-left)/p.physics.x+(up-down)/p.physics.y);
    if(any(isnan(u)) || any(isinf(u))) { atomicAdd(stats[3],1); u=vec3(0); }
    u.x=max(u.x,0.0); // roundoff guard; donor draining preserves mass before this clamp
    u.yz*=exp(-max(p.physics.w,0.0)*timestep);
    if(u.x<=DRY) u.yz=vec2(0);
    next_state[i]=vec4(u,0);
    imageStore(height_output,c,vec4(u.x,0,0,0));
}
