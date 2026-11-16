// Shared by the visible water and physical photon tracer. Undeformed WORLD XZ
// coordinates, cell-centered SWE sampling, and absolute free-surface composition.
vec2 region_uv(vec2 world) {
    vec2 d=world-region_origin;
    return vec2(region_rotation.x*d.x-region_rotation.y*d.y,region_rotation.y*d.x+region_rotation.x*d.y)/region_size+0.5;
}
bool in_region(vec2 uv) { return all(greaterThanEqual(uv,vec2(0.0)))&&all(lessThanEqual(uv,vec2(1.0))); }
vec4 sample_swe(vec2 uv) {
    vec2 grid=uv*float(swe_resolution)-0.5;
    ivec2 base=ivec2(floor(grid)); vec2 f=fract(grid);
    float eta=0.0,wet_weight=0.0,depth=0.0,bed=0.0,weight=0.0;
    for(int z=0;z<2;z++) { for(int x=0;x<2;x++) {
        ivec2 c=clamp(base+ivec2(x,z),ivec2(0),ivec2(swe_resolution-1));
        vec4 q=texelFetch(swe_map,c,0);
        float w=(x==1?f.x:1.0-f.x)*(z==1?f.y:1.0-f.y)*q.w;
        depth+=w*q.y; bed+=w*q.z; weight+=w;
        if(q.y>dry_depth) { eta+=w*q.x; wet_weight+=w; }
    }}
    return vec4(eta/max(wet_weight,0.000001),depth/max(weight,0.000001),bed/max(weight,0.000001),weight);
}
float swe_weight(vec2 uv,vec4 q) {
    if(!swe_enabled||!in_region(uv)) return 0.0;
    if(!fft_enabled) return 1.0;
    if(swe_model_blend) {
        // shore.wgsl ocean_weight's MODEL branch, not its analytic-slope branch.
        vec2 distance=min(uv,vec2(1.0)-uv)*region_size;
        float inside=smoothstep(0.0,2.0*max(region_size.x,region_size.y)/float(swe_resolution),min(distance.x,distance.y));
        vec4 edges=vec4(uv.x,1.0-uv.x,uv.y,1.0-uv.y);
        float ocean=1.0-inside;
        for(int axis=0;axis<4;axis++) if((swe_fft_edges&(1<<axis))!=0)
            ocean=max(ocean,1.0-smoothstep(0.0,edge_width,edges[axis]));
        return 1.0-ocean;
    }
    float edge=min(min(uv.x,uv.y),min(1.0-uv.x,1.0-uv.y));
    float shallow=1.0-smoothstep(blend_depth,2.5*blend_depth,max(-q.z,0.0));
    return shallow*smoothstep(0.0,edge_width,edge);
}
vec3 surface(vec2 world) {
    vec3 wave=vec3(0.0);
    if(fft_enabled) wave=textureLod(fft_map,world/fft_length+vec2(0.5+0.5/fft_resolution),0.0).xyz*height_gain;
    vec2 uv=region_uv(world);
    vec4 q=vec4(0.0);
    if(swe_enabled&&in_region(uv)) q=sample_swe(uv);
    float w=swe_weight(uv,q);
    return vec3(world.x+wave.y*choppiness*(1.0-w),sea_level+mix(wave.x,q.x,w),world.y+wave.z*choppiness*(1.0-w));
}
float surface_normal_step() {
    float step_size=fft_length/fft_resolution;
    if(swe_enabled) step_size=min(step_size,min(region_size.x,region_size.y)/float(swe_resolution));
    return step_size;
}
vec3 surface_normal_at(vec2 world,float step_size) {
    vec3 tx=surface(world+vec2(step_size,0.0))-surface(world-vec2(step_size,0.0));
    vec3 tz=surface(world+vec2(0.0,step_size))-surface(world-vec2(0.0,step_size));
    vec3 area=cross(tz,tx);
    return dot(area,area)>1e-12?normalize(area):vec3(0.0,1.0,0.0);
}
vec3 surface_normal(vec2 world) { return surface_normal_at(world,surface_normal_step()); }

// Reference: render/shaders/surface.wgsl. Render-only short-wave slopes,
// NOT another height field, noise source, or feedback into FFT -> SWE.
float detail_height_at(ivec2 cell) {
    int n=int(fft_resolution);
    ivec2 wrapped=((cell%ivec2(n))+ivec2(n))%ivec2(n);
    return texelFetch(fft_map,wrapped,0).r;
}
vec2 fft_detail_slope_at(ivec2 cell) {
    float x=detail_height_at(cell+ivec2(1,0))-detail_height_at(cell-ivec2(1,0))
        -0.25*(detail_height_at(cell+ivec2(4,0))-detail_height_at(cell-ivec2(4,0)));
    float z=detail_height_at(cell+ivec2(0,1))-detail_height_at(cell-ivec2(0,1))
        -0.25*(detail_height_at(cell+ivec2(0,4))-detail_height_at(cell-ivec2(0,4)));
    return vec2(x,z);
}
vec4 detail_cubic_weights(float t) {
    float t2=t*t,t3=t2*t;
    return vec4(-0.5*t+t2-0.5*t3,1.0-2.5*t2+1.5*t3,
        0.5*t+2.0*t2-1.5*t3,-0.5*t2+0.5*t3);
}
vec2 fft_detail_slope(vec2 grid) {
    ivec2 cell=ivec2(floor(grid));
    vec4 wx=detail_cubic_weights(fract(grid.x)),wz=detail_cubic_weights(fract(grid.y));
    vec2 slope=vec2(0.0);
    for(int z=0;z<4;z++) {
        vec2 row=vec2(0.0);
        for(int x=0;x<4;x++) row+=wx[x]*fft_detail_slope_at(cell+ivec2(x-1,z-1));
        slope+=wz[z]*row;
    }
    return slope*height_gain*fft_resolution/(2.0*fft_length);
}
vec2 shore_detail_slope(vec2 base,float depth,float footprint) {
    if(!fft_enabled||!swe_enabled||shore_normal_strength<=0.0) return vec2(0.0);
    vec2 uv=region_uv(base);
    if(!in_region(uv)) return vec2(0.0);
    vec4 q=sample_swe(uv);
    float weight=swe_weight(uv,q)*smoothstep(0.02,0.25,depth)
        *(1.0-smoothstep(0.5,2.0,footprint))*shore_normal_strength;
    if(weight<=0.0) return vec2(0.0);
    return fft_detail_slope((base/fft_length+0.5)*fft_resolution)*weight;
}
vec3 apply_detail_slope(vec3 base,vec2 slope) {
    if(all(equal(slope,vec2(0.0)))) return base;
    return normalize(vec3(base.x-base.y*slope.x,base.y,base.z-base.y*slope.y));
}
