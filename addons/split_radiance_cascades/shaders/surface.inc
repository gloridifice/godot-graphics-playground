bool surface(ivec2 pixel, out vec3 pos, out vec3 n) {
	float depth = texelFetch(depth_tex, pixel, 0).r;
	if (depth <= 0.0) return false; // Forward+ reverse Z clear value
	vec2 uv = (vec2(pixel)+0.5)/vec2(p.grid.xy);
	vec4 view = p.inv_proj * vec4(uv*2.0-1.0,depth,1);
	pos = (p.camera * vec4(view.xyz/view.w,1)).xyz;
	n = normalize(mat3(p.camera) * (texelFetch(normal_tex,pixel,0).xyz*2.0-1.0));
	return true;
}
