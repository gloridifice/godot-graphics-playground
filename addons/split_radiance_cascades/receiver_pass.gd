@tool
extends RefCounted
## Forward+ has no public albedo G-buffer. Redraw the accepted static faces into
## one depth-matched color attachment; never read lit scene color as reflectance.
## Global RD / render thread only. One persistent draw batch per opaque material.
const ShaderFile := preload("shaders/receiver.glsl")
const HitReflectance := preload("shaders/hit_reflectance.glsl")
const Snapshot := preload("scene_snapshot.gd")

class Batch:
	var vertices: RID
	var indices: RID
	var material: RID
	var color: PackedByteArray
	# Keep borrowed RenderingServer textures alive until all dependent draws are done.
	var texture: Texture2D
	var metal_texture: Texture2D

class BakeKernel:
	var shader: RID
	var pipeline: RID

var _bake: BakeKernel # Lazy: an untextured tracing proxy needs no bake.
var _rd: RenderingDevice
var _shader: RID
var _pipeline: RID
var _format := RenderingDevice.INVALID_FORMAT_ID
var _white: RID
var _samplers := {}
var _buffers: Array[RID] = []
var _batches: Array[Batch] = []
var _target: RID
var _fb: RID
var _size := Vector2i.ZERO

func initialize(rd: RenderingDevice) -> bool:
	_rd = rd
	var spirv := ShaderFile.get_spirv()
	if not spirv or not spirv.compile_error_vertex.is_empty() or not spirv.compile_error_fragment.is_empty():
		return false
	_shader = rd.shader_create_from_spirv(spirv)
	var pos := RDVertexAttribute.new()
	pos.format = RenderingDevice.DATA_FORMAT_R32G32B32_SFLOAT
	pos.stride = 12
	var uv := RDVertexAttribute.new()
	uv.location = 1
	uv.format = RenderingDevice.DATA_FORMAT_R32G32_SFLOAT
	uv.stride = 8
	_format = rd.vertex_format_create([pos,uv])
	var fmt := RDTextureFormat.new()
	fmt.width = 1
	fmt.height = 1
	fmt.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	_white = rd.texture_create(fmt,RDTextureView.new(),[PackedByteArray([255,255,255,255])])
	return _shader.is_valid() and _white.is_valid() and _format != RenderingDevice.INVALID_FORMAT_ID

func replace_scene(snapshot: Snapshot) -> bool:
	for buffer in _buffers: _rd.free_rid(buffer) # invalidates the dependent vertex arrays
	_buffers.clear()
	_batches.clear()
	if not snapshot: return true
	for i in snapshot.receivers.size():
		var src := snapshot.receivers[i]
		if src.positions.is_empty(): continue
		var streams: Array[RID] = []
		for bytes: PackedByteArray in [src.positions.to_byte_array(),src.uvs.to_byte_array()]:
			var buffer := _rd.vertex_buffer_create(bytes.size(),bytes)
			if not buffer.is_valid(): return false
			streams.append(buffer)
			_buffers.append(buffer)
		var batch := Batch.new()
		batch.vertices = _rd.vertex_array_create(src.positions.size(),_format,streams)
		var index_buffer := _rd.index_buffer_create(src.indices.size(), RenderingDevice.INDEX_BUFFER_FORMAT_UINT32, src.indices.to_byte_array())
		if not index_buffer.is_valid(): return false
		_buffers.append(index_buffer)
		batch.indices = _rd.index_array_create(index_buffer, 0, src.indices.size())
		batch.color = PackedVector4Array([src.tint, src.metal_weights]).to_byte_array()
		batch.texture = src.texture
		batch.metal_texture = src.metal_texture
		batch.material = _texture_set(src, _shader)
		if not batch.vertices.is_valid() or not batch.indices.is_valid() or not batch.material.is_valid(): return false
		_batches.append(batch)
	return true

func _texture_set(src: Snapshot.ReceiverBatch, shader: RID) -> RID:
	var texture := RenderingServer.texture_get_rd_texture(src.texture_rid,true) if src.texture_rid.is_valid() else _white
	var metal := RenderingServer.texture_get_rd_texture(src.metal_rid,false) if src.metal_rid.is_valid() else _white
	var sampler := _sampler(src.filter,src.repeat)
	if not texture.is_valid() or not metal.is_valid() or not sampler.is_valid(): return RID()
	return UniformSetCacheRD.get_cache(shader, 1, [_texture_uniform(0,sampler,texture), _texture_uniform(1,sampler,metal)])

# Average the actual diffuse reflectance directly into the shared SW/RT hit table.
# Visible receivers still sample these textures per pixel. No CPU texture readback.
func bake_hit_materials(snapshot: Snapshot, table: RID) -> bool:
	var ids := PackedInt32Array()
	for i in snapshot.receivers.size():
		var src := snapshot.receivers[i]
		if src.traced and (src.texture or src.metal_texture): ids.append(i)
	if ids.is_empty(): return true
	if not _bake:
		var spirv := HitReflectance.get_spirv()
		if not spirv or not spirv.compile_error_compute.is_empty(): return false
		_bake = BakeKernel.new()
		_bake.shader = _rd.shader_create_from_spirv(spirv)
		if _bake.shader.is_valid(): _bake.pipeline = _rd.compute_pipeline_create(_bake.shader)
	if not _bake.pipeline.is_valid(): return false
	var dst := RDUniform.new()
	dst.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	dst.binding = 0
	dst.add_id(table)
	var output := UniformSetCacheRD.get_cache(_bake.shader, 0, [dst])
	if not output.is_valid(): return false
	var sets: Array[RID] = []
	for i in ids:
		var inputs := _texture_set(snapshot.receivers[i], _bake.shader)
		if not inputs.is_valid(): return false
		sets.append(inputs)
	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list,_bake.pipeline)
	_rd.compute_list_bind_uniform_set(list,output,0)
	for j in ids.size():
		var src := snapshot.receivers[ids[j]]
		var tint := src.tint
		tint.w = ids[j]
		var pc := PackedVector4Array([tint,src.metal_weights]).to_byte_array()
		_rd.compute_list_bind_uniform_set(list,sets[j],1)
		_rd.compute_list_set_push_constant(list,pc,pc.size())
		_rd.compute_list_dispatch(list,1,1,1)
	_rd.compute_list_end()
	return true

func _sampler(filter: int, repeat: bool) -> RID:
	var key := filter*2 + int(repeat)
	if not _samplers.has(key):
		var state := RDSamplerState.new()
		state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR if filter % 2 else RenderingDevice.SAMPLER_FILTER_NEAREST
		state.mag_filter = state.min_filter
		if filter >= BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS:
			state.mip_filter = RenderingDevice.SAMPLER_FILTER_NEAREST if ProjectSettings.get_setting("rendering/textures/default_filters/use_nearest_mipmap_filter",false) else RenderingDevice.SAMPLER_FILTER_LINEAR
		else: state.max_lod = 0.0
		if filter >= BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS_ANISOTROPIC:
			var level := int(ProjectSettings.get_setting("rendering/textures/default_filters/anisotropic_filtering_level",2))
			state.anisotropy_max = float(1 << clampi(level,0,4))
			state.use_anisotropy = state.anisotropy_max > 1.0
		state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT if repeat else RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
		state.repeat_v = state.repeat_u
		_samplers[key] = _rd.sampler_create(state)
	return _samplers[key]

func _texture_uniform(binding: int, sampler: RID, texture: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u.binding = binding
	u.add_id(sampler)
	u.add_id(texture)
	return u

func target(size: Vector2i) -> RID:
	if size == _size: return _target
	if _target.is_valid(): _rd.free_rid(_target) # also frees its framebuffer and dependent sets
	_size = size
	var fmt := RDTextureFormat.new()
	fmt.width = size.x
	fmt.height = size.y
	fmt.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_SRGB # preserve dark albedos; sampler returns linear RGB
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_COLOR_ATTACHMENT_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	_target = _rd.texture_create(fmt,RDTextureView.new())
	if not _target.is_valid(): return RID()
	_fb = _rd.framebuffer_create([_target])
	if not _fb.is_valid(): return RID()
	if not _pipeline.is_valid():
		var blend := RDPipelineColorBlendState.new()
		blend.attachments = [RDPipelineColorBlendStateAttachment.new()]
		_pipeline = _rd.render_pipeline_create(_shader,_rd.framebuffer_get_format(_fb),_format,RenderingDevice.RENDER_PRIMITIVE_TRIANGLES,
			RDPipelineRasterizationState.new(),RDPipelineMultisampleState.new(),RDPipelineDepthStencilState.new(),blend)
	return _target if _pipeline.is_valid() else RID()

func draw(depth: RID, sampler: RID, matrix: PackedByteArray) -> bool:
	var depth_set := UniformSetCacheRD.get_cache(_shader,0,[_texture_uniform(0,sampler,depth)])
	if not depth_set.is_valid(): return false
	var list := _rd.draw_list_begin(_fb,RenderingDevice.DRAW_CLEAR_COLOR_0,PackedColorArray([Color(0,0,0,0)]))
	_rd.draw_list_bind_render_pipeline(list,_pipeline)
	_rd.draw_list_bind_uniform_set(list,depth_set,0)
	for batch in _batches:
		_rd.draw_list_bind_vertex_array(list,batch.vertices)
		_rd.draw_list_bind_index_array(list,batch.indices)
		_rd.draw_list_bind_uniform_set(list,batch.material,1)
		var pc := matrix + batch.color
		_rd.draw_list_set_push_constant(list,pc,pc.size())
		_rd.draw_list_draw(list,true,1)
	_rd.draw_list_end()
	return true

func close() -> void:
	replace_scene(null)
	if _bake:
		if _bake.pipeline.is_valid(): _rd.free_rid(_bake.pipeline)
		if _bake.shader.is_valid(): _rd.free_rid(_bake.shader)
		_bake = null
	for rid: RID in [_target,_pipeline,_shader,_white]:
		if rid.is_valid(): _rd.free_rid(rid)
	for rid: RID in _samplers.values():
		if rid.is_valid(): _rd.free_rid(rid)
	_samplers.clear()
