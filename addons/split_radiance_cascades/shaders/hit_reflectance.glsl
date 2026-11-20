#[compute]
#version 450
// One workgroup per textured hit material at snapshot build, never per ray/frame.
layout(local_size_x=8, local_size_y=8, local_size_z=1) in;
layout(set=0,binding=0,std430) writeonly buffer Materials { vec4 materials[]; };
layout(set=1,binding=0) uniform sampler2D base_color;   // sRGB view: fetch returns linear
layout(set=1,binding=1) uniform sampler2D metal_map;    // linear data, selected channel
layout(push_constant,std430) uniform Material { vec4 tint_index; vec4 metal_weights; } pc;
shared vec3 subtotal[64];

void main() {
	// Stratify over the whole UV tile. Read the same UV from both maps so
	// metal texels don't color the diffuse light, even on a mixed material.
	vec3 sum = vec3(0);
	for (uint y=gl_LocalInvocationID.y; y<64u; y+=8u) {
		for (uint x=gl_LocalInvocationID.x; x<64u; x+=8u) {
			uint h = (y*64u+x+1u)*747796405u + 2891336453u;
			h = ((h >> ((h >> 28u)+4u)) ^ h) * 277803737u;
			h = (h >> 22u) ^ h;
			vec2 uv = (vec2(x,y) + vec2(h & 65535u,h >> 16u)/65536.0) / 64.0;
			vec3 albedo = texelFetch(base_color,ivec2(uv*textureSize(base_color,0)),0).rgb;
			float metal = dot(pc.metal_weights,texelFetch(metal_map,ivec2(uv*textureSize(metal_map,0)),0));
			sum += albedo*(1.0-metal);
		}
	}
	uint i = gl_LocalInvocationIndex;
	subtotal[i] = sum;
	barrier();
	for (uint step=32u; step>0u; step>>=1u) {
		if (i<step) subtotal[i] += subtotal[i+step];
		barrier();
	}
	// Only replace reflectance. Entry 2*i+1 still holds emitted radiance.
	if (i==0u) materials[2*int(pc.tint_index.w)] = vec4(pc.tint_index.rgb*(subtotal[0]/4096.0),0);
}
