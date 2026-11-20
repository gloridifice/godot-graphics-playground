const float BIAS = 0.003;
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
			vec3 ab = triangles[tri*3+1].xyz, ac = triangles[tri*3+2].xyz;
			vec3 pv = cross(d,ac);
			float det = dot(ab,pv);
			if (abs(det) < 1e-9) continue;
			vec3 offset = o-triangles[tri*3].xyz;
			float u = dot(offset,pv)/det;
			if (u < 0.0 || u > 1.0) continue;
			vec3 q = cross(offset,ab);
			float v = dot(d,q)/det, t = dot(ac,q)/det;
			if (v < 0.0 || u+v > 1.0 || t <= 0.00001 || t >= h.t) continue;
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
vec3 hemisphere(vec3 n, uint seed) {
	// Per-tile scramble of the R2 sequence. Uniform solid angle; cosine is
	// applied only at irradiance lookup, not a second time while depositing.
	vec2 scramble = vec2(hash32(seed), hash32(seed^9137u)) * (1.0/4294967296.0);
	vec2 u = fract(scramble + float(p.grid.w % 16384)*vec2(0.754877666,0.569840296));
	vec3 t = normalize(cross(abs(n.y) < 0.9 ? vec3(0,1,0) : vec3(1,0,0), n));
	float r = sqrt(max(0.0,1.0-u.y*u.y)), phi = 2.0*PI*u.x;
	return t*(cos(phi)*r) + cross(n,t)*(sin(phi)*r) + n*u.y;
}
bool surface(ivec2 pixel, out vec3 pos, out vec3 n) {
	float depth = texelFetch(depth_tex, pixel, 0).r;
	if (depth <= 0.0) return false; // Forward+ reverse Z clear value
	vec2 uv = (vec2(pixel)+0.5)/vec2(p.grid.xy);
	vec4 view = p.inv_proj * vec4(uv*2.0-1.0,depth,1);
	pos = (p.camera * vec4(view.xyz/view.w,1)).xyz;
	n = normalize(mat3(p.camera) * (texelFetch(normal_tex,pixel,0).xyz*2.0-1.0));
	return true;
}
vec3 hit_light(vec3 pos, vec3 n, int tri) {
	int m = hit_material(tri)*2;
	vec3 illumination = vec3(0);
	for (int i = 0; i < p.options.w; ++i) {
		vec4 light = lights[i*2], energy = lights[i*2+1];
		vec3 l = light.xyz;
		float reach = MISS, scale = 1.0;
		if (light.w > 0.0) {
			l -= pos; reach = length(l);
			if (reach >= light.w || reach <= BIAS) continue;
			l /= reach;
			float window = 1.0 - pow(reach/light.w,4.0);
			scale = window*window / pow(max(0.1,reach),energy.w);
		}
		float cosine = dot(n,l);
		if (cosine > 0.0 && intersect_scene(pos+n*BIAS,l,reach-BIAS,true).tri < 0)
			illumination += energy.rgb*(cosine*scale/PI);
	}
	if (p.options.x != 0) illumination += irradiance_over_pi(pos,n,true);
	return materials[m+1].rgb + materials[m].rgb * illumination;
}
Ray trace_ray(vec3 pos, vec3 n, vec3 d, out vec3 next_pos, out vec3 next_n) {
	vec3 o = pos + n*BIAS;
	Hit hit = intersect_scene(o, d, MISS, false); // traverse the snapshot, including open-ended C3
	vec3 radiance = vec3(0);
	float distance_traced = MISS;
	if (hit.tri >= 0) {
		distance_traced = hit.t;
		next_pos = o + d*hit.t;
		next_n = hit_normal(hit.tri);
		if (dot(d,next_n)>0.0) next_n = -next_n;
		radiance = hit_light(next_pos, next_n, hit.tri);
	}
	return Ray(vec4(pos,distance_traced),vec4(radiance,float(direction_bin(d))));
}
void trace_tile(ivec2 tile, int index, int tile_count) {
	int stride = p.grid.z;
	uint seed = hash32(uint(index));
	uint jitter = (seed + uint(p.grid.w)) % uint(stride*stride);
	ivec2 pixel = tile * stride + ivec2(int(jitter)%stride, int(jitter)/stride);
	Ray invalid = Ray(vec4(0,0,0,-1),vec4(0));
	rays[index] = invalid;
	if (p.options.x != 0) rays[index+tile_count] = invalid;
	vec3 pos, n;
	if (any(greaterThanEqual(pixel,p.grid.xy)) || !surface(pixel,pos,n)) return;
	vec3 hit_pos, hit_n, unused_pos, unused_n;
	Ray primary = trace_ray(pos,n,hemisphere(n,seed),hit_pos,hit_n);
	rays[index] = primary;
	if (p.options.x != 0 && primary.origin_t.w < MISS)
		rays[index+tile_count] = trace_ray(hit_pos,hit_n,hemisphere(hit_n,seed^0x527ba1u),unused_pos,unused_n);
}
