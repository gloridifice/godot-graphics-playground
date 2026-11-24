const float BIAS = 0.003;
#ifndef SRC_RAYGEN
// Entries sort by conservative face depth (high 16 bits) then triangle index
// (low 16 bits, SceneSnapshot.MAX_TRIANGLES = 65536).
const int TILE_TRIANGLES = 16;
const uint EMPTY_ENTRY = 0xffffffffu;
struct ShadowTile { uint entries[TILE_TRIANGLES]; uint omitted_depth; };
#ifdef BUILD_SHADOW_TILES
#define SHADOW_ACCESS
#else
#define SHADOW_ACCESS readonly
#endif
layout(set=0,binding=15,std430) SHADOW_ACCESS buffer PointShadowTiles {
	int first_light, light_count, side, pad;
	ShadowTile tiles[];
} shadow;

vec3 face_axes(vec3 v, int axis) {
	return axis == 0 ? v.yzx : (axis == 1 ? v.zxy : v);
}
int tile_index(int light, int face, ivec2 xy) {
	return ((light*6 + face)*shadow.side + xy.y)*shadow.side + xy.x;
}
uint depth_bin(float z, float range) { return uint(clamp(z/range,0.0,1.0)*65534.0); }
#endif

#ifndef BUILD_SHADOW_TILES
bool light_visible(int light, vec3 origin, vec3 direction, float reach) {
	float limit = reach-BIAS;
#ifndef SRC_RAYGEN
	int slot = light - shadow.first_light;
	if (slot >= 0 && slot < shadow.light_count) {
		vec3 ad = abs(direction);
		int axis = ad.x >= ad.y && ad.x >= ad.z ? 0 : (ad.y >= ad.z ? 1 : 2);
		vec3 local = face_axes(-direction,axis);
		int face = 2*axis + (local.z < 0.0 ? 1 : 0);
		vec2 uv = (local.xy/abs(local.z))*0.5+0.5;
		ivec2 xy = clamp(ivec2(uv*float(shadow.side)),ivec2(0),ivec2(shadow.side-1));
		int tile = tile_index(slot,face,xy);
		float range = lights[light].position_range.w;
		uint end_depth = depth_bin(reach*abs(local.z),range);
		for (int j=0; j<TILE_TRIANGLES; ++j) {
			uint entry = shadow.tiles[tile].entries[j];
			if ((entry >> 16) > end_depth) return true;
			float t;
			if (triangle_hit(int(entry & 65535u),origin,direction,limit,t)) return false;
		}
		uint omitted = shadow.tiles[tile].omitted_depth;
		if (end_depth < omitted) return true;
		// The part nearest the light has already been tested against every possible blocker.
		float tested = (float(omitted)/65534.0)*range/abs(local.z);
		limit = min(limit,reach-tested+BIAS);
	}
#endif
	return intersect_scene(origin,direction,limit,true).tri < 0;
}
#endif
