layout(set=0,binding=0,std140) uniform DirectFrame {
	mat4 inv_proj, camera, previous_clip;
	ivec4 grid; // width, height, first plugin light, plugin light count
	ivec4 frame; // mode, sequence, valid reservoir history, reusable point-shadow bitmask
	vec4 quality; // absolute linear RGB error budget
} p;
layout(set=0,binding=1) uniform sampler2D depth_tex;
layout(set=0,binding=2) uniform sampler2D normal_tex;
layout(set=0,binding=3) uniform sampler2D receiver_tex;
layout(rgba16f,set=0,binding=4) uniform image2D color_tex;
layout(rg32ui,set=0,binding=5) uniform uimage2D history_tex;
layout(rg32ui,set=0,binding=6) uniform uimage2D candidates_tex;
layout(rgba32ui,set=0,binding=7) uniform uimage2D surface_tex;
layout(rg32ui,set=0,binding=8) uniform uimage2D visibility_tex;
#ifndef SRC_RAYGEN
layout(set=0,binding=10,std430) readonly buffer Nodes { vec4 nodes[]; };
layout(set=0,binding=11,std430) readonly buffer Triangles { vec4 triangles[]; };
#endif
