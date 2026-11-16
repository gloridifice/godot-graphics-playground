#[compute]
#version 450
layout(local_size_x=8,local_size_y=8) in;
layout(push_constant,std430) uniform Resolve { vec4 map; } p;
#include "res://addons/water/shaders/caustics_mesh.glslinc"
layout(set=0,binding=3,std430) writeonly buffer VertexLight { vec4 light[]; };

void main() {
    ivec2 vertex=ivec2(gl_GlobalInvocationID.xy);
    int n=cfg.flags.w;
    if(any(greaterThan(vertex,ivec2(n)))) return;
    int index=vertex.y*(n+1)+vertex.x;
    vec3 flux=vec3(0.0);
    float area_sum=0.0;
    // Lump one third of each incident triangle's transmitted flux AND actual
    // receiver area at its nodes. Linear interpolation then preserves total
    // flux over the complete receiver mesh, without constant-color face tiles.
    for(int y=-1;y<=0;y++) for(int x=-1;x<=0;x++) {
        ivec2 cell=vertex+ivec2(x,y);
        if(any(lessThan(cell,ivec2(0)))||any(greaterThanEqual(cell,ivec2(n)))) continue;
        for(int triangle=0;triangle<2;triangle++) {
            ivec3 indices=caustic_indices(cell,triangle);
            if(all(notEqual(indices,ivec3(index)))) continue;
            vec3 irradiance; float area;
            if(!caustic_triangle(indices,irradiance,area)) continue;
            flux+=irradiance*area;
            area_sum+=area;
        }
    }
    light[index]=vec4(flux/max(area_sum,1e-20),0.0);
}
