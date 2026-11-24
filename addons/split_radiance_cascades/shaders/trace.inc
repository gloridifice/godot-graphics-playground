vec3 hemisphere(vec3 n, uint seed) {
	// Per-tile scramble of the R2 sequence. Uniform solid angle; cosine is
	// applied only at irradiance lookup, not a second time while depositing.
	vec2 scramble = vec2(hash32(seed), hash32(seed^9137u)) * (1.0/4294967296.0);
	vec2 u = fract(scramble + float(p.grid.w % 16384)*vec2(0.754877666,0.569840296));
	vec3 t = normalize(cross(abs(n.y) < 0.9 ? vec3(0,1,0) : vec3(1,0,0), n));
	float r = sqrt(max(0.0,1.0-u.y*u.y)), phi = 2.0*PI*u.x;
	return t*(cos(phi)*r) + cross(n,t)*(sin(phi)*r) + n*u.y;
}
vec3 hit_light(vec3 pos, vec3 n, int tri) {
	int m = hit_material(tri)*2;
	vec3 illumination = vec3(0);
	for (int i = 0; i < p.options.w; ++i) {
		SceneLight lamp = lights[i];
		vec3 l;
		float reach;
		float factor = diffuse_factor(lamp, pos, n, l, reach);
		if (factor > 0.0 && any(greaterThan(lamp.bounce.rgb, vec3(0))) &&
				light_visible(i,pos+n*BIAS,l,reach))
			illumination += lamp.bounce.rgb * factor;
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
