#[compute]
#version 450
layout(local_size_x=64) in;
layout(set=0,binding=0,std430) readonly buffer FFT { vec2 field[]; };
layout(set=0,binding=1,std430) buffer History { vec4 history[]; };
layout(set=0,binding=2,std430) readonly buffer Clock { uint stats[]; };
layout(set=0,binding=3,std430) readonly buffer Configuration {
    vec4 source; vec4 front; vec4 response; vec4 offshore;
    ivec4 mode; vec4 lifetime; vec4 geometry; ivec4 grid;
} f;
layout(push_constant,std430) uniform Params { vec4 fft; } p; // FFT length,initialize flag...
vec2 displacement(ivec2 c) {
    int n=f.grid.y; c=((c%n)+n)%n; int i=c.y*n+c.x;
    return vec2(field[n*n+i].x,field[2*n*n+i].x);
}
void main() {
    int i=int(gl_GlobalInvocationID.x),n=f.grid.y;
    if(i>=n*n) return;
    ivec2 c=ivec2(i%n,i/n);
    float factor=f.offshore.w/(2.0*p.fft.x/float(n));
    vec2 dx=(displacement(c+ivec2(1,0))-displacement(c-ivec2(1,0)))*factor;
    vec2 dz=(displacement(c+ivec2(0,1))-displacement(c-ivec2(0,1)))*factor;
    float j=(1.0+dx.x)*(1.0+dz.y)-dz.x*dx.y;
    float amount=p.fft.y>0.5?0.0:history[i].x;
    float duration=p.fft.y>0.5?0.0:uintBitsToFloat(stats[8]);
    float source=f.offshore.y*clamp(f.offshore.x-j,0.0,1.0)*(f.mode.y!=0&&(f.grid.w&1)!=0?1.0:0.0);
    float rate=source+f.offshore.z;
    if(f.mode.x!=0&&duration>0.0&&rate>0.0) {
        float equilibrium=source/rate;
        amount=equilibrium+(amount-equilibrium)*exp(-rate*duration);
    }
    float phase=uintBitsToFloat(stats[9]);
    history[i]=vec4(clamp(amount,0.0,1.0),j,phase,0);
}
