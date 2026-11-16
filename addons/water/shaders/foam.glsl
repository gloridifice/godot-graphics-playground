#[compute]
#version 450
layout(local_size_x=8,local_size_y=8) in;
struct FoamRecord { vec4 amount; vec4 coordinates; }; // total,px,pz,R; world back-displacements A/B
layout(set=0,binding=0,std430) buffer Foam { FoamRecord records[]; };
layout(set=0,binding=1,std430) readonly buffer Water { vec4 states[]; };
layout(set=0,binding=2,std430) readonly buffer Terrain { vec2 terrain[]; };
layout(set=0,binding=3,std430) buffer Control { uint stats[]; };
layout(set=0,binding=4,std430) readonly buffer Configuration {
    vec4 source; vec4 front; vec4 response; vec4 offshore;
    ivec4 mode; vec4 lifetime; vec4 geometry; ivec4 grid;
} f;
layout(set=0,binding=5,std430) buffer FluxX { vec4 flux_x[]; };
layout(set=0,binding=6,std430) buffer FluxZ { vec4 flux_z[]; };
layout(push_constant,std430) uniform Params { ivec4 roles; ivec4 stage; } p; // old,new,original,RK; pass 0 flux/1 update/2 clear
int cells() { return f.grid.x*f.grid.x; }
int idx(ivec2 c) { return c.y*f.grid.x+c.x; }
bool inside(ivec2 c) { return all(greaterThanEqual(c,ivec2(0)))&&all(lessThan(c,ivec2(f.grid.x))); }
bool valid(ivec2 c) { return inside(c)&&terrain[idx(c)].y>0.5; }
vec3 water(ivec2 c,int role) { return states[role*cells()+idx(clamp(c,ivec2(0),ivec2(f.grid.x-1)))].xyz; }
vec2 velocity(vec3 q) { return q.yz/max(q.x,0.005); }
vec4 amount(ivec2 c) { return records[p.roles.x*cells()+idx(c)].amount; }
float dt() { return uintBitsToFloat(stats[3]); }
float response_duration(float rate,float duration) {
    float x=rate*duration;
    return x<0.001?duration*(1.0-0.5*x+x*x/6.0):(1.0-exp(-x))/rate;
}
vec2 bounded(vec2 v) { return v*min(1.0,12.0/max(length(v),0.000001)); }
vec2 foam_speed(vec4 q,vec2 water_velocity) { return bounded(q.x>0.0?q.yz/q.x:water_velocity*f.response.y); }
vec2 coupled(vec2 previous,vec2 v,float duration) {
    if((f.grid.w&2)==0) return previous;
    return f.response.z<=0.0?v*f.response.y:mix(previous,v*f.response.y,1.0-exp(-duration/f.response.z));
}
vec2 transport(ivec2 c) {
    vec2 v=velocity(water(c,p.roles.x));
    return bounded(coupled(foam_speed(amount(c),v),v,dt()*0.5));
}
bool open_face(ivec2 n,int axis,float side) {
    return !inside(n)&&(f.grid.z&(1<<(axis*2+(side>0.0?1:0))))!=0;
}
bool blocked(ivec2 a,ivec2 b,int water_role) {
    if(!valid(a)||!valid(b)) return true;
    float za=terrain[idx(a)].x,zb=terrain[idx(b)].x;
    return max(za,zb)>=max(za+water(a,water_role).x,zb+water(b,water_role).x);
}
vec3 limited(vec3 a,vec3 b) { return 0.5*(sign(a)+sign(b))*min(min(2.0*abs(a),2.0*abs(b)),0.5*abs(a+b)); }
vec3 slope(ivec2 c,int axis) {
    ivec2 d=ivec2(0); d[axis]=1;
    vec3 q=amount(c).xyz;
    if(f.mode.z<2||q.x<=0.0||!valid(c-d)||!valid(c+d)||blocked(c,c-d,p.roles.x)||blocked(c,c+d,p.roles.x)) return vec3(0);
    if(min(water(c,p.roles.x).x,min(water(c-d,p.roles.x).x,water(c+d,p.roles.x).x))<=0.02) return vec3(0);
    vec3 left=amount(c-d).xyz,right=amount(c+d).xyz;
    vec3 s=limited(q-left,right-q);
    vec2 v=q.yz/q.x;
    vec2 vl=left.x>0.0?left.yz/left.x:v,vr=right.x>0.0?right.yz/right.x:v;
    vec2 tolerance=0.000002*max(vec2(1),abs(v));
    vec2 lo=min(v,min(vl,vr))-tolerance,hi=max(v,max(vl,vr))+tolerance;
    float scale=min(1.0,2.0*q.x/max(abs(s.x),1e-30));
    vec2 lower=2.0*max(vec2(0),q.yz-lo*q.x)/max(abs(s.yz-lo*s.x),vec2(1e-30));
    vec2 upper=2.0*max(vec2(0),hi*q.x-q.yz)/max(abs(hi*s.x-s.yz),vec2(1e-30));
    return s*min(scale,min(min(lower.x,lower.y),min(upper.x,upper.y)));
}
vec3 face_flux(ivec2 c,int axis,float side) {
    ivec2 n=c; n[axis]+=int(side);
    if(!valid(n)) {
        if(open_face(n,axis,side)) return max(0.0,transport(c)[axis]*side)*amount(c).xyz*side;
        return vec3(0);
    }
    if(blocked(c,n,p.roles.x)) return vec3(0);
    ivec2 a=side>0.0?c:n,b=side>0.0?n:c;
    vec3 qa=amount(a).xyz+0.5*slope(a,axis),qb=amount(b).xyz-0.5*slope(b,axis);
    vec2 av=velocity(water(a,p.roles.x)),bv=velocity(water(b,p.roles.x));
    float va=bounded(coupled(foam_speed(vec4(qa,0),av),av,dt()*0.5))[axis];
    float vb=bounded(coupled(foam_speed(vec4(qb,0),bv),bv,dt()*0.5))[axis];
    float signal=max(abs(va),abs(vb));
    return (water(a,p.roles.x).x>0.003?0.5*(va+signal)*qa:vec3(0))+(water(b,p.roles.x).x>0.003?0.5*(vb-signal)*qb:vec3(0));
}
float threshold(float value,float cutoff,float width) { return width>0.0?smoothstep(cutoff,cutoff+width,value):(value>cutoff?1.0:0.0); }
vec3 flow_at(vec2 grid) {
    ivec2 base=ivec2(floor(grid)); vec2 fraction=fract(grid); vec3 value=vec3(0);
    for(int z=0;z<2;z++) for(int x=0;x<2;x++) {
        ivec2 c=base+ivec2(x,z);
        if(!valid(c)||water(c,p.roles.x).x<=0.00001) continue;
        float w=(x==0?1.0-fraction.x:fraction.x)*(z==0?1.0-fraction.y:fraction.y);
        value+=w*vec3(velocity(water(c,p.roles.x)),1);
    }
    return value;
}
float front_weight(ivec2 c) {
    vec2 v=velocity(water(c,p.roles.x)); float speed=length(v);
    if(speed<=0.02) return 0.0;
    vec2 direction=v/speed; float strength=0.0;
    for(int sample_index=1;sample_index<=4;sample_index++) {
        float distance=f.front.y*float(sample_index)*0.25;
        vec2 grid=vec2(c)+direction*distance/f.geometry.xy;
        if(any(lessThan(grid,vec2(0)))||any(greaterThan(grid,vec2(f.grid.x-1)))) continue;
        vec3 flow=flow_at(grid);
        if(flow.z>0.000001) strength=max(strength,max(0.0,dot(v-flow.xy/flow.z,direction))/distance);
    }
    return threshold(strength,f.front.z,f.front.w)*smoothstep(0.02,0.1,speed);
}
float edge_weight(ivec2 c) {
    // Match the SWE relaxation source, supplied below in the per-dispatch push.
    vec2 uv=(vec2(c)+0.5)/float(f.grid.x); float edge=0.0;
    float width=intBitsToFloat(p.stage.y);
    for(int axis=0;axis<2;axis++) {
        if((f.grid.z&(1<<(axis*2)))!=0) edge=max(edge,1.0-smoothstep(0.0,width,uv[axis]));
        if((f.grid.z&(1<<(axis*2+1)))!=0) edge=max(edge,smoothstep(1.0-width,1.0,uv[axis]));
    }
    return edge;
}
vec4 sampled_amount(vec2 grid,int role,ivec2 receiver) {
    ivec2 base=ivec2(floor(grid)); vec2 fraction=fract(grid); vec4 value=vec4(0);
    for(int z=0;z<2;z++) for(int x=0;x<2;x++) {
        ivec2 c=base+ivec2(x,z);
        if(!valid(c)||water(c,role).x<=0.003) continue;
        float w=(x==0?1.0-fraction.x:fraction.x)*(z==0?1.0-fraction.y:fraction.y);
        ivec2 xleg=ivec2(c.x,receiver.y),zleg=ivec2(receiver.x,c.y);
        if(blocked(receiver,xleg,role)||blocked(receiver,zleg,role)||blocked(xleg,c,role)||blocked(zleg,c,role)) continue;
        value+=records[role*cells()+idx(c)].amount*w;
    }
    return value;
}
vec4 sampled_coordinates(vec2 grid,int role,ivec2 receiver) {
    ivec2 base=ivec2(floor(grid)); vec2 fraction=fract(grid); vec4 value=vec4(0); float sum=0.0;
    for(int z=0;z<2;z++) for(int x=0;x<2;x++) {
        ivec2 c=base+ivec2(x,z);
        if(!valid(c)||water(c,role).x<=0.003) continue;
        ivec2 xleg=ivec2(c.x,receiver.y),zleg=ivec2(receiver.x,c.y);
        if(blocked(receiver,xleg,role)||blocked(receiver,zleg,role)||blocked(xleg,c,role)||blocked(zleg,c,role)) continue;
        float w=(x==0?1.0-fraction.x:fraction.x)*(z==0?1.0-fraction.y:fraction.y);
        value+=records[role*cells()+idx(c)].coordinates*w; sum+=w;
    }
    return value/max(sum,0.000001);
}
vec2 dual_sources(vec2 amount,float source,float duration) {
    float a=0.69314718056/f.lifetime.x,b=0.69314718056/f.lifetime.y;
    float transfer=exp(-min(a,b)*duration)*response_duration(abs(a-b),duration);
    float generated=response_duration(b,duration)-transfer;
    if(max(a,b)*duration<0.05) {
        float x=a*duration,y=b*duration;
        generated=duration*x*(0.5-(x+y)/6.0+(x*x+x*y+y*y)/24.0-(x*x*x+x*x*y+x*y*y+y*y*y)/120.0);
    }
    return max(vec2(0),vec2(amount.x*exp(-a*duration)+source*response_duration(a,duration),amount.y*exp(-b*duration)+f.lifetime.z*(a*amount.x*transfer+source*generated)));
}
void main() {
    ivec2 c=ivec2(gl_GlobalInvocationID.xy);
    if(!inside(c)) return;
    int i=idx(c),target=p.roles.y*cells()+i;
    if(p.stage.x==2) {
        for(int role=0;role<3;role++) records[role*cells()+i]=FoamRecord(vec4(0),vec4(0));
        return;
    }
    float duration=dt();
    if(p.stage.x==0) {
        if(!valid(c)||duration<=0.0||f.mode.x==0||f.mode.w!=0) { flux_x[i]=vec4(0); flux_z[i]=vec4(0); return; }
        flux_x[i]=vec4(face_flux(c,0,1.0),0); flux_z[i]=vec4(face_flux(c,1,1.0),0); return;
    }
    if(f.mode.x==0||duration<=0.0) { records[target]=records[p.roles.x*cells()+i]; return; }
    if(!valid(c)) { records[target]=FoamRecord(vec4(0),vec4(0)); return; }
    vec4 q=amount(c);
    if(f.mode.w==0) {
        vec3 left=valid(c-ivec2(1,0))?flux_x[idx(c-ivec2(1,0))].xyz:face_flux(c,0,-1.0);
        vec3 down=valid(c-ivec2(0,1))?flux_z[idx(c-ivec2(0,1))].xyz:face_flux(c,1,-1.0);
        q.xyz-=duration*((flux_x[i].xyz-left)/f.geometry.x+(flux_z[i].xyz-down)/f.geometry.y);
        if(p.roles.w==2) q.xyz=0.5*(records[p.roles.z*cells()+i].amount.xyz+q.xyz);
    }
    if(p.roles.w==1) { records[target]=FoamRecord(q,vec4(0)); return; }
    vec3 water_new=water(c,p.roles.y),original=water(c,p.roles.z);
    vec2 v=velocity(water_new),advect=transport(c);
    if(p.roles.w==2) {
        vec4 old=records[p.roles.z*cells()+i].amount;
        advect=bounded(0.5*(advect+coupled(foam_speed(old,velocity(original)),velocity(original),duration*0.5)));
    }
    if(f.mode.w!=0) advect=p.roles.w==2?0.5*(velocity(original)+velocity(water(c,p.roles.x))):velocity(original);
    vec2 offset=advect*duration/f.geometry.xy;
    for(int axis=0;axis<2;axis++) {
        ivec2 donor=c; donor[axis]-=int(sign(offset[axis]));
        if(blocked(c,donor,p.roles.z)) offset[axis]=0.0;
    }
    vec2 departure=vec2(c)-offset;
    vec2 vx1=velocity(water(clamp(c+ivec2(1,0),ivec2(0),ivec2(f.grid.x-1)),p.roles.x));
    vec2 vx0=velocity(water(clamp(c-ivec2(1,0),ivec2(0),ivec2(f.grid.x-1)),p.roles.x));
    vec2 vz1=velocity(water(clamp(c+ivec2(0,1),ivec2(0),ivec2(f.grid.x-1)),p.roles.x));
    vec2 vz0=velocity(water(clamp(c-ivec2(0,1),ivec2(0),ivec2(f.grid.x-1)),p.roles.x));
    float divergence=(vx1.x-vx0.x)/(2.0*f.geometry.x)+(vz1.y-vz0.y)/(2.0*f.geometry.y);
    float wave_speed=sqrt(intBitsToFloat(p.stage.w)*max(water_new.x,0.001));
    float rising=max(0.0,(water_new.x-original.x)/duration)/wave_speed;
    float bore=smoothstep(1.0,1.4,length(v)/wave_speed);
    float compression=smoothstep(0.1,0.6,max(-divergence,0.0));
    float background=f.source.x*f.source.y*threshold(rising,f.source.z,f.source.w)*mix(0.25,1.0,max(bore,compression));
    float edge=edge_weight(c),rate=intBitsToFloat(p.stage.z);
    float source=(background+f.front.x*front_weight(c))*smoothstep(0.003,0.03,water_new.x)*(1.0-edge)*(f.mode.y!=0?1.0:0.0);
    if(f.mode.w!=0) {
        vec4 sampled=sampled_amount(departure,p.roles.z,c);
        vec2 species=vec2(max(sampled.x-sampled.w,0.0),max(sampled.w,0.0))*exp(-divergence*duration-edge*rate*duration);
        species=dual_sources(species,source,duration);
        q=vec4(species.x+species.y,(species.x+species.y)*v,species.y);
    } else {
        q.xyz*=exp(-duration*edge*rate);
        float decay=exp(-f.response.x*duration),source_time=response_duration(f.response.x,duration);
        float density=max(q.x,0.0)*decay+source*source_time;
        vec2 desired=v*f.response.y,birth=bounded(v*f.response.w);
        if((f.grid.w&2)==0) q.yz=q.yz*decay+source*birth*source_time;
        else if(f.response.z<=0.0) q.yz=density*desired;
        else {
            float drag=1.0/f.response.z,response=exp(-drag*duration);
            q.yz=decay*(q.yz*response+max(q.x,0.0)*desired*(1.0-response))+source*(desired*source_time+(birth-desired)*response_duration(f.response.x+drag,duration));
        }
        q.x=density; q.w=0.0;
    }
    vec2 world_velocity=vec2(f.geometry.z*advect.x+f.geometry.w*advect.y,-f.geometry.w*advect.x+f.geometry.z*advect.y);
    vec4 coordinates=sampled_coordinates(departure,p.roles.z,c)+vec4(world_velocity,world_velocity)*duration;
    if(f.lifetime.w>0.0) {
        float phase=fract(uintBitsToFloat(stats[9])+uintBitsToFloat(stats[2])/f.lifetime.w);
        float next=phase+duration/f.lifetime.w;
        if(next>=1.0) coordinates.xy=world_velocity*(fract(next)*f.lifetime.w);
        if(fract(phase+0.5)+duration/f.lifetime.w>=1.0) coordinates.zw=world_velocity*(fract(next+0.5)*f.lifetime.w);
    }
    if(water_new.x<=0.003) { q=vec4(0); coordinates=vec4(0); }
    if(any(isnan(q))||any(isinf(q))||q.x< -0.00001) { atomicAdd(stats[4],1); q=vec4(0); }
    if(q.x<=0.0) q=vec4(0);
    q.yz=bounded(q.yz/max(q.x,1e-30))*q.x;
    records[target]=FoamRecord(q,coordinates);
}
