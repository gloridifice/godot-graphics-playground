extends SceneTree
## Integration risk specific to this asset: a perfectly renderable Sponza can
## silently exceed the SRC snapshot budget. Inspect rendered light, not mesh counts.
const Preview := preload("res://scenes/sponza_src_preview.tscn")
var samples: Array[Dictionary] = []
var failures := 0

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	if not RenderingServer.get_rendering_device() or RenderingServer.get_current_rendering_method() != "forward_plus":
		push_error("Sponza preview test requires a real Forward+ viewport")
		quit(2)
		return
	root.unfocusable = true
	root.size = Vector2i(640,360)
	var scene := Preview.instantiate()
	root.add_child(scene)
	current_scene = scene
	var gi: SplitRadianceCascades = scene.get_node("WorldEnvironment/SplitRadianceCascades")
	gi.timings_updated.connect(func(times: Dictionary):
		if not times.is_empty(): samples.append(times))
	await _draw(45)
	for i in 180:
		if samples.size() >= 3: break
		await RenderingServer.frame_post_draw
	var on := root.get_texture().get_image()
	var vp := root.get_viewport_rid()
	var viewport_ms := Vector2(RenderingServer.viewport_get_measured_render_time_cpu(vp), RenderingServer.viewport_get_measured_render_time_gpu(vp))
	var timed := Vector2.ZERO
	if not samples.is_empty():
		for t: Vector2 in samples.back().values(): timed += t
	# The viewport measures independently with the engine's unit conversion.
	# Loose ratios catch an ns/us/ms error without imposing a hardware budget.
	_check(samples.size() >= 3 and timed.x > viewport_ms.x*0.002 and timed.x < viewport_ms.x*5 and timed.y > viewport_ms.y*0.01 and timed.y < viewport_ms.y*5,
		"live stage timings in ms: SRC %s, viewport %s (CPU, GPU)" % [timed,viewport_ms])
	_key(KEY_G)
	await _draw(5)
	var off := root.get_texture().get_image()
	var lift := 0.0
	var count := 0
	for y in range(on.get_height()/2, on.get_height()*9/10, 3):
		for x in range(on.get_width()/6, on.get_width()*2/3, 3):
			lift += on.get_pixel(x,y).get_luminance() - off.get_pixel(x,y).get_luminance()
			count += 1
	_check(not gi.enabled and lift/count > 0.004, "Sponza geometry receives measurable indirect light (luma lift %.4f)" % (lift/count))
	_key(KEY_G)
	_key(KEY_P)
	samples.clear()
	await _draw(45)
	_check(samples.is_empty(), "hiding the HUD stops SRC timestamp sampling")
	_key(KEY_P)
	for i in 120:
		if not samples.is_empty(): break
		await RenderingServer.frame_post_draw
	_check(not samples.is_empty(), "showing the HUD resumes live completed samples")
	print("Sponza SRC preview: %d failure(s)" % failures)
	quit(1 if failures else 0)

func _draw(frames: int) -> void:
	for i in frames: await RenderingServer.frame_post_draw

func _key(code: Key) -> void:
	for down: bool in [true, false]:
		var e := InputEventKey.new()
		e.keycode = code
		e.pressed = down
		root.push_input(e, true)

func _check(ok: bool, message: String) -> void:
	if ok:
		print("PASS: ", message)
	else:
		failures += 1
		push_error(message)
