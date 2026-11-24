@tool
extends RefCounted
## Per-viewport sample history. The temporal pass consumes the previous frame
## before the spatial/shadow pass replaces it, so no in-place neighbor races.
const ShaderFile := preload("shaders/restir_di.glsl")
const HardwareTrace := preload("hardware_trace.gd")
const Profiler := preload("stage_profiler.gd")
const TEXTURES := [&"reservoir", &"candidates", &"surface", &"visibility"]
const PARAM_BYTES := 240

class ViewHistory:
	var buffers: WeakRef
	var clip := Projection()
	var revision := -1
	var frame := 0
	var light_positions := PackedVector4Array()

var revision := 0
var light_positions := PackedVector4Array()
var _views := {}
var _context := StringName("restir_di_%d" % get_instance_id())
var _rd: RenderingDevice
var _shader: RID
var _pipeline: RID
var _params: RID

func _initialize() -> bool:
	_rd = RenderingServer.get_rendering_device()
	_shader = _rd.shader_create_from_spirv(ShaderFile.get_spirv())
	if not _shader.is_valid(): return false
	_pipeline = _rd.compute_pipeline_create(_shader)
	_params = _rd.uniform_buffer_create(PARAM_BYTES)
	return _pipeline.is_valid() and _params.is_valid()

func draw(buffers: RenderSceneBuffersRD, xf: Transform3D, projection: Projection, depth: RID, normal: RID,
		albedo: RID, color: RID, sampler: RID, lights: RID, first: int, count: int,
		geometry: Array[RID], shadow_tiles: RID, rt: HardwareTrace, mode: int, error_budget: float, profiler: Profiler) -> bool:
	if not _rd and not _initialize(): return false
	var target := buffers.get_render_target()
	var size := buffers.get_internal_size()
	var history: ViewHistory = _views.get(target)
	if not history:
		history = ViewHistory.new()
		_views[target] = history
	var valid := history.revision == revision and buffers.has_texture(_context,TEXTURES[0])
	history.buffers = weakref(buffers)
	var clip := projection * Projection(xf.affine_inverse())
	var inv := projection.inverse()
	var camera := Projection(xf)
	var prev := history.clip
	var reusable := 0
	if valid and clip == prev:
		reusable = -1
		if light_positions != history.light_positions:
			for i in mini(32,count):
				if light_positions[i] != history.light_positions[i]:
					reusable &= ~(1 << i)
	var bytes := PackedVector4Array([inv.x,inv.y,inv.z,inv.w,camera.x,camera.y,camera.z,camera.w,
			prev.x,prev.y,prev.z,prev.w]).to_byte_array()
	bytes.append_array(PackedInt32Array([size.x,size.y,first,count, mode,history.frame,int(valid),reusable]).to_byte_array())
	bytes.append_array(PackedFloat32Array([error_budget,0,0,0]).to_byte_array())
	_rd.buffer_update(_params,0,PARAM_BYTES,bytes)
	var uniforms: Array[RDUniform] = [_uniform(0,RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER,_params)]
	for texture: RID in [depth,normal,albedo]:
		var u := _uniform(uniforms.size(),RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE,sampler)
		u.add_id(texture)
		uniforms.append(u)
	uniforms.append(_uniform(4,RenderingDevice.UNIFORM_TYPE_IMAGE,color))
	for name: StringName in TEXTURES:
		var format := RenderingDevice.DATA_FORMAT_R32G32B32A32_UINT if name == &"surface" else RenderingDevice.DATA_FORMAT_R32G32_UINT
		var image := buffers.create_texture(_context,name,format,RenderingDevice.TEXTURE_USAGE_STORAGE_BIT,
				RenderingDevice.TEXTURE_SAMPLES_1,size,1,1,true,false)
		uniforms.append(_uniform(uniforms.size(),RenderingDevice.UNIFORM_TYPE_IMAGE,image))
	uniforms.append(_uniform(9,RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER,lights))
	var ray_set := RID()
	if rt:
		var ray_shader := rt.direct_shader()
		if not ray_shader.is_valid(): return false
		ray_set = UniformSetCacheRD.get_cache(ray_shader,0,uniforms)
		if not ray_set.is_valid(): return false
	for i in 2:
		uniforms.append(_uniform(10+i,RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER,geometry[i]))
	uniforms.append(_uniform(15,RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER,shadow_tiles))
	var bindings := UniformSetCacheRD.get_cache(_shader,0,uniforms)
	if not bindings.is_valid(): return false
	var groups := (size+Vector2i(7,7))/8
	if mode != 3: _dispatch(bindings,groups,0)
	if profiler: profiler.end_stage(_rd,Profiler.STAGES.size())
	if rt: rt.dispatch(ray_set,size,true)
	else: _dispatch(bindings,groups,1)
	if profiler: profiler.end_stage(_rd,Profiler.STAGES.size()+1)
	history.clip = clip
	history.light_positions = light_positions
	history.revision = revision
	history.frame = (history.frame + 1) & 0x7fffffff
	return true

func _dispatch(bindings: RID, groups: Vector2i, stage: int) -> void:
	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list,_pipeline)
	_rd.compute_list_bind_uniform_set(list,bindings,0)
	_rd.compute_list_set_push_constant(list,PackedInt32Array([stage,0,0,0]).to_byte_array(),16)
	_rd.compute_list_dispatch(list,groups.x,groups.y,1)
	_rd.compute_list_end()

func _uniform(binding: int, type: RenderingDevice.UniformType, id: RID) -> RDUniform:
	var u := RDUniform.new()
	u.binding = binding
	u.uniform_type = type
	u.add_id(id)
	return u

func close() -> void:
	for history: ViewHistory in _views.values():
		var buffers := history.buffers.get_ref() as RenderSceneBuffersRD
		if buffers: buffers.clear_context(_context)
	_views.clear()
	for rid: RID in [_params,_pipeline,_shader]:
		if rid.is_valid(): _rd.free_rid(rid)
