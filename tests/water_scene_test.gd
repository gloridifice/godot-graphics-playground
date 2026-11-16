extends SceneTree

# Owner: actual scene/renderer wiring and asset edit lifecycle. Math invariants
# are owned by water_gpu_test; here real pixels must change without a solver reset.
var failures := 0
var _report: Dictionary

func _initialize() -> void:
	_run.call_deferred()

func _check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error(message)

func _wait_ready(water: WaterBody3D) -> bool:
	for i in 300:
		if water.gpu != null and water.gpu.ready:
			return true
		await process_frame
	_check(false, "Water scene GPU readiness: " + water.status)
	return false

func _snapshot(water: WaterBody3D) -> Dictionary:
	_report = {}
	water.gpu.snapshot(func(report: Dictionary): _report = report)
	for i in 300:
		if not _report.is_empty():
			return _report
		await process_frame
	_check(false, "Water diagnostic snapshot must complete")
	return {}

func _capture() -> Image:
	for i in 3:
		await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()

func _difference(a: Image, b: Image) -> float:
	var sum := 0.0
	var count := 0
	for y in range(120, a.get_height(), 8):
		for x in range(0, a.get_width(), 8):
			var av := a.get_pixel(x,y)
			var bv := b.get_pixel(x,y)
			sum += absf(av.r-bv.r)+absf(av.g-bv.g)+absf(av.b-bv.b)
			count += 3
	return sum / maxi(count, 1)

func _patch(camera: Camera3D, image: Image, world: Vector3) -> Color:
	var point := Vector2i(camera.unproject_position(world))
	var color := Color(0,0,0,0)
	for y in range(-2,3):
		for x in range(-2,3):
			color += image.get_pixel(clampi(point.x+x,0,image.get_width()-1),clampi(point.y+y,0,image.get_height()-1)) / 25.0
	return color

func _run() -> void:
	var scene := load("res://scenes/water_playground.tscn").instantiate() as Node3D
	var water := scene.get_node("Water") as WaterBody3D
	var fft := scene.get_node("Water/FFT") as FFTDeformer3D
	var swe := scene.get_node("Water/SWE") as SWEDeformer3D
	# Never edit the user's reusable preset assets in a verification process.
	water.surface_settings = water.surface_settings.duplicate()
	water.material_settings = water.material_settings.duplicate()
	fft.settings = fft.settings.duplicate()
	swe.settings = swe.settings.duplicate()
	swe.bake_settings = swe.bake_settings.duplicate()
	water.paused = true
	root.add_child(scene)
	current_scene = scene
	if not await _wait_ready(water):
		scene.free()
		quit(1)
		return
	var camera := scene.get_node("Camera3D") as Camera3D
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 80.0
	camera.position = Vector3(0,100,0)
	camera.look_at(Vector3.ZERO,Vector3.BACK)
	var before := await _snapshot(water)
	_check(before.simulated_time == 0.0, "Paused startup must not integrate even one physics step")
	var gpu := water.gpu
	var shaded := await _capture()
	water.visible = false
	var bare := await _capture()
	water.visible = true
	_check(_difference(shaded,bare) > 0.005, "Actual water shader must alter the scene, not merely publish unused GPU textures")
	var rock_water := _patch(camera,shaded,Vector3(3,1.3,1))
	var rock_bare := _patch(camera,bare,Vector3(3,1.3,1))
	_check(Vector3(rock_water.r-rock_bare.r,rock_water.g-rock_bare.g,rock_water.b-rock_bare.b).length() < 0.03, "Emergent rock top must occlude the water instead of receiving a water blanket")
	water.material_settings.debug_view = 1
	var depth_image := await _capture()
	var deep := _patch(camera,depth_image,Vector3(-12,0,12)).r
	var shallow := _patch(camera,depth_image,Vector3(10,0,12)).r
	_check(deep > shallow + 0.1, "Rendered depth must come from the sloping baked bed and actual SWE texture")
	water.material_settings.debug_view = 0
	water.material_settings.extinction = Vector3(1.5,1.5,1.5)
	water.material_settings.scattering = Vector3.ZERO
	var absorbed := await _capture()
	_check(_difference(shaded,absorbed) > 0.01, "Material resource edits must reach real optical absorption")
	water.surface_settings.resolution = 96
	fft.settings.choppiness = 0.2
	swe.settings.blend_depth = 1.3
	await _capture()
	var after := await _snapshot(water)
	_check(water.gpu == gpu and after.state == before.state and after.simulated_time == 0.0, "Material, mesh density, choppiness and display blend edits must preserve paused GPU state")
	water.paused = false
	for i in 10:
		await process_frame
	water.paused = true
	after = await _snapshot(water)
	_check(after.simulated_time > 0.0 and after.faults == 0, "Real scene unpause advances the coupled solver")
	var paused := await _snapshot(water)
	await _capture()
	after = await _snapshot(water)
	_check(after.state == paused.state and after.simulated_time == paused.simulated_time, "Pause freezes actual state and FFT clock together")
	gpu = water.gpu
	swe.settings.second_order = true
	for i in 3:
		await process_frame
	await _wait_ready(water)
	after = await _snapshot(water)
	_check(water.gpu != gpu and absf(after.simulated_time - paused.simulated_time) < 0.000001, "Physical parameter rebuild must initialize SWE from the current FFT phase without CPU clock readback")
	swe.position.x += 1.0
	for i in 3:
		await process_frame
	_check(water.gpu == null and not swe.is_bake_current(), "Region movement must stop rendering/simulation from a stale heightfield")
	swe.bake()
	await _wait_ready(water)
	after = await _snapshot(water)
	_check(after.simulated_time == 0.0, "Successful explicit rebake must rebuild from the initial FFT")
	gpu = water.gpu
	var retired: WeakRef = weakref(gpu)
	water.reset()
	await process_frame
	await _wait_ready(water)
	_check(water.gpu != gpu, "Explicit reset must rebuild even when all parameter signatures are unchanged")
	gpu = null
	for i in 3:
		await process_frame
	_check(retired.get_ref() == null, "Retired GPU owners must be collectable after reset, not retained by their own initialization signal")
	root.remove_child(scene)
	for i in 2:
		await process_frame
	root.add_child(scene)
	await _wait_ready(water)
	after = await _snapshot(water)
	_check(after.simulated_time == 0.0 and swe.is_bake_current(), "Re-entering the same scene must recreate GPU resources and bake current CSG")
	scene.free()
	for i in 5:
		await process_frame
	await _optical_reference()
	print("Water scene/render/lifecycle: %d failure(s)" % failures)
	quit(0 if failures == 0 else 1)

func _optical_reference() -> void:
	# Flat water over a known two-meter column: independent Beer-Lambert oracle.
	var scene := Node3D.new()
	root.add_child(scene)
	current_scene = scene
	var world := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color.BLACK
	environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	world.environment = environment
	scene.add_child(world)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(10,10)
	ground.mesh = plane
	ground.position.y = -2.0
	var ground_material := StandardMaterial3D.new()
	ground_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ground_material.albedo_color = Color(0.3,0.5,0.7)
	ground.material_override = ground_material
	scene.add_child(ground)
	var water := WaterBody3D.new()
	water.surface_settings.size = Vector2(8,8)
	water.surface_settings.resolution = 8
	water.material_settings.refractive_index = 1.0
	water.material_settings.refraction_enabled = false
	water.material_settings.extinction = Vector3(0.4,0.2,0.0)
	water.material_settings.scattering = Vector3(0.02,0.01,0.03)
	water.paused = true
	scene.add_child(water)
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 6.0
	camera.position = Vector3(0,10,0)
	scene.add_child(camera)
	camera.look_at(Vector3.ZERO,Vector3.BACK)
	camera.current = true
	if not await _wait_ready(water):
		scene.free()
		return
	water.visible = false
	var bare := await _capture()
	water.visible = true
	var image := await _capture()
	var background := _patch(camera,bare,Vector3.ZERO).srgb_to_linear()
	var actual := _patch(camera,image,Vector3.ZERO).srgb_to_linear()
	var expected := Vector3.ZERO
	var b := Vector3(background.r,background.g,background.b)
	for k in 3:
		var sigma := water.material_settings.extinction[k]
		var transmission := exp(-sigma*2.0)
		expected[k] = b[k]*transmission+water.material_settings.scattering[k]*((1.0-transmission)/sigma if sigma > 0.0 else 2.0)
	var error := Vector3(actual.r,actual.g,actual.b).distance_to(expected)
	_check(error < 0.015, "Actual shader must integrate a 2 m path in linear RGB, including zero extinction; error %.6f" % error)
	scene.free()
	for i in 3:
		await process_frame
