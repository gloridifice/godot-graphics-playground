#[raygen]
#version 460
#extension GL_EXT_ray_tracing : require
#define SRC_RAYGEN
#include "trace_bindings.inc"
#include "rt_payload.inc"
#include "grid.inc"
#include "scene_light.inc"
#include "scene_query.inc"
#include "surface.inc"
#include "trace.inc"
void main() {
	ivec2 tile = ivec2(gl_LaunchIDEXT.xy), size = ivec2(gl_LaunchSizeEXT.xy);
	trace_tile(tile, tile.y*size.x + tile.x, size.x*size.y);
}

#[closest_hit]
#version 460
#extension GL_EXT_ray_tracing : require
#include "rt_payload.inc"
#include "rt_closest.inc"

#[miss]
#version 460
#extension GL_EXT_ray_tracing : require
#include "rt_payload.inc"
layout(location=0) rayPayloadInEXT HitPayload payload;
void main() { payload.material = -1; }
