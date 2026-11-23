shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled;

float hash(vec2 cell) { return fract(sin(dot(cell, vec2(12.79, 71.37))) * 43758.41); }
float noise(vec2 p) {
	vec2 i = floor(p), f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i+vec2(1,0)), f.x), mix(hash(i+vec2(0,1)), hash(i+1.0), f.x), f.y);
}

// Advected bends travel up the wick. Change the silhouette, not the OmniLight energy.
void fragment() {
	float h = 1.0 - UV.y;
	float t = TIME * 4.5;
	float tip = 0.93 + 0.045 * sin(t * 1.3);
	float y = clamp(h / tip, 0.0, 1.0);
	float bend = y * y * (0.33 * sin(6.0 * y - t) + 0.16 * sin(13.0 * y - 1.7 * t));
	float x = (UV.x * 2.0 - 1.0) - bend;
	float width = (0.54 + 0.29 * sin(PI * min(1.0, y * 2.5))) * pow(1.0 - y, 0.82);
	width *= 1.0 + 0.13 * sin(13.0 * y - 1.3 * t) + 0.06 * sin(31.0 * y - 1.9 * t);
	float roll = noise(vec2(4.5*x, 6.0*y-t*1.4));
	float tongues = noise(vec2(6.0*x+roll, 5.0*y-t));
	float inside = 1.0 - abs(x) / max(0.001, width) + (roll - 0.5) * (0.65 + y);
	float alpha = smoothstep(-0.03, 0.18, inside) * (1.0 - smoothstep(0.96, 1.0, y));
	if (alpha < 0.015) { discard; }
	float core = clamp(1.2 * inside - 0.95 * y + 0.75 * (tongues - 0.34), 0.0, 1.0);
	ALBEDO = mix(vec3(1.05, 0.066, 0.004), vec3(3.1, 1.45, 0.36), core*core);
	ALPHA = alpha;
}
