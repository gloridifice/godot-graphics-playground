// Shared ABI for the compute passes and the optional RT raygen stage.
layout(set=0,binding=0,std140) uniform Params {
	mat4 inv_proj, camera;
	uvec4 capacity, slot_base, bin_base;
	vec4 tuning; // base spacing, first interval end, LOD distance, history retention
	ivec4 grid; // width, height, effective ray stride, frame
	ivec4 options; // secondary bounce, view mode, inspected cascade, light count
	vec4 display; // indirect strength
} p;
#ifdef SRC_RAYGEN
#define PROBE_ACCESS readonly
#else
#define PROBE_ACCESS
#endif
layout(set=0,binding=1,std430) PROBE_ACCESS buffer Table { uvec4 slots[]; };
struct Bin { uvec4 sum; uint mass; float weight; vec2 pad; vec4 interval, merged; };
layout(set=0,binding=4,std430) PROBE_ACCESS buffer Bins { Bin bins[]; };
struct Ray { vec4 origin_t, rgb_bin; };
layout(set=0,binding=5,std430) buffer Rays { Ray rays[]; };
layout(set=0,binding=8,std430) readonly buffer Materials { vec4 materials[]; };
layout(set=0,binding=10) uniform sampler2D depth_tex;
layout(set=0,binding=11) uniform sampler2D normal_tex;
