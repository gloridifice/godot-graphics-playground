#[compute]
#version 450
// Radix-2 inverse FFT, same indexing/normalization as the Rust reference.
layout(local_size_x=64) in;
layout(set=0,binding=0,std430) readonly buffer InputField { vec2 input_field[]; };
layout(set=0,binding=1,std430) writeonly buffer OutputField { vec2 output_field[]; };
layout(push_constant,std430) uniform Params { uvec4 grid; } p; // N, span, axis, bits
uint read_index(uint channel,uint x,uint z,uint coordinate) {
    uint c=p.grid.y==2 ? bitfieldReverse(coordinate)>>(32-p.grid.w) : coordinate;
    return channel*p.grid.x*p.grid.x+(p.grid.z==0 ? z*p.grid.x+c : c*p.grid.x+x);
}
void main() {
    uint i=gl_GlobalInvocationID.x,n=p.grid.x,span=p.grid.y;
    if(i>=6*n*n) return;
    uint channel=i/(n*n),x=i%n,z=(i/n)%n;
    uint coordinate=p.grid.z==0 ? x : z,half_span=span/2,j=coordinate%half_span,start=(coordinate/span)*span;
    vec2 a=input_field[read_index(channel,x,z,start+j)],b=input_field[read_index(channel,x,z,start+j+half_span)];
    float angle=6.28318530718*float(j)/float(span);
    vec2 w=vec2(cos(angle),sin(angle));
    vec2 wb=vec2(w.x*b.x-w.y*b.y,w.x*b.y+w.y*b.x);
    output_field[i]=(a+(coordinate%span>=half_span ? -wb : wb))*(span==n ? 1.0/float(n) : 1.0);
}
