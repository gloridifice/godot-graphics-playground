extends SceneTree

# Real Forward+ rendering: terrain exclusion, soft top, world-space continuity and drift.
var failures := 0

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var scene := Node3D.new()
	root.add_child(scene)
	current_scene = scene
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color.BLACK
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	environment.volumetric_fog_enabled = true
	environment.volumetric_fog_density = 0.0
	environment.volumetric_fog_length = 16.0
	environment.volumetric_fog_temporal_reprojection_enabled = false
	var world := WorldEnvironment.new()
	world.environment = environment
	scene.add_child(world)
	_surface(scene, Vector3(16,0.2,16), Vector3(0,-0.1,0))
	var rock := _surface(scene, Vector3(2,1.0,6), Vector3(2,0.5,0))
	var box := HeightfieldFogBox.new()
	box.position = Vector3(0,-2,0)
	box.size = Vector3(12,6,12)
	box.source_root = NodePath("..")
	box.edge_fade = 1.0
	box.extinction = 0.8
	box.brightness = 1.0
	box.tint = Color.WHITE
	var preset := box.initialization
	preset.natural_mist_enabled = true
	preset.horizontal_top = true
	preset.base_height = 2.5
	preset.noise_amplitude = 0.0
	preset.detail_strength = 0.0
	preset.wind_speed = 0.0
	preset.top_softness = 0.1
	scene.add_child(box)
	box.bake()
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 8.0
	camera.position = Vector3(0,8,0)
	scene.add_child(camera)
	camera.look_at(Vector3.ZERO, Vector3.BACK)
	camera.current = true
	var image := await _capture()
	var low := _patch(camera, image, Vector3(-2,0,0))
	var high := _patch(camera, image, Vector3(2,1,0))
	_check(low > 0.05, "low terrain must contain visible mist")
	_check(high < low * 0.08, "rock above mist top must remain dry, not receive an equal-thickness blanket")
	preset.top_softness = 1.0
	image = await _capture()
	_check(_patch(camera, image, Vector3(-2,0,0)) < low * 0.9, "softer top must smoothly reduce integrated column density")
	rock.visible = false
	box.bake()
	# Regression: .tres noise controls must reach the rendered static AND GPU initial field.
	# Pause SWE before startup so physics cannot smooth away the compared initial shapes.
	preset.noise_amplitude = 0.6
	box.swe_paused = true
	for simulated in [false, true]:
		box.swe_enabled = simulated
		preset.noise_frequency = 0.13
		var coarse := await _capture()
		preset.noise_frequency = 0.83
		var fine := await _capture()
		_check(_difference(coarse, fine) > 0.002, "noise frequency changes actual mist, including paused SWE initialization: %s" % simulated)
	box.swe_enabled = false
	box.swe_paused = false
	preset.noise_amplitude = 0.3
	preset.noise_frequency = 0.5
	preset.detail_strength = 0.6
	preset.detail_scale = 0.5
	box.bake()
	var before := await _capture()
	var repeat := await _capture()
	_check(_difference(before,repeat) < 0.001, "zero wind must remain temporally stable")
	box.rotation.y = PI * 0.5
	box.bake()
	var rotated := await _capture()
	_check(_difference(before,rotated) < 0.004, "rotating a square box must not rotate world-space mist detail")
	preset.wind_speed = 1.0
	before = await _capture()
	await create_timer(1.0).timeout
	var moved := await _capture()
	_check(_difference(before,moved) > 0.001, "nonzero wind must advect the rendered mist")
	# End-to-end: actual SWE output must reach the fog shader through Texture2DRD,
	# including world-to-local impulse conversion for this rotated box.
	preset.wind_speed = 0.0
	preset.noise_amplitude = 0.0
	preset.detail_strength = 0.0
	box.swe_enabled = true
	for i in 120:
		await process_frame
	_check(box.swe_metrics().ready, "SWE initializes in the rendered box")
	var baseline := await _capture()
	var original := _patch(camera, baseline, Vector3(-2,0,0))
	box.disturb_mist(Vector3(-2,0,0))
	var disturbed := await _capture()
	_check(_patch(camera, disturbed, Vector3(-2,0,0)) < original * 0.8, "transported SWE thickness changes the actual fog rendering")
	box.swe_paused = true
	var frozen := await _capture()
	var still := await _capture()
	_check(_difference(frozen,still)<0.001,"pausing SWE freezes physical shape")
	preset.concentration = 0.25
	var faint := await _capture()
	_check(_difference(frozen, faint) > 0.002, "concentration remains a live visual control")
	preset.coverage = 0.0
	var clear := await _capture()
	_check(_patch(camera, clear, Vector3(-2,0,0)) < 0.002, "zero coverage leaves clear ground")
	preset.concentration = 1.0
	preset.coverage = 1.0
	var restored := await _capture()
	_check(_difference(frozen, restored) < 0.001, "density/coverage edits must preserve the disturbed paused SWE state")
	# Exercise disposal/recreation without stale GPU texture bindings.
	box.swe_enabled = false
	await _capture()
	box.swe_enabled = true
	await _capture()
	_check(box.swe_metrics().ready,"SWE can be recreated after disabling")
	print("Natural mist GPU: ", "PASS" if failures == 0 else "FAIL", " (basin/rock, soft top, zero wind, rotated box, drift, SWE texture/impulse/pause/recreate)")
	scene.queue_free()
	for i in 5:
		await process_frame
	quit(0 if failures == 0 else 1)

func _surface(parent: Node3D, size: Vector3, at: Vector3) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color.BLACK
	mesh.material = material
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.position = at
	parent.add_child(node)
	return node

func _capture() -> Image:
	for i in 24:
		await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()

func _patch(camera: Camera3D, image: Image, position: Vector3) -> float:
	var p := Vector2i(camera.unproject_position(position))
	var sum := 0.0
	for y in range(p.y-4,p.y+5):
		for x in range(p.x-4,p.x+5):
			sum += image.get_pixel(x,y).r
	return sum / 81.0

func _difference(a: Image, b: Image) -> float:
	var total := 0.0
	var count := 0
	for y in range(a.get_height()/4,a.get_height()*3/4,4):
		for x in range(a.get_width()/4,a.get_width()*3/4,4):
			total += absf(a.get_pixel(x,y).r - b.get_pixel(x,y).r)
			count += 1
	return total / count

func _check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		printerr("FAIL: ",message)
