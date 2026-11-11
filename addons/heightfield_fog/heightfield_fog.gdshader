shader_type fog;

uniform sampler2D height_map : filter_linear, repeat_disable;
uniform mat4 world_to_box;
uniform vec3 box_size = vec3(8.0, 4.0, 8.0);
uniform sampler2D thickness_map : filter_linear, repeat_disable;
uniform float concentration = 1.0;
uniform float edge_fade = 1.0;
uniform float extinction = 3.0;
uniform vec3 tint : source_color = vec3(0.85, 0.9, 1.0);
uniform float brightness = 0.3;
uniform float vertical_filter = 0.1;

uniform bool natural_mist_enabled = false;
uniform bool horizontal_top = false;
uniform float baseline_height = 0.4;
uniform float top_variation = 0.25;
uniform float top_scale = 20.0;
uniform float top_softness = 0.65;
uniform float detail_strength = 0.3;
uniform float detail_scale = 3.0;
uniform float wind_stretch = 4.0;
uniform vec2 wind_direction = vec2(1.0, 0.0);
uniform float wind_speed = 0.12;
uniform float mist_time = 0.0;
uniform float noise_seed = 7.0;
uniform vec2 noise_offset = vec2(0.0);
uniform bool swe_active = false;

// Smooth, deterministic value noise: no reseeding or texture upload during animation.
float hash_value(vec2 p) {
	vec3 q = fract(vec3(p.xyx) * 0.1031 + fract(noise_seed * 0.0137));
	q += dot(q, q.yzx + 33.33);
	return fract((q.x + q.y) * q.z);
}

float smooth_noise(vec2 p) {
	vec2 cell = floor(p);
	vec2 f = fract(p);
	f = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
	return mix(mix(hash_value(cell), hash_value(cell + vec2(1.0, 0.0)), f.x),
		mix(hash_value(cell + vec2(0.0, 1.0)), hash_value(cell + vec2(1.0)), f.x), f.y) * 2.0 - 1.0;
}

float broad_noise(vec2 p) {
	return (smooth_noise(p) + 0.35 * smooth_noise(p * 2.03 + vec2(17.2, 9.4))) / 1.35;
}

// Antiderivative of a constant lower density with a smoothstep fade at the top.
// Average over a vertical interval instead of point-sampling the thin profile.
float mist_integral(float y, float height) {
	float width = max(height * top_softness, 0.00001);
	float clamped_y = clamp(y, 0.0, height);
	float t = clamp((clamped_y - (height - width)) / width, 0.0, 1.0);
	return clamped_y - width * (t * t * t - 0.5 * t * t * t * t);
}

float integral(float s) {
	s = clamp(s, 0.0, 1.0);
	return s * s * (3.0 - 2.0 * s);
}

void fog() {
	vec3 p = (world_to_box * vec4(WORLD_POSITION, 1.0)).xyz;
	vec2 uv = p.xz / box_size.xz + 0.5;
	DENSITY = 0.0;
	ALBEDO = tint;
	EMISSION = tint * brightness;
	if (SDF <= 0.0 && all(greaterThanEqual(uv, vec2(0.0))) && all(lessThan(uv, vec2(1.0)))) {
		vec2 dimensions = vec2(textureSize(height_map, 0));
		vec2 center = (floor(uv * dimensions) + 0.5) / dimensions;
		vec2 valid = textureLod(height_map, center, 0.0).rg;
		vec2 bed = textureLod(height_map, uv, 0.0).rg;
		// Query-time taper acts on thickness, never on the supporting surface.
		vec2 distance_to_edge = box_size.xz * 0.5 - abs(p.xz);
		float distance = min(distance_to_edge.x, distance_to_edge.y);
		float weight = edge_fade > 0.0 ? smoothstep(0.0, edge_fade, distance) : 1.0;
		if (valid.g > 0.5 && bed.g > 0.0001) {
			float ground = bed.r / bed.g;
			float y = p.y - ground;
			float radius = max(vertical_filter * 0.5, 0.001);
			if (natural_mist_enabled) {
				// A world-aligned field prevents rotated/adjacent boxes from rotating the wind.
				vec2 advected = WORLD_POSITION.xz + noise_offset - wind_direction * wind_speed * mist_time;
				float top_offset = swe_active ? 0.0 : top_variation * broad_noise(advected / top_scale);
				// Subtract terrain BEFORE clamping: a rock above the mist top must stay dry.
				float h = (swe_active ? textureLod(thickness_map, uv, 0.0).r : max(baseline_height + top_offset - (horizontal_top ? ground : 0.0), 0.0)) * weight;
				if (h > 0.00001 && y > -radius && y < h + radius) {
					vec2 across = vec2(-wind_direction.y, wind_direction.x);
					vec2 q = vec2(dot(advected, wind_direction) / wind_stretch, dot(advected, across)) / detail_scale;
					q.y += 0.3 * broad_noise(advected / top_scale + vec2(31.0, 7.0));
					// Keep a connected body; detail is stronger near the soft upper boundary.
					float modulation = 1.0 + detail_strength * broad_noise(q) * mix(0.4, 1.0, smoothstep(0.0, h, y));
					float coverage = mist_integral(y + radius, h) - mist_integral(y - radius, h);
					DENSITY = extinction * concentration * max(coverage, 0.0) / (2.0 * radius) * modulation;
				}
			} else {
				float h = textureLod(thickness_map, uv, 0.0).r * weight;
				if (h > 0.00001) {
					float coverage = integral((y + radius) / h) - integral((y - radius) / h);
					DENSITY = extinction * concentration * h * coverage / (2.0 * radius);
				}
			}
		}
	}
}
