#[raygen]
#version 460
#extension GL_EXT_ray_tracing : require
// Share diffuse sampling and GGX shading with compute. All shadow rays use the TLAS.
#define SRC_RAYGEN
#include "rt_payload.inc"
#include "restir_bindings.inc"
#include "scene_light.inc"
#include "scene_query.inc"
#include "point_shadow_tiles.inc"
#include "surface.inc"
#include "restir_di.inc"
void main() { shade(ivec2(gl_LaunchIDEXT.xy)); }

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
