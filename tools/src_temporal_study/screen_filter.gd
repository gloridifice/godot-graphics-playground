@tool
extends RefCounted
## Three lists: temporal / edge-aware stride 1 / stride 2 plus composition.
const ShaderFile := preload("shaders/screen_filter.glsl")
var rd: RenderingDevice
var shader: RID
var pipeline: RID
var textures: Array[RID] = [] # raw/scratch, two radiance and two geometry histories
var extent := Vector2i.ZERO
var target: RID
var last_frame := -1
var prev_matrix := Projection.IDENTITY
var prev_eye := Vector3.ZERO
var ping := 0

func resize(device: RenderingDevice, size: Vector2i, view: RID) -> RID:
	rd = device
	if not shader.is_valid():
		var spirv := ShaderFile.get_spirv()
		if not spirv or not spirv.compile_error_compute.is_empty(): return RID()
		shader = rd.shader_create_from_spirv(spirv)
		if shader.is_valid(): pipeline = rd.compute_pipeline_create(shader)
	if not pipeline.is_valid(): return RID()
	if extent != size:
		_release_textures(); extent = size; last_frame = -1
		var fmt := RDTextureFormat.new(); fmt.width=size.x; fmt.height=size.y
		fmt.format=RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT; fmt.usage_bits=RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
		for i in 5:
			var tex := rd.texture_create(fmt,RDTextureView.new())
			if not tex.is_valid(): _release_textures(); extent=Vector2i.ZERO; return RID()
			textures.append(tex)
	if target!=view: target=view; last_frame=-1
	return textures[0]

func run(params: RID, sampler: RID, depth: RID, normal: RID, albedo: RID, color: RID, matrix: Projection, eye: Vector3, frame: int) -> bool:
	var ids: Array[RID] = [params,depth,normal,albedo,color,textures[0],textures[1+ping],textures[2-ping],textures[3+ping],textures[4-ping]]
	var uniforms: Array[RDUniform] = []
	for i in ids.size():
		var u:=RDUniform.new(); u.binding=i
		if i==0: u.uniform_type=RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
		elif i<=3: u.uniform_type=RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE; u.add_id(sampler)
		else: u.uniform_type=RenderingDevice.UNIFORM_TYPE_IMAGE
		u.add_id(ids[i]); uniforms.append(u)
	var bindings:=UniformSetCacheRD.get_cache(shader,0,uniforms)
	if not bindings.is_valid(): return false
	var head:=PackedVector4Array([prev_matrix.x,prev_matrix.y,prev_matrix.z,prev_matrix.w,Vector4(prev_eye.x,prev_eye.y,prev_eye.z,0)]).to_byte_array()
	for op in 3:
		var list:=rd.compute_list_begin(); rd.compute_list_bind_compute_pipeline(list,pipeline)
		rd.compute_list_bind_uniform_set(list,bindings,0)
		var pc:=head+PackedInt32Array([op,int(frame>1 and last_frame==frame-1),0,0]).to_byte_array()
		rd.compute_list_set_push_constant(list,pc,pc.size()); rd.compute_list_dispatch(list,ceili(extent.x/8.0),ceili(extent.y/8.0),1)
		rd.compute_list_end()
	prev_matrix=matrix; prev_eye=eye; last_frame=frame; ping=1-ping; return true

func _release_textures() -> void:
	for t in textures: rd.free_rid(t)
	textures.clear()

func close() -> void:
	_release_textures()
	if pipeline.is_valid(): rd.free_rid(pipeline)
	if shader.is_valid(): rd.free_rid(shader)
