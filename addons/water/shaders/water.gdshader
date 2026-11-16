shader_type spatial;
render_mode depth_draw_always, cull_back, ambient_light_disabled;

uniform sampler2D screen_color : hint_screen_texture, repeat_disable, filter_linear;
uniform sampler2D screen_depth : hint_depth_texture, repeat_disable, filter_nearest;
uniform sampler2D fft_map : repeat_enable, filter_linear;
uniform sampler2D swe_map : repeat_disable, filter_nearest;
uniform bool fft_enabled = false;
uniform bool swe_enabled = false;
uniform bool swe_model_blend = true;
uniform int swe_fft_edges = 1;
uniform float fft_length = 128.0;
uniform float fft_resolution = 128.0;
uniform float height_gain = 1.0;
uniform float choppiness = 1.0;
uniform float sea_level = 0.0;
uniform vec2 region_origin = vec2(0.0);
uniform vec2 region_rotation = vec2(1.0, 0.0);
uniform vec2 region_size = vec2(64.0);
uniform int swe_resolution = 128;
uniform float blend_depth = 2.0;
uniform float edge_width = 0.2;
uniform float shore_normal_strength = 1.0;
uniform vec3 extinction = vec3(0.32, 0.10, 0.055);
uniform vec3 scattering = vec3(0.012, 0.035, 0.045);
uniform vec4 reflection_color : source_color = vec4(0.30, 0.48, 0.65, 1.0);
uniform sampler2D reflection_panorama : source_color, repeat_enable, filter_linear_mipmap;
uniform bool use_reflection_panorama = false;
uniform float refractive_index = 1.333;
uniform float water_roughness = 0.28;
uniform bool refraction_enabled = true;
uniform float refraction_strength = 1.0;
uniform float refraction_limit = 0.025;
uniform float dry_depth = 0.008;
uniform int debug_view = 0;
uniform bool caustics_enabled = false;
uniform sampler2D caustics_map : repeat_disable, filter_linear;
uniform vec2 caustics_center = vec2(0.0);
uniform vec2 caustics_size = vec2(64.0);
uniform float caustics_strength = 1.0;
uniform float caustics_filter = 1.0;
uniform float caustics_flat_depth = 6.0;
uniform vec3 caustics_sun = vec3(0.0,1.0,0.0);
varying vec3 surface_world;
varying vec2 base_world;
varying vec3 normal_world;

#include "res://addons/water/shaders/surface.gdshaderinc"
#include "res://addons/water/shaders/foam.gdshaderinc"
void vertex() {
    vec3 base=(MODEL_MATRIX*vec4(VERTEX,1.0)).xyz;
    base_world=base.xz;
    surface_world=surface(base.xz);
    normal_world=surface_normal(base.xz);
    foam_normal_world=foam_enabled?foam_normal(base.xz):normal_world;
    vec3 rendered=surface_world+vec3(0.0,foam_height_offset(base.xz),0.0);
    VERTEX=(inverse(MODEL_MATRIX)*vec4(rendered,1.0)).xyz;
    NORMAL=inverse(mat3(MODEL_MATRIX))*normal_world;
}
vec3 reconstruct_world(vec2 uv,float depth,mat4 inverse_projection,mat4 inverse_view) {
    vec4 point=inverse_projection*vec4(uv*2.0-1.0,depth,1.0);
    return (inverse_view*vec4(point.xyz/point.w,1.0)).xyz;
}
#include "res://addons/water/shaders/ssr.gdshaderinc"
vec3 caustic_light(vec3 receiver) {
    vec2 uv=(receiver.xz-caustics_center)/caustics_size+0.5;
    vec2 pixel=caustics_filter/vec2(textureSize(caustics_map,0));
    vec3 value=textureLod(caustics_map,uv,0.0).rgb*0.5;
    value+=textureLod(caustics_map,uv+vec2(pixel.x,0.0),0.0).rgb*0.125;
    value+=textureLod(caustics_map,uv-vec2(pixel.x,0.0),0.0).rgb*0.125;
    value+=textureLod(caustics_map,uv+vec2(0.0,pixel.y),0.0).rgb*0.125;
    value+=textureLod(caustics_map,uv-vec2(0.0,pixel.y),0.0).rgb*0.125;
    return value;
}
vec3 caustic_factor(vec3 receiver) {
    if(!caustics_enabled||caustics_sun.y<=0.0) return vec3(1.0);
    vec2 uv=(receiver.xz-caustics_center)/caustics_size+0.5;
    if(!in_region(uv)) return vec3(1.0);
    float bed_height=sea_level-caustics_flat_depth;
    float tolerance=0.1;
    if(swe_enabled) {
        vec2 bed_uv=region_uv(receiver.xz);
        if(!in_region(bed_uv)) return vec3(1.0);
        vec4 bed=sample_swe(bed_uv);
        if(bed.w<0.5) return vec3(1.0);
        bed_height=bed.z+sea_level;
        tolerance=max(0.1,max(region_size.x,region_size.y)/float(swe_resolution)*1.5);
    }
    if(receiver.y>=sea_level||abs(receiver.y-bed_height)>tolerance) return vec3(1.0);
    vec3 sun=normalize(caustics_sun);
    vec3 flat_ray=refract(-sun,vec3(0.0,1.0,0.0),1.0/refractive_index);
    float distance_light=max(sea_level-bed_height,0.0)/max(-flat_ray.y,0.001);
    float f0=pow((refractive_index-1.0)/(refractive_index+1.0),2.0);
    float fresnel=refractive_index<=1.000001?0.0:f0+(1.0-f0)*pow(1.0-sun.y,5.0);
    vec3 baseline=sun.y*(1.0-fresnel)*exp(-extinction*distance_light);
    vec3 factor=clamp(caustic_light(receiver)/max(baseline,vec3(0.0001)),vec3(0.0),vec3(25.0));
    float edge=min(min(uv.x,uv.y),min(1.0-uv.x,1.0-uv.y));
    return mix(vec3(1.0),factor,smoothstep(0.0,0.08,edge)*caustics_strength);
}
void fragment() {
    vec2 uv_region=region_uv(base_world);
    vec4 q=vec4(0.0);
    bool local=swe_enabled && in_region(uv_region);
    if(local) q=sample_swe(uv_region);
    if(swe_enabled && !fft_enabled && !local) discard;
    if(local && (q.w<0.5 || q.y<=dry_depth)) discard;
    vec2 detail_grid=base_world/fft_length*fft_resolution;
    float footprint=max(length(dFdx(detail_grid)),length(dFdy(detail_grid)));
    float local_depth=local?mix(max(surface_world.y-sea_level-q.z,0.0),q.y,swe_weight(uv_region,q)):0.0;
    vec2 detail=shore_detail_slope(base_world,local_depth,footprint);
    vec3 normal=apply_detail_slope(normalize(normal_world),detail);
    NORMAL=normalize((VIEW_MATRIX*vec4(normal,0.0)).xyz);
    vec3 eye=INV_VIEW_MATRIX[3].xyz;
    vec3 incoming=PROJECTION_MATRIX[3][3]>0.5?normalize(-INV_VIEW_MATRIX[2].xyz):normalize(surface_world-eye);
    float depth=textureLod(screen_depth,SCREEN_UV,0.0).r;
    vec3 receiver=reconstruct_world(SCREEN_UV,depth,INV_PROJECTION_MATRIX,INV_VIEW_MATRIX);
    float distance_water=depth>0.000001 ? length(receiver-surface_world) : 100.0;
    vec3 background=depth>0.000001 ? textureLod(screen_color,SCREEN_UV,0.0).rgb : vec3(0.0);
    if(refraction_enabled && depth>0.000001 && eye.y>surface_world.y) {
        vec3 ray=refract(incoming,normal,1.0/refractive_index);
        float t=(receiver.y-surface_world.y)/min(ray.y,-0.0001);
        if(ray.y<0.0 && t>0.0) {
            vec4 clip=PROJECTION_MATRIX*VIEW_MATRIX*vec4(surface_world+ray*t,1.0);
            vec2 candidate=clip.xy/clip.w*0.5+0.5;
            vec2 limit=vec2(VIEWPORT_SIZE.y/VIEWPORT_SIZE.x,1.0)*refraction_limit;
            vec2 offset=clamp((candidate-SCREEN_UV)*refraction_strength*smoothstep(0.0,2.0,distance_water),-limit,limit);
            candidate=SCREEN_UV+offset;
            if(all(greaterThan(candidate,vec2(0.0))) && all(lessThan(candidate,vec2(1.0)))) {
                float candidate_depth=textureLod(screen_depth,candidate,0.0).r;
                vec3 hit=reconstruct_world(candidate,candidate_depth,INV_PROJECTION_MATRIX,INV_VIEW_MATRIX);
                if(candidate_depth>0.000001 && hit.y<surface_world.y && dot(hit-surface_world,incoming)>0.0) {
                    float edge=min(min(candidate.x,candidate.y),min(1.0-candidate.x,1.0-candidate.y));
                    float confidence=smoothstep(0.0,0.015,edge);
                    background=mix(background,textureLod(screen_color,candidate,0.0).rgb,confidence);
                    distance_water=mix(distance_water,length(hit-surface_world),confidence);
                    receiver=mix(receiver,hit,confidence);
                }
            }
        }
    }
    if(depth>0.000001) background*=caustic_factor(receiver);
    // Beer-Lambert plus constant-source analytic integration, including sigma=0.
    vec3 transmission=exp(-extinction*distance_water);
    vec3 source;
    for(int k=0;k<3;k++) source[k]=scattering[k]*(extinction[k]>0.000001 ? (1.0-transmission[k])/extinction[k] : distance_water);
    float f0=pow((refractive_index-1.0)/(refractive_index+1.0),2.0);
    float fresnel=refractive_index<=1.000001 ? 0.0 : f0+(1.0-f0)*pow(1.0-clamp(dot(normal,-incoming),0.0,1.0),5.0);
    vec3 reflection=reflection_color.rgb;
    if(use_reflection_panorama) {
        vec3 r=reflect(incoming,normal);
        vec2 sky_uv=vec2(atan(r.z,r.x)/6.28318530718+0.5,acos(clamp(r.y,-1.0,1.0))/3.14159265359);
        reflection=textureLod(reflection_panorama,sky_uv,water_roughness*6.0).rgb;
    }
    vec4 ssr=water_ssr(surface_world,normal,incoming,PROJECTION_MATRIX*VIEW_MATRIX,INV_PROJECTION_MATRIX,INV_VIEW_MATRIX,VIEWPORT_SIZE);
    reflection=mix(reflection,ssr.rgb,ssr.a);
    vec3 color=mix(background*transmission+source,reflection,fresnel);
    vec4 foam=vec4(0.0);
    if(foam_enabled) foam=water_foam(base_world,surface_world,apply_detail_slope(normalize(foam_normal_world),detail),-incoming,q);
    foam_surface_coverage=foam.a;
    color=color*(1.0-foam.a)+foam.rgb;
    if(debug_view==1) color=vec3(clamp(q.y/5.0,0.0,1.0));
    if(debug_view==2) color=vec3(clamp(distance_water/20.0,0.0,1.0));
    if(debug_view==3) color=transmission;
    if(debug_view==4) color=normal*0.5+0.5;
    if(debug_view==5) color=vec3(swe_weight(uv_region,q));
    if(debug_view==6) color=vec3(q.w,local ? 0.0 : 0.3,0.0);
    if(debug_view==7) color=caustics_enabled?caustic_light(receiver):vec3(0.0);
    if(debug_view==8) {
        float amount=local?dot(textureLod(foam_map,uv_region,0.0).rg,vec2(1.0)):0.0;
        color=mix(vec3(0.0,1.0,0.0),vec3(1.0,0.0,0.0),clamp(amount/foam_coverage_reference,0.0,1.0));
    }
    if(debug_view==9) color=vec3(foam.a);
    if(debug_view==10) {
        vec4 flow=local?foam_coordinates(uv_region):vec4(0.0);
        vec2 grid=(base_world-flow.xy)*2.0;
        vec2 line=1.0-smoothstep(vec2(0.0),max(fwidth(grid),vec2(0.001)),abs(fract(grid-0.5)-0.5));
        color=vec3(max(line.x,line.y));
    }
    if(debug_view==11) color=ssr.rgb*ssr.a;
    if(debug_view==12) color=vec3(0.0,ssr.a,0.0);
    ALBEDO=vec3(0.0);
    EMISSION=color;
    ROUGHNESS=water_roughness;
    SPECULAR=0.0;
}
void light() {
    // Custom dielectric GGX; avoid a second, built-in specular highlight.
    if(debug_view==0 && refractive_index>1.000001) {
        vec3 h=normalize(VIEW+LIGHT);
        float nv=max(dot(NORMAL,VIEW),0.0001),nl=max(dot(NORMAL,LIGHT),0.0),nh=max(dot(NORMAL,h),0.0);
        float a=water_roughness*water_roughness,a2=a*a;
        float d=a2/(3.14159265359*pow(nh*nh*(a2-1.0)+1.0,2.0));
        float gv=2.0*nv/(nv+sqrt(a2+(1.0-a2)*nv*nv));
        float gl=2.0*nl/max(nl+sqrt(a2+(1.0-a2)*nl*nl),0.0001);
        float f0=pow((refractive_index-1.0)/(refractive_index+1.0),2.0);
        float f=f0+(1.0-f0)*pow(1.0-max(dot(VIEW,h),0.0),5.0);
        SPECULAR_LIGHT+=LIGHT_COLOR*ATTENUATION*d*gv*gl*f/(4.0*nv)*(1.0-foam_surface_coverage);
    }
}
