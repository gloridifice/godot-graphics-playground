extends SceneTree
## Compare actual Forward+ output at identical poses. A frozen noise pattern
## passes a frame-difference test but fails the independent all-light reference.
const Scene := preload("res://scenes/sponza_restir_di.tscn")
const RC := preload("res://addons/split_radiance_cascades/split_radiance_cascades.gd")

class Errors:
	var histogram := PackedInt64Array()
	func _init() -> void:
		histogram.resize(256)
	func add(a: Image, b: Image) -> void:
		var x := a.get_data()
		var y := b.get_data()
		for i in range(0,x.size(),3):
			var error := maxi(absi(x[i]-y[i]),maxi(absi(x[i+1]-y[i+1]),absi(x[i+2]-y[i+2])))
			histogram[error] += 1
	func report(label: String) -> Vector3:
		var total := 0
		var squares := 0
		var peak := 0
		for e in 256:
			total += histogram[e]
			squares += e*e*histogram[e]
			if histogram[e]: peak = e
		var cumulative := 0
		var p99 := 0
		while p99 < peak:
			cumulative += histogram[p99]
			if cumulative >= 0.99*total: break
			p99 += 1
		var rms := sqrt(float(squares)/total)
		print("%s: RMS %.4f, P99 %d, max %d (RGB8 max channel, %d pixels)" % [label,rms,p99,peak,total])
		return Vector3(rms,p99,peak)

var failures := 0
var output := ""
var gi: RC
var camera: Camera3D
var lamps: Node3D

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var rd := RenderingServer.get_rendering_device()
	var hardware := "--hardware" in OS.get_cmdline_user_args()
	if not rd or RenderingServer.get_current_rendering_method() != "forward_plus" or (hardware and not rd.has_feature(RenderingDevice.SUPPORTS_RAYTRACING_PIPELINE)):
		push_error("Requested Forward+ graphics device unavailable")
		quit(2)
		return
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--capture="):
			output = arg.trim_prefix("--capture=")
			DirAccess.make_dir_recursive_absolute(output)
	root.unfocusable = true
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.size = Vector2i(1280,720)
	root.use_taa = false
	var scene := Scene.instantiate()
	gi = scene.get_node("WorldEnvironment/SplitRadianceCascades")
	gi.prefer_hardware_trace = hardware
	gi.view = RC.View.DIRECT_ONLY
	gi.direct_mode = RC.DirectMode.ALL_LIGHTS
	camera = scene.get_node("Camera3D")
	lamps = scene.get_node("Subject/PointLights")
	scene.get_node("HUD").hide()
	root.add_child(scene)
	current_scene = scene
	camera.set_process(false) # Replay exact transforms without the interactive fly controller.
	var reference := await _image(20)
	_save(reference,"reference")
	lamps.hide()
	var dark := await _image(4)
	lamps.show()
	_check(_difference("Illumination from plugin lights",reference,dark).x > 20, "many-light fixture illuminates the arcade")
	# With one light the reservoir's normalized estimate must be the exact shadowed RGB,
	# including immediately after changing only its indirect multiplier.
	var amber := lamps.get_node("Amber1") as ReSTIRPointLight3D
	for light in lamps.get_children(): light.visible = light == amber
	var one := await _image(3)
	_check(_difference("Single lamp vs off",one,dark).x > 5, "single-lamp normalization has a lit receiver")
	amber.indirect_energy = 0.0
	gi.direct_mode = RC.DirectMode.RAW_RESTIR
	_check(_difference("Single lamp ReSTIR vs reference",await _image(4),one).z <= 1,
			"normalized raw ReSTIR matches one light and DI is independent of indirect energy")
	amber.indirect_energy = 1.0
	for light in lamps.get_children(): light.show()
	var single_frame_error := 0.0
	for mode in [RC.DirectMode.SINGLE_FRAME_RIS,RC.DirectMode.RAW_RESTIR]:
		gi.direct_mode = mode
		var raw := await _image(8)
		var name := "single-frame-ris" if mode == RC.DirectMode.SINGLE_FRAME_RIS else "raw-restir"
		_save(raw,name)
		var error := _difference(name,raw,reference).x
		if mode == RC.DirectMode.SINGLE_FRAME_RIS:
			single_frame_error = error
			_check(error > 2, "stochastic control exposes visible sample noise")
		else:
			_check(error < 0.9*single_frame_error, "spatiotemporal reuse reduces raw error before visibility reconstruction")

	gi.direct_mode = RC.DirectMode.RESTIR
	var last := await _image(1)
	var spatial := Errors.new()
	var flicker := Errors.new()
	spatial.add(last,reference)
	for i in 24:
		var frame := await _image(1)
		spatial.add(frame,reference)
		flicker.add(frame,last)
		last = frame
	_save(last,"restir-di")
	_check(spatial.report("Static DI vs reference").z <= 2, "every static DI pixel agrees with the reference")
	_check(flicker.report("Static DI consecutive frames").z <= 2, "static DI has no visible flicker")

	var start := camera.transform
	var path_reference := await _motion(RC.DirectMode.ALL_LIGHTS,start)
	var moving := await _motion(RC.DirectMode.RESTIR,start)
	var travel := Errors.new()
	for i in moving.size(): travel.add(moving[i],path_reference[i])
	_check(travel.report("Moving camera, moving / removed light vs reference").z <= 3,
			"disocclusion, shadow movement and light removal follow the current pose")

	gi.view = RC.View.INDIRECT_ONLY
	var indirect := await _image(72)
	lamps.hide()
	dark = await _image(16)
	_check(_difference("Plugin light bounce",indirect,dark).x > 2, "plugin light reaches SRC's world-space hit shader")
	lamps.show()
	gi.view = RC.View.COMPOSITE
	last = await _image(120)
	_save(last,"composite")
	var combined := Errors.new()
	for i in 16:
		var frame := await _image(1)
		combined.add(last,frame)
		last = frame
	var composite_noise := combined.report("Composite including SRC consecutive frames")
	_check(composite_noise.y <= 1 and composite_noise.z <= 3,"settled composite is stable across consecutive frames")
	# Replay from the same GI sampling phase so true lighting changes on the route
	# are shared by both images. This also exercises history release on a light edit.
	gi.enabled = false
	gi.enabled = true
	path_reference = await _motion(RC.DirectMode.ALL_LIGHTS,start)
	gi.enabled = false
	gi.enabled = true
	moving = await _motion(RC.DirectMode.RESTIR,start)
	var composite_travel := Errors.new()
	for i in moving.size(): composite_travel.add(moving[i],path_reference[i])
	var replay := composite_travel.report("Composite motion vs all-light replay")
	_check(replay.x <= 1 and replay.y <= 2, "direct and bounce track the same moving-light reference")
	print("Sponza ReSTIR DI: %d failure(s)" % failures)
	quit(1 if failures else 0)

func _motion(mode: RC.DirectMode, start: Transform3D) -> Array[Image]:
	var lamp := lamps.get_node("Amber1") as ReSTIRPointLight3D
	var origin := lamp.position
	gi.direct_mode = mode
	await _image(4)
	var images: Array[Image] = []
	for i in 12:
		var travel := maxi(0,i-3)
		camera.transform = Transform3D(Basis(Vector3.UP,travel*0.024) * start.basis,
				start.origin + Vector3(travel*0.24,0.0,sin(travel*0.25)*1.25))
		camera.reset_physics_interpolation()
		lamp.position = origin + Vector3(0.0,0.0,i*0.18)
		lamp.visible = i < 6 or i > 8
		# Apply the light change on the main thread, then capture the first submitted pose.
		await process_frame
		images.append(await _image(1))
	camera.transform = start
	camera.reset_physics_interpolation()
	lamp.position = origin
	lamp.show()
	return images

func _image(frames: int) -> Image:
	for i in frames: await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	image.convert(Image.FORMAT_RGB8)
	return image

func _difference(label: String, a: Image, b: Image) -> Vector3:
	var errors := Errors.new()
	errors.add(a,b)
	return errors.report(label)

func _save(image: Image, label: String) -> void:
	if not output.is_empty(): image.save_png(output.path_join(label+".png"))

func _check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error(message)
