const float MISS = 1e20;
struct Hit { float t; int tri; };
#ifdef SRC_RAYGEN
layout(set=1,binding=0) uniform accelerationStructureEXT scene_as;
layout(location=0) rayPayloadEXT HitPayload payload;
Hit intersect_scene(vec3 o, vec3 d, float limit, bool any_hit) {
	if (limit <= 0.00001) return Hit(limit, -1);
	uint flags = gl_RayFlagsOpaqueEXT;
	if (any_hit) flags |= gl_RayFlagsTerminateOnFirstHitEXT | gl_RayFlagsSkipClosestHitShaderEXT;
	payload.material = 0; // shadow hit skips closest-hit; miss sets -1
	payload.t = limit;
	traceRayEXT(scene_as, flags, 255, 0, 0, 0, o, 0.00001, d, limit, 0);
	return Hit(payload.t, payload.material);
}
int hit_material(int key) { return key; }
vec3 hit_normal(int key) { return payload.normal; }
#else
bool triangle_hit(int tri, vec3 o, vec3 d, float limit, out float t) {
	vec3 ab = triangles[tri*3+1].xyz, ac = triangles[tri*3+2].xyz;
	vec3 pv = cross(d,ac);
	float det = dot(ab,pv);
	if (abs(det) < 1e-9) return false;
	vec3 offset = o-triangles[tri*3].xyz;
	float u = dot(offset,pv)/det;
	if (u < 0.0 || u > 1.0) return false;
	vec3 q = cross(offset,ab);
	float v = dot(d,q)/det;
	t = dot(ac,q)/det;
	return v >= 0.0 && u+v <= 1.0 && t > 0.00001 && t < limit;
}
Hit intersect_scene(vec3 o, vec3 d, float limit, bool any_hit) {
	Hit h = Hit(limit, -1);
	// Nonzero inverse also handles axis-parallel rays on a slab boundary.
	vec3 inv = mix(vec3(-1), vec3(1), greaterThanEqual(d,vec3(0))) / max(abs(d), vec3(1e-12));
	int node = 0, end = int(nodes[0].w);
	while (node < end) {
		vec4 lo = nodes[node*2], hi = nodes[node*2+1];
		vec3 a = (lo.xyz - 0.0001 - o)*inv, b = (hi.xyz + 0.0001 - o)*inv;
		vec3 near_t = min(a,b), far_t = max(a,b);
		if (max(0.0, max(near_t.x,max(near_t.y,near_t.z))) > min(h.t, min(far_t.x,min(far_t.y,far_t.z)))) {
			node = int(lo.w); continue;
		}
		int leaf = int(hi.w);
		for (int j = 0; j < (leaf & 7); ++j) {
			int tri = (leaf >> 3) + j;
			float t;
			if (!triangle_hit(tri,o,d,h.t,t)) continue;
			h = Hit(t,tri);
			if (any_hit) return h;
		}
		node++;
	}
	return h;
}
int hit_material(int key) { return int(triangles[key*3].w); }
vec3 hit_normal(int key) { return normalize(cross(triangles[key*3+1].xyz, triangles[key*3+2].xyz)); }
#endif
