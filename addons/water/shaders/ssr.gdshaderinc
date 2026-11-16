// Port of screen_trace.wgsl's projected-segment / reconstructed-world hit
// contract. Godot reverse-Z and UV convention; bounded pixel DDA instead of the
// source renderer's separately-owned min/max depth pyramid acceleration.
uniform bool ssr_enabled = false;
uniform float ssr_maximum = 100.0;
uniform int ssr_max_steps = 256;
uniform float ssr_tolerance = 1.0;
uniform float ssr_bias = 0.02;
uniform float ssr_strength = 1.0;

vec4 water_ssr(vec3 origin,vec3 normal,vec3 incoming,mat4 view_projection,mat4 inverse_projection,mat4 inverse_view,vec2 viewport) {
    if(!ssr_enabled||ssr_strength<=0.0) return vec4(0.0);
    vec3 ray=normalize(reflect(incoming,normal));
    vec3 start_world=origin+normal*ssr_bias;
    vec4 start=view_projection*vec4(start_world,1.0);
    vec4 delta=view_projection*vec4(ray,0.0);
    float reach=ssr_maximum;
    // Clip homogeneous W and BOTH depth planes; works with reverse-Z as well.
    if(delta.w<0.0) reach=min(reach,(start.w-0.001)/(-delta.w));
    if(delta.z<0.0) reach=min(reach,start.z/(-delta.z));
    if(delta.w-delta.z<0.0) reach=min(reach,(start.w-start.z)/(delta.z-delta.w));
    if(reach<=0.01||start.w<=0.0) return vec4(0.0);
    vec4 finish=start+delta*reach;
    vec2 a=start.xy/start.w*0.5+0.5,b=finish.xy/finish.w*0.5+0.5;
    vec2 q=a*viewport,dq=(b-a)*viewport;
    float enter=0.0,leave=1.0;
    for(int axis=0;axis<2;axis++) {
        if(abs(dq[axis])<0.00000001) { if(q[axis]<0.0||q[axis]>=viewport[axis]) return vec4(0.0); }
        else {
            float x=-q[axis]/dq[axis],y=(viewport[axis]-q[axis])/dq[axis];
            enter=max(enter,min(x,y)); leave=min(leave,max(x,y));
        }
    }
    float t=enter;
    for(int visit=0;visit<ssr_max_steps;visit++) {
        if(t>=leave) return vec4(0.0);
        vec2 location=clamp(q+dq*t+sign(dq)*0.001,vec2(0.0),viewport-0.0001);
        vec2 pixel=floor(location);
        vec2 uv=(pixel+0.5)/viewport;
        float depth=textureLod(screen_depth,uv,0.0).r;
        if(depth>0.000001) {
            vec3 opaque=reconstruct_world(uv,depth,inverse_projection,inverse_view);
            float distance_ray=dot(opaque-start_world,ray);
            vec3 closest=start_world+ray*distance_ray;
            vec3 adjacent=reconstruct_world((pixel+1.5)/viewport,depth,inverse_projection,inverse_view);
            float tolerance=max(0.03,1.5*length(adjacent-opaque))*ssr_tolerance;
            if(distance_ray>ssr_bias&&distance_ray<=ssr_maximum&&length(closest-opaque)<tolerance) {
                // Do not reflect the visible underwater floor as an above-water rock.
                if(opaque.y>surface(opaque.xz).y+ssr_bias*0.25) {
                    float edge=min(min(uv.x*viewport.x,uv.y*viewport.y),min((1.0-uv.x)*viewport.x,(1.0-uv.y)*viewport.y));
                    float confidence=smoothstep(0.0,16.0,edge)*(1.0-smoothstep(0.8*ssr_maximum,ssr_maximum,distance_ray))*ssr_strength;
                    return vec4(textureLod(screen_color,uv,0.0).rgb,confidence);
                }
            }
        }
        float end=leave;
        for(int axis=0;axis<2;axis++) if(abs(dq[axis])>0.00000001) {
            float boundary=pixel[axis]+(dq[axis]>0.0?1.0:0.0);
            end=min(end,(boundary-q[axis])/dq[axis]);
        }
        t=max(end,t+0.0000001);
    }
    return vec4(0.0); // offscreen, occluded, or exhausted budget => environment fallback
}
