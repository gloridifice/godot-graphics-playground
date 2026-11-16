uniform bool foam_enabled = false;
uniform bool foam_dual = false;
uniform bool foam_distortion = true;
uniform bool foam_periodic = true;
uniform sampler2D foam_map : repeat_disable, filter_linear;
uniform sampler2D foam_flow_map : repeat_disable, filter_nearest;
uniform sampler2D offshore_foam_map : repeat_enable, filter_linear;
uniform sampler2D foam_nsh : repeat_enable, filter_linear_mipmap;
uniform vec4 foam_color : source_color = vec4(0.87,0.92,0.90,1.0);
uniform float foam_tile_size = 12.0;
uniform float foam_micro_normal = 0.65;
uniform float foam_roughness = 0.85;
uniform float foam_opacity_scale = 2.0;
uniform float foam_coverage_reference = 2.0;
uniform vec3 foam_sun = vec3(0.0,1.0,0.0);
varying float foam_surface_coverage;
varying vec3 foam_normal_world;
uniform vec3 foam_height = vec3(0.05,0.1,1.9);

float foam_height_offset(vec2 base) {
    if(!foam_enabled||!swe_enabled||foam_height.x<=0.0) return 0.0;
    vec2 uv=region_uv(base);
    if(!in_region(uv)) return 0.0;
    vec4 q=sample_swe(uv);
    float density=dot(textureLod(foam_map,uv,0.0).rg,vec2(1.0));
    return foam_height.x*smoothstep(foam_height.y,foam_height.y+foam_height.z,density)*smoothstep(0.008,0.02,q.y);
}
vec3 foam_surface(vec2 base) {
    vec3 p=surface(base);
    p.y+=foam_height_offset(base);
    return p;
}
vec3 foam_normal(vec2 base) {
    float step_size=surface_normal_step();
    vec3 tx=foam_surface(base+vec2(step_size,0.0))-foam_surface(base-vec2(step_size,0.0));
    vec3 tz=foam_surface(base+vec2(0.0,step_size))-foam_surface(base-vec2(0.0,step_size));
    return normalize(cross(tz,tx));
}

vec4 foam_coordinates(vec2 uv) {
    vec2 grid=uv*float(swe_resolution)-0.5;
    ivec2 base=ivec2(floor(grid)); vec2 f=fract(grid);
    vec4 result=vec4(0.0); float sum=0.0;
    for(int z=0;z<2;z++) for(int x=0;x<2;x++) {
        ivec2 c=clamp(base+ivec2(x,z),ivec2(0),ivec2(swe_resolution-1));
        vec4 q=texelFetch(swe_map,c,0);
        if(q.w<0.5||q.y<=0.003) continue;
        float w=(x==0?1.0-f.x:f.x)*(z==0?1.0-f.y:f.y);
        result+=texelFetch(foam_flow_map,c,0)*w; sum+=w;
    }
    return result/max(sum,0.000001);
}
vec2 nsh_slope(vec4 data) {
    vec2 xy=data.rg*2.0-1.0;
    return xy/max(sqrt(max(0.0,1.0-dot(xy,xy))),0.25);
}
vec4 foam_phase(vec2 material,vec3 world,vec3 normal,vec3 view,vec2 species,float depth) {
    vec4 coarse=texture(foam_nsh,material/foam_tile_size);
    vec4 fine=texture(foam_nsh,material/foam_tile_size*10.0);
    vec2 pattern=0.72*coarse.ba+0.28*fine.ba;
    float density=max(species.x,0.0);
    float m=pow(clamp(density/foam_coverage_reference,0.0,1.0),1.5)*smoothstep(0.003,0.02,depth);
    float sw=max(0.04,fwidth(pattern.x)),threshold=mix(1.0+sw,-sw,m);
    float opacity=smoothstep(threshold-sw,threshold+sw,pattern.x)*smoothstep(0.0,0.02,m)*(1.0-exp(-density/foam_opacity_scale));
    vec2 wx=dFdx(world.xz),wy=dFdy(world.xz),mx=dFdx(material),my=dFdy(material);
    float determinant=wx.x*wy.y-wx.y*wy.x;
    vec4 jacobian=vec4(1.0,0.0,0.0,1.0);
    if(abs(determinant)>0.00000001) jacobian=vec4((mx*wy.y-my*wx.y)/determinant,(my*wx.x-mx*wy.x)/determinant);
    vec2 slope=0.72*nsh_slope(coarse)+0.28*nsh_slope(fine);
    vec3 offset=vec3(dot(slope,jacobian.xy),0.0,dot(slope,jacobian.zw))*foam_micro_normal;
    offset-=normal*dot(offset,normal);
    offset*=min(1.0,8.0/max(length(offset),0.0001));
    vec3 n=normalize(normal+offset);
    vec3 sun=normalize(foam_sun);
    float light=max(dot(n,sun),0.0);
    float exponent=max(2.0,2.0/pow(foam_roughness,4.0)-2.0);
    float highlight=pow(max(dot(n,normalize(view+sun)),0.0),exponent)*light*0.04;
    vec3 color=foam_color.rgb*(0.65+0.35*light)+vec3(highlight);
    vec3 premultiplied=color*opacity;
    if(foam_dual) {
        float coverage=1.0-exp(-max(species.y,0.0)/foam_opacity_scale);
        float grain=0.55*texture(foam_nsh,material/foam_tile_size*2.5).b+0.30*texture(foam_nsh,material/foam_tile_size*7.0).b+0.15*texture(foam_nsh,material/foam_tile_size*17.0).b;
        float band=abs(grain-0.5)*2.0,aa=0.025+fwidth(grain);
        float residual=(1.0-smoothstep(coverage-aa,coverage+aa,band))*smoothstep(0.0,0.02,coverage)*smoothstep(0.003,0.02,depth);
        vec3 old_color=foam_color.rgb*(0.65+0.35*max(dot(normal,sun),0.0));
        premultiplied+=0.72*old_color*residual*(1.0-opacity);
        opacity+=residual*(1.0-opacity);
    }
    return vec4(premultiplied,opacity);
}
vec4 water_foam(vec2 base,vec3 world,vec3 normal,vec3 view,vec4 water_field) {
    vec2 uv=region_uv(base);
    vec4 result=vec4(0.0);
    float weight=swe_weight(uv,water_field);
    if(swe_enabled&&in_region(uv)) {
        vec2 species=textureLod(foam_map,uv,0.0).rg;
        vec4 flow=foam_distortion?foam_coordinates(uv):vec4(0.0);
        float phase=texelFetch(offshore_foam_map,ivec2(0),0).z;
        float blend=foam_periodic?smoothstep(0.0,1.0,1.0-abs(2.0*phase-1.0)):1.0;
        // Threshold and shade each phase BEFORE cross-fading premultiplied results.
        vec4 a=foam_phase(base-flow.xy,world,normal,view,species,water_field.y);
        vec4 b=foam_phase(base-flow.zw,world,normal,view,species,water_field.y);
        result=mix(b,a,blend)*weight;
    }
    if(fft_enabled) {
        float density=textureLod(offshore_foam_map,base/fft_length+vec2(0.5+0.5/fft_resolution),0.0).r;
        float detail=texture(foam_nsh,base/foam_tile_size).b;
        float amount=smoothstep(0.015,0.25,density)*(0.55+0.45*smoothstep(0.15,0.75,detail))*(1.0-weight);
        vec3 color=foam_color.rgb*(0.65+0.35*max(dot(normal,normalize(foam_sun)),0.0));
        result.rgb+=color*amount*(1.0-result.a);
        result.a+=amount*(1.0-result.a);
    }
    return result;
}
