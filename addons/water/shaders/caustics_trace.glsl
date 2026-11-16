#[compute]
#version 450
layout(local_size_x=8,local_size_y=8) in;
layout(set=0,binding=0,std430) readonly buffer Configuration {
    vec4 fft; vec4 region; vec4 extent; ivec4 flags;
    vec4 water; vec4 tile; vec4 sun; vec4 medium; vec4 foam;
} cfg;
layout(set=0,binding=1) uniform sampler2D fft_map;
layout(set=0,binding=2) uniform sampler2D swe_map;
struct LightHit { vec4 origin; vec4 hit; vec4 transmission; };
layout(set=0,binding=3,std430) writeonly buffer Hits { LightHit hits[]; };
layout(set=0,binding=4) uniform sampler2D foam_map;
layout(set=0,binding=5) uniform sampler2D offshore_foam_map;
#define fft_length cfg.fft.x
#define fft_resolution cfg.fft.y
#define height_gain cfg.fft.z
#define choppiness cfg.fft.w
#define region_origin cfg.region.xy
#define region_rotation cfg.region.zw
#define region_size cfg.extent.xy
#define blend_depth cfg.extent.z
#define edge_width cfg.extent.w
#define fft_enabled (cfg.flags.x!=0)
#define swe_enabled (cfg.flags.y!=0)
#define swe_resolution cfg.flags.z
#define sea_level cfg.water.x
#define dry_depth cfg.water.y
#define shore_normal_strength cfg.foam.z
#define swe_model_blend ((int(cfg.foam.w)&16)!=0)
#define swe_fft_edges (int(cfg.foam.w)&15)
#include "res://addons/water/shaders/surface.gdshaderinc"

// Only fully covered bilinear patches are receivers: no interpolation across
// missing bed. Grid DDA visits every patch in front-to-back order, solving BOTH
// quadratic roots within each patch (a sign-only marcher misses narrow ridges).
vec2 receiver(vec2 world) {
    if(!swe_enabled) return vec2(sea_level-cfg.water.w,1);
    vec2 uv=region_uv(world);
    if(!in_region(uv)) return vec2(0,0);
    vec2 q=uv*float(swe_resolution)-0.5;
    ivec2 c=ivec2(floor(q)); vec2 f=fract(q);
    float h=0.0,valid=1.0;
    for(int z=0;z<2;z++) for(int x=0;x<2;x++) {
        vec4 value=texelFetch(swe_map,clamp(c+ivec2(x,z),ivec2(0),ivec2(swe_resolution-1)),0);
        valid*=value.w;
        h+=value.z*(x==0?1.0-f.x:f.x)*(z==0?1.0-f.y:f.y);
    }
    return vec2(h+sea_level,valid);
}
float gap(vec3 o,vec3 d,float t) { vec3 p=o+d*t; return p.y-receiver(p.xz).x; }
float patch_hit(vec3 o,vec3 d,float begin,float end) {
    if(receiver((o+d*((begin+end)*0.5)).xz).y<0.5) return -1.0;
    float a=gap(o,d,begin),m=gap(o,d,(begin+end)*0.5),b=gap(o,d,end);
    float aa=2.0*(b+a-2.0*m),bb=b-a-aa,root=2.0;
    if(abs(a)<0.00002) return begin;
    if(abs(aa)<0.00001) { if(abs(bb)>0.000001) root=-a/bb; }
    else {
        float disc=bb*bb-4.0*aa*a;
        if(disc>=0.0) {
            float q=-0.5*(bb+(bb>=0.0?1.0:-1.0)*sqrt(disc));
            float r0=q/aa,r1=abs(q)>1e-12?a/q:2.0;
            if(r0>=-0.00001&&r0<=1.00001) root=r0;
            if(r1>=-0.00001&&r1<=1.00001) root=min(root,r1);
        }
    }
    return root>=-0.00001&&root<=1.00001?mix(begin,end,clamp(root,0.0,1.0)):-1.0;
}
vec2 trace_bed(vec3 o,vec3 d) {
    float limit=cfg.sun.w;
    if(!swe_enabled) {
        float t=(sea_level-cfg.water.w-o.y)/min(d.y,-0.000001);
        return vec2(d.y<0.0&&t>0.0&&t<=limit?t:-1.0,1);
    }
    vec2 q=region_uv(o.xz)*float(swe_resolution)-0.5;
    vec2 dq=vec2(region_rotation.x*d.x-region_rotation.y*d.z,region_rotation.y*d.x+region_rotation.x*d.z)/region_size*float(swe_resolution);
    float begin=0.0,end=limit;
    for(int axis=0;axis<2;axis++) {
        if(abs(dq[axis])<1e-10) { if(q[axis]<-0.5||q[axis]>float(swe_resolution)-0.5) return vec2(-1,0); }
        else {
            float a=(-0.5-q[axis])/dq[axis],b=(float(swe_resolution)-0.5-q[axis])/dq[axis];
            begin=max(begin,min(a,b)); end=min(end,max(a,b));
        }
    }
    float t=begin;
    for(int visit=0;visit<int(cfg.medium.w);visit++) {
        if(t>=end) return vec2(-1,visit);
        vec2 p=q+dq*t+sign(dq)*0.00001;
        ivec2 cell=ivec2(floor(p)); float leave=end;
        for(int axis=0;axis<2;axis++) if(abs(dq[axis])>1e-10) {
            float boundary=float(cell[axis])+(dq[axis]>0.0?1.0:0.0);
            leave=min(leave,(boundary-q[axis])/dq[axis]);
        }
        float hit=patch_hit(o,d,t,leave);
        if(hit>0.0) return vec2(hit,visit+1);
        t=max(leave,t+max(0.000001,abs(t)*0.0000002));
    }
    return vec2(-2,cfg.medium.w); // traversal exhaustion is a miss, not a fabricated floor
}
void main() {
    ivec2 id=ivec2(gl_GlobalInvocationID.xy); int n=cfg.flags.w;
    if(any(greaterThan(id,ivec2(n)))) return;
    vec3 sun=normalize(cfg.sun.xyz);
    vec3 flat_ray=refract(-sun,vec3(0,1,0),1.0/cfg.water.z);
    vec2 center=cfg.tile.xy;
    float center_depth=max(sea_level-receiver(center).x,0.0);
    vec2 base=center+(vec2(id)/float(n)-0.5)*cfg.tile.zw*1.5-flat_ray.xz*center_depth/max(-flat_ray.y,0.001);
    vec3 origin=surface(base);
    float footprint=max(cfg.tile.z,cfg.tile.w)*1.5/float(n)*fft_resolution/fft_length;
    float delta=clamp(footprint,0.02,1.0)*fft_length/fft_resolution;
    vec3 normal=surface_normal_at(base,delta);
    float depth=origin.y-receiver(origin.xz).x;
    normal=apply_detail_slope(normal,shore_detail_slope(base,depth,footprint));
    vec3 ray=refract(-sun,normal,1.0/cfg.water.z);
    vec2 result=trace_bed(origin,ray);
    bool valid=sun.y>0.0&&dot(normal,sun)>0.0&&result.x>0.0;
    vec2 uv=region_uv(base);
    if(swe_enabled&&in_region(uv)) { vec4 q=sample_swe(uv); valid=valid&&q.w>0.5&&q.y>dry_depth; }
    float cosine=clamp(dot(normal,sun),0.0,1.0);
    float f0=pow((cfg.water.z-1.0)/(cfg.water.z+1.0),2.0);
    float fresnel=cfg.water.z<=1.000001?0.0:f0+(1.0-f0)*pow(1.0-cosine,5.0);
    float foam_transmission=1.0;
    if(cfg.foam.x>0.5) {
        float near_density=0.0,w=0.0;
        if(swe_enabled&&in_region(uv)) {
            near_density=dot(textureLod(foam_map,uv,0.0).rg,vec2(1.0));
            w=swe_weight(uv,sample_swe(uv));
        }
        float far_coverage=fft_enabled?textureLod(offshore_foam_map,base/fft_length+vec2(0.5+0.5/fft_resolution),0.0).r:0.0;
        foam_transmission=mix(1.0-far_coverage,exp(-near_density/max(cfg.foam.y,0.0001)),w);
    }
    vec3 transmission=(1.0-fresnel)*exp(-cfg.medium.xyz*max(result.x,0.0))*foam_transmission;
    int index=id.y*(n+1)+id.x;
    hits[index]=LightHit(vec4(origin,valid?1.0:0.0),vec4(origin+ray*max(result.x,0.0),result.x),vec4(transmission,result.y));
}
