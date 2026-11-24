extends PanelContainer
## Preview-only overlay. Viewport CPU is render work, not delta or game-thread time.
const RC := preload("split_radiance_cascades.gd")
const Profiler := preload("stage_profiler.gd")
@export var cascades: RC
var _viewport: RID
var _sample := {}
var _received := -1
var _refresh_at := 0

func _ready() -> void:
	_viewport = get_viewport().get_viewport_rid()
	if cascades:
		cascades.timings_updated.connect(_receive)
	visibility_changed.connect(_measurement)
	_measurement()
	%Stages.text = "Pass  /  ms\nViewport\nSRC total\n" + "\n".join(Profiler.STAGES)

func _measurement() -> void:
	if not _viewport.is_valid():
		return
	var measuring := is_visible_in_tree()
	RenderingServer.viewport_set_measure_render_time(_viewport, measuring)
	if cascades:
		cascades.profile_stages = measuring
	set_process(measuring)
	_refresh_at = 0

func _receive(times_ms: Dictionary) -> void:
	_sample = times_ms
	_received = Time.get_ticks_msec()
	if times_ms.is_empty():
		_refresh_at = 0

func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec()
	if now < _refresh_at:
		return
	_refresh_at = now + 250
	var vp_cpu := RenderingServer.viewport_get_measured_render_time_cpu(_viewport)
	var vp_gpu := RenderingServer.viewport_get_measured_render_time_gpu(_viewport)
	var cpu := PackedStringArray(["CPU", _ms(vp_cpu) if vp_cpu > 0.0 else "—"])
	var gpu := PackedStringArray(["GPU", _ms(vp_gpu) if vp_gpu > 0.0 else "—"])
	var valid := cascades and cascades.enabled and not _sample.is_empty() and now - _received < 2000
	var total := Vector2.ZERO
	var gpu_valid := valid
	var stages := Profiler.STAGES + Profiler.DIRECT_STAGES if _sample.has("DI shade") else Profiler.STAGES
	%Stages.text = "Pass  /  ms\nViewport\nSRC total\n" + "\n".join(stages)
	for stage: String in stages:
		var t: Vector2 = _sample[stage] if valid else Vector2(-1,-1)
		cpu.append(_ms(t.x))
		gpu.append(_ms(t.y))
		total += t
		gpu_valid = gpu_valid and t.y >= 0.0
	cpu.insert(2, _ms(total.x) if valid else "—")
	gpu.insert(2, _ms(total.y) if gpu_valid else "—")
	%Cpu.text = "\n".join(cpu)
	%Gpu.text = "\n".join(gpu)

func _ms(value: float) -> String:
	return "%.3f" % value if value >= 0.0 else "—"

func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_P:
		visible = not visible
		get_viewport().set_input_as_handled()

func _exit_tree() -> void:
	if _viewport.is_valid():
		RenderingServer.viewport_set_measure_render_time(_viewport, false)
		_viewport = RID()
	if is_instance_valid(cascades):
		cascades.profile_stages = false
