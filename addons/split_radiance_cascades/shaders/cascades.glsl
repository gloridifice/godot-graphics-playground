#[compute]
#version 450
layout(local_size_x=8, local_size_y=8, local_size_z=1) in;
#include "trace_bindings.inc"
layout(push_constant,std430) uniform Command { int stage, cascade, pad0, pad1; } cmd;
layout(set=0,binding=2,std430) buffer Counters { uvec4 groups[4]; };
layout(set=0,binding=3,std430) buffer ActiveIDs { uint active_ids[]; };
// Two vec4s per stackless BVH node. Layout is shared with scene_snapshot.gd.
layout(set=0,binding=6,std430) readonly buffer Nodes { vec4 nodes[]; };
layout(set=0,binding=7,std430) readonly buffer Triangles { vec4 triangles[]; };
layout(rgba16f,set=0,binding=12) uniform image2D color_tex;
layout(set=0,binding=13) uniform sampler2D receiver_tex;

#include "grid.inc"
#include "trace.inc"
#include "light_motion.inc"
#include "merge.inc"

void apply_pixel(ivec2 pixel) {
	if (any(greaterThanEqual(pixel,p.grid.xy))) return;
	vec3 pos, n;
	if (!surface(pixel,pos,n)) return;
	vec4 original = imageLoad(color_tex,pixel);
	vec3 color = vec3(0);
	int mode = p.options.y;
	if (mode <= 1) {
		vec4 receiver = texelFetch(receiver_tex,pixel,0);
		if (receiver.a > 0.0) color = irradiance_over_pi(pos,n,false)*receiver.rgb*p.display.x;
		if (mode == 0) color += original.rgb;
	} else {
		float lod = lod_at(pos);
		int c = p.options.z;
		uint id = lookup(c, key_at(pos,int(lod),c));
		if (mode == 2 && id != NONE) {
			uint h = hash32(id+1u);
			color = vec3((uvec3(h) >> uvec3(0,8,16)) & 255u)/255.0;
		} else if (mode == 3) {
			const vec3 palette[] = vec3[](vec3(0.08,0.5,0.2),vec3(0.12,0.35,0.9),vec3(0.9,0.4,0.08),vec3(0.65,0.1,0.6));
			color = mix(palette[int(lod)],palette[min(3,int(lod)+1)],fract(lod));
		} else if (mode == 4 && id != NONE) {
			uint base = bin_start(id,c);
			float total = 0.0;
			for (int d=0; d<bin_count(c); ++d) {
				float w = bins[base+d].weight;
				color += bins[base+d].interval.rgb*w; total += w;
			}
			color /= max(1e-5,total);
		}
	}
	imageStore(color_tex,pixel,vec4(color,original.a));
}
void main() {
	int c = cmd.cascade;
	uint lane = gl_WorkGroupID.x*64u + gl_LocalInvocationIndex;
	if (cmd.stage == 0) { // expire + reset active counts (not history)
		if (lane < 4u) groups[lane] = uvec4(0,1,1,0);
		if (lane < p.slot_base.w + p.capacity.w && (p.grid.w == 1 || uint(p.grid.w)-slots[lane].y > 32u)) slots[lane] = uvec4(0);
	} else if (cmd.stage == 3) { // gather parents from occupied children only
		if (lane >= groups[c].x) return;
		uint key = slots[active_ids[p.slot_base[c]+lane]].x;
		acquire(c+1,key_for(cell_of(key) >> 1,tag_of(key)));
	} else if (cmd.stage == 5) {
		merge_probe(c); // Motion smoothing is confined to the primary display result.
	} else if (cmd.stage == 7) { // stage 6 is the receiver raster draw
		apply_pixel(ivec2(gl_GlobalInvocationID.xy));
	} else {
		ivec2 tile = ivec2(gl_GlobalInvocationID.xy), size = (p.grid.xy+p.grid.z-1)/p.grid.z;
		if (any(greaterThanEqual(tile,size))) return;
		int index = tile.x + size.x*tile.y, tile_count = size.x*size.y;
		if (cmd.stage == 1) { trace_tile(tile,index,tile_count); return; }
		for (int bank = 0; bank <= p.options.x; ++bank) {
			Ray ray = rays[index + bank*tile_count];
			if (ray.origin_t.w < 0.0) continue;
			float lod = lod_at(ray.origin_t.xyz);
			uint hi = uint(round(fract(lod)*float(LOD_ONE)));
			for (int l=int(lod); l<=int(ceil(lod)); ++l) {
				uint mass = l == int(lod) ? LOD_ONE-hi : hi;
				if (mass == 0u) continue;
				int tag = l + bank*4;
				if (cmd.stage == 2) acquire(0,key_at(ray.origin_t.xyz,tag,0));
				else deposit(ray,tag,mass);
			}
		}
	}
}
