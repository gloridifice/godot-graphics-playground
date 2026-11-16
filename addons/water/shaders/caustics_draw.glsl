#[vertex]
#version 450
layout(push_constant,std430) uniform Draw { vec4 map; } p;
#include "res://addons/water/shaders/caustics_mesh.glslinc"
layout(set=0,binding=3,std430) readonly buffer VertexLight { vec4 light[]; };
layout(location=0) out vec3 irradiance;
void main() {
    int n=cfg.flags.w,cell=gl_VertexIndex/6,corner=gl_VertexIndex%6;
    ivec3 indices=caustic_indices(ivec2(cell%n,cell/n),corner/3);
    vec3 unused; float area;
    bool valid=caustic_triangle(indices,unused,area);
    int vertex=indices[corner%3];
    vec2 uv=(hits[vertex].hit.xz-cfg.tile.xy)/cfg.tile.zw+0.5;
    gl_Position=valid?vec4(uv*2.0-1.0,0,1):vec4(2,2,0,1);
    irradiance=light[vertex].rgb;
}
#[fragment]
#version 450
layout(location=0) in vec3 irradiance;
layout(location=0) out vec4 color;
void main() { color=vec4(irradiance,0); }
