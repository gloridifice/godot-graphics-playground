struct SceneLight {
	vec4 position_range; // range zero denotes a directional light
	vec4 direct_falloff;
	vec4 bounce; // RGB indirect energy; W movement used by the probe history
};
layout(set=0,binding=9,std430) readonly buffer Lights { SceneLight lights[]; };

// Distance window and falloff, without any surface term. Zero outside the lamp's range.
float light_scale(SceneLight lamp, vec3 pos, out vec3 direction, out float reach) {
	direction = lamp.position_range.xyz;
	reach = 1e20;
	float scale = 1.0;
	float radius = lamp.position_range.w;
	if (radius > 0.0) {
		direction -= pos;
		reach = length(direction);
		if (reach >= radius || reach <= 0.003) return 0.0;
		direction /= reach;
		float window = 1.0 - pow(reach/radius, 4.0);
		scale = window*window / pow(max(0.1,reach), lamp.direct_falloff.w);
	}
	return scale;
}

float diffuse_factor(SceneLight lamp, vec3 pos, vec3 n, out vec3 direction, out float reach) {
	float scale = light_scale(lamp, pos, direction, reach);
	return max(0.0, dot(n,direction)) * scale / 3.14159265359;
}
