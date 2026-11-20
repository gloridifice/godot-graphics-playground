extends "res://tools/profile_sponza_src.gd"
## Copied into the isolated project. Quality captures and timing never overlap.
var gi: SplitRadianceCascades
var cam: Camera3D
var leaf: OmniLight3D
var origin: Transform3D
var dest := OS.get_environment("SRC_STUDY_OUT")
var variant := OS.get_environment("SRC_STUDY_CASE")

func _run() -> void:
	var rd := RenderingServer.get_rendering_device()
	if not rd or not rd.has_feature(RenderingDevice.SUPPORTS_RAYTRACING_PIPELINE): push_error("requires hardware RT"); quit(2); return
	root.unfocusable = true; root.size = Vector2i(1280,720); root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	var job := String(OS.get_cmdline_user_args()[0])
	var packed: PackedScene = load("res://scenes/sponza_temporal_preview.tscn") if job == "settle" else Preview
	var scene := packed.instantiate(); gi = scene.get_node("WorldEnvironment/SplitRadianceCascades")
	if job == "settle": # Check the user-facing scene itself, before the harness can override it.
		var start: Camera3D = scene.get_node("Camera3D")
		var marker: Marker3D = scene.get_node("Views/Arcade")
		if not is_equal_approx(gi.history_retention,0.995) or not start.transform.is_equal_approx(marker.transform) or not gi.trace_proxy_root.is_empty() or not gi.prefer_hardware_trace:
			push_error("preview does not start with the measured 0.995 / full mesh / Arcade inputs"); quit(2); return
	gi.prefer_hardware_trace = true; gi.trace_proxy_root = NodePath(); gi.multi_bounce = true
	gi.ray_stride = 2 if job == "reference" else 6
	gi.history_retention = 0.995 if variant.ends_with("995") else (0.99 if variant == "ctrl99" else 0.98)
	if variant.ends_with("995") and not is_equal_approx(gi.history_retention,0.995): push_error("study clamp not applied"); quit(2); return
	gi.view = SplitRadianceCascades.View.COMPOSITE
	root.add_child(scene); current_scene = scene; scene.get_node("HUD").hide(); gi.profile_stages = false
	cam = scene.get_node("Camera3D"); cam.process_mode = Node.PROCESS_MODE_DISABLED
	cam.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	origin = scene.get_node("Views/Arcade").global_transform; _pose(0)
	leaf = scene.get_node("Subject/GalleryLight/GalleryLight/GalleryLight")
	print("INPUTS ",rd.get_device_name()," ",job," / ",variant,"; stride ",gi.ray_stride,"; history ",gi.history_retention,"; multi ",gi.multi_bounce,"; omni lights ",scene.find_children("*","OmniLight3D",true,false).size(),"; leaf ",leaf.global_position)
	await _wait(12)
	if Vector2i(root.get_texture().get_size()) != root.size or root.scaling_3d_scale != 1.0: push_error("wrong viewport"); quit(2); return
	if variant.ends_with("995") and job == "quality":
		var kernels := {}
		for name in ["cascades", "hardware_trace", "screen_filter"]:
			var path := "res://addons/split_radiance_cascades/shaders/%s.glsl" % name
			if not ResourceLoader.exists(path): continue
			var file: RDShaderFile = load(path)
			var spirv := file.get_spirv()
			var code := spirv.bytecode_raygen if name == "hardware_trace" else spirv.bytecode_compute
			if code.is_empty(): push_error("empty kernel: "+name); quit(2); return
			var hash_ctx := HashingContext.new(); hash_ctx.start(HashingContext.HASH_SHA256); hash_ctx.update(code)
			kernels[name] = hash_ctx.finish().hex_encode()
		print("KERNELS ",JSON.stringify(kernels))
	match job:
		"reference": await _reference()
		"quality": await _quality()
		"timing": await _timing()
		"settle": await _settle()
		_: push_error("unknown measurement"); quit(2); return
	scene.queue_free(); await process_frame; await process_frame; print("STUDY DONE"); quit()

func _pose(t: float) -> void:
	var xf := origin; xf.origin += origin.basis.x * 0.40 * t
	cam.global_transform = xf; cam.reset_physics_interpolation()

func _move_light() -> void:
	leaf.global_position += Vector3(-2,-1.5,-2)

func _wait(n: int) -> void:
	for i in n: await RenderingServer.frame_post_draw

func _pixels() -> PackedByteArray:
	var im := root.get_texture().get_image(); im.convert(Image.FORMAT_RGB8)
	im.resize(320,180,Image.INTERPOLATE_NEAREST)
	return im.get_data()

func _frames(label: String, n: int) -> void:
	var f := FileAccess.open(dest.path_join(label+".rgb"),FileAccess.WRITE)
	for i in n:
		await RenderingServer.frame_post_draw
		f.store_buffer(_pixels())
	f.close()

func _reference() -> void:
	gi.enabled = false; await _wait(16); await _frames("native",12)
	gi.enabled = true
	for i in 9:
		_pose(float(i)/8); await _wait(480); await _frames("pose%d" % i,24)
	_pose(0); _move_light(); await _wait(512); await _frames("moved",24)
	gi.enabled = false; await _wait(12); await _frames("native_moved",12)
	# Negative control: no temporal GI, same movement vs held poses. A one-frame
	# camera/readback offset would otherwise masquerade as trails for every algorithm.
	leaf.global_position -= Vector3(-2,-1.5,-2)
	_pose(0); await _wait(12)
	var f := FileAccess.open(dest.path_join("native_motion.rgb"),FileAccess.WRITE)
	for i in range(1,33):
		_pose(float(i)/32); await RenderingServer.frame_post_draw
		if i%4 == 0: f.store_buffer(_pixels())
	f.close()
	for i in range(1,9):
		_pose(float(i)/8); await _wait(16); await _frames("native_pose%d" % i,1)

func _quality() -> void:
	await _wait(512); await _frames("static",120)
	var f := FileAccess.open(dest.path_join("motion.rgb"),FileAccess.WRITE)
	for i in range(1,33):
		_pose(float(i)/32); await RenderingServer.frame_post_draw
		if i%4 == 0: f.store_buffer(_pixels())
	f.close()
	_pose(0); await _wait(512); await _frames("before",24)
	# Change in process_frame (before tree processing) so frame 1 includes the edit.
	await process_frame; _move_light(); await _frames("response",96)
	await _wait(512); await _frames("plateau",24)

func _settle() -> void:
	# Runtime reset, not an editor UI capture. Compare the actual 64th draw with
	# the same variant long after warm-up; collect another 120-frame noise window.
	gi.enabled = false; await _wait(12); await process_frame; gi.enabled = true
	await _wait(64)
	var f := FileAccess.open(dest.path_join("draw64.rgb"),FileAccess.WRITE); f.store_buffer(_pixels()); f.close()
	await _wait(2048-64)
	var png_error := root.get_texture().get_image().save_png(dest.path_join("arcade.png"))
	if png_error != OK: push_error("could not save settled screenshot"); return
	await _frames("late",120)

func _timing() -> void:
	var vp := root.get_viewport_rid(); RenderingServer.viewport_set_measure_render_time(vp,true)
	gi.timings_updated.connect(_sample); gi.profile_stages = true
	var record := {}
	for size: Vector2i in [Vector2i(1280,720),Vector2i(1920,1080)]:
		root.size = size; var until := Time.get_ticks_msec()+2200; var n := 0
		while n<256 or Time.get_ticks_msec()<until: await RenderingServer.frame_post_draw; n+=1
		if Vector2i(root.get_texture().get_size())!=size or root.scaling_3d_scale!=1.0: push_error("wrong timing size"); return
		_rows.clear(); _capturing = true; until = Time.get_ticks_msec()+18000
		while _rows.get("SRC total",[]).size()<16 and Time.get_ticks_msec()<until:
			await RenderingServer.frame_post_draw
			var ms := RenderingServer.viewport_get_measured_render_time_gpu(vp)
			if ms>0: _record("Viewport",ms)
		_capturing = false
		if _rows.get("SRC total",[]).size()<16 or not _rows.has("Viewport"): push_error("missing timestamps"); return
		record[str(size.y)] = _rows.duplicate(true)
	var f := FileAccess.open(dest.path_join("timestamps.json"),FileAccess.WRITE); f.store_string(JSON.stringify(record)); f.close()
