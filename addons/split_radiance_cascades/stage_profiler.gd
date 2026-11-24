@tool
extends RefCounted
## Render-thread only. Ordered markers delimit all stages of ONE
## callback. Read the finished query pool several frames later; never sync RD.
signal measured(times_ms: Dictionary)
const STAGES := ["Prepare", "Trace", "Gather", "Parents", "Deposit", "Merge", "Receiver", "Apply"]
const DIRECT_STAGES := ["DI temporal", "DI shade"]
const PERIOD_US := 250000
var _markers := PackedStringArray()
var _read_frame := -1
var _next_sample := 0
var _pending := false
var _issued_frame := -1
var _stages := STAGES

func _init() -> void:
	# New namespace on each profiling session: in-flight samples from a disabled
	# effect, another viewport session or a previous scene cannot be mixed in.
	var prefix := "SplitRC/%s/" % get_instance_id()
	_markers.append(prefix + "Begin")
	for stage: String in STAGES + DIRECT_STAGES:
		_markers.append(prefix + stage)

func begin(rd: RenderingDevice, direct := false) -> bool:
	var frame := rd.get_captured_timestamps_frame()
	if _read_frame == frame:
		return false
	_read_frame = frame
	if _pending:
		_read_completed(rd)
		if _pending and frame - _issued_frame < 16:
			return false # at most one outstanding sample; retry if a result was lost
	var now := Time.get_ticks_usec()
	if now < _next_sample:
		return false
	_next_sample = now + PERIOD_US
	_issued_frame = frame
	_stages = STAGES + DIRECT_STAGES if direct else STAGES
	_pending = true
	rd.capture_timestamp(_markers[0])
	return true

func end_stage(rd: RenderingDevice, stage: int) -> void:
	rd.capture_timestamp(_markers[stage + 1])

func _read_completed(rd: RenderingDevice) -> void:
	var next := 0
	var times := {}
	var prev_cpu := 0
	var prev_gpu := 0
	for i in rd.get_captured_timestamps_count():
		if rd.get_captured_timestamp_name(i) != _markers[next]:
			continue
		var cpu := rd.get_captured_timestamp_cpu_time(i)
		var gpu := rd.get_captured_timestamp_gpu_time(i)
		if next > 0:
			# Godot 4.7 RD stores CPU ticks in us; both Vulkan and D3D12
			# timestamp_query_result_to_time return ns (as in RendererViewport).
			times[_stages[next-1]] = Vector2((cpu-prev_cpu)/1000.0, (gpu-prev_gpu)/1e6 if prev_gpu > 0 and gpu >= prev_gpu else -1.0)
		prev_cpu = cpu
		prev_gpu = gpu
		next += 1
		if next == _stages.size()+1:
			_pending = false
			measured.emit(times)
			return
