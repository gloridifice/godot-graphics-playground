@tool
class_name HeightfieldFogStableFluid
extends RefCounted

## Projected MAC air plus radial near-ground interaction; both advect an h0 reference map.
const ShaderFile = preload("res://addons/heightfield_fog/shaders/stable_fluid.glsl")
const TICK := 1.0 / 60.0
const MAX_MOVEMENTS := 16
signal initialized(success: bool)
var texture := Texture2DRD.new()
var wind_phase_texture := Texture2DRD.new()
var flow_displacement_texture := Texture2DRD.new()
var ready := false
var dropped_time := 0.0
var gpu_time_ms := -1.0
var cpu_submit_ms := 0.0
var gpu_sample_frame := -1
var _dimensions := Vector2i.ZERO
var _cell := Vector2.ONE
var _accumulator := 0.0
var _events := PackedVector4Array()
var _movements := PackedVector4Array()
var _closed := false
var _marker := ""
var _last_profile_frame := -1
# RIDs, ping-pong indices and submitted simulation time belong to the render thread.
var _rd: RenderingDevice
var _shader: RID
var _pipeline: RID
var _buffers: Array[RID] = []
var _images: Array[RID] = []
var _sets: Array[RID] = []
var _noise: RID
var _sampler: RID
var _velocity_ping := 0
var _scalar_ping := 0
var _pressure_ping := 0
var _simulated_time := 0.0
var _last_timestamp_frame := -1

func configure(terrain: Image, thickness: Image, extent: Vector2, noise: Image = null) -> void:
	_dimensions = terrain.get_size()
	_cell = extent / Vector2(_dimensions)
	_marker = "HeightfieldStableFluid/" + str(get_instance_id())
	var values := PackedFloat32Array()
	values.resize(_dimensions.x * _dimensions.y * 8)
	for y in _dimensions.y:
		for x in _dimensions.x:
			var cell := (y * _dimensions.x + x) * 8
			values[cell+6] = 1.0 # Neutral gain, including empty/invalid air.
			if terrain.get_pixel(x,y).g > 0.5:
				values[cell] = thickness.get_pixel(x,y).r
				values[cell+3] = 1.0 # Initially all valid air references h0, even where h0 is zero.
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
		texture.texture_rd_rid = _images[0]
		wind_phase_texture.texture_rd_rid = _images[1]
		flow_displacement_texture.texture_rd_rid = _images[2]
	initialized.emit(success)

func _image(size: Vector2i, format: RenderingDevice.DataFormat, data: PackedByteArray) -> RID:
	var description := RDTextureFormat.new()
	description.width = size.x
	description.height = size.y
	description.format = format
	description.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	return _rd.texture_create(description,RDTextureView.new(),[data])

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
	var zero_flow := PackedByteArray()
	zero_flow.resize(_dimensions.x * _dimensions.y * 8)
	_images = [
		_image(_dimensions,RenderingDevice.DATA_FORMAT_R32_SFLOAT,heights),
		_image(Vector2i.ONE,RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT,PackedFloat32Array([0,0,0,0]).to_byte_array()),
		_image(_dimensions,RenderingDevice.DATA_FORMAT_R32G32_SFLOAT,zero_flow),
	]
	_noise = _image(noise_size,RenderingDevice.DATA_FORMAT_R32_SFLOAT,noise_bytes)
	var sampler := RDSamplerState.new()
	sampler.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	sampler.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	_sampler = _rd.sampler_create(sampler)
	var faces := (_dimensions.x + 1) * (_dimensions.y + 1) * 16
	var zero_velocity := PackedByteArray()
	zero_velocity.resize(faces)
	var zero_stats := PackedByteArray()
	zero_stats.resize(16)
	var cells := _dimensions.x * _dimensions.y
	_buffers = [
		_rd.storage_buffer_create(faces,zero_velocity), _rd.storage_buffer_create(faces,zero_velocity),
		_rd.storage_buffer_create(initial.size(),initial), _rd.storage_buffer_create(initial.size(),initial),
		_rd.storage_buffer_create(terrain.size(),terrain),
		_rd.storage_buffer_create(cells*4), _rd.storage_buffer_create(cells*4), _rd.storage_buffer_create(cells*4),
		_rd.storage_buffer_create(80,PackedFloat32Array([0,0,0,0,0,0,0,0,1,0,0,1,0,0,0,1,1,0,0,0]).to_byte_array()),
		_rd.storage_buffer_create(16+MAX_MOVEMENTS*48), _rd.storage_buffer_create(16,zero_stats),
		_rd.storage_buffer_create(heights.size(),heights), # Immutable h0; never a compute output.
	]
	for rid in _buffers + _images + [_noise,_sampler]:
		if not rid.is_valid():
			_finish.call_deferred(false)
			return
	for velocity_ping in 2:
		for scalar_ping in 2:
			for pressure_ping in 2:
				var uniforms: Array[RDUniform] = []
				for binding in 16:
					var uniform := RDUniform.new()
					uniform.binding = binding
					if binding < 11:
						uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
						var index := binding
						if binding < 2:
							index = (binding+velocity_ping)%2
						elif binding < 4:
							index = 2+(binding-2+scalar_ping)%2
						elif binding == 5 or binding == 6:
							index = 5+(binding-5+pressure_ping)%2
						uniform.add_id(_buffers[index])
					elif binding < 14:
						uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
						uniform.add_id(_images[binding-11])
					elif binding == 14:
						uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
						uniform.add_id(_sampler)
						uniform.add_id(_noise)
					else:
						uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
						uniform.add_id(_buffers[11])
					uniforms.append(uniform)
				var set := _rd.uniform_set_create(uniforms,_shader,0)
				_sets.append(set)
				if not set.is_valid():
					_finish.call_deferred(false)
					return
	_finish.call_deferred(true)

func impulse(local_feet: Vector3, strength: float = 1.0) -> void:
	if not ready or _closed or not local_feet.is_finite() or not is_finite(strength) or strength == 0.0:
		return
	if _events.size() >= 4:
		_events.remove_at(0)
	_events.append(Vector4(local_feet.x,local_feet.y,local_feet.z,clampf(strength,-1.0,1.0)))

func movement(start: Vector3, end: Vector3, duration: float, radius: float, coupling: float, wake: float) -> void:
	if not ready or _closed or not start.is_finite() or not end.is_finite() or not is_finite(duration) or duration <= 0.0 or duration > 0.1 or not is_finite(radius) or not is_finite(coupling) or not is_finite(wake) or radius <= 0.0 or coupling <= 0.0:
		return
	var velocity := Vector2(end.x-start.x,end.z-start.z)/duration
	if velocity.length() < 0.05 or velocity.length() > 20.0:
		return
	if _movements.size() >= MAX_MOVEMENTS*3:
		_movements = _movements.slice(3)
	_movements.append(Vector4(start.x,start.y,start.z,radius))
	_movements.append(Vector4(end.x,end.y,end.z,coupling))
	_movements.append(Vector4(velocity.x,velocity.y,duration,clampf(wake,0.0,1.0)))

func advance(delta: float, drag: float, radius: float, speed: float, iterations: int, wind_parameters: PackedFloat32Array, height_gains: Vector3 = Vector3(1.75,0.25,0.8)) -> void:
	if not ready or _closed:
		return
	RenderingServer.call_on_render_thread(_poll_gpu_rd)
	_accumulator += delta
	var ticks := mini(int(_accumulator/TICK),4)
	if ticks == 0:
		return
	_accumulator -= ticks*TICK
	if _accumulator > TICK*4:
		dropped_time += _accumulator-TICK*4
		_accumulator = TICK*4
	var events := _events.duplicate()
	var movements := _movements.duplicate()
	_events.clear()
	_movements.clear()
	var gains := Vector3(clampf(height_gains.x,1.0,2.0),clampf(height_gains.y,0.0,1.0),clampf(height_gains.z,0.01,32.0))
	RenderingServer.call_on_render_thread(_advance_rd.bind(ticks,maxf(drag,0.0),radius,speed,clampi(iterations,8,128),wind_parameters.to_byte_array(),events,movements,gains))

func _dispatch(commands: int, push: PackedByteArray, stage: int) -> void:
	push.encode_float(24,float(stage))
	_rd.compute_list_bind_uniform_set(commands,_sets[_velocity_ping*4+_scalar_ping*2+_pressure_ping],0)
	_rd.compute_list_set_push_constant(commands,push,push.size())
	var single := stage == 0 or stage == 7
	_rd.compute_list_dispatch(commands,1 if single else ceili((_dimensions.x+1)/8.0),1 if single else ceili((_dimensions.y+1)/8.0),1)
	_rd.compute_list_add_barrier(commands)

func _advance_rd(ticks: int, drag: float, radius: float, speed: float, iterations: int, wind_parameters: PackedByteArray, events: PackedVector4Array, movements: PackedVector4Array, height_gains: Vector3) -> void:
	if not _pipeline.is_valid():
		return
	var started := Time.get_ticks_usec()
	var timestamp_frame := _rd.get_captured_timestamps_frame()
	var sample_gpu := timestamp_frame != _last_timestamp_frame
	if sample_gpu:
		_last_timestamp_frame = timestamp_frame
		_rd.capture_timestamp(_marker+"/begin")
	if wind_parameters.size() == 80:
		_rd.buffer_update(_buffers[8],0,80,wind_parameters)
	if not movements.is_empty():
		var bytes := PackedInt32Array([movements.size()/3,0,0,0]).to_byte_array()
		bytes.append_array(movements.to_byte_array())
		_rd.buffer_update(_buffers[9],0,bytes.size(),bytes)
	var push := PackedFloat32Array([_cell.x,_cell.y,TICK,drag,radius,speed,0,0]).to_byte_array()
	push.append_array(PackedInt32Array([_dimensions.x,_dimensions.y,events.size(),movements.size()/3]).to_byte_array())
	events.resize(4)
	push.append_array(events.to_byte_array())
	push.append_array(PackedFloat32Array([height_gains.x,height_gains.y,height_gains.z,0]).to_byte_array())
	var commands := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(commands,_pipeline)
	for tick in ticks:
		if tick > 0:
			push.encode_s32(40,0)
			push.encode_s32(44,0)
		_dispatch(commands,push,0)
		_dispatch(commands,push,1)
		_velocity_ping = 1-_velocity_ping
		_dispatch(commands,push,2)
		_velocity_ping = 1-_velocity_ping
		_dispatch(commands,push,3)
		for iteration in iterations:
			_dispatch(commands,push,4)
			_pressure_ping = 1-_pressure_ping
		_dispatch(commands,push,5)
		_velocity_ping = 1-_velocity_ping
		_dispatch(commands,push,6)
		_scalar_ping = 1-_scalar_ping
		_dispatch(commands,push,7)
		_simulated_time += TICK
	_rd.compute_list_end()
	if sample_gpu:
		_rd.capture_timestamp(_marker+"/end")
	_publish_cpu.call_deferred((Time.get_ticks_usec()-started)/1000.0)

func _poll_gpu_rd() -> void:
	if not _pipeline.is_valid():
		return
	var frame := _rd.get_captured_timestamps_frame()
	if frame == _last_profile_frame:
		return
	_last_profile_frame = frame
	var begin := -1
	for i in _rd.get_captured_timestamps_count():
		var name := _rd.get_captured_timestamp_name(i)
		if name == _marker+"/begin":
			begin = _rd.get_captured_timestamp_gpu_time(i)
		elif name == _marker+"/end" and begin >= 0:
			var end := _rd.get_captured_timestamp_gpu_time(i)
			if end > begin:
				_publish_gpu.call_deferred((end-begin)/1000000.0,frame)

func _publish_gpu(milliseconds: float, frame: int) -> void:
	gpu_time_ms = milliseconds
	gpu_sample_frame = frame

func _publish_cpu(milliseconds: float) -> void:
	cpu_submit_ms = milliseconds

## Explicit diagnostics only. Transport plus temporary height gain is not mass conservative.
func snapshot(callback: Callable) -> void:
	RenderingServer.call_on_render_thread(_snapshot_rd.bind(callback))

func _snapshot_rd(callback: Callable) -> void:
	if not _pipeline.is_valid():
		callback.call_deferred({})
		return
	var materials := _rd.buffer_get_data(_buffers[2+_scalar_ping]).to_float32_array()
	var scalars := PackedFloat32Array()
	scalars.resize(_dimensions.x*_dimensions.y*4)
	var height_gain := PackedFloat32Array()
	height_gain.resize(_dimensions.x*_dimensions.y)
	var faces := _rd.buffer_get_data(_buffers[_velocity_ping]).to_float32_array()
	var diagnostics := _rd.buffer_get_data(_buffers[10])
	var velocities := PackedFloat32Array()
	velocities.resize(_dimensions.x*_dimensions.y*2)
	var radial_velocities := PackedFloat32Array()
	radial_velocities.resize(velocities.size())
	var maximum := 0.0
	for y in _dimensions.y:
		for x in _dimensions.x:
			var cell := y*_dimensions.x+x
			var face := (y*(_dimensions.x+1)+x)*4
			var top := face+(_dimensions.x+1)*4
			var radial_u := (faces[face+2]+faces[face+6])*0.5
			var radial_v := (faces[face+3]+faces[top+3])*0.5
			velocities[cell*2] = (faces[face]+faces[face+4])*0.5+radial_u
			velocities[cell*2+1] = (faces[face+1]+faces[top+1])*0.5+radial_v
			radial_velocities[cell*2] = radial_u
			radial_velocities[cell*2+1] = radial_v
			for component in 4:
				scalars[cell*4+component] = materials[cell*8+component]
			height_gain[cell] = materials[cell*8+6]
			maximum = maxf(maximum,scalars[cell*4])
	# Keep thickness/material coordinates distinct from velocity; no fictitious SWE momentum.
	callback.call_deferred({"scalar":scalars,"height_gain":height_gain,"velocity":velocities,"radial_velocity":radial_velocities,"simulated_time":_simulated_time,"last_dt":TICK if _simulated_time>0 else 0.0,"faults":diagnostics.decode_u32(0),"trace_limited":diagnostics.decode_u32(4),"divergence_before":diagnostics.decode_float(8),"divergence_after":diagnostics.decode_float(12),"maximum_height":maximum})

func close() -> void:
	if _closed:
		return
	_closed = true
	ready = false
	texture.texture_rd_rid = RID()
	wind_phase_texture.texture_rd_rid = RID()
	flow_displacement_texture.texture_rd_rid = RID()
	_events.clear()
	_movements.clear()
	RenderingServer.call_on_render_thread(_free_rd)

func _free_rd() -> void:
	if _rd == null:
		return
	for set in _sets:
		if _rd.uniform_set_is_valid(set):
			_rd.free_rid(set)
	_sets.clear()
	for rid in _buffers + _images + [_sampler,_noise,_pipeline,_shader]:
		if rid.is_valid():
			_rd.free_rid(rid)
	_buffers.clear()
	_images.clear()
	_pipeline = RID()
