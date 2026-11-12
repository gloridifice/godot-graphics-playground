@tool
class_name HeightfieldFogSWE
extends RefCounted

# Global RenderingDevice only: the output is sampled directly by FogVolume, without CPU copies.
const ShaderFile = preload("res://addons/heightfield_fog/shaders/swe.glsl")
const TICK := 1.0 / 60.0
const MAX_MOVEMENTS := 16
signal initialized(success: bool)
var texture := Texture2DRD.new()
# Shared GPU phase keeps density shading and incoming noise on the same simulation clock.
var wind_phase_texture := Texture2DRD.new()
var ready: bool = false
var dropped_time: float = 0.0
var gpu_time_ms: float = -1.0
var cpu_submit_ms: float = 0.0
var gpu_sample_frame: int = -1
var _marker := ""
var _last_profile_frame := -1
var _accumulator := 0.0
var _dimensions := Vector2i.ZERO
var _cell := Vector2.ONE
var _initial_max := 0.0
var _events := PackedVector4Array()
# Three vec4s per physics sample; separate from the four one-shot jump events.
var _movements := PackedVector4Array()
var _closed := false
var _second_order := false
# Below this point RIDs and ping-pong state are owned by the render thread.
var _rd: RenderingDevice
var _shader: RID
var _pipeline: RID
var _buffers: Array[RID] = []
var _sets: Array[RID] = []
var _height: RID
var _wind_parameters: RID
var _movement_parameters: RID
var _noise: RID
var _noise_sampler: RID
var _wind_phase: RID
var _ping := 0
var _last_timestamp_frame := -1

func configure(terrain: Image, thickness: Image, extent: Vector2, noise: Image = null, second_order: bool = false) -> void:
	_second_order = second_order
	_marker = "HeightfieldSWE/" + str(get_instance_id())
	_dimensions = terrain.get_size()
	_cell = extent / Vector2(_dimensions)
	var values := PackedFloat32Array()
	values.resize(_dimensions.x * _dimensions.y * 4)
	for y in _dimensions.y:
		for x in _dimensions.x:
			var h := thickness.get_pixel(x,y).r if terrain.get_pixel(x,y).g > 0.5 else 0.0
			values[(y*_dimensions.x+x)*4] = h
			_initial_max = maxf(_initial_max,h)
	if noise == null:
		noise = Image.create(1,1,false,Image.FORMAT_RF)
		noise.fill(Color(0.5,0,0,0))
	else:
		noise = noise.duplicate()
		noise.convert(Image.FORMAT_RF)
	RenderingServer.call_on_render_thread(_initialize_rd.bind(terrain.get_data(),values.to_byte_array(),thickness.get_data(),noise.get_size(),noise.get_data()))

func _finish(success: bool) -> void:
	if _closed:
		return
	ready = success
	if success:
		texture.texture_rd_rid = _height
		wind_phase_texture.texture_rd_rid = _wind_phase
	initialized.emit(success)

func _initialize_rd(terrain: PackedByteArray, initial: PackedByteArray, heights: PackedByteArray, noise_size: Vector2i, noise_bytes: PackedByteArray) -> void:
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		_finish.call_deferred(false)
		return
	_shader = _rd.shader_create_from_spirv(ShaderFile.get_spirv())
	if not _shader.is_valid():
		_finish.call_deferred(false)
		return
	_pipeline = _rd.compute_pipeline_create(_shader)
	if not _pipeline.is_valid():
		_finish.call_deferred(false)
		return
	var format := RDTextureFormat.new()
	format.width = _dimensions.x
	format.height = _dimensions.y
	format.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	_height = _rd.texture_create(format,RDTextureView.new(),[heights])
	if not _height.is_valid():
		_finish.call_deferred(false)
		return
	var noise_format := RDTextureFormat.new()
	noise_format.width = noise_size.x
	noise_format.height = noise_size.y
	noise_format.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
	noise_format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	_noise = _rd.texture_create(noise_format,RDTextureView.new(),[noise_bytes])
	var sampler := RDSamplerState.new()
	sampler.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	sampler.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	_noise_sampler = _rd.sampler_create(sampler)
	var phase_format := RDTextureFormat.new()
	phase_format.width = 1
	phase_format.height = 1
	phase_format.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	phase_format.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	_wind_phase = _rd.texture_create(phase_format,RDTextureView.new(),[PackedFloat32Array([0,0,0,0]).to_byte_array()])
	_wind_parameters = _rd.storage_buffer_create(80,PackedFloat32Array([0,0,0,0,0,0,0,0,1,0,0,1,0,0,0,1,1,0,0,0]).to_byte_array())
	if not _noise.is_valid() or not _noise_sampler.is_valid() or not _wind_phase.is_valid() or not _wind_parameters.is_valid():
		_finish.call_deferred(false)
		return
	_buffers = [_rd.storage_buffer_create(initial.size(),initial), _rd.storage_buffer_create(initial.size(),initial), _rd.storage_buffer_create(terrain.size(),terrain), _rd.storage_buffer_create(initial.size()), _rd.storage_buffer_create(initial.size()), _rd.storage_buffer_create(32,PackedByteArray([0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]))]
	_movement_parameters = _rd.storage_buffer_create(16 + MAX_MOVEMENTS * 48)
	if not _movement_parameters.is_valid():
		_finish.call_deferred(false)
		return
	for ping in 2:
		var uniforms: Array[RDUniform] = []
		for binding in 7:
			var uniform := RDUniform.new()
			uniform.binding = binding
			uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE if binding == 6 else RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
			var rid := _height if binding == 6 else _buffers[binding]
			if binding < 2:
				rid = _buffers[(binding+ping)%2]
			uniform.add_id(rid)
			uniforms.append(uniform)
		var wind_uniform := RDUniform.new()
		wind_uniform.binding = 7
		wind_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		wind_uniform.add_id(_wind_parameters)
		uniforms.append(wind_uniform)
		var noise_uniform := RDUniform.new()
		noise_uniform.binding = 8
		noise_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		noise_uniform.add_id(_noise_sampler)
		noise_uniform.add_id(_noise)
		uniforms.append(noise_uniform)
		var phase_uniform := RDUniform.new()
		phase_uniform.binding = 9
		phase_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		phase_uniform.add_id(_wind_phase)
		uniforms.append(phase_uniform)
		var movement_uniform := RDUniform.new()
		movement_uniform.binding = 10
		movement_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		movement_uniform.add_id(_movement_parameters)
		uniforms.append(movement_uniform)
		_sets.append(_rd.uniform_set_create(uniforms,_shader,0))
		if not _sets[ping].is_valid():
			_finish.call_deferred(false)
			return
	_finish.call_deferred(true)

## Signed radial multiplier: negative gathers, positive spreads; never changes mass.
func impulse(local_feet: Vector3, radial_strength: float = 1.0) -> void:
	if _closed or not local_feet.is_finite() or not is_finite(radial_strength) or radial_strength == 0.0:
		return
	if _events.size() >= 4:
		_events.remove_at(0)
	_events.append(Vector4(local_feet.x,local_feet.y,local_feet.z,clampf(radial_strength,-1.0,1.0)))

## Grounded swept-body sample. Duration is physical exposure, not a render-frame multiplier.
func movement(start: Vector3, end: Vector3, duration: float, radius: float, coupling: float, wake: float) -> void:
	if _closed or not start.is_finite() or not end.is_finite() or not is_finite(duration) or duration <= 0.0 or duration > 0.1 or not is_finite(radius) or not is_finite(coupling) or not is_finite(wake) or radius <= 0.0 or coupling <= 0.0:
		return
	var velocity := Vector2(end.x-start.x, end.z-start.z) / duration
	# Teleports are not body motion; tiny contact corrections are not walking.
	if velocity.length() < 0.05 or velocity.length() > 20.0:
		return
	if _movements.size() >= MAX_MOVEMENTS * 3:
		_movements = _movements.slice(3)
	_movements.append(Vector4(start.x, start.y, start.z, radius))
	_movements.append(Vector4(end.x, end.y, end.z, coupling))
	_movements.append(Vector4(velocity.x, velocity.y, duration, clampf(wake, 0.0, 1.0)))

func advance(delta: float, gravity: float, drag: float, radius: float, speed: float, gravity_threshold: float = 0.0, wind_parameters: PackedFloat32Array = PackedFloat32Array()) -> void:
	if not ready or _closed:
		return
	RenderingServer.call_on_render_thread(_poll_gpu_rd)
	# Limit catch-up rather than submitting an unbounded queue after a debugger/OS stall.
	_accumulator += delta
	var ticks := mini(int(_accumulator/TICK),4)
	if ticks == 0:
		return
	_accumulator -= ticks*TICK
	if _accumulator > TICK*4:
		dropped_time += _accumulator-TICK*4
		_accumulator = TICK*4
	var events := _events.duplicate()
	_events.clear()
	var movements := _movements.duplicate()
	_movements.clear()
	# Conservative scheduling estimate; a GPU reduction independently enforces the actual CFL.
	gravity_threshold = maxf(gravity_threshold,0.0)
	var wind_speed := Vector2(wind_parameters[0],wind_parameters[1]).length() if wind_parameters.size() == 20 else 0.0
	var movement_speed := 0.0
	for i in range(2,movements.size(),3):
		movement_speed = maxf(movement_speed,Vector2(movements[i].x,movements[i].y).length()*2.0)
	var rate := 2.0*(sqrt(gravity*maxf(_initial_max-gravity_threshold,0.0))+maxf(speed*4.0,movement_speed)+wind_speed)/minf(_cell.x,_cell.y)
	var substeps := clampi(int(ceil(TICK*rate/(0.25 if _second_order else 0.4))),1,64)
	RenderingServer.call_on_render_thread(_advance_rd.bind(ticks,substeps,gravity,drag,radius,speed,events,gravity_threshold,wind_parameters.to_byte_array(),movements))

func _poll_gpu_rd() -> void:
	if not _pipeline.is_valid():
		return
	var profile_frame := _rd.get_captured_timestamps_frame()
	if profile_frame != _last_profile_frame:
		_last_profile_frame = profile_frame
		var begin := -1
		for i in _rd.get_captured_timestamps_count():
			var name := _rd.get_captured_timestamp_name(i)
			if name == _marker + "/begin":
				begin = _rd.get_captured_timestamp_gpu_time(i)
			elif name == _marker + "/end" and begin >= 0:
				var end := _rd.get_captured_timestamp_gpu_time(i)
				if end > begin:
					# Driver timestamps are nanoseconds (D3D12 converts ticks with 1e9/frequency).
					_publish_gpu.call_deferred((end-begin)/1000000.0,profile_frame)

func _advance_rd(ticks: int, substeps: int, gravity: float, drag: float, radius: float, speed: float, events: PackedVector4Array, gravity_threshold: float, wind_parameters: PackedByteArray, movements: PackedVector4Array) -> void:
	if not _pipeline.is_valid():
		return
	var started := Time.get_ticks_usec()
	# Simulation may advance without drawing. Bound profiling queries until the
	# completed timestamp frame advances instead of exhausting the RD query pool.
	var timestamp_frame := _rd.get_captured_timestamps_frame()
	var sample_gpu := timestamp_frame != _last_timestamp_frame
	if sample_gpu:
		_last_timestamp_frame = timestamp_frame
		_rd.capture_timestamp(_marker+"/begin")
	if wind_parameters.size() == 80:
		_rd.buffer_update(_wind_parameters,0,80,wind_parameters)
	var push := PackedFloat32Array([_cell.x,_cell.y,gravity,drag,TICK/substeps,radius,speed,0]).to_byte_array()
	push.append_array(PackedInt32Array([_dimensions.x,_dimensions.y,events.size(),0]).to_byte_array())
	events.resize(4)
	push.append_array(events.to_byte_array())
	push.append_array(PackedFloat32Array([gravity_threshold,1.0 if _second_order else 0.0,0,0]).to_byte_array())
	if not movements.is_empty():
		var movement_bytes := PackedInt32Array([movements.size()/3,0,0,0]).to_byte_array()
		movement_bytes.append_array(movements.to_byte_array())
		_rd.buffer_update(_movement_parameters,0,movement_bytes.size(),movement_bytes)
	var commands := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(commands,_pipeline)
	if not movements.is_empty():
		# Apply each elapsed physics sample once, before CFL sees the forced velocity.
		push.encode_float(28,5.0)
		_rd.compute_list_bind_uniform_set(commands,_sets[_ping],0)
		_rd.compute_list_set_push_constant(commands,push,push.size())
		_rd.compute_list_dispatch(commands,ceili(_dimensions.x/8.0),ceili(_dimensions.y/8.0),1)
		_rd.compute_list_add_barrier(commands)
		_ping = 1-_ping
	for step in ticks*substeps:
		# Apply each impulse exactly once, not once per substep or per render frame.
		if step > 0:
			push.encode_s32(40,0)
		_rd.compute_list_bind_uniform_set(commands,_sets[_ping],0)
		for stage in 5:
			push.encode_float(28,float(stage))
			_rd.compute_list_set_push_constant(commands,push,push.size())
			_rd.compute_list_dispatch(commands,1 if stage == 0 or stage == 4 else ceili(_dimensions.x/8.0),1 if stage == 0 or stage == 4 else ceili(_dimensions.y/8.0),1)
			_rd.compute_list_add_barrier(commands)
		_ping = 1-_ping
	_rd.compute_list_end()
	if sample_gpu:
		_rd.capture_timestamp(_marker+"/end")
	_publish_cpu.call_deferred((Time.get_ticks_usec()-started)/1000.0)

func _publish_gpu(milliseconds: float, frame: int) -> void:
	gpu_time_ms = milliseconds
	gpu_sample_frame = frame

func _publish_cpu(milliseconds: float) -> void:
	cpu_submit_ms = milliseconds

## Explicit diagnostic snapshot only; never used by the rendering/update path. May stall GPU.
func snapshot(callback: Callable) -> void:
	RenderingServer.call_on_render_thread(_snapshot_rd.bind(callback))

func _snapshot_rd(callback: Callable) -> void:
	if _pipeline.is_valid():
		var state := _rd.buffer_get_data(_buffers[_ping]).to_float32_array()
		var bytes := _rd.buffer_get_data(_buffers[5])
		var report := {"state":state,"simulated_time":bytes.decode_float(4),"last_dt":bytes.decode_float(8),"faults":bytes.decode_u32(12),"maximum_height":bytes.decode_float(16),"cfl_limited_steps":bytes.decode_u32(20)}
		callback.call_deferred(report)

func close() -> void:
	if _closed:
		return
	_closed = true
	ready = false
	texture.texture_rd_rid = RID()
	wind_phase_texture.texture_rd_rid = RID()
	RenderingServer.call_on_render_thread(_free_rd)

func _free_rd() -> void:
	if _rd == null:
		return
	for uniform in _sets:
		if _rd.uniform_set_is_valid(uniform):
			_rd.free_rid(uniform)
	_sets.clear()
	for buffer in _buffers:
		if buffer.is_valid():
			_rd.free_rid(buffer)
	_buffers.clear()
	for rid in [_pipeline,_shader,_height,_wind_parameters,_movement_parameters,_noise_sampler,_noise,_wind_phase]:
		if rid.is_valid():
			_rd.free_rid(rid)
	_pipeline = RID()
