void deposit(Ray ray, int tag, uint mass) {
	int finest = int(ray.rgb_bin.w);
	for (int c = 0; c < 4; ++c) {
		// C3 owns every remaining known hit, not misses (open, black sky).
		bool hit = ray.origin_t.w < MISS && (c == 3 || ray.origin_t.w < interval_end(tag,c));
		uint id = lookup(c, key_at(ray.origin_t.xyz,tag,c));
		if (id != NONE && slots[id].y == uint(p.grid.w)) {
			uint b = bin_start(id,c) + uint(ancestor_bin(finest,c));
			// Separate banks: at most MAX_TILES (262144) rays per bin per frame.
			// 262144 * 255 * 64 fits in uint32 even if every ray hits the same bin.
			atomicAdd(bins[b].mass,mass);
			if (hit) {
				uvec3 rgb = uvec3(round(clamp(ray.rgb_bin.rgb,0.0,64.0)*float(mass)));
				atomicAdd(bins[b].sum.x,rgb.r);
				atomicAdd(bins[b].sum.y,rgb.g);
				atomicAdd(bins[b].sum.z,rgb.b);
			} else atomicAdd(bins[b].sum.w,mass); // measured transmission
		}
		if (hit) break; // never deposit behind the first surface
	}
}
shared uint neighbors[8];
shared float spatial[8];
shared float old_decay;
void merge_probe(int c) {
	uint id = active_ids[p.slot_base[c] + gl_WorkGroupID.x];
	uint lane = gl_LocalInvocationIndex;
	if (lane == 0u) {
		uint previous = slots[id].z;
		old_decay = previous == 0u ? 0.0 : pow(p.tuning.w,float(uint(p.grid.w)-previous));
		slots[id].z = uint(p.grid.w);
	}
	if (c < 3 && lane < 8u) {
		uint key = slots[id].x;
		vec3 g = (vec3(cell_of(key))+0.5)*0.5 - 0.5;
		ivec3 corner = (ivec3(lane) >> ivec3(0,1,2)) & 1;
		uint upper = lookup(c+1, key_for(ivec3(floor(g))+corner,tag_of(key)));
		neighbors[lane] = upper != NONE && slots[upper].y == uint(p.grid.w) ? upper : NONE;
		vec3 w = mix(1.0-fract(g),fract(g),vec3(corner));
		spatial[lane] = w.x*w.y*w.z;
	}
	barrier();
	uint base = bin_start(id,c);
	for (int d = int(lane); d < bin_count(c); d += 64) {
		uint b = base + d;
		float count = float(bins[b].mass) / float(LOD_ONE);
		vec4 sum = vec4(bins[b].sum) / float(LOD_ONE);
		// Accumulate only the LOCAL interval. Re-feeding the merged result here
		// would count the same far light once per frame even without a bounce.
		float old_count = old_decay > 0.0 ? bins[b].weight*old_decay : 0.0;
		if (old_count > 0.0) sum += bins[b].interval * old_count;
		count += old_count;
		if (count < 1e-5) count = 0.0;
		vec4 local = count > 0.0 ? sum/count : vec4(0); // no evidence of transmission
		bins[b].interval = local;
		bins[b].weight = count;
		bins[b].mass = 0u;
		bins[b].sum = uvec4(0);
		vec3 far_light = vec3(0);
		float confidence = 0.0;
		if (c < 3 && local.a > 0.0) {
			int width = 4 << c;
			int child = 2*(d%width) + 4*width*(d/width);
			for (int j = 0; j < 8; ++j) {
				if (neighbors[j] == NONE) continue;
				uint first = bin_start(neighbors[j],c+1) + uint(child);
				vec3 light = vec3(0);
				float samples = 0.0, valid = 0.0;
				for (int k = 0; k < 4; ++k) {
					vec4 v = bins[first + (k&1) + (k/2)*width*2].merged;
					if (v.a <= 0.0) continue;
					light += v.rgb; valid++; samples += min(32.0,v.a);
				}
				if (valid == 0.0) continue;
				float w = spatial[j]*samples*0.25;
				far_light += w*(light/valid); confidence += w;
			}
			if (confidence > 0.0) far_light /= confidence;
		}
		// Only local evidence can validate a direction. An opaque black hit is
		// valid with T=0; an unsampled direction is invalid even above a lit parent.
		bins[b].merged = vec4(local.rgb + local.a*far_light, count);
	}
}
