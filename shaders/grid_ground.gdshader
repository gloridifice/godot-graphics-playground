shader_type spatial;
render_mode cull_back;

varying vec3 world_position;

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

float grid_line(vec2 position, float period, float width) {
	vec2 coordinate = position / period;
	vec2 footprint = max(fwidth(coordinate), vec2(0.00001));
	vec2 distance_to_line = abs(fract(coordinate - 0.5) - 0.5) / footprint;
	float line = 1.0 - smoothstep(width, width + 1.0, min(distance_to_line.x, distance_to_line.y));
	return line * (1.0 - smoothstep(0.15, 0.5, max(footprint.x, footprint.y)));
}

void fragment() {
	float fine = grid_line(world_position.xz, 1.0, 0.4);
	float major = grid_line(world_position.xz, 5.0, 0.8);
	vec3 color = mix(vec3(0.22, 0.28, 0.065), vec3(0.40, 0.48, 0.14), fine);
	color = mix(color, vec3(0.57, 0.64, 0.22), major * 0.7);
	vec2 axis_distance = abs(world_position.xz) / max(fwidth(world_position.xz), vec2(0.0001));
	color = mix(color, vec3(0.55, 0.38, 0.10), 1.0 - smoothstep(1.0, 2.0, axis_distance.y));
	color = mix(color, vec3(0.26, 0.43, 0.12), 1.0 - smoothstep(1.0, 2.0, axis_distance.x));
	ALBEDO = color;
	ROUGHNESS = 0.95;
}
