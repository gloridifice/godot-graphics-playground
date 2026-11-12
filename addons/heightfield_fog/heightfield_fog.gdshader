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
uniform sampler2D noise_map : filter_linear, repeat_enable;
// Frequency / tile period: same noise-space conversion as CPU initialization.
uniform float noise_uv_scale = 0.01;
uniform float coverage = 1.0;
uniform float coverage_softness = 0.15;
uniform float top_softness = 0.65;
uniform float detail_strength = 0.3;
uniform float detail_scale = 1.0;
uniform float wind_stretch = 4.0;
uniform vec2 wind_direction = vec2(1.0, 0.0);
// Preview displacement is retained as the visual origin across SWE mode changes.
uniform vec2 density_drift = vec2(0.0);
uniform bool simulated_wind = false;
uniform sampler2D wind_phase_map : filter_nearest, repeat_disable;
// Stable Fluids transports local material, rather than adding a second global drift.
uniform bool simulated_flow = false;
uniform sampler2D flow_displacement_map : filter_linear, repeat_disable;
uniform vec2 noise_offset = vec2(0.0);

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
				vec2 drift = density_drift;
				if (simulated_flow) {
					drift += textureLod(flow_displacement_map, uv, 0.0).rg;
				} else if (simulated_wind) {
					drift += textureLod(wind_phase_map, vec2(0.5), 0.0).rg;
				}
				vec2 advected = WORLD_POSITION.xz + noise_offset - drift;
				// No alternate procedural top: preview and SWE consume the same resource-built field.
				float h = textureLod(thickness_map, uv, 0.0).r * weight;
				if (h > 0.00001 && y > -radius && y < h + radius) {
					vec2 across = vec2(-wind_direction.y, wind_direction.x);
					vec2 q = vec2(dot(advected, wind_direction) / wind_stretch, dot(advected, across));
					float noise = textureLod(noise_map, q * noise_uv_scale / detail_scale, 0.0).r;
					// Coverage shapes visible wisps only; never erases mass from the SWE state.
					// Move the threshold past [0, 1] at the endpoints, without an abrupt switch.
					float threshold = mix(1.0 + coverage_softness, -coverage_softness, coverage);
					float mask = smoothstep(threshold - coverage_softness, threshold + coverage_softness, noise);
					float modulation = 1.0 + detail_strength * (noise * 2.0 - 1.0) * mix(0.4, 1.0, smoothstep(0.0, h, y));
					float column = mist_integral(y + radius, h) - mist_integral(y - radius, h);
					DENSITY = extinction * concentration * max(column, 0.0) / (2.0 * radius) * modulation * mask;
				}
			} else {
				float h = textureLod(thickness_map, uv, 0.0).r * weight;
				if (h > 0.00001) {
					float column = integral((y + radius) / h) - integral((y - radius) / h);
					DENSITY = extinction * concentration * h * column / (2.0 * radius);
				}
			}
		}
	}
}
