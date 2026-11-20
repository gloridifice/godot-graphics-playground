#[compute]
#version 450
layout(local_size_x=8,local_size_y=8) in;
layout(set=0,binding=0,std140) uniform Params {
    mat4 inv_proj, camera; uvec4 capacity,slot_base,bin_base; vec4 tuning; ivec4 grid,options; vec4 display;
} p;
layout(set=0,binding=1) uniform sampler2D depth_tex;
layout(set=0,binding=2) uniform sampler2D normal_tex;
layout(set=0,binding=3) uniform sampler2D receiver_tex;
layout(rgba16f,set=0,binding=4) uniform image2D viewport_color;
layout(rgba16f,set=0,binding=5) uniform image2D raw_scratch;
layout(rgba16f,set=0,binding=6) readonly uniform image2D prev_light;
layout(rgba16f,set=0,binding=7) uniform image2D curr_light; // irradiance + E[Y²]
layout(rgba16f,set=0,binding=8) readonly uniform image2D prev_geom;
layout(rgba16f,set=0,binding=9) uniform image2D curr_geom; // oct world normal, eye distance, history length
layout(push_constant,std430) uniform Control { mat4 prev_vp; vec4 prev_eye; ivec4 op; } pc;
const vec3 Y = vec3(.2126,.7152,.0722);
vec2 oct_encode(vec3 n) {
    n /= dot(abs(n),vec3(1));
    return n.z>=0. ? n.xy : (1.-abs(n.yx))*mix(vec2(-1),vec2(1),greaterThanEqual(n.xy,vec2(0)));
}
vec3 oct_decode(vec2 e) {
    vec3 n=vec3(e,1.-abs(e.x)-abs(e.y));
    n.xy += mix(vec2(1),vec2(-1),greaterThanEqual(n.xy,vec2(0))) * max(-n.z,0.);
    return normalize(n);
}
bool inside(ivec2 q) { return all(greaterThanEqual(q,ivec2(0))) && all(lessThan(q,p.grid.xy)); }
void temporal(ivec2 q) {
    vec4 cur=imageLoad(raw_scratch,q);
    if (cur.a==0.) { imageStore(curr_light,q,vec4(0)); imageStore(curr_geom,q,vec4(0)); return; }
    vec2 uv=(vec2(q)+.5)/vec2(p.grid.xy);
    vec4 view=p.inv_proj*vec4(uv*2.-1.,texelFetch(depth_tex,q,0).r,1);
    vec3 pos=(p.camera*vec4(view.xyz/view.w,1)).xyz;
    vec3 n=normalize(mat3(p.camera)*(texelFetch(normal_tex,q,0).xyz*2.-1.));
    vec4 clip=pc.prev_vp*vec4(pos,1);
    vec4 history=vec4(0); float mass=0., length_sum=0.;
    if (pc.op.y!=0 && clip.w>1e-6) {
        vec2 prev=(clip.xy/clip.w*.5+.5)*vec2(p.grid.xy)-.5;
        ivec2 base=ivec2(floor(prev)); vec2 f=fract(prev);
        float expected=distance(pos,pc.prev_eye.xyz);
        for (int i=0;i<4;i++) {
            ivec2 shift=ivec2(i&1,i>>1), j=base+shift;
            if (!inside(j)) continue;
            vec4 g=imageLoad(prev_geom,j);
            if (g.w<1. || abs(g.z-expected)>max(.025,.01*expected) || dot(oct_decode(g.xy),n)<.94) continue;
            vec2 w=mix(1.-f,f,vec2(shift)); float wt=w.x*w.y;
            history+=imageLoad(prev_light,j)*wt; mass+=wt; length_sum+=wt*g.w;
        }
    }
    float len=mass>.01?min(16.,1.+length_sum/mass):1.;
    float lum=dot(cur.rgb,Y);
    vec4 estimate=vec4(cur.rgb,lum*lum);
    if (len>1.) estimate=mix(history/mass,estimate,1./len);
    imageStore(curr_light,q,estimate);
    imageStore(curr_geom,q,vec4(oct_encode(n),length(view.xyz/view.w),len));
}
void spatial(ivec2 q) {
    bool last=pc.op.x==2;
    vec4 center=imageLoad(curr_light,q), g=imageLoad(curr_geom,q);
    if (g.w==0.) {
        if (!last) imageStore(raw_scratch,q,vec4(0));
        else if (p.options.y==1 && texelFetch(depth_tex,q,0).r>0.) imageStore(viewport_color,q,vec4(0,0,0,imageLoad(viewport_color,q).a));
        return;
    }
    vec3 n=oct_decode(g.xy);
    float l=dot(center.rgb,Y), sigma=.015+3.*sqrt(max(0.,center.w-l*l));
    vec3 sum=vec3(0); float weights=0.;
    for (int y=-1;y<=1;y++) for (int x=-1;x<=1;x++) {
        ivec2 j=q+ivec2(x,y)*pc.op.x;
        if (!inside(j)) continue;
        vec4 s=imageLoad(curr_geom,j); if (s.w==0.) continue;
        vec3 val=last?imageLoad(raw_scratch,j).rgb:imageLoad(curr_light,j).rgb;
        float w=float((2-abs(x))*(2-abs(y)))*pow(max(0.,dot(n,oct_decode(s.xy))),32.);
        w*=exp(-abs(dot(val,Y)-l)/sigma - abs(s.z-g.z)/max(.02,.006*g.z*float(pc.op.x)));
        sum+=w*val; weights+=w;
    }
    vec3 filtered=weights>1e-6?sum/weights:center.rgb;
    if (!last) { imageStore(raw_scratch,q,vec4(filtered,1)); return; }
    vec4 original=imageLoad(viewport_color,q);
    vec3 indirect=filtered*texelFetch(receiver_tex,q,0).rgb*p.display.x;
    imageStore(viewport_color,q,vec4(indirect+(p.options.y==0?original.rgb:vec3(0)),original.a));
}
void main() {
    ivec2 q=ivec2(gl_GlobalInvocationID.xy); if (!inside(q)) return;
    if (pc.op.x==0) temporal(q); else spatial(q);
}
