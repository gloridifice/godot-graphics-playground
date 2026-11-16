@tool
class_name WaterGPU
extends RefCounted

## 一个水体的 GPU 所有者。所有 RID 仅在全局 RD 的渲染线程创建、推进和释放。
## 主线程只上传参数；正常帧没有场回读、submit() 或 sync()。
signal initialized(success: bool)
# Lazy load imported compute resources: CPU baking and first editor scans must
# not require the .glsl import cache or a graphics driver just to parse node types.
const SHADER_PATHS := ["res://addons/water/shaders/spectral.glsl", "res://addons/water/shaders/ifft.glsl", "res://addons/water/shaders/swe.glsl", "res://addons/water/shaders/publish.glsl", "res://addons/water/shaders/foam.glsl", "res://addons/water/shaders/foam_offshore.glsl"]
const TICK := 1.0 / 60.0
var fft_texture := Texture2DRD.new()
var swe_texture := Texture2DRD.new()
var foam_texture := Texture2DRD.new()
var foam_flow_texture := Texture2DRD.new()
var offshore_foam_texture := Texture2DRD.new()
var _foam_data := PackedByteArray()
var _spectrum_key: Array = []
var _foam: RID
var _offshore: RID
var _foam_set: RID
var _offshore_set: RID
var _foam_config: RID
var _foam_records: RID
var _far_history: RID
var _foam_image: RID
var _foam_flow_image: RID
var _far_image: RID
var ready := false
var dropped_cpu_time := 0.0
var gpu_time_ms := -1.0
var cpu_submit_ms := 0.0
var error_message := ""
var _closed := false
var _accumulator := 0.0
var _fft_n := 8
var _swe_n := 0
var _substeps := 1
var _second_order := false
var _spectral_push := PackedByteArray()
var _swe_push := PackedByteArray()
# 以下 RID 和缓冲角色由渲染线程独占；初始配置上传后，仅渲染线程更新泡沫参数。
var _rd: RenderingDevice
var _owned: Array[RID] = []
var _sets: Array[RID] = []
var _evolve: RID
var _ifft: RID
var _swe: RID
var _publish: RID
var _evolve_set: RID
var _ifft_sets: Array[RID] = []
var _swe_set: RID
var _publish_set: RID
var _fields: RID
var _previous_fft: RID
var _states: RID
var _terrain: RID
var _stats: RID
var _fft_image: RID
var _swe_image: RID
var _role := 0
var _marker := ""
var _last_query_frame := -1
var _last_poll_frame := -1

func configure(fft: WaterFFTSettings, swe: WaterSWESettings, terrain: Image, region: Transform3D, extent: Vector2, sea_level: float, fft_enabled: bool = true, clock_source: WaterGPU = null, foam_settings: WaterFoamSettings = null) -> void:
	_marker = "Water/" + str(get_instance_id())
	_fft_n = fft.resolution if fft_enabled else 8
	_spectrum_key = [fft_enabled,_fft_n,fft.length,fft.amplitude,fft.phillips_length,fft.wind_angle_degrees,fft.seed]
	_swe_n = terrain.get_width() if terrain != null and swe != null else 0
	_second_order = swe != null and swe.second_order
	var foam_config := foam_settings if foam_settings != null else WaterFoamSettings.new()
	_foam_data = foam_config.simulation_data(fft,swe,extent,Vector2(region.basis.x.x,region.basis.z.x),fft_enabled)
	var modes := fft.create_spectrum() if fft_enabled else PackedFloat32Array()
	if not fft_enabled:
		modes.resize(_fft_n * _fft_n * 4)
	if modes.is_empty():
		error_message = "Invalid FFT spectrum."
		_finish.call_deferred(false)
		return
	var bed_values := PackedFloat32Array([0, 0])
	var max_depth := 0.0
	if _swe_n > 0:
		bed_values.resize(_swe_n * _swe_n * 2)
		for z in _swe_n:
			for x in _swe_n:
				var sample := terrain.get_pixel(x, z)
				var i := (z * _swe_n + x) * 2
				bed_values[i] = sample.r + region.origin.y - sea_level
				bed_values[i + 1] = sample.g
				if sample.g > 0.5:
					max_depth = maxf(max_depth, -bed_values[i])
	var size := maxi(_swe_n, 1)
	var cell := extent / size
	var gravity := swe.gravity if swe != null else 9.81
	var edges := swe.fft_edges if swe != null and fft_enabled else 0
	_swe_push = PackedFloat32Array([cell.x, cell.y, gravity, swe.manning if swe != null else 0.03,
		float(_fft_n), fft.length, fft.height_gain * swe.input_gain if swe != null else fft.height_gain, 1.0 if fft_enabled else 0.0,
		region.origin.x, region.origin.z, region.basis.x.x, region.basis.z.x,
		extent.x, extent.y, swe.relaxation_width if swe != null else 0.2, swe.relaxation_rate if swe != null else 4.0]).to_byte_array()
	_swe_push.append_array(PackedInt32Array([_swe_n, 0, 1 if _second_order else 0, edges]).to_byte_array())
	_swe_push.append_array(PackedFloat32Array([TICK, 1.0 if foam_config.enabled else 0.0, foam_config.texture_period, 0]).to_byte_array())
	_swe_push.append_array(PackedInt32Array([0, 1, 0, 0]).to_byte_array())
	_spectral_push = PackedFloat32Array([float(_fft_n), fft.length, swe.filter_cutoff if swe != null else 12.0, swe.filter_transition if swe != null else 12.0,
		1.0 if swe != null and swe.filter_enabled else 0.0, 0, 0, 0]).to_byte_array()
	if _swe_n > 0:
		var bound := 0.0
		for i in range(0, modes.size(), 4):
			bound += Vector2(modes[i], modes[i + 1]).length()
		bound *= 2.0 * fft.height_gain * swe.input_gain / float(_fft_n * _fft_n)
		var rate := 2.0 * (12.0 + sqrt(gravity * (max_depth + bound + 1.0))) / minf(cell.x, cell.y)
		_substeps = mini(swe.max_substeps, maxi(2, ceili(TICK * rate / 0.18) + 2))
	RenderingServer.call_on_render_thread(_initialize_rd.bind(modes.to_byte_array(), bed_values.to_byte_array(), clock_source))

func _own(rid: RID) -> RID:
	if rid.is_valid():
		_owned.append(rid)
	return rid

func _pipeline(path: String) -> Array[RID]:
	var file := load(path) as RDShaderFile
	if file == null:
		error_message = "Water compute shader is not imported: " + path
		return [RID(), RID()]
	var spirv := file.get_spirv()
	var compile_error := spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
	if not compile_error.is_empty():
		error_message = compile_error
		return [RID(), RID()]
	var shader := _own(_rd.shader_create_from_spirv(spirv))
	return [shader, _own(_rd.compute_pipeline_create(shader)) if shader.is_valid() else RID()]

func _buffer_uniform(binding: int, rid: RID) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.binding = binding
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	uniform.add_id(rid)
	return uniform

func _make_set(shader: RID, buffers: Array[RID], images: Array[RID] = []) -> RID:
	var uniforms: Array[RDUniform] = []
	for i in buffers.size():
		uniforms.append(_buffer_uniform(i, buffers[i]))
	for i in images.size():
		var uniform := RDUniform.new()
		uniform.binding = buffers.size() + i
		uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		uniform.add_id(images[i])
		uniforms.append(uniform)
	var result := _rd.uniform_set_create(uniforms, shader, 0)
	_sets.append(result)
	return result

func _image(size: int) -> RID:
	var format := RDTextureFormat.new()
	format.width = size
	format.height = size
	format.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	return _own(_rd.texture_create(format, RDTextureView.new()))

func _initialize_rd(modes: PackedByteArray, bed_values: PackedByteArray, clock_source: WaterGPU) -> void:
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		error_message = "Water requires a graphical Forward+ RenderingDevice (not headless/Compatibility)."
		_finish.call_deferred(false)
		return
	var pipelines: Array[Array] = []
	for path in SHADER_PATHS:
		var pair := _pipeline(path)
		if not pair[1].is_valid():
			if error_message.is_empty():
				error_message = "Could not create a water compute pipeline on this device."
			_finish.call_deferred(false)
			return
		pipelines.append(pair)
	_evolve = pipelines[0][1]
	_ifft = pipelines[1][1]
	_swe = pipelines[2][1]
	_publish = pipelines[3][1]
	_foam = pipelines[4][1]
	_offshore = pipelines[5][1]
	var initial := _own(_rd.storage_buffer_create(modes.size(), modes))
	_fields = _own(_rd.storage_buffer_create(6 * _fft_n * _fft_n * 8))
	var scratch := _own(_rd.storage_buffer_create(6 * _fft_n * _fft_n * 8))
	_previous_fft = _own(_rd.storage_buffer_create(3 * _fft_n * _fft_n * 8))
	var zeros := PackedByteArray()
	zeros.resize(64)
	_stats = _own(_rd.storage_buffer_create(64, zeros))
	# Preserve the current FFT phase on parameter/bed rebuilds without CPU readback.
	# The owner closes the source only AFTER this initialization is queued.
	if clock_source != null and clock_source._stats.is_valid() and _stats.is_valid():
		_rd.buffer_copy(clock_source._stats, _stats, 4, 4, 4)
	_states = _own(_rd.storage_buffer_create(maxi(_swe_n * _swe_n, 1) * 3 * 16))
	_terrain = _own(_rd.storage_buffer_create(bed_values.size(), bed_values))
	var flux_x := _own(_rd.storage_buffer_create(maxi(_swe_n * _swe_n, 1) * 16))
	var flux_z := _own(_rd.storage_buffer_create(maxi(_swe_n * _swe_n, 1) * 16))
	_foam_config = _own(_rd.storage_buffer_create(_foam_data.size(),_foam_data))
	_foam_records = _own(_rd.storage_buffer_create(maxi(_swe_n*_swe_n,1)*3*32))
	_far_history = _own(_rd.storage_buffer_create(_fft_n*_fft_n*16))
	var preserve_offshore := clock_source != null and clock_source._spectrum_key == _spectrum_key and clock_source._far_history.is_valid()
	if preserve_offshore:
		_rd.buffer_copy(clock_source._far_history,_far_history,0,0,_fft_n*_fft_n*16)
	var foam_fx := _own(_rd.storage_buffer_create(maxi(_swe_n*_swe_n,1)*16))
	var foam_fz := _own(_rd.storage_buffer_create(maxi(_swe_n*_swe_n,1)*16))
	_foam_image = _image(maxi(_swe_n,1))
	_foam_flow_image = _image(maxi(_swe_n,1))
	_far_image = _image(_fft_n)
	_fft_image = _image(_fft_n)
	_swe_image = _image(maxi(_swe_n, 1))
	for rid in [initial, _fields, scratch, _previous_fft, _stats, _states, _terrain, flux_x, flux_z, _fft_image, _swe_image, _foam_config, _foam_records, _far_history, foam_fx, foam_fz, _foam_image, _foam_flow_image, _far_image]:
		if not rid.is_valid():
			error_message = "Could not allocate water GPU resources."
			_finish.call_deferred(false)
			return
	_evolve_set = _make_set(pipelines[0][0], [initial, _fields, _stats])
	_ifft_sets = [_make_set(pipelines[1][0], [_fields, scratch]), _make_set(pipelines[1][0], [scratch, _fields])]
	_swe_set = _make_set(pipelines[2][0], [_states, _terrain, flux_x, flux_z, _stats, _fields, _previous_fft])
	_publish_set = _make_set(pipelines[3][0], [_fields, _states, _terrain, _foam_records, _far_history], [_fft_image, _swe_image, _foam_image, _foam_flow_image, _far_image])
	_foam_set = _make_set(pipelines[4][0], [_foam_records,_states,_terrain,_stats,_foam_config,foam_fx,foam_fz])
	_offshore_set = _make_set(pipelines[5][0], [_fields,_far_history,_stats,_foam_config])
	for uniform_set in _sets:
		if not uniform_set.is_valid():
			error_message = "Could not bind water GPU resources."
			_finish.call_deferred(false)
			return
	var commands := _rd.compute_list_begin()
	_encode_swe(commands, 0, 0, 1, 0, 0)
	_encode_fft(commands, 0.0)
	_rd.compute_list_end()
	# Both interpolation endpoints must be initialized, even for alpha=1:
	# mixing an undefined/NaN previous value is not a valid way to select current.
	_rd.buffer_copy(_fields, _previous_fft, 3 * _fft_n * _fft_n * 8, 0, 3 * _fft_n * _fft_n * 8)
	commands = _rd.compute_list_begin()
	if _swe_n > 0:
		_encode_swe(commands, 8, 0, 1, 0, 0)
		_encode_foam(commands,2,0,1,0,0)
	_encode_offshore(commands,not preserve_offshore)
	_encode_publish(commands)
	_rd.compute_list_end()
	_finish.call_deferred(true)

func _finish(success: bool) -> void:
	if _closed:
		return
	ready = success
	if success:
		fft_texture.texture_rd_rid = _fft_image
		swe_texture.texture_rd_rid = _swe_image
		foam_texture.texture_rd_rid = _foam_image
		foam_flow_texture.texture_rd_rid = _foam_flow_image
		offshore_foam_texture.texture_rd_rid = _far_image
	initialized.emit(success)

func _encode_fft(commands: int, time_offset: float) -> void:
	var push := _spectral_push.duplicate()
	push.encode_float(20, time_offset)
	_rd.compute_list_bind_compute_pipeline(commands, _evolve)
	_rd.compute_list_bind_uniform_set(commands, _evolve_set, 0)
	_rd.compute_list_set_push_constant(commands, push, push.size())
	_rd.compute_list_dispatch(commands, ceili(_fft_n * _fft_n / 64.0), 1, 1)
	_rd.compute_list_add_barrier(commands)
	_rd.compute_list_bind_compute_pipeline(commands, _ifft)
	var bits := int(round(log(_fft_n) / log(2.0)))
	var ping := 0
	for axis in 2:
		for bit in range(1, bits + 1):
			var stage := PackedInt32Array([_fft_n, 1 << bit, axis, bits]).to_byte_array()
			_rd.compute_list_bind_uniform_set(commands, _ifft_sets[ping], 0)
			_rd.compute_list_set_push_constant(commands, stage, 16)
			_rd.compute_list_dispatch(commands, ceili(6 * _fft_n * _fft_n / 64.0), 1, 1)
			_rd.compute_list_add_barrier(commands)
			ping = 1 - ping

func _encode_swe(commands: int, stage: int, input: int, output: int, original: int, rk_stage: int) -> void:
	var push := _swe_push.duplicate()
	push.encode_s32(68, stage)
	push.encode_s32(96, input)
	push.encode_s32(100, output)
	push.encode_s32(104, original)
	push.encode_s32(108, rk_stage)
	_rd.compute_list_bind_compute_pipeline(commands, _swe)
	_rd.compute_list_bind_uniform_set(commands, _swe_set, 0)
	_rd.compute_list_set_push_constant(commands, push, push.size())
	var global_stage := stage in [0, 1, 3, 6, 7, 9]
	var groups := 1 if global_stage else ceili(_swe_n / 8.0)
	_rd.compute_list_dispatch(commands, groups, groups, 1)
	_rd.compute_list_add_barrier(commands)

func set_foam_parameters(data: PackedByteArray) -> void:
	if not _closed:
		RenderingServer.call_on_render_thread(_set_foam_rd.bind(data))

func _set_foam_rd(data: PackedByteArray) -> void:
	if not _foam_config.is_valid() or data == _foam_data:
		return
	data = data.duplicate()
	data.encode_s32(112,_swe_n)
	data.encode_s32(116,_fft_n)
	_foam_data = data
	_swe_push.encode_float(84,float(data.decode_s32(64)))
	_swe_push.encode_float(88,data.decode_float(92))
	_rd.buffer_update(_foam_config,0,data.size(),data)

func _encode_foam(commands: int, stage: int, input: int, output: int, original: int, rk: int) -> void:
	var push := PackedInt32Array([input,output,original,rk,stage,0,0,0]).to_byte_array()
	push.encode_float(20,_swe_push.decode_float(56))
	push.encode_float(24,_swe_push.decode_float(60))
	push.encode_float(28,_swe_push.decode_float(8))
	_rd.compute_list_bind_compute_pipeline(commands,_foam)
	_rd.compute_list_bind_uniform_set(commands,_foam_set,0)
	_rd.compute_list_set_push_constant(commands,push,32)
	_rd.compute_list_dispatch(commands,ceili(_swe_n/8.0),ceili(_swe_n/8.0),1)
	_rd.compute_list_add_barrier(commands)

func _encode_offshore(commands: int, initialize: bool) -> void:
	_rd.compute_list_bind_compute_pipeline(commands,_offshore)
	_rd.compute_list_bind_uniform_set(commands,_offshore_set,0)
	var push := PackedFloat32Array([_spectral_push.decode_float(4),1.0 if initialize else 0.0,0,0]).to_byte_array()
	_rd.compute_list_set_push_constant(commands,push,16)
	_rd.compute_list_dispatch(commands,ceili(_fft_n*_fft_n/64.0),1,1)
	_rd.compute_list_add_barrier(commands)

func _encode_publish(commands: int) -> void:
	_rd.compute_list_bind_compute_pipeline(commands, _publish)
	_rd.compute_list_bind_uniform_set(commands, _publish_set, 0)
	_rd.compute_list_set_push_constant(commands, PackedInt32Array([_fft_n, _swe_n, _role, 0]).to_byte_array(), 16)
	var groups := ceili(maxi(_fft_n, _swe_n) / 8.0)
	_rd.compute_list_dispatch(commands, groups, groups, 1)
	_rd.compute_list_add_barrier(commands)

func advance(delta: float) -> void:
	if not ready or _closed or not is_finite(delta) or delta <= 0.0:
		return
	_accumulator += delta
	var ticks := mini(int((_accumulator + 0.00000001) / TICK), 4)
	if ticks == 0:
		return
	_accumulator -= ticks * TICK
	if _accumulator > TICK * 4:
		dropped_cpu_time += _accumulator - TICK * 4
		_accumulator = TICK * 4
	RenderingServer.call_on_render_thread(_advance_rd.bind(ticks))

func _advance_rd(ticks: int) -> void:
	if not _swe.is_valid():
		return
	var start := Time.get_ticks_usec()
	_poll_timestamps_rd()
	var frame := _rd.get_captured_timestamps_frame()
	var profile := frame != _last_query_frame
	if profile:
		_last_query_frame = frame
		_rd.capture_timestamp(_marker + "/begin")
	for tick in ticks:
		# Previous accepted FFT endpoint, including filtered height AND momentum.
		_rd.buffer_copy(_fields, _previous_fft, 3 * _fft_n * _fft_n * 8, 0, 3 * _fft_n * _fft_n * 8)
		var commands := _rd.compute_list_begin()
		_encode_swe(commands, 0, _role, 1 - _role, _role, 0)
		if _swe_n > 0:
			_encode_fft(commands, TICK)
			for step in _substeps:
				var target := 1 - _role
				_encode_swe(commands, 1, _role, target, _role, 0)
				_encode_swe(commands, 2, _role, target, _role, 0)
				_encode_swe(commands, 3, _role, target, _role, 0)
				_encode_swe(commands, 4, _role, target, _role, 0)
				_encode_swe(commands, 5, _role, 2 if _second_order else target, _role, 1 if _second_order else 0)
				_encode_foam(commands,0,_role,2 if _second_order else target,_role,1 if _second_order else 0)
				_encode_foam(commands,1,_role,2 if _second_order else target,_role,1 if _second_order else 0)
				if _second_order:
					_encode_swe(commands, 4, 2, target, _role, 2)
					_encode_swe(commands, 5, 2, target, _role, 2)
					_encode_foam(commands,0,2,target,_role,2)
					_encode_foam(commands,1,2,target,_role,2)
				_encode_swe(commands, 6, _role, target, _role, 0)
				_role = target
		_encode_swe(commands, 7, _role, 1 - _role, _role, 0)
		# GPU accepted time is authoritative. Re-evaluate display FFT at that time,
		# so a CFL budget shortfall cannot advance FFT ahead of the actual SWE.
		_encode_fft(commands, 0.0)
		_encode_swe(commands,9,_role,1-_role,_role,0)
		_encode_offshore(commands,false)
		_encode_publish(commands)
		_rd.compute_list_end()
	if profile:
		_rd.capture_timestamp(_marker + "/end")
	_publish_cpu.call_deferred((Time.get_ticks_usec() - start) / 1000.0)

func _poll_timestamps_rd() -> void:
	var frame := _rd.get_captured_timestamps_frame()
	if frame == _last_poll_frame:
		return
	_last_poll_frame = frame
	var begin := -1
	for i in _rd.get_captured_timestamps_count():
		var name := _rd.get_captured_timestamp_name(i)
		if name == _marker + "/begin":
			begin = _rd.get_captured_timestamp_gpu_time(i)
		elif name == _marker + "/end" and begin >= 0:
			var end := _rd.get_captured_timestamp_gpu_time(i)
			if end > begin:
				_publish_gpu.call_deferred((end - begin) / 1000000.0)

func _publish_gpu(milliseconds: float) -> void:
	gpu_time_ms = milliseconds

func _publish_cpu(milliseconds: float) -> void:
	cpu_submit_ms = milliseconds

## 显式诊断/验证才回读；可等待 GPU，不能在逐帧显示路径调用。
func snapshot(callback: Callable) -> void:
	RenderingServer.call_on_render_thread(_snapshot_rd.bind(callback))

func _snapshot_rd(callback: Callable) -> void:
	if not _swe.is_valid():
		callback.call_deferred({"error": "Water GPU is not initialized."})
		return
	var bytes := _rd.buffer_get_data(_stats)
	var values := PackedFloat32Array()
	if _swe_n > 0:
		values = _rd.buffer_get_data(_states, _role * _swe_n * _swe_n * 16, _swe_n * _swe_n * 16).to_float32_array()
	var foam_values := _rd.buffer_get_data(_foam_records,_role*_swe_n*_swe_n*32,_swe_n*_swe_n*32).to_float32_array() if _swe_n > 0 else PackedFloat32Array()
	callback.call_deferred({"foam":foam_values,"offshore_foam":_rd.buffer_get_data(_far_history).to_float32_array(),"state": values, "spectral": _rd.buffer_get_data(_fields).to_float32_array(), "bed": _rd.buffer_get_data(_terrain).to_float32_array(),
		"simulated_time": bytes.decode_float(4), "last_dt": bytes.decode_float(12), "faults": bytes.decode_u32(16), "dropped_gpu_time": bytes.decode_float(20), "accepted_steps": bytes.decode_u32(24)})

func close() -> void:
	if _closed:
		return
	_closed = true
	ready = false
	fft_texture.texture_rd_rid = RID()
	swe_texture.texture_rd_rid = RID()
	foam_texture.texture_rd_rid = RID()
	foam_flow_texture.texture_rd_rid = RID()
	offshore_foam_texture.texture_rd_rid = RID()
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
	_swe = RID()
