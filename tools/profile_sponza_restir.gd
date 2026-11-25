extends SceneTree
## GPU-only timings for the README cover scene. Run with --rendering-driver vulkan.
const Scene := preload("res://scenes/sponza_restir_di.tscn")
const Size := Vector2i(1600, 900)
var viewport_ms: Array[float] = []
var gi_ms: Array[float] = []
var di_ms: Array[float] = []
var shared_ms: Array[float] = []

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	if RenderingServer.get_current_rendering_driver_name() != "vulkan" or RenderingServer.get_current_rendering_method() != "forward_plus":
		push_error("Requires Forward+ on Vulkan")
		quit(2)
		return
	root.unfocusable = true
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.size = Size
	var scene := Scene.instantiate()
	var gi: SplitRadianceCascades = scene.get_node("WorldEnvironment/SplitRadianceCascades")
	gi.multi_bounce = true
	root.add_child(scene)
	current_scene = scene
	scene.get_node("Camera3D").process_mode = Node.PROCESS_MODE_DISABLED
	scene.get_node("HUD").hide()
	gi.profile_stages = true
	var vp := root.get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(vp, true)
	for i in 240:
		await RenderingServer.frame_post_draw
	if Vector2i(root.get_texture().get_size()) != Size or root.scaling_3d_scale != 1.0:
		push_error("Unexpected render resolution")
		quit(2)
		return
	gi.timings_updated.connect(_sample)
	var deadline := Time.get_ticks_msec() + 30000
	while di_ms.size() < 64 and Time.get_ticks_msec() < deadline:
		await RenderingServer.frame_post_draw
		var ms := RenderingServer.viewport_get_measured_render_time_gpu(vp)
		if ms > 0: viewport_ms.append(ms)
	gi.timings_updated.disconnect(_sample)
	if di_ms.size() < 64 or viewport_ms.is_empty():
		push_error("Insufficient completed GPU timestamps")
		quit(2)
		return
	for row in [["Viewport", viewport_ms], ["GI", gi_ms], ["DI", di_ms], ["Receiver + Apply", shared_ms]]:
		var data: Array = row[1]
		data.sort()
		print("%s: median %.3f ms, p95 %.3f ms (n=%d)" % [row[0], data[ceili(data.size()*0.5)-1], data[ceili(data.size()*0.95)-1], data.size()])
	quit()

func _sample(times: Dictionary) -> void:
	if not times.has("DI shade"): return
	for time: Vector2 in times.values():
		if time.y < 0: return
	var indirect := 0.0
	for stage in ["Prepare", "Trace", "Gather", "Parents", "Deposit", "Merge"]:
		indirect += times[stage].y
	gi_ms.append(indirect)
	di_ms.append(times["DI temporal"].y + times["DI shade"].y)
	shared_ms.append(times.Receiver.y + times.Apply.y)
