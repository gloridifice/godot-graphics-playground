// Cascade is implicit in the table slice. The exact key, not its hash, is
// compared; the high bits distinguish overlapping spatial LODs and both caches.
const uint NONE = 0xffffffffu;
const uint WAYS = 8u;
const float PI = 3.14159265359;
uint hash32(uint x) {
	x ^= x >> 16; x *= 0x7feb352du; x ^= x >> 15; x *= 0x846ca68bu; return x ^ (x >> 16);
}
uint key_for(ivec3 cell, int tag) {
	if (any(lessThan(cell, ivec3(-256))) || any(greaterThan(cell, ivec3(255)))) return 0u;
	uvec3 v = uvec3(cell + 256);
	return 1u + (v.x | (v.y << 9) | (v.z << 18) | (uint(tag) << 27));
}
ivec3 cell_of(uint key) { return ivec3((uvec3(key - 1u) >> uvec3(0,9,18)) & 511u) - 256; }
int tag_of(uint key) { return int((key - 1u) >> 27); }
uint bucket(int c, uint key) { return p.slot_base[c] + (hash32(key) & (p.capacity[c] - 1u)) / WAYS * WAYS; }
uint lookup(int c, uint key) {
	if (key == 0u) return NONE;
	uint start = bucket(c, key);
	for (uint i = start; i < start + WAYS; ++i) if (slots[i].x == key) return i;
	return NONE;
}
#ifndef SRC_RAYGEN
void acquire(int c, uint key) {
	if (key == 0u) return;
	uint start = bucket(c, key), id = NONE;
	// Search *all* ways first: expiration can leave a hole before an old key.
	for (uint i = start; i < start + WAYS; ++i) {
		if (atomicAdd(slots[i].x, 0u) == key) { id = i; break; }
	}
	if (id == NONE) for (uint i = start; i < start + WAYS; ++i) {
		uint was = atomicCompSwap(slots[i].x, 0u, key);
		if (was == 0u || was == key) { id = i; break; }
	}
	if (id == NONE) return; // bounded overload: drop, never alias another probe
	uint frame = uint(p.grid.w);
	if (atomicExchange(slots[id].y, frame) != frame) {
		uint next = atomicAdd(groups[c].x, 1u);
		active_ids[p.slot_base[c] + next] = id;
	}
}
#endif
int level_of(int tag) { return tag < 4 ? tag : tag - 2; } // secondary is two levels coarser
float spacing(int tag, int c) { return p.tuning.x * float(1 << (level_of(tag) + c)); }
float interval_end(int tag, int c) { return p.tuning.y * float(1 << (level_of(tag) + 2*c)); }
// One ray's confidence is shared between overlapping LODs in fixed point.
// Each grid estimates the whole integral; blend normalized estimates at lookup.
const uint LOD_ONE = 255u;
float lod_at(vec3 pos) {
	float distance_ratio = distance(pos, p.camera[3].xyz) / p.tuning.z;
	float coordinate_ratio = max(max(abs(pos.x), abs(pos.y)), abs(pos.z)) / (120.0 * p.tuning.x);
	float t = clamp(log2(max(1.0, max(distance_ratio, coordinate_ratio))), 0.0, 3.0);
	return floor(t) + smoothstep(0.65, 1.0, fract(t));
}
uint key_at(vec3 pos, int tag, int c) { return key_for(ivec3(floor(pos / spacing(tag,c))), tag); }
int bin_count(int c) { return 8 << (2*c); }
uint bin_start(uint slot, int c) { return p.bin_base[c] + (slot - p.slot_base[c]) * uint(bin_count(c)); }
// Equal solid angles: azimuth x height on the unit sphere; every bin has
// exactly four angular children. Store the finest index once per traced ray.
int direction_bin(vec3 dir) {
	float u = fract(atan(dir.z, dir.x) / (2.0*PI) + 1.0);
	return min(31, int(u*32.0)) + 32 * clamp(int((dir.y*0.5 + 0.5)*16.0), 0, 15);
}
int ancestor_bin(int finest, int c) {
	return ((finest % 32) >> (3-c)) + (4 << c) * ((finest / 32) >> (3-c));
}
vec3 base_direction(int b) {
	// Centers of the 4 azimuth x 2 height bins (sqrt(3/8) horizontally).
	int col = b % 4;
	const float s = 0.612372436;
	return vec3(col == 0 || col == 3 ? s : -s, b < 4 ? -0.5 : 0.5, col < 2 ? s : -s);
}
// RGB is radiance, w is available angular weight (0 means missing, not black).
vec4 diffuse_probe(uint id, vec3 n) {
	if (id == NONE) return vec4(0);
	if (slots[id].z == 0u) return vec4(0);
	vec4 result = vec4(0);
	uint base = bin_start(id, 0);
	for (int b = 0; b < 8; ++b) {
		vec4 v = bins[base + b].merged;
		float w = v.a > 0.0 ? max(dot(n, base_direction(b)), 0.0) : 0.0;
		result += vec4(v.rgb, 1.0) * w;
	}
	return result.w > 0.0 ? vec4(result.rgb/result.w, 1) : vec4(0);
}
vec4 at_surface(vec3 pos, vec3 n, int tag, bool interpolate) {
	if (!interpolate) return diffuse_probe(lookup(0, key_at(pos, tag, 0)), n);
	vec3 g = pos/spacing(tag,0) - 0.5;
	ivec3 base = ivec3(floor(g));
	vec3 f = fract(g);
	vec4 total = vec4(0);
	for (int j = 0; j < 8; ++j) {
		ivec3 corner = (ivec3(j) >> ivec3(0,1,2)) & 1;
		vec3 w = mix(1.0-f, f, vec3(corner));
		total += w.x*w.y*w.z * diffuse_probe(lookup(0, key_for(base+corner, tag)), n);
	}
	return total.w > 0.0 ? vec4(total.rgb/total.w, 1) : vec4(0);
}
vec3 irradiance_over_pi(vec3 pos, vec3 n, bool secondary) {
	float lod = lod_at(pos);
	int tag = int(lod) + (secondary ? 4 : 0);
	vec4 a = at_surface(pos, n, tag, !secondary);
	if (fract(lod) == 0.0) return a.rgb;
	vec4 v = mix(a, at_surface(pos, n, tag+1, !secondary), fract(lod));
	return v.w > 0.0 ? v.rgb/v.w : vec3(0);
}
