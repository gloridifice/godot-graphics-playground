@tool
extends RefCounted
## Geometry acceleration for finite software shadow rays. Tiles belong to the
## light and static snapshot, so every camera and both lighting passes share them.
const BuildShader := preload("shaders/build_point_shadow_tiles.glsl")
const SIDE := 64
const MAX_LIGHTS := 32
const TILE_BYTES := 68 # 16 packed depth/triangle entries and a bound on the omitted geometry

var buffer: RID
var _rd: RenderingDevice
var _shader: RID
var _pipeline: RID
var _capacity := -1
var _first := -1
var _positions := PackedVector4Array()

func update(rd: RenderingDevice, geometry: Array[RID], positions: PackedVector4Array, first: int, rebuild: bool) -> bool:
	_rd = rd
	var count := mini(positions.size(),MAX_LIGHTS)
	if count > _capacity:
		if buffer.is_valid(): rd.free_rid(buffer)
		buffer = rd.storage_buffer_create(16 + count*6*SIDE*SIDE*TILE_BYTES)
		if not buffer.is_valid(): return false
		_capacity = count
		rebuild = true
	if rebuild or first != _first or count != _positions.size():
		rd.buffer_update(buffer,0,16,PackedInt32Array([first,count,SIDE,0]).to_byte_array())
		_first = first
	var slots := PackedInt32Array()
	for i in count:
		if rebuild or i >= _positions.size() or positions[i] != _positions[i]: slots.append(i)
	_positions = positions.slice(0,count)
	if slots.is_empty(): return true
	if not _pipeline.is_valid():
		_shader = rd.shader_create_from_spirv(BuildShader.get_spirv())
		if not _shader.is_valid(): return false
		_pipeline = rd.compute_pipeline_create(_shader)
		if not _pipeline.is_valid(): return false
	var uniforms: Array[RDUniform] = []
	for binding: int in [0,1,15]:
		var u := RDUniform.new()
		u.binding = binding
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		u.add_id(buffer if binding == 15 else geometry[binding])
		uniforms.append(u)
	var bindings := UniformSetCacheRD.get_cache(_shader,0,uniforms)
	if not bindings.is_valid(): return false
	var list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list,_pipeline)
	rd.compute_list_bind_uniform_set(list,bindings,0)
	for i in slots:
		var params := PackedVector4Array([positions[i]]).to_byte_array()
		params.append_array(PackedInt32Array([i,0,0,0]).to_byte_array())
		rd.compute_list_set_push_constant(list,params,32)
		rd.compute_list_dispatch(list,SIDE/8,SIDE/8,6)
	rd.compute_list_end()
	return true

func close() -> void:
	for rid: RID in [buffer,_pipeline,_shader]:
		if rid.is_valid(): _rd.free_rid(rid)
