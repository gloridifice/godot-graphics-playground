shader_type spatial;
render_mode depth_prepass_alpha;

uniform sampler2D base_color : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D opacity_map : filter_linear_mipmap, repeat_enable;
uniform float opacity_factor : hint_range(0.0, 1.0) = 0.35;

void fragment() {
	ALBEDO = texture(base_color, UV).rgb;
	ALPHA = texture(opacity_map, UV).r * opacity_factor;
	// Match the source glTF material's default PBR factors.
	METALLIC = 1.0;
	ROUGHNESS = 1.0;
}
