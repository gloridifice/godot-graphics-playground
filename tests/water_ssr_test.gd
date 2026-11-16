extends SceneTree

# Owner: native compatibility and migrated reflection against real visible opaque
# geometry. A positive native mirror control prevents a meaningless SSR no-op pass.
var failures := 0
func _initialize() -> void:
	_run.call_deferred()
func _check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error(message)
func _capture() -> Image:
	for i in 6:
		await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()
func _red(camera: Camera3D,image: Image,world: Vector3) -> float:
	var p := Vector2i(camera.unproject_position(world))
	var sum := 0.0
	for z in range(-8,9):
		for x in range(-8,9):
			var color := image.get_pixel(clampi(p.x+x,0,image.get_width()-1),clampi(p.y+z,0,image.get_height()-1))
			sum += color.r-color.g
	return sum/289.0
func _run() -> void:
	var scene := Node3D.new()
	root.add_child(scene)
	current_scene = scene
	var world := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color.BLACK
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	environment.ssr_max_steps = 256
	world.environment = environment
	scene.add_child(world)
	var mirror := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(24,24)
	mirror.mesh = plane
	var material := StandardMaterial3D.new()
	material.albedo_color = Color.WHITE
	material.metallic = 1.0
	material.roughness = 0.02
	mirror.material_override = material
	scene.add_child(mirror)
	var target := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(1.5,2.0,1.0)
	target.mesh = box
	target.position = Vector3(0,1,0)
	var red := StandardMaterial3D.new()
	red.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	red.albedo_color = Color(1,0,0)
	target.material_override = red
	scene.add_child(target)
	var camera := Camera3D.new()
	camera.position = Vector3(0,3,7)
	scene.add_child(camera)
	camera.look_at(Vector3(0,0.5,0))
	camera.current = true
	var point := Vector3(0,0,2.4)
	environment.ssr_enabled = false
	var off := await _capture()
	environment.ssr_enabled = true
	var on := await _capture()
	var native_delta := _red(camera,on,point)-_red(camera,off,point)
	_check(native_delta>0.02,"Positive control: Godot native SSR must reflect the red opaque target on a native mirror; delta %.6f"%native_delta)
	mirror.visible = false
	var bottom := MeshInstance3D.new()
	bottom.mesh = plane
	bottom.position.y = -3.0
	var black := StandardMaterial3D.new()
	black.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	black.albedo_color = Color.BLACK
	bottom.material_override = black
	scene.add_child(bottom)
	var water := WaterBody3D.new()
	water.paused = true
	water.surface_settings.size = Vector2(24,24)
	water.surface_settings.resolution = 16
	water.material_settings.reflection_color = Color.BLACK
	water.material_settings.extinction = Vector3(4,4,4)
	water.material_settings.scattering = Vector3.ZERO
	water.material_settings.refraction_enabled = false
	scene.add_child(water)
	for i in 300:
		if water.gpu != null and water.gpu.ready:
			break
		await process_frame
	environment.ssr_enabled = false
	off = await _capture()
	environment.ssr_enabled = true
	on = await _capture()
	var water_delta := absf(_red(camera,on,point)-_red(camera,off,point))
	_check(water_delta<0.003,"Current screen-reading/custom optical water must not be misreported as automatically native-SSR compatible; delta %.6f"%water_delta)
	print("Native SSR mirror delta=",native_delta,"; current water native delta=",water_delta)
	# Now enable the migrated water-owned SSR, leaving the native environment off.
	environment.ssr_enabled = false
	var gpu := water.gpu
	water.ssr_settings.max_steps = 512
	water.ssr_settings.enabled = true
	water.material_settings.debug_view = 11
	var reflected := await _capture()
	var reflected_red := _red(camera,reflected,point)
	_check(reflected_red>0.1,"Migrated SSR must hit visible above-water opaque geometry; red %.6f"%reflected_red)
	water.material_settings.debug_view = 0
	var composed := await _capture()
	_check(_red(camera,composed,point)>0.03,"SSR hit must enter Fresnel-weighted water composition, not only a debug texture")
	# Orthographic rays must remain parallel, not point from every fragment to eye.
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 8.0
	water.material_settings.debug_view = 11
	var ortho := await _capture()
	_check(_red(camera,ortho,point)>0.1,"Custom SSR must reconstruct orthographic scene depth and reflected view rays")
	camera.projection = Camera3D.PROJECTION_PERSPECTIVE
	water.ssr_settings.strength = 0.0
	var zero := await _capture()
	_check(absf(_red(camera,zero,point))<0.003,"Zero SSR strength must return environment fallback, without retaining a stale hit")
	water.ssr_settings.strength = 1.0
	water.ssr_settings.maximum_distance = 1.0
	var short_ray := await _capture()
	_check(absf(_red(camera,short_ray,point))<0.003,"Maximum distance must bound actual reflection hits")
	water.ssr_settings.maximum_distance = 100.0
	water.ssr_settings.max_steps = 8
	var exhausted := await _capture()
	_check(absf(_red(camera,exhausted,point))<0.003,"Exhausted traversal budget must miss instead of stretching or retaining a prior hit")
	water.ssr_settings.max_steps = 512
	target.visible = false
	var miss := await _capture()
	_check(absf(_red(camera,miss,point))<0.003,"Missing/offscreen geometry must not fabricate a reflection")
	water.material_settings.debug_view = 0
	water.material_settings.reflection_color = Color(0,0,1)
	var fallback := await _capture()
	var pixel := Vector2i(camera.unproject_position(point))
	_check(fallback.get_pixelv(pixel).b>0.05,"SSR miss must preserve the configured environment reflection")
	target.visible = true
	red.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	red.albedo_color = Color(1,0,0,0.5)
	water.material_settings.debug_view = 11
	var transparent := await _capture()
	_check(absf(_red(camera,transparent,point))<0.003,"Transparent targets outside the opaque depth/color pass must not become false SSR hits")
	_check(water.gpu == gpu,"SSR activation, tracing and display controls must not rebuild water simulation")
	print("Migrated SSR reflection red=",reflected_red)
	scene.free()
	for i in 5:
		await process_frame
	print("Water SSR: %d failure(s)"%failures)
	quit(0 if failures==0 else 1)
