#[compute]
#version 450
layout(local_size_x=8,local_size_y=8) in;
layout(set=0,binding=0,std430) readonly buffer FFT { vec2 field[]; };
layout(set=0,binding=1,std430) readonly buffer States { vec4 states[]; };
layout(set=0,binding=2,std430) readonly buffer Terrain { vec2 terrain[]; };
struct FoamRecord { vec4 amount; vec4 coordinates; };
layout(set=0,binding=3,std430) readonly buffer Foam { FoamRecord records[]; };
layout(set=0,binding=4,std430) readonly buffer Offshore { vec4 offshore[]; };
layout(rgba32f,set=0,binding=5) uniform writeonly image2D fft_output;
layout(rgba32f,set=0,binding=6) uniform writeonly image2D swe_output;
layout(rgba32f,set=0,binding=7) uniform writeonly image2D foam_output;
layout(rgba32f,set=0,binding=8) uniform writeonly image2D flow_output;
layout(rgba32f,set=0,binding=9) uniform writeonly image2D offshore_output;
layout(push_constant,std430) uniform Params { ivec4 grid; } p;
void main() {
    ivec2 c=ivec2(gl_GlobalInvocationID.xy);
    if(all(lessThan(c,ivec2(p.grid.x)))) {
        int n=p.grid.x,i=c.y*n+c.x;
        imageStore(fft_output,c,vec4(field[i].x,field[n*n+i].x,field[2*n*n+i].x,1));
        imageStore(offshore_output,c,offshore[i]);
    }
    if(all(lessThan(c,ivec2(max(p.grid.y,1))))) {
        if(p.grid.y==0) { imageStore(swe_output,c,vec4(0)); imageStore(foam_output,c,vec4(0)); imageStore(flow_output,c,vec4(0)); return; }
        int n=p.grid.y,i=c.y*n+c.x;
        vec3 q=states[p.grid.z*n*n+i].xyz;
        FoamRecord foam=records[p.grid.z*n*n+i];
        imageStore(swe_output,c,vec4(q.x+terrain[i].x,q.x,terrain[i].x,terrain[i].y));
        imageStore(foam_output,c,vec4(max(foam.amount.x-foam.amount.w,0.0),foam.amount.w,0,terrain[i].y));
        imageStore(flow_output,c,foam.coordinates);
    }
}
