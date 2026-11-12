#[compute]
#version 450

layout(local_size_x=8,local_size_y=8,local_size_z=1) in;
// MAC faces: XY is projected air relative to wind, ZW is near-ground radial motion.
// The latter represents unresolved vertical coupling, not a divergence-free 2D flow.
layout(set=0,binding=0,std430) readonly buffer VelocityIn { vec4 velocity[]; };
layout(set=0,binding=1,std430) writeonly buffer VelocityOut { vec4 next_velocity[]; };
// Transport the map, source metadata and temporary height gain. trace.x is output
// only, never an input to height transport. Source weights exclude the gain channel.
struct MaterialState {
    vec4 trace; // output height, world backward displacement X/Z, initial weight
    vec4 source; // inlet weight, inlet-weighted support height, height gain [0,2], reserved
};
layout(set=0,binding=2,std430) readonly buffer ScalarIn { MaterialState material[]; };
layout(set=0,binding=3,std430) writeonly buffer ScalarOut { MaterialState next_material[]; };
layout(set=0,binding=4,std430) readonly buffer Terrain { vec2 terrain[]; };
layout(set=0,binding=5,std430) buffer PressureIn { float pressure[]; };
layout(set=0,binding=6,std430) buffer PressureOut { float next_pressure[]; };
layout(set=0,binding=7,std430) buffer Divergence { float divergence[]; };
layout(set=0,binding=8,std430) readonly buffer Wind {
    vec4 velocity;
    vec4 world;
    vec4 basis;
    vec4 shape;
    vec4 noise;
} wind;
struct Movement { vec4 start; vec4 end; vec4 motion; };
layout(set=0,binding=9,std430) readonly buffer Movements { ivec4 counts; Movement samples[]; } movement;
layout(set=0,binding=10,std430) buffer Diagnostics { uint stats[]; };
layout(r32f,set=0,binding=11) uniform writeonly image2D height_output;
layout(rgba32f,set=0,binding=12) uniform image2D phase_output;
layout(rg32f,set=0,binding=13) uniform writeonly image2D displacement_output;
layout(set=0,binding=14) uniform sampler2D noise_map;
layout(set=0,binding=15,std430) readonly buffer InitialHeight { float initial_height[]; };
layout(push_constant,std430) uniform Parameters {
    vec4 physics; // dx, dz, dt, drag
    vec4 interaction; // radius, speed, stage, unused
    ivec4 grid; // nx, nz, event count, movement count
    vec4 events[4];
    vec4 height_gain; // takeoff target, landing target, recovery half-life, unused
} p;

int index_of(ivec2 c) { return c.y*p.grid.x+c.x; }
int face_index(ivec2 c) { return c.y*(p.grid.x+1)+c.x; }
bool inside(ivec2 c) { return all(greaterThanEqual(c,ivec2(0))) && all(lessThan(c,p.grid.xy)); }
bool valid(ivec2 c) { return inside(c) && terrain[index_of(c)].y>0.5; }
float bed(ivec2 c) { vec2 b=terrain[index_of(c)]; return b.x/max(b.y,0.00001); }
vec2 world_vector(vec2 v) { return wind.basis.xy*v.x+wind.basis.zw*v.y; }
vec2 phase() { return imageLoad(phase_output,ivec2(0)).xy; }
vec2 local_position(vec2 c) { return (c+0.5-vec2(p.grid.xy)*0.5)*p.physics.xy; }
bool finite_value(float v) { return !isnan(v) && !isinf(v); }
bool face_valid(ivec2 c,int axis) {
    ivec2 step=axis==0 ? ivec2(1,0) : ivec2(0,1);
    return valid(c) || valid(c-step);
}
float face_channel(ivec2 c,int channel) {
    if(any(lessThan(c,ivec2(0))) || any(greaterThan(c,p.grid.xy)) || !face_valid(c,channel%2)) return 0.0;
    return velocity[face_index(c)][channel];
}
float face_value(ivec2 c,int axis) { return face_channel(c,axis); }
float interpolate_face(vec2 c,int channel) {
    ivec2 lo=ivec2(floor(c));
    vec2 f=fract(c);
    return mix(mix(face_channel(lo,channel),face_channel(lo+ivec2(1,0),channel),f.x),
               mix(face_channel(lo+ivec2(0,1),channel),face_channel(lo+ivec2(1,1),channel),f.x),f.y);
}
vec2 flow(vec2 c) {
    return wind.velocity.xy
          +vec2(interpolate_face(c+vec2(0.5,0),0),interpolate_face(c+vec2(0,0.5),1))
          +vec2(interpolate_face(c+vec2(0.5,0),2),interpolate_face(c+vec2(0,0.5),3));
}
vec2 backward_displacement(vec2 c) {
    vec2 middle=c-0.5*p.physics.z*flow(c)/p.physics.xy;
    return p.physics.z*flow(middle);
}
vec2 departure(vec2 c) { return c-backward_displacement(c)/p.physics.xy; }
float pressure_at(ivec2 c) { return valid(c) ? pressure[index_of(c)] : 0.0; }
float divergence_at(ivec2 c) {
    return (face_value(c+ivec2(1,0),0)-face_value(c,0))/p.physics.x
          +(face_value(c+ivec2(0,1),1)-face_value(c,1))/p.physics.y;
}
float reservoir_height(vec2 origin,float support) {
    vec2 world=origin+wind.noise.zw;
    vec2 across=vec2(-wind.noise.y,wind.noise.x);
    vec2 q=vec2(dot(world,wind.noise.xy)/wind.shape.w,dot(world,across));
    float noise=textureLod(noise_map,q*wind.shape.z,0.0).r*2.0-1.0;
    float h=max(0.0,wind.world.z+wind.shape.x*noise-(wind.world.w>0.5 ? support : 0.0));
    return wind.shape.y>0.0 ? min(h,wind.shape.y) : h;
}
// Walk crossed cell faces, not just the endpoint: a trace cannot teleport across a hole.
// Return the first open perimeter and the fraction of the backward segment it took.
vec2 clip_trace(vec2 start,vec2 end,out ivec2 edge,out vec2 normal,out float fraction) {
    edge=ivec2(floor(start+0.5));
    normal=vec2(0);
    fraction=1.0;
    vec2 delta=end-start;
    ivec2 step=ivec2(sign(delta));
    vec2 interval=1.0/max(abs(delta),vec2(0.0000001));
    vec2 boundary=vec2(edge)+vec2(step)*0.5;
    vec2 next=vec2(abs(delta.x)>0.0000001 ? (boundary.x-start.x)/delta.x : 1e20,
                   abs(delta.y)>0.0000001 ? (boundary.y-start.y)/delta.y : 1e20);
    for(int i=0;i<128;i++) {
        int axis=next.x<=next.y ? 0 : 1;
        float t=next[axis];
        if(t>1.0) return end;
        ivec2 neighbor=edge;
        neighbor[axis]+=step[axis];
        if(!valid(neighbor)) {
            normal[axis]=float(step[axis]);
            fraction=clamp(t,0.0,1.0);
            return start+delta*max(0.0,t-0.00001*interval[axis]);
        }
        edge=neighbor;
        next[axis]+=interval[axis];
    }
    // Bound pathological traces without skipping an obstacle or reading out of bounds.
    atomicAdd(stats[1],1);
    fraction=clamp(min(next.x,next.y),0.0,1.0);
    return vec2(edge);
}
MaterialState exterior_material(ivec2 edge,vec2 normal,vec2 drift) {
    bool inlet=dot(wind.velocity.xy,normal)<-0.000001;
    return MaterialState(vec4(0.0,drift,0.0),vec4(inlet ? 1.0 : 0.0,inlet ? bed(edge) : 0.0,1,0));
}
MaterialState material_at(ivec2 c,ivec2 edge) {
    if(!valid(c)) return exterior_material(edge,normalize(vec2(c-edge)),phase());
    MaterialState value=material[index_of(c)];
    value.trace.x=0.0; // Do not feed the previous height back into interpolation.
    return value;
}
MaterialState interpolate_material(vec2 c) {
    ivec2 edge=ivec2(floor(c+0.5));
    ivec2 lo=ivec2(floor(c));
    vec2 f=fract(c);
    MaterialState a=material_at(lo,edge),b=material_at(lo+ivec2(1,0),edge);
    MaterialState d=material_at(lo+ivec2(0,1),edge),e=material_at(lo+ivec2(1,1),edge);
    return MaterialState(mix(mix(a.trace,b.trace,f.x),mix(d.trace,e.trace,f.x),f.y),
                         mix(mix(a.source,b.source,f.x),mix(d.source,e.source,f.x),f.y));
}
vec2 initial_at(ivec2 c) { return valid(c) ? vec2(initial_height[index_of(c)],1.0) : vec2(0); }
float reconstruct_height(ivec2 c,inout MaterialState value) {
    vec2 drift=value.trace.yz;
    // Upright unit-scale boxes have an orthonormal X/Z world basis.
    vec2 local_drift=vec2(dot(wind.basis.xy,drift),dot(wind.basis.zw,drift));
    vec2 origin=vec2(c)-local_drift/p.physics.xy;
    ivec2 lo=ivec2(floor(origin));
    vec2 f=fract(origin);
    vec2 original=mix(mix(initial_at(lo),initial_at(lo+ivec2(1,0)),f.x),
                      mix(initial_at(lo+ivec2(0,1)),initial_at(lo+ivec2(1,1)),f.x),f.y);
    float initial=original.y>0.000001 ? original.x/original.y : 0.0;
    // Source weights are also interpolated. Once the origin has left h0's support,
    // discard its residual initial weight instead of mixing in fictitious zero depth.
    if(!valid(ivec2(floor(origin+0.5)))) {
        float remaining=max(0.0,1.0-value.trace.w);
        value.trace.w=0.0;
        value.source.xy=remaining>0.000001 ? value.source.xy/remaining : vec2(0);
    }
    float total=value.trace.w+value.source.x;
    if(total>1.0) {
        value.trace.w/=total;
        value.source.xy/=total;
    }
    float supplied=0.0;
    if(value.source.x>0.000001) {
        vec2 world_origin=wind.world.xy+world_vector(local_position(vec2(c)))-drift;
        supplied=reservoir_height(world_origin,value.source.y/value.source.x);
    }
    return max(0.0,value.trace.w*initial+value.source.x*supplied);
}
float support_at(ivec2 c,int axis) {
    ivec2 neighbor=c-(axis==0 ? ivec2(1,0) : ivec2(0,1));
    if(!valid(c)) return bed(neighbor);
    return valid(neighbor) ? 0.5*(bed(c)+bed(neighbor)) : bed(c);
}
float square(float x) { return x*x; }
float event_weight(vec2 pos,float ground,vec4 event) {
    return (1.0-smoothstep(0.0,p.interaction.x,length(pos-event.xz)))
          *(1.0-smoothstep(0.2,1.5,abs(ground-event.y)));
}
float update_height_gain(ivec2 c,float previous) {
    float gain=mix(1.0,previous,exp2(-p.physics.z/p.height_gain.z));
    vec2 pos=local_position(vec2(c));
    for(int i=0;i<p.grid.z;i++) {
        vec4 event=p.events[i];
        float target=event.w<0.0 ? p.height_gain.x : p.height_gain.y;
        if(target==1.0) continue; // A neutral target disables new gain injection.
        gain=mix(gain,target,abs(event.w)*event_weight(pos,bed(c),event));
    }
    return clamp(gain,0.0,2.0);
}
vec2 radial_impulse(vec2 pos,float ground) {
    vec2 delta=vec2(0);
    for(int i=0;i<p.grid.z;i++) {
        vec2 offset=pos-p.events[i].xz;
        float r=length(offset);
        float weight=event_weight(pos,ground,p.events[i]);
        delta+=p.interaction.y*p.events[i].w*weight*offset/max(r,0.00001);
    }
    return delta;
}
vec2 movement_velocity(vec2 pos,float ground,vec2 current) {
    for(int i=0;i<p.grid.w;i++) {
        Movement m=movement.samples[i];
        vec2 travel=m.end.xz-m.start.xz;
        float t=clamp(dot(pos-m.start.xz,travel)/max(dot(travel,travel),0.000001),0.0,1.0);
        vec3 center=mix(m.start.xyz,m.end.xyz,t);
        float vertical=1.0-smoothstep(0.15,0.8,abs(ground-center.y));
        if(vertical<=0.0) continue;
        float speed=length(m.motion.xy),radius=m.start.w;
        vec2 forward=m.motion.xy/max(speed,0.000001),side=vec2(-forward.y,forward.x);
        vec2 offset=(pos-center.xz)/radius;
        float a=dot(offset,forward),b=dot(offset,side);
        if(abs(a)>5.0 || abs(b)>3.5) continue;
        float front=exp(-square((a-0.5)/0.95)-square(b/1.15))*smoothstep(-0.2,0.5,a);
        float flank=exp(-square(a/1.15)-square((abs(b)-0.85)/0.65));
        float wake=exp(-square((a+1.5)/1.5)-square(b/1.6))*(1.0-smoothstep(-0.3,0.2,a));
        vec2 field=vec2(0.9*front+0.55*m.motion.w*wake,0.65*sign(b)*flank);
        for(int s=-1;s<=1;s+=2) {
            vec2 q=vec2(a+1.4,b-float(s)*0.9);
            field+=0.35*m.motion.w*float(-s)*vec2(-q.y,q.x)*exp(-dot(q,q)/0.8);
        }
        float envelope=max(front,max(flank,m.motion.w*wake));
        if(envelope<0.001) continue;
        vec2 target=speed*(forward*field.x+side*field.y)/envelope;
        float exposure=m.motion.z*min(1.0,2.0*radius/max(length(travel),0.000001));
        current=mix(current,target,1.0-exp(-m.end.w*vertical*envelope*exposure));
    }
    return current;
}

void main() {
    ivec2 c=ivec2(gl_GlobalInvocationID.xy);
    int stage=int(p.interaction.z);
    if(stage==0 || stage==7) {
        if(any(notEqual(c,ivec2(0)))) return;
        if(stage==0) { stats[2]=0; stats[3]=0; }
        else imageStore(phase_output,ivec2(0),vec4(phase()+world_vector(wind.velocity.xy)*p.physics.z,0,0));
        return;
    }
    if(stage==1 || stage==2 || stage==5) {
        if(any(greaterThan(c,p.grid.xy))) return;
        vec4 result=vec4(0);
        for(int axis=0;axis<2;axis++) {
            if(!face_valid(c,axis)) continue;
            vec2 offset=axis==0 ? vec2(0.5,0) : vec2(0,0.5);
            vec2 point=vec2(c)-offset;
            if(stage==1) {
                vec2 back=departure(point)+offset;
                result[axis]=interpolate_face(back,axis);
                result[axis+2]=interpolate_face(back,axis+2);
            }
            if(stage==2) {
                float ground=support_at(c,axis);
                vec2 impulse=radial_impulse(local_position(point),ground);
                float radial=face_channel(c,axis+2)+impulse[axis];
                vec2 absolute=flow(point)+impulse;
                absolute[axis]=face_value(c,axis)+wind.velocity[axis]+radial;
                vec2 exchange=movement_velocity(local_position(point),ground,absolute)-absolute;
                float damping=exp(-p.physics.w*p.physics.z);
                result[axis]=(face_value(c,axis)+exchange[axis])*damping;
                result[axis+2]=radial*damping;
            }
            if(stage==5) {
                ivec2 step=axis==0 ? ivec2(1,0) : ivec2(0,1);
                result[axis]=face_value(c,axis)-p.physics.z*(pressure_at(c)-pressure_at(c-step))/p.physics[axis];
                result[axis+2]=face_channel(c,axis+2);
            }
            if(!finite_value(result[axis]) || !finite_value(result[axis+2])) {
                atomicAdd(stats[0],1);
                result[axis]=0.0;
                result[axis+2]=0.0;
            }
        }
        next_velocity[face_index(c)]=result;
        return;
    }
    if(!inside(c)) return;
    int i=index_of(c);
    if(stage==3) {
        float d=valid(c) ? divergence_at(c) : 0.0;
        divergence[i]=d/p.physics.z;
        pressure[i]=0.0;
        next_pressure[i]=0.0;
        atomicMax(stats[2],floatBitsToUint(abs(d)));
    }
    if(stage==4) {
        vec2 w=1.0/(p.physics.xy*p.physics.xy);
        float sum=w.x*(pressure_at(c+ivec2(1,0))+pressure_at(c-ivec2(1,0)))
                 +w.y*(pressure_at(c+ivec2(0,1))+pressure_at(c-ivec2(0,1)));
        next_pressure[i]=valid(c) ? (sum-divergence[i])/(2.0*(w.x+w.y)) : 0.0;
    }
    if(stage==6) {
        MaterialState result=MaterialState(vec4(0),vec4(0,0,1,0));
        if(valid(c)) {
            ivec2 edge;
            vec2 normal;
            float fraction;
            vec2 travel=backward_displacement(vec2(c));
            vec2 back=clip_trace(vec2(c),vec2(c)-travel/p.physics.xy,edge,normal,fraction);
            bool crossed=dot(normal,normal)>0.0;
            if(crossed) {
                vec2 drift=phase()+world_vector(wind.velocity.xy)*p.physics.z*(1.0-fraction);
                result=exterior_material(edge,normal,drift);
            } else result=interpolate_material(back);
            // Avoid subtracting almost equal grid coordinates on every normal tick.
            vec2 travelled=(fraction<1.0 && !crossed) ? (vec2(c)-back)*p.physics.xy : travel*fraction;
            result.trace.yz+=world_vector(travelled);
            result.trace.w=clamp(result.trace.w,0.0,1.0);
            result.source.x=clamp(result.source.x,0.0,1.0);
            result.source.z=update_height_gain(c,result.source.z);
            result.trace.x=reconstruct_height(c,result)*result.source.z;
            if(any(isnan(result.trace)) || any(isinf(result.trace)) || any(isnan(result.source)) || any(isinf(result.source))) {
                atomicAdd(stats[0],1);
                result=MaterialState(vec4(0),vec4(0,0,1,0));
            }
            atomicMax(stats[3],floatBitsToUint(abs(divergence_at(c))));
        }
        next_material[i]=result;
        imageStore(height_output,c,vec4(result.trace.x,0,0,0));
        imageStore(displacement_output,c,vec4(result.trace.yz,0,0));
    }
}
