shader_type spatial;

// The charred wrap has a glowing seam where its turns overlap; it is not a GI emitter.
instance uniform float lit : hint_range(0.0, 1.0) = 1.0;
uniform sampler2D grain : source_color, repeat_enable;
void fragment() {
	float fibre = texture(grain, UV * vec2(1.5, 1.0)).r;
	float turn = UV.x * 2.0 + UV.y * 7.0 + 0.095 * sin(UV.x * 50.265) + fibre * 1.5;
	float edge = abs(fract(turn) - 0.5);
	float hot = (1.0 - smoothstep(0.03, 0.18, edge)) * (0.45 + 0.55 * sin(12.566 * UV.x + UV.y * 9.0) * sin(12.566 * UV.x + UV.y * 9.0));
	ALBEDO = vec3(0.036, 0.017, 0.008) * (0.4 + 2.2 * fibre);
	ROUGHNESS = 0.98;
	EMISSION = vec3(1.9, 0.20, 0.012) * hot * lit;
}
