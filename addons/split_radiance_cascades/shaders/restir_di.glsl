#[compute]
#version 450
// Both stages run here on software BVH; hardware still uses stage 0 for resampling.
layout(local_size_x=8, local_size_y=8) in;
layout(push_constant, std430) uniform Command { int stage, pad1, pad2, pad3; } cmd;
#include "restir_bindings.inc"
#include "scene_light.inc"
#include "scene_query.inc"
#include "surface.inc"
#include "restir_di.inc"
void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(pixel, p.grid.xy))) return;
	if (cmd.stage == 0) initial_and_temporal(pixel);
	else shade(pixel);
}
