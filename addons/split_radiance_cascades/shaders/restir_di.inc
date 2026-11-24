const int STABLE = 0, RAW = 1, RIS = 2, REFERENCE = 3;
struct Receiver { vec3 pos, n, albedo; };
bool receiver_at(ivec2 px, out Receiver s) {
	vec4 material = texelFetch(receiver_tex, px, 0);
	s.albedo = material.rgb;
	return material.a > 0.0 && surface(px, s.pos, s.n);
}
vec3 contribution(Receiver s, int id, out vec3 l, out float reach) {
	SceneLight lamp = lights[p.grid.z + id];
	return s.albedo * lamp.direct_falloff.rgb * diffuse_factor(lamp,s.pos,s.n,l,reach);
}
float target(Receiver s, int id) {
	vec3 l; float reach;
	// Keep proposal support across surface changes, including a light just outside its range.
	return dot(contribution(s,id,l,reach), vec3(0.2126,0.7152,0.0722)) + 1e-7;
}
uint seed(ivec2 px) {
	return uint(px.x + px.y*p.grid.x) ^ (uint(p.frame.y)*0x9e3779b9u);
}
float random01(inout uint state) {
	state = state * 747796405u + 2891336453u;
	uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
	return float((word ^ (word >> 22u)) >> 8u) * (1.0/16777216.0);
}

// In-flight weight is sum(w); stored weight is W = sum(w) / (M * target(y)).
struct Reservoir { int id; float weight; uint m; };
Reservoir empty_reservoir() { return Reservoir(-1,0.0,0u); }
Reservoir unpack_reservoir(uvec2 bits) {
	return Reservoir(int(bits.x & 0xffffffu)-1, uintBitsToFloat(bits.y), bits.x >> 24u);
}
uvec4 pack_reservoir(Reservoir r) {
	return uvec4((r.m << 24u) | uint(r.id+1),floatBitsToUint(r.weight),0,0);
}
void stream(inout Reservoir r, int id, float w, uint m, inout uint rng) {
	r.m += m;
	r.weight += w;
	if (random01(rng)*r.weight < w) r.id = id;
}
void combine(inout Reservoir r, Receiver s, Reservoir source, uint cap, inout uint rng) {
	if (source.id < 0) return;
	uint m = min(source.m,cap);
	stream(r,source.id,target(s,source.id)*source.weight*float(m),m,rng);
}
void normalize_reservoir(inout Reservoir r, Receiver s) {
	if (r.id >= 0) r.weight /= float(r.m)*target(s,r.id);
}
bool in_view(ivec2 px) {
	return all(greaterThanEqual(px,ivec2(0))) && all(lessThan(px,p.grid.xy));
}
bool similar(Receiver s, vec3 pos, vec3 n) {
	float footprint = max(0.02, 4.0*distance(s.pos,p.camera[3].xyz)/float(p.grid.y));
	return dot(s.n,n) > 0.95 && distance(s.pos,pos) < 3.0*footprint &&
			abs(dot(s.pos-pos,s.n)) < 0.2*footprint;
}

#ifndef SRC_RAYGEN
void initial_and_temporal(ivec2 px) {
	Receiver s;
	Reservoir r = empty_reservoir();
	if (receiver_at(px,s)) {
		uint rng = seed(px);
		int k = min(8,p.grid.w);
		// Stratify the uniform discrete proposal. For <= 8 lights this visits each once.
		for (int j=0; j<k; ++j) {
			int id = min(p.grid.w-1,int((float(j)+random01(rng))*float(p.grid.w)/float(k)));
			stream(r,id,target(s,id)*float(p.grid.w),1u,rng);
		}
		if (p.frame.z != 0 && p.frame.x != RIS) {
			vec4 clip = p.previous_clip * vec4(s.pos,1);
			if (clip.w > 0.0) {
				ivec2 prev = ivec2(floor((clip.xy/clip.w*0.5+0.5)*vec2(p.grid.xy)));
				if (in_view(prev)) {
					uvec4 old = imageLoad(surface_tex,prev);
					if (old.w != 0u && similar(s,uintBitsToFloat(old.xyz),unpackSnorm4x8(old.w).xyz))
						combine(r,s,unpack_reservoir(imageLoad(history_tex,prev).xy),16u,rng);
				}
			}
		}
		normalize_reservoir(r,s);
	}
	imageStore(candidates_tex,px,pack_reservoir(r));
}
#endif

Reservoir spatial(ivec2 px, Receiver s) {
	Reservoir center = unpack_reservoir(imageLoad(candidates_tex,px).xy);
	if (p.frame.x == RIS) return center;
	Reservoir r = empty_reservoir();
	uint rng = seed(px) ^ 0x68bc21ebu;
	combine(r,s,center,32u,rng);
	const ivec2 offsets[] = ivec2[](ivec2(2,1),ivec2(-1,2),ivec2(-2,-1),ivec2(1,-2));
	for (int i=0; i<4; ++i) {
		ivec2 neighbor = px + offsets[i];
		if (!in_view(neighbor)) continue;
		vec3 pos,n;
		if (surface(neighbor,pos,n) && similar(s,pos,n))
			combine(r,s,unpack_reservoir(imageLoad(candidates_tex,neighbor).xy),8u,rng);
	}
	normalize_reservoir(r,s);
	return r;
}
bool visible(Receiver s, vec3 l, float reach) {
	return intersect_scene(s.pos+s.n*BIAS,l,reach-BIAS,true).tri < 0;
}

// Point lights have one binary visibility per fixed surface point. Integrate
// known terms exactly. The unresolved sum bounds every possible shadow result;
// spend extra rays on cold pixels until the remaining RGB interval fits the budget.
vec3 resolve(Receiver s, Reservoir r, inout uvec2 masks) {
	vec3 selected = vec3(0), lower = vec3(0), unresolved = vec3(0);
	if (p.frame.x == RAW || p.frame.x == RIS) {
		if (r.id < 0) return selected;
		vec3 l; float reach;
		vec3 c = contribution(s,r.id,l,reach);
		if (all(equal(c,vec3(0)))) return vec3(0);
		return visible(s,l,reach) ? r.weight*c : vec3(0);
	}
	for (int id=0; id<p.grid.w; ++id) {
		vec3 l; float reach;
		vec3 c = contribution(s,id,l,reach);
		if (all(equal(c,vec3(0)))) continue;
		uint bit = id < 32 ? 1u << uint(id) : 0u;
		bool lit;
		if (p.frame.x == REFERENCE) {
			lit = visible(s,l,reach);
		} else if ((masks.x & bit) != 0u) {
			lit = (masks.y & bit) != 0u;
		} else {
			if (id != r.id && all(lessThanEqual(unresolved+c,vec3(p.quality.x)))) {
				unresolved += c;
				continue;
			}
			lit = visible(s,l,reach);
			masks.x |= bit;
			if (lit) masks.y |= bit;
		}
		if (lit) {
			lower += c;
			if (id == r.id) selected = r.weight*c;
		}
	}
	return clamp(selected,lower,lower+unresolved);
}
void shade(ivec2 px) {
	Receiver s;
	if (!receiver_at(px,s)) {
		imageStore(surface_tex,px,uvec4(0));
		imageStore(history_tex,px,uvec4(0));
		return;
	}
	uvec4 key = uvec4(floatBitsToUint(s.pos),packSnorm4x8(vec4(s.n,1.0)));
	uvec2 masks = uvec2(0);
	if (p.frame.x == STABLE && p.frame.w != 0 && all(equal(imageLoad(surface_tex,px),key)))
		masks = imageLoad(visibility_tex,px).xy & uvec2(uint(p.frame.w));
	Reservoir r = empty_reservoir();
	if (p.frame.x != REFERENCE) r = spatial(px,s);
	vec3 direct = resolve(s,r,masks);
	imageStore(history_tex,px,pack_reservoir(r));
	imageStore(surface_tex,px,key);
	imageStore(visibility_tex,px,uvec4(masks,0,0));
	vec4 original = imageLoad(color_tex,px);
	imageStore(color_tex,px,vec4(original.rgb+direct,original.a));
}
