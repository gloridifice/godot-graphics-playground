@tool
extends RefCounted
## Render-thread only. One BLAS per unique mesh surface, one transformed TLAS
## entry per use. The rest of SRC consumes exactly the same Ray records.
const Snapshot := preload("scene_snapshot.gd")
const ShaderFile := preload("shaders/hardware_trace.glsl")
const INPUT := RenderingDevice.BUFFER_CREATION_ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY_BIT | RenderingDevice.BUFFER_CREATION_DEVICE_ADDRESS_BIT
const FAST := RenderingDevice.ACCELERATION_STRUCTURE_PREFER_FAST_TRACE_BIT
var shader: RID
var _rd: RenderingDevice
class Program:
	var shader: RID
	var pipeline: RID
	var sbt: RID
	var hit_range: int

var _gi: Program
var _direct: Program
var _scene_set: RID
var _owned: Array[RID] = []

func _own(id: RID) -> RID:
	if id.is_valid(): _owned.append(id)
	return id

func build(rd: RenderingDevice, snapshot: Snapshot) -> bool:
	_rd = rd
	_gi = _build_program(ShaderFile)
	if not _gi: return false
	shader = _gi.shader
	var shapes: Array[RID] = []
	var bases := PackedInt32Array()
	var normals := PackedVector4Array()
	for src in snapshot.surfaces:
		var geo := RDAccelerationStructureGeometry.new()
		geo.flags = RenderingDevice.ACCELERATION_STRUCTURE_GEOMETRY_OPAQUE_BIT
		var bytes := src.vertices.to_byte_array()
		geo.vertex_buffer = _own(rd.vertex_buffer_create(bytes.size(), bytes, INPUT))
		geo.vertex_count = src.vertices.size()
		geo.vertex_format = RenderingDevice.DATA_FORMAT_R32G32B32_SFLOAT
		geo.vertex_stride = 12
		geo.index_buffer = _own(rd.index_buffer_create(src.indices.size(), RenderingDevice.INDEX_BUFFER_FORMAT_UINT32, src.indices.to_byte_array(), false, INPUT))
		geo.index_count = src.indices.size()
		if not geo.vertex_buffer.is_valid() or not geo.index_buffer.is_valid(): return false
		var shape := _own(rd.blas_create([geo], FAST))
		if not shape.is_valid() or rd.blas_build(shape) != OK: return false
		shapes.append(shape)
		bases.append(normals.size())
		for i in range(0,src.indices.size(),3):
			var a := src.vertices[src.indices[i]]
			var n := (src.vertices[src.indices[i+1]]-a).cross(src.vertices[src.indices[i+2]]-a)
			normals.append(Vector4(n.x,n.y,n.z,0))
	var instances: Array[RDAccelerationStructureInstance] = []
	var lookup := PackedInt32Array()
	for src in snapshot.instances:
		var inst := RDAccelerationStructureInstance.new()
		inst.blas = shapes[src.surface]
		inst.transform = src.transform
		inst.id = instances.size()
		inst.hit_sbt_range = _gi.hit_range
		instances.append(inst)
		lookup.append(bases[src.surface])
		lookup.append(src.material)
	var tlas := _own(rd.tlas_create(instances.size(), FAST))
	if not tlas.is_valid() or rd.tlas_build(tlas,instances) != OK: return false
	var a := RDUniform.new()
	a.binding = 0
	a.uniform_type = RenderingDevice.UNIFORM_TYPE_ACCELERATION_STRUCTURE
	a.add_id(tlas)
	var uniforms: Array[RDUniform] = [a]
	for bytes: PackedByteArray in [normals.to_byte_array(),lookup.to_byte_array()]:
		var id := _own(rd.storage_buffer_create(bytes.size(),bytes))
		if not id.is_valid(): return false
		var u := RDUniform.new()
		u.binding = uniforms.size()
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		u.add_id(id)
		uniforms.append(u)
	_scene_set = _own(rd.uniform_set_create(uniforms, shader, 1))
	print_verbose("Split RC hardware trace: %d BLAS, %d instances, %d unique triangles" % [shapes.size(),instances.size(),normals.size()])
	return _scene_set.is_valid()

func _build_program(file: RDShaderFile) -> Program:
	var program := Program.new()
	var spirv := file.get_spirv()
	if not spirv or spirv.bytecode_raygen.is_empty() or spirv.bytecode_closest_hit.is_empty() or spirv.bytecode_miss.is_empty(): return null
	program.shader = _own(_rd.shader_create_from_spirv(spirv))
	if not program.shader.is_valid(): return null
	var stages := RDPipelineShader.new()
	stages.shader = program.shader
	var hit := RDHitGroup.new()
	hit.closest_hit_shader = stages
	program.pipeline = _own(_rd.raytracing_pipeline_create([stages], [stages], [hit], 1))
	if not program.pipeline.is_valid(): return null
	program.sbt = _own(_rd.hit_sbt_create(program.pipeline, 1))
	if not program.sbt.is_valid(): return null
	program.hit_range = _rd.hit_sbt_range_alloc(program.sbt, 1)
	if _rd.hit_sbt_range_update(program.sbt, program.hit_range, 0, PackedInt32Array([0])) != OK: return null
	return program

func direct_shader() -> RID:
	if not _direct:
		_direct = _build_program(preload("shaders/restir_hardware.glsl"))
	return _direct.shader if _direct else RID()

func dispatch(frame_set: RID, tiles: Vector2i, direct := false) -> void:
	var program := _direct if direct else _gi
	var list := _rd.raytracing_list_begin()
	_rd.raytracing_list_bind_raytracing_pipeline(list, program.pipeline)
	_rd.raytracing_list_bind_uniform_set(list, frame_set, 0)
	_rd.raytracing_list_bind_uniform_set(list, _scene_set, 1)
	_rd.raytracing_list_trace_rays(list, 0, program.sbt, tiles.x, tiles.y, 1)
	_rd.raytracing_list_end()

func close() -> void:
	# Free dependents before their inputs, including partially built snapshots.
	_owned.reverse()
	for id in _owned: _rd.free_rid(id)
	_owned.clear()
