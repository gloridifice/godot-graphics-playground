#[raygen]
#version 460
#extension GL_EXT_ray_tracing : require
#define SRC_RAYGEN
#include "trace_bindings.inc"
#include "rt_payload.inc"
#include "grid.inc"
#include "trace.inc"
void main() {
	ivec2 tile = ivec2(gl_LaunchIDEXT.xy), size = ivec2(gl_LaunchSizeEXT.xy);
	trace_tile(tile, tile.y*size.x + tile.x, size.x*size.y);
}

#[closest_hit]
#version 460
#extension GL_EXT_ray_tracing : require
#include "rt_payload.inc"
layout(location=0) rayPayloadInEXT HitPayload payload;
layout(set=1,binding=1,std430) readonly buffer Normals { vec4 normals[]; };
layout(set=1,binding=2,std430) readonly buffer Instances { uvec2 instances[]; };
void main() {
	uvec2 instance = instances[gl_InstanceCustomIndexEXT];
	vec3 n = normals[instance.x + gl_PrimitiveID].xyz;
	payload.normal = normalize(n * mat3(gl_WorldToObjectEXT));
	payload.t = gl_HitTEXT;
	payload.material = int(instance.y);
}

#[miss]
#version 460
#extension GL_EXT_ray_tracing : require
#include "rt_payload.inc"
layout(location=0) rayPayloadInEXT HitPayload payload;
void main() { payload.material = -1; }
