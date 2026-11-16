@tool
class_name WaterCausticsGPU
extends RefCounted

## GPU 光束追踪 → 面积加权顶点通量重建 → 连续插值加法累积 RGBA16F。
## 借用水体发布纹理，必须先 close 本对象，再释放相应 WaterGPU。
signal initialized(success: bool)
# Optical input semantics changed: existing editor-preview pipelines must retire.
const SHADER_REVISION := 2
var texture := Texture2DRD.new()
var ready := false
var error_message := ""
var _closed := false
var _rd: RenderingDevice
var _owned: Array[RID] = []
var _sets: Array[RID] = []
var _trace: RID
var _resolve: RID
var _draw: RID
var _trace_set: RID
var _resolve_set: RID
var _draw_set: RID
var _config: RID
var _hits: RID
var _lights: RID
var _image: RID
var _framebuffer: RID
var _rays := 256
var _size := 1024
var _last_parameters := PackedByteArray()

func configure(gpu: WaterGPU, geometry: Dictionary, settings: WaterCausticsSettings, sun: Vector3, extinction: Vector3, ior: float) -> void:
	_rays = settings.ray_resolution
	_size = settings.texture_resolution
	var bytes := _parameters(geometry,settings,sun,extinction,ior)
	_last_parameters = bytes
	RenderingServer.call_on_render_thread(_initialize_rd.bind(gpu.fft_texture.texture_rd_rid,gpu.swe_texture.texture_rd_rid,gpu.foam_texture.texture_rd_rid,gpu.offshore_foam_texture.texture_rd_rid,bytes))

func _parameters(g: Dictionary, s: WaterCausticsSettings, sun: Vector3, extinction: Vector3, ior: float) -> PackedByteArray:
	var data := PackedFloat32Array([g.fft_length,g.fft_resolution,g.height_gain,g.choppiness,
		g.region_origin.x,g.region_origin.y,g.region_rotation.x,g.region_rotation.y,
		g.region_size.x,g.region_size.y,g.blend_depth,g.edge_width]).to_byte_array()
	data.append_array(PackedInt32Array([1 if g.fft_enabled else 0,1 if g.swe_enabled else 0,g.swe_resolution,_rays]).to_byte_array())
	data.append_array(PackedFloat32Array([g.sea_level,g.dry_depth,ior,s.flat_bed_depth,
		g.caustics_center.x,g.caustics_center.y,s.size.x,s.size.y,
		sun.x,sun.y,sun.z,s.maximum_distance,
		extinction.x,extinction.y,extinction.z,float(s.traversal_budget),
		1.0 if g.foam_enabled else 0.0,g.foam_opacity_scale,g.shore_normal_strength,(16 if g.swe_model_blend else 0)|int(g.swe_fft_edges)]).to_byte_array())
	return data

func _own(rid: RID) -> RID:
	if rid.is_valid():
		_owned.append(rid)
	return rid

func _shader(path: String) -> RID:
	var file := load(path) as RDShaderFile
	if file == null:
		error_message = "Caustics shader is not imported: " + path
		return RID()
	var spirv := file.get_spirv()
	for stage in [RenderingDevice.SHADER_STAGE_COMPUTE,RenderingDevice.SHADER_STAGE_VERTEX,RenderingDevice.SHADER_STAGE_FRAGMENT]:
		var error := spirv.get_stage_compile_error(stage)
		if not error.is_empty():
			error_message = error
			return RID()
	return _own(_rd.shader_create_from_spirv(spirv))

func _uniform(binding: int, type: int, ids: Array[RID]) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.binding = binding
	uniform.uniform_type = type
	for rid in ids:
		uniform.add_id(rid)
	return uniform

func _initialize_rd(fft: RID, swe: RID, foam: RID, offshore: RID, bytes: PackedByteArray) -> void:
	_rd = RenderingServer.get_rendering_device()
	var trace_shader := _shader("res://addons/water/shaders/caustics_trace.glsl")
	var resolve_shader := _shader("res://addons/water/shaders/caustics_resolve.glsl")
	var draw_shader := _shader("res://addons/water/shaders/caustics_draw.glsl")
	if not trace_shader.is_valid() or not resolve_shader.is_valid() or not draw_shader.is_valid():
		_finish.call_deferred(false)
		return
	_config = _own(_rd.storage_buffer_create(bytes.size(),bytes))
	_hits = _own(_rd.storage_buffer_create((_rays+1)*(_rays+1)*48))
	_lights = _own(_rd.storage_buffer_create((_rays+1)*(_rays+1)*16))
	var sampler_state := RDSamplerState.new()
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	sampler_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	var sampler := _own(_rd.sampler_create(sampler_state))
	var format := RDTextureFormat.new()
	format.width = _size
	format.height = _size
	format.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_COLOR_ATTACHMENT_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	_image = _own(_rd.texture_create(format,RDTextureView.new()))
	_framebuffer = _own(_rd.framebuffer_create([_image]))
	_trace = _own(_rd.compute_pipeline_create(trace_shader))
	_resolve = _own(_rd.compute_pipeline_create(resolve_shader))
	var attachment := RDPipelineColorBlendStateAttachment.new()
	attachment.enable_blend = true
	attachment.src_color_blend_factor = RenderingDevice.BLEND_FACTOR_ONE
	attachment.dst_color_blend_factor = RenderingDevice.BLEND_FACTOR_ONE
	attachment.src_alpha_blend_factor = RenderingDevice.BLEND_FACTOR_ONE
	attachment.dst_alpha_blend_factor = RenderingDevice.BLEND_FACTOR_ONE
	var blend := RDPipelineColorBlendState.new()
	blend.attachments = [attachment]
	var raster := RDPipelineRasterizationState.new()
	raster.cull_mode = RenderingDevice.POLYGON_CULL_DISABLED
	_draw = _own(_rd.render_pipeline_create(draw_shader,_rd.framebuffer_get_format(_framebuffer),-1,RenderingDevice.RENDER_PRIMITIVE_TRIANGLES,raster,RDPipelineMultisampleState.new(),RDPipelineDepthStencilState.new(),blend))
	_trace_set = _rd.uniform_set_create([
		_uniform(0,RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER,[_config]),
		_uniform(1,RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE,[sampler,fft]),
		_uniform(2,RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE,[sampler,swe]),
		_uniform(3,RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER,[_hits]),
		_uniform(4,RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE,[sampler,foam]),
		_uniform(5,RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE,[sampler,offshore])],trace_shader,0)
	var mesh_uniforms: Array[RDUniform] = [
		_uniform(0,RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER,[_config]),
		_uniform(1,RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER,[_hits]),
		_uniform(2,RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE,[sampler,swe]),
		_uniform(3,RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER,[_lights])]
	_resolve_set = _rd.uniform_set_create(mesh_uniforms,resolve_shader,0)
	_draw_set = _rd.uniform_set_create(mesh_uniforms,draw_shader,0)
	_sets = [_trace_set,_resolve_set,_draw_set]
	for rid in [_config,_hits,_lights,_image,_framebuffer,_trace,_resolve,_draw,_trace_set,_resolve_set,_draw_set]:
		if not rid.is_valid():
			error_message = "Could not allocate/bind physical caustics GPU resources."
			_finish.call_deferred(false)
			return
	_render_rd(bytes)
	_finish.call_deferred(true)

func _finish(success: bool) -> void:
	if _closed:
		return
	ready = success
	if success:
		texture.texture_rd_rid = _image
	initialized.emit(success)

func update(geometry: Dictionary, settings: WaterCausticsSettings, sun: Vector3, extinction: Vector3, ior: float, moving: bool) -> void:
	if not ready or _closed:
		return
	var bytes := _parameters(geometry,settings,sun,extinction,ior)
	if moving or bytes != _last_parameters:
		_last_parameters = bytes
		RenderingServer.call_on_render_thread(_render_rd.bind(bytes))

func _render_rd(bytes: PackedByteArray) -> void:
	_rd.buffer_update(_config,0,bytes.size(),bytes)
	var commands := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(commands,_trace)
	_rd.compute_list_bind_uniform_set(commands,_trace_set,0)
	_rd.compute_list_dispatch(commands,ceili((_rays+1)/8.0),ceili((_rays+1)/8.0),1)
	_rd.compute_list_add_barrier(commands)
	_rd.compute_list_bind_compute_pipeline(commands,_resolve)
	_rd.compute_list_bind_uniform_set(commands,_resolve_set,0)
	_rd.compute_list_set_push_constant(commands,PackedFloat32Array([float(_size),0,0,0]).to_byte_array(),16)
	_rd.compute_list_dispatch(commands,ceili((_rays+1)/8.0),ceili((_rays+1)/8.0),1)
	_rd.compute_list_end()
	var draw_list := _rd.draw_list_begin(_framebuffer,RenderingDevice.DRAW_CLEAR_COLOR_0,PackedColorArray([Color(0,0,0,0)]))
	_rd.draw_list_bind_render_pipeline(draw_list,_draw)
	_rd.draw_list_bind_uniform_set(draw_list,_draw_set,0)
	_rd.draw_list_set_push_constant(draw_list,PackedFloat32Array([float(_size),0,0,0]).to_byte_array(),16)
	_rd.draw_list_draw(draw_list,false,1,6*_rays*_rays)
	_rd.draw_list_end()

## 显式诊断；普通帧不回读光束或接收贴图。
func snapshot(callback: Callable) -> void:
	RenderingServer.call_on_render_thread(_snapshot_rd.bind(callback))

func _snapshot_rd(callback: Callable) -> void:
	if _rd == null or not _image.is_valid():
		callback.call_deferred({"error":"Caustics is not ready."})
		return
	callback.call_deferred({"hits":_rd.buffer_get_data(_hits).to_float32_array(),"image":Image.create_from_data(_size,_size,false,Image.FORMAT_RGBAH,_rd.texture_get_data(_image,0))})

func close() -> void:
	if _closed:
		return
	_closed = true
	ready = false
	texture.texture_rd_rid = RID()
	RenderingServer.call_on_render_thread(_free_rd)

func _free_rd() -> void:
	if _rd == null:
		return
	for uniform in _sets:
		if _rd.uniform_set_is_valid(uniform):
			_rd.free_rid(uniform)
	_sets.clear()
	_owned.reverse()
	for rid in _owned:
		_rd.free_rid(rid)
	_owned.clear()
	_image = RID()
