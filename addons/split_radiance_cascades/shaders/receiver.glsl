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
	vec3 w_row = vec3(pc.world_to_clip[0].w,pc.world_to_clip[1].w,pc.world_to_clip[2].w);
	vec3 z_row = vec3(pc.world_to_clip[0].z,pc.world_to_clip[1].z,pc.world_to_clip[2].z);
	float z = gl_FragCoord.z;
	float base = all(equal(w_row,vec3(0))) ? 2e-7 : max(2e-7,depth*2e-5);
	// A subpixel difference in projected vertices produces a larger depth error
	// on a grazing triangle. Use its own slope, never a neighboring occluder's.
	float slope_error = fwidth(z) * (1.0/256.0);
	// |grad_world(clip_z / clip_w)| converts 2 mm of axial separation to depth
	// for either projection. Never widen past that cap or shrink the old floor.
	float cap = 0.002 * gl_FragCoord.w * length(z_row - z*w_row);
	float epsilon = max(base, min(base + slope_error, cap));
	vec2 dx = dFdx(uv), dy = dFdy(uv); // get mip gradients before the nonuniform discard
	if (depth <= 0.0 || abs(depth-gl_FragCoord.z) > epsilon) discard;
	float metal = dot(pc.metal_weights, textureGrad(metallic_map,uv,dx,dy));
	albedo = vec4(pc.diffuse.rgb * textureGrad(base_color,uv,dx,dy).rgb * (1.0-metal),1);
}
