#[compute]
#version 450
// Adapted from water-simulation/simulation/spectral/shaders/evolve.wgsl.
layout(local_size_x=64) in;
layout(set=0,binding=0,std430) readonly buffer Spectrum { vec4 modes[]; };
layout(set=0,binding=1,std430) writeonly buffer Field { vec2 field[]; };
layout(set=0,binding=2,std430) readonly buffer Clock { uint stats[]; };
layout(push_constant,std430) uniform Params {
    vec4 grid; // N, length m, rejected wavelength m, transition m
    vec4 clock; // input filter enabled, time offset s, unused, unused
} p;
vec2 cmul(vec2 a,vec2 b) { return vec2(a.x*b.x-a.y*b.y,a.x*b.y+a.y*b.x); }
void main() {
    uint n=uint(p.grid.x), i=gl_GlobalInvocationID.x;
    if(i>=n*n) return;
    uint x=i%n, z=i/n, opposite=((n-z)%n)*n+(n-x)%n;
    vec4 mode=modes[i];
    float k=length(mode.zw), omega=sqrt(9.81*k);
    float angle=omega*(uintBitsToFloat(stats[1])+p.clock.y);
    vec2 phase=vec2(cos(angle),sin(angle));
    vec2 a=cmul(mode.xy,phase), b=cmul(modes[opposite].xy*vec2(1,-1),phase*vec2(1,-1));
    vec2 h=a+b;
    field[i]=h;
    field[n*n+i]=vec2(h.y,-h.x)*mode.z/max(k,0.000001);
    field[2*n*n+i]=vec2(h.y,-h.x)*mode.w/max(k,0.000001);
    float wavelength=6.28318530718/max(k,0.000001), lowpass=1.0;
    if(p.clock.x>0.5) lowpass=p.grid.w>0.0 ? smoothstep(p.grid.z,p.grid.z+p.grid.w,wavelength) : float(wavelength>p.grid.z);
    vec2 flux=(b-a)*omega/max(k*k,0.00000001)*lowpass;
    field[3*n*n+i]=h*lowpass;
    field[4*n*n+i]=flux*mode.z;
    field[5*n*n+i]=flux*mode.w;
}
