layout(location=0) rayPayloadInEXT HitPayload payload;
layout(set=1,binding=1,std430) readonly buffer Normals { vec4 normals[]; };
layout(set=1,binding=2,std430) readonly buffer Instances { uvec2 instances[]; };
void main() {
	uvec2 instance = instances[gl_InstanceCustomIndexEXT];
	vec3 n = normals[instance.x + gl_PrimitiveID].xyz;
	payload.normal = normalize(n * mat3(gl_WorldToObjectEXT));
	payload.t = gl_HitTEXT;
	payload.material = int(instance.y);
}
