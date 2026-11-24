#[compute]
#version 450
layout(local_size_x=8, local_size_y=8) in;
layout(set=0,binding=0,std430) readonly buffer Nodes { vec4 nodes[]; };
layout(set=0,binding=1,std430) readonly buffer Triangles { vec4 triangles[]; };
layout(push_constant,std430) uniform Build { vec4 lamp; ivec4 slot; } cmd;
#define BUILD_SHADOW_TILES
#include "point_shadow_tiles.inc"

// Rays start BIAS along the receiver normal, so their lines can miss the lamp
// center by BIAS. Expand the beam tests by that distance plus float roundoff.
const float PAD = BIAS + 0.0005;
bool overlaps_tile(vec3 low, vec3 high, vec4 uv, float range) {
	float z0 = max(0.0,low.z-PAD), z1 = min(range,high.z+PAD);
	return z0 <= z1 && all(greaterThanEqual(high.xy+PAD, min(uv.xy*z0,uv.xy*z1))) &&
			all(lessThanEqual(low.xy-PAD, max(uv.zw*z0,uv.zw*z1)));
}
float max_projection(vec3 n, vec4 uv) {
	vec2 m = max(n.xy*uv.xy, n.xy*uv.zw);
	return m.x + m.y + n.z;
}
// Bound the actual triangle, not just its AABB. Large diagonal floor and wall
// triangles otherwise occupy tiles far outside their silhouette.
float triangle_depth(vec3 a, vec3 b, vec3 c, vec4 uv, float range) {
	vec3 low = min(a,min(b,c)), high = max(a,max(b,c));
	if (!overlaps_tile(low,high,uv,range)) return 1e30;
	float near_z = max(0.0, low.z-PAD);
	vec3 normal = cross(b-a,c-a);
	float plane = dot(normal,a);
	float winding = plane < 0.0 ? -1.0 : 1.0;
	float distance = abs(plane) - PAD*length(normal);
	if (distance > 0.0) {
		float projection = max_projection(winding*normal,uv);
		if (projection <= 0.0) return 1e30;
		near_z = max(near_z, distance/projection);
	}
	vec3 edges[3] = vec3[](cross(a,b), cross(b,c), cross(c,a));
	for (int i=0; i<3; ++i) {
		if (near_z*max_projection(winding*edges[i],uv) < -PAD*length(edges[i])) return 1e30;
	}
	return near_z;
}
void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(pixel,ivec2(shadow.side)))) return;
	int face = int(gl_GlobalInvocationID.z), axis = face/2;
	vec3 sign_z = vec3(1,1,(face & 1) == 0 ? 1 : -1);
	vec4 uv = vec4(pixel,pixel+1)*(2.0/float(shadow.side))-1.0;
	vec3 light_pos = cmd.lamp.xyz;
	float range = cmd.lamp.w;
	ShadowTile tile;
	for (int i=0; i<TILE_TRIANGLES; ++i) tile.entries[i] = EMPTY_ENTRY;
	tile.omitted_depth = EMPTY_ENTRY;
	float cutoff = range;
	int node = 0, end = int(nodes[0].w);
	while (node < end) {
		vec4 lo = nodes[node*2], hi = nodes[node*2+1];
		vec3 aabb0 = face_axes(lo.xyz-light_pos,axis)*sign_z;
		vec3 aabb1 = face_axes(hi.xyz-light_pos,axis)*sign_z;
		if (!overlaps_tile(min(aabb0,aabb1),max(aabb0,aabb1),uv,cutoff)) {
			node = int(lo.w);
			continue;
		}
		int leaf = int(hi.w);
		for (int j=0; j<(leaf & 7); ++j) {
			int tri = (leaf >> 3) + j;
			vec3 a = face_axes(triangles[tri*3].xyz-light_pos,axis)*sign_z;
			vec3 b = a + face_axes(triangles[tri*3+1].xyz,axis)*sign_z;
			vec3 c = a + face_axes(triangles[tri*3+2].xyz,axis)*sign_z;
			float depth = triangle_depth(a,b,c,uv,range);
			if (depth > cutoff) continue;
			// Keep the nearest candidates. The first discarded bound also
			// certifies all shorter segments without a full BVH traversal.
			uint entry = (depth_bin(depth,range) << 16) | uint(tri);
			for (int i=0; i<TILE_TRIANGLES && entry!=EMPTY_ENTRY; ++i) {
				uint other = tile.entries[i];
				tile.entries[i] = min(entry,other);
				entry = max(entry,other);
			}
			if (entry != EMPTY_ENTRY) {
				tile.omitted_depth = min(tile.omitted_depth,entry >> 16);
				cutoff = range*float(tile.omitted_depth+1u)/65534.0;
			}
		}
		++node;
	}
	shadow.tiles[tile_index(cmd.slot.x,face,pixel)] = tile;
}
