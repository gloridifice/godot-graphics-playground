#[vertex]
#version 450
layout(location=0) in vec3 position;
layout(location=1) in vec2 texcoord;
layout(location=0) out vec2 uv;
layout(push_constant,std430) uniform MaterialDraw { mat4 world_to_clip; vec4 diffuse; vec4 metal_weights; } pc;
void main() {
	gl_Position = pc.world_to_clip * vec4(position,1);
	uv = texcoord;
}

#[fragment]
#version 450
layout(location=0) in vec2 uv;
layout(location=0) out vec4 albedo;
layout(set=0,binding=0) uniform sampler2D scene_depth;
layout(set=1,binding=0) uniform sampler2D base_color;
layout(set=1,binding=1) uniform sampler2D metallic_map;
layout(push_constant,std430) uniform MaterialDraw { mat4 world_to_clip; vec4 diffuse; vec4 metal_weights; } pc;
void main() {
	// The viewport depth is read-only. Ignored / dynamic occluders still mask
	// receivers. Use a small depth tolerance for the different transform paths.
	float depth = texelFetch(scene_depth,ivec2(gl_FragCoord.xy),0).r;
	// In orthographic projection clip W is constant: a relative tolerance
	// near depth=1 could accept surfaces centimetres apart at a long far plane.
	vec3 w_row = vec3(pc.world_to_clip[0].w,pc.world_to_clip[1].w,pc.world_to_clip[2].w);
	float epsilon = all(equal(w_row,vec3(0))) ? 2e-7 : max(2e-7,depth*2e-5);
	vec2 dx = dFdx(uv), dy = dFdy(uv); // get mip gradients before the nonuniform discard
	if (depth <= 0.0 || abs(depth-gl_FragCoord.z) > epsilon) discard;
	float metal = dot(pc.metal_weights, textureGrad(metallic_map,uv,dx,dy));
	albedo = vec4(pc.diffuse.rgb * textureGrad(base_color,uv,dx,dy).rgb * (1.0-metal),1);
}
