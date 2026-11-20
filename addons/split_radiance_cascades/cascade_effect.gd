@tool
extends CompositorEffect
## Owned by one SplitRadianceCascades node. All mutable fields below belong to
## the render thread; no scene tree access and no GPU-to-CPU readback per frame.

const ShaderFile := preload("shaders/cascades.glsl")
const Snapshot := preload("scene_snapshot.gd")
const Lights := preload("scene_lights.gd")
const CAPACITY := [8192, 2048, 512, 256] # power of two, at least eight ways
const MAX_TILES := 262144 # also bounds the per-bank uint32 sums in merge.inc
const PARAM_BYTES := 240
const EDITOR_SETTLE_FRAMES := 64

const Profiler := preload("stage_profiler.gd")
const ReceiverPass := preload("receiver_pass.gd")
const HardwareTrace := preload("hardware_trace.gd")
var _rt: HardwareTrace
enum Stage { PREPARE, TRACE, GATHER, PARENTS, DEPOSIT, MERGE, RECEIVER, APPLY }
# Assigned before installation. Never touch editor UI on the render thread.
var editor_redraw: Callable
var _editor_views := {} # render target -> [unjittered view key, draws remaining]
var _receiver := ReceiverPass.new()
var _profiler: Profiler
var _rd: RenderingDevice
var _shader: RID
var _pipeline: RID
var _sampler: RID
var _params: RID
var _table: RID
var _counts: RID
var _active: RID
var _bins: RID
var _args: RID
var _rays: RID
var _light_buffer: RID
var _scene_buffers: Array[RID] = []
var _layout := PackedByteArray()
var _slots := 0
var _ray_bytes := 0
var _origin := Vector3.ZERO
var _light_count := 0
var _frame := 0
var _failed := false
var _warned_view := false
var _tuning := Vector4(0.4, 0.6, 8.0, 0.94)
var _options := Vector4i(4, 1, 0, 0) # stride, bounce, view, cascade
var _strength := 1.0

func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_SKY
	access_resolved_color = true
	access_resolved_depth = true
	needs_normal_roughness = true

func configure(tuning: Vector4, options: Vector4i, strength: float, reset: bool) -> void:
	_editor_views.clear()
	if reset:
		_frame = 0
	_tuning = tuning
	_options = options
	_strength = strength

func set_profiler(profiler: Profiler) -> void:
	_profiler = profiler

func _initialize_rd() -> bool:
	_rd = RenderingServer.get_rendering_device()
	if not _rd or _failed:
		return false
	if _pipeline.is_valid():
		return true
	var spirv := ShaderFile.get_spirv()
	if not spirv or not spirv.compile_error_compute.is_empty():
		_failure("compute shader import: " + (spirv.compile_error_compute if spirv else "missing SPIR-V"))
		return false
	_shader = _rd.shader_create_from_spirv(spirv)
	if _shader.is_valid():
		_pipeline = _rd.compute_pipeline_create(_shader)
	if not _pipeline.is_valid():
		_failure("compute pipeline")
		return false
	var starts := PackedInt32Array()
	var bin_starts := PackedInt32Array()
	var bin_count := 0
	for c in CAPACITY.size():
		starts.append(_slots)
		bin_starts.append(bin_count)
		_slots += CAPACITY[c]
		bin_count += CAPACITY[c] * (8 << (2*c))
	_layout = PackedInt32Array(CAPACITY).to_byte_array()
	_layout.append_array(starts.to_byte_array())
	_layout.append_array(bin_starts.to_byte_array())
	_sampler = _rd.sampler_create(RDSamplerState.new())
	_params = _rd.uniform_buffer_create(PARAM_BYTES)
	_table = _rd.storage_buffer_create(_slots*16)
	_counts = _rd.storage_buffer_create(64)
	_args = _rd.storage_buffer_create(64, PackedByteArray(), RenderingDevice.STORAGE_BUFFER_USAGE_DISPATCH_INDIRECT)
	_active = _rd.storage_buffer_create(_slots*4)
	_bins = _rd.storage_buffer_create(bin_count*64)
	for rid: RID in [_sampler, _params, _table, _counts, _args, _active, _bins]:
		if not rid.is_valid():
			_failure("probe buffers")
			return false
	_rd.buffer_clear(_bins, 0, bin_count*64)
	if not _receiver.initialize(_rd):
		_failure("receiver raster resources")
		return false
	return true

func replace_scene(snapshot: Snapshot, lights: PackedVector4Array) -> void:
	if _rt:
		_rt.close()
		_rt = null
	for buffer in _scene_buffers:
		_free(buffer)
	_scene_buffers.clear()
	if not snapshot:
		_receiver.replace_scene(null)
		_reset_light_history()
		return
	if not _initialize_rd(): return
	if not _receiver.replace_scene(snapshot):
		_failure("receiver material/vertex buffers")
		return
	_origin = snapshot.origin
	if snapshot.hardware:
		_rt = HardwareTrace.new()
		if not _rt.build(_rd, snapshot):
			_rt.close()
			_rt = null
			push_error("Split RC: hardware trace build failed. Disable Prefer Hardware Trace and rebuild to use the software BVH.")
			return
	for stream: PackedVector4Array in [snapshot.nodes, snapshot.triangles, snapshot.materials]:
		var bytes := stream.to_byte_array()
		if bytes.is_empty(): bytes.resize(16) # unused software-only bindings in hardware mode
		var buffer := _rd.storage_buffer_create(bytes.size(), bytes)
		if not buffer.is_valid():
			_failure("scene snapshot buffer")
			return
		_scene_buffers.append(buffer)
	if not _receiver.bake_hit_materials(snapshot, _scene_buffers[2]):
		_failure("ray hit material reflectance")
		return
	replace_lights(lights)

func _has_light_buffer() -> bool:
	# A retained @tool instance can have Nil in a newly added RID member after reload.
	return typeof(_light_buffer) == TYPE_RID and _light_buffer.is_valid()

func replace_lights(lights: PackedVector4Array) -> void:
	if _failed or _scene_buffers.size() != 3:
		return
	# Allocate independently of the pipeline; a reloaded instance can already have one.
	if not _has_light_buffer():
		_light_buffer = _rd.storage_buffer_create(Lights.BUFFER_BYTES)
		if not _has_light_buffer():
			_failure("light buffer allocation")
			return
	if not lights.is_empty():
		var bytes := lights.to_byte_array()
		if _rd.buffer_update(_light_buffer, 0, bytes.size(), bytes) != OK:
			_failure("light buffer upload")
			return
	_light_count = lights.size() >> 1 # A zero count bypasses stale entries in the buffer.
	_reset_light_history()

func _reset_light_history() -> void:
	_frame = 0 # PREPARE clears both probe banks before TRACE can read history.
	_editor_views.clear()
	if editor_redraw.is_valid():
		editor_redraw.call_deferred()

func _render_callback(_type: int, data: RenderData) -> void:
	if _failed or _scene_buffers.size() != 3 or not _has_light_buffer():
		return
	var buffers := data.get_render_scene_buffers() as RenderSceneBuffersRD
	if not buffers:
		return
	# POST_SKY modifies the single-sample HDR surface, before transparency.
	# A subsequent MSAA resolve would overwrite it. Do not silently misrender.
	if buffers.get_view_count() != 1 or buffers.get_msaa_3d() != RenderingServer.VIEWPORT_MSAA_DISABLED or not buffers.has_texture(&"forward_clustered", &"normal_roughness"):
		if not _warned_view:
			push_warning("Split RC bypassed: requires mono Forward+, normal/roughness and MSAA 3D disabled.")
			_warned_view = true
		return
	var size := buffers.get_internal_size()
	if size.x <= 0 or size.y <= 0:
		return
	var timed := _profiler != null and _profiler.begin(_rd)
	var stride := _options.x
	var tiles := (size + Vector2i.ONE*(stride-1)) / stride
	while tiles.x*tiles.y > MAX_TILES:
		stride += 1
		tiles = (size + Vector2i.ONE*(stride-1)) / stride
	var bytes_needed := tiles.x * tiles.y * 32 * (1 + _options.y)
	if _ray_bytes != bytes_needed:
		_free(_rays)
		_rays = _rd.storage_buffer_create(bytes_needed)
		_ray_bytes = bytes_needed
		if not _rays.is_valid():
			_failure("ray scratch buffer")
			return
	var depth := buffers.get_depth_layer(0)
	var normal := buffers.get_texture_slice(&"forward_clustered", &"normal_roughness", 0, 0, 1, 1)
	var color := buffers.get_color_layer(0)
	var albedo := _receiver.target(size)
	if not albedo.is_valid():
		_failure("receiver framebuffer/pipeline")
		return
	var bindings := _uniform_set(depth, normal, color, albedo)
	var rt_bindings := _uniform_set(depth, normal, color, albedo, true) if _rt else RID()
	if not bindings.is_valid() or (_rt and not rt_bindings.is_valid()):
		_failure("viewport uniform set")
		return
	_frame = _frame + 1 if _frame < 0x7ffffffe else 1
	var camera := data.get_render_scene_data()
	var xf := camera.get_cam_transform()
	xf.origin -= _origin
	var projection := camera.get_cam_projection() # includes renderer Y, reverse Z and jitter
	var values := _matrix(projection.inverse())
	values.append_array(_matrix(Projection(xf)))
	values.append_array(_layout)
	values.append_array(PackedVector4Array([_tuning]).to_byte_array())
	values.append_array(PackedInt32Array([size.x, size.y, stride, _frame, _options.y, _options.z, _options.w, _light_count]).to_byte_array())
	values.append_array(PackedFloat32Array([_strength, 0, 0, 0]).to_byte_array())
	_rd.buffer_update(_params, 0, PARAM_BYTES, values)
	var tile_groups := (tiles + Vector2i(7,7)) / 8
	_dispatch(bindings, Stage.PREPARE, 0, Vector2i((_slots+63)/64, 1))
	if timed: _profiler.end_stage(_rd, Stage.PREPARE)
	if _rt:
		_rt.dispatch(rt_bindings, tiles)
	else:
		_dispatch(bindings, Stage.TRACE, 0, tile_groups)
	if timed: _profiler.end_stage(_rd, Stage.TRACE)
	_dispatch(bindings, Stage.GATHER, 0, tile_groups)
	if timed: _profiler.end_stage(_rd, Stage.GATHER)
	for c in 3:
		_dispatch(bindings, Stage.PARENTS, c, Vector2i((CAPACITY[c]+63)/64, 1))
	if timed: _profiler.end_stage(_rd, Stage.PARENTS)
	_dispatch(bindings, Stage.DEPOSIT, 0, tile_groups)
	# The argument buffer is not simultaneously bound as a writable SSBO (D3D12).
	_rd.buffer_copy(_counts, _args, 0, 0, 64)
	if timed: _profiler.end_stage(_rd, Stage.DEPOSIT)
	for c in range(3, -1, -1):
		_dispatch(bindings, Stage.MERGE, c, Vector2i.ZERO)
	if timed: _profiler.end_stage(_rd, Stage.MERGE)
	if _options.z <= 1 and not _receiver.draw(depth,_sampler,_matrix(projection * Projection(xf.affine_inverse()))):
		_failure("receiver depth binding")
		return
	if timed: _profiler.end_stage(_rd, Stage.RECEIVER)
	_dispatch(bindings, Stage.APPLY, 0, (size + Vector2i(7,7)) / 8)
	if timed: _profiler.end_stage(_rd, Stage.APPLY)
	if editor_redraw.is_valid():
		_settle_editor_view(buffers.get_render_target(), [xf, size, projection.x.x, projection.y.y])

func _settle_editor_view(target: RID, view_key: Array) -> void:
	# The editor normally draws only on changes. Accumulate after a move, zoom,
	# resize or rebuild, then let it sleep; split views settle independently.
	var state: Array = _editor_views.get(target, [])
	if state.is_empty() or state[0] != view_key:
		state = [view_key, EDITOR_SETTLE_FRAMES]
		_editor_views[target] = state
	if state[1] > 0:
		state[1] -= 1
		editor_redraw.call_deferred()

func _dispatch(bindings: RID, stage: Stage, cascade: int, groups: Vector2i) -> void:
	# Separate lists let RD schedule the storage/indirect barriers between stages.
	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, _pipeline)
	_rd.compute_list_bind_uniform_set(list, bindings, 0)
	_rd.compute_list_set_push_constant(list, PackedInt32Array([stage, cascade, 0, 0]).to_byte_array(), 16)
	if stage == Stage.MERGE:
		_rd.compute_list_dispatch_indirect(list, _args, cascade*16)
	else:
		_rd.compute_list_dispatch(list, groups.x, groups.y, 1)
	_rd.compute_list_end()

func _uniform_set(depth: RID, normal: RID, color: RID, albedo: RID, hardware := false) -> RID:
	var uniforms: Array[RDUniform] = []
	var ids: Array[RID] = [_params, _table, _counts, _active, _bins, _rays]
	ids.append_array(_scene_buffers)
	ids.append_array([_light_buffer, depth, normal, color, albedo])
	for i in ids.size():
		if hardware and i not in [0,1,4,5,8,9,10,11]: continue
		var u := RDUniform.new()
		u.binding = i
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		if i == 0:
			u.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
		elif i == 10 or i == 11 or i == 13:
			u.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
			u.add_id(_sampler)
		elif i == 12:
			u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		u.add_id(ids[i])
		uniforms.append(u)
	return UniformSetCacheRD.get_cache(_rt.shader if hardware else _shader, 0, uniforms)

func _matrix(m: Projection) -> PackedByteArray:
	return PackedVector4Array([m.x, m.y, m.z, m.w]).to_byte_array()

func _failure(what: String) -> void:
	push_error("Split RC disabled: " + what)
	_failed = true

func _free(rid: RID) -> void:
	if rid.is_valid():
		_rd.free_rid(rid)

func close() -> void:
	_failed = true
	if _rt:
		_rt.close()
		_rt = null
	_receiver.close()
	for buffer in _scene_buffers:
		_free(buffer)
	_scene_buffers.clear()
	if _has_light_buffer():
		_free(_light_buffer)
	for rid: RID in [_rays, _bins, _active, _args, _counts, _table, _params, _sampler, _pipeline, _shader]:
		_free(rid)
