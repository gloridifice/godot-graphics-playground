class_name HeightfieldFogSWE
extends RefCounted

# Global RenderingDevice only: the output is sampled directly by FogVolume, without CPU copies.
const ShaderFile = preload("res://addons/heightfield_fog/shaders/swe.glsl")
const TICK := 1.0 / 60.0
signal initialized(success: bool)
var texture := Texture2DRD.new()
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
var _closed := false
# Below this point RIDs and ping-pong state are owned by the render thread.
var _rd: RenderingDevice
var _shader: RID
var _pipeline: RID
var _buffers: Array[RID] = []
var _sets: Array[RID] = []
var _height: RID
var _ping := 0

func configure(terrain: Image, thickness: Image, extent: Vector2) -> void:
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
	RenderingServer.call_on_render_thread(_initialize_rd.bind(terrain.get_data(),values.to_byte_array(),thickness.get_data()))

func _finish(success: bool) -> void:
	if _closed:
		return
	ready = success
	if success:
		texture.texture_rd_rid = _height
	initialized.emit(success)

func _initialize_rd(terrain: PackedByteArray, initial: PackedByteArray, heights: PackedByteArray) -> void:
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
	_buffers = [_rd.storage_buffer_create(initial.size(),initial), _rd.storage_buffer_create(initial.size(),initial), _rd.storage_buffer_create(terrain.size(),terrain), _rd.storage_buffer_create(initial.size()), _rd.storage_buffer_create(initial.size()), _rd.storage_buffer_create(32,PackedByteArray([0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]))]
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
		_sets.append(_rd.uniform_set_create(uniforms,_shader,0))
		if not _sets[ping].is_valid():
			_finish.call_deferred(false)
			return
	_finish.call_deferred(true)

func impulse(local_feet: Vector3) -> void:
	if _closed or not local_feet.is_finite():
		return
	if _events.size() >= 4:
		_events.remove_at(0)
	_events.append(Vector4(local_feet.x,local_feet.y,local_feet.z,0))

func advance(delta: float, gravity: float, drag: float, radius: float, speed: float) -> void:
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
	# Conservative scheduling estimate; a GPU reduction independently enforces the actual CFL.
	var rate := 2.0*(sqrt(gravity*maxf(_initial_max,0.01))+speed*4.0)/minf(_cell.x,_cell.y)
	var substeps := clampi(int(ceil(TICK*rate/0.4)),1,64)
	RenderingServer.call_on_render_thread(_advance_rd.bind(ticks,substeps,gravity,drag,radius,speed,events))

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

func _advance_rd(ticks: int, substeps: int, gravity: float, drag: float, radius: float, speed: float, events: PackedVector4Array) -> void:
	if not _pipeline.is_valid():
		return
	var started := Time.get_ticks_usec()
	_rd.capture_timestamp(_marker+"/begin")
	var push := PackedFloat32Array([_cell.x,_cell.y,gravity,drag,TICK/substeps,radius,speed,0]).to_byte_array()
	push.append_array(PackedInt32Array([_dimensions.x,_dimensions.y,events.size(),0]).to_byte_array())
	events.resize(4)
	push.append_array(events.to_byte_array())
	var commands := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(commands,_pipeline)
	for step in ticks*substeps:
		# Apply each impulse exactly once, not once per substep or per render frame.
		if step > 0:
			push.encode_s32(40,0)
		_rd.compute_list_bind_uniform_set(commands,_sets[_ping],0)
		for stage in 4:
			push.encode_float(28,float(stage))
			_rd.compute_list_set_push_constant(commands,push,push.size())
			_rd.compute_list_dispatch(commands,1 if stage == 0 else ceili(_dimensions.x/8.0),1 if stage == 0 else ceili(_dimensions.y/8.0),1)
			_rd.compute_list_add_barrier(commands)
		_ping = 1-_ping
	_rd.compute_list_end()
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
	for rid in [_pipeline,_shader,_height]:
		if rid.is_valid():
			_rd.free_rid(rid)
	_pipeline = RID()
