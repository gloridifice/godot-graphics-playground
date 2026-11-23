extends SceneTree
## Ground contact, actual light on architecture and input mode handoff, in the real level.
const Walk := preload("res://scenes/sponza_torch_walk.tscn")
const Player := preload("res://scenes/sponza_walk/player.gd")
var failures := 0

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	if not RenderingServer.get_rendering_device() or RenderingServer.get_current_rendering_method() != "forward_plus":
		push_error("Torch walk needs a real Forward+ viewport"); quit(2); return
	root.unfocusable = true # do not capture or send OS input to the user's editor
	root.size = Vector2i(640, 360)
	var scene := Walk.instantiate()
	# Isolate only the carried light; do not edit the saved GalleryLights or Sun.
	scene.get_node("Subject/GalleryLight").hide(); scene.get_node("Subject/Sun").hide()
	scene.get_node("HUD").hide()
	root.add_child(scene); current_scene = scene
	await _draw(50)
	var fly: Camera3D = scene.get_node("Camera3D")
	var eye := root.get_camera_3d()
	var player := eye.get_parent() as Player
	if not player:
		push_error("did not enter first person"); quit(1); return
	_check(player.is_on_floor() and eye.global_position.y - player.global_position.y > 1.4 and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED, "starts at eye height on the palace floor without taking the cursor")
	# Independent fixed observer: don't confuse moving the viewmodel or camera with relighting stone.
	var observer := Camera3D.new(); observer.fov = eye.fov; observer.cull_mask = 1
	scene.add_child(observer); observer.global_transform = eye.global_transform; observer.make_current()
	var gi: SplitRadianceCascades = scene.get_node("WorldEnvironment/SplitRadianceCascades")
	gi.enabled = false; await _draw(8); var native_lit := _stone()
	_key(KEY_T); await _draw(8); var native_dark := _stone()
	gi.enabled = true; await _draw(90); var composite_dark := _stone()
	_key(KEY_T); await _draw(120); var composite_lit := _stone()
	var direct := _diff(native_lit, native_dark)
	var bounce := _diff(composite_lit, native_lit)
	var unlit := _diff(composite_dark, native_dark)
	_check(direct > 0.03 and bounce > 0.008 and absf(unlit) < 0.002,
		"torch lights stone directly and indirectly; extinguishing removes both (native lift %.4f, GI lift %.4f, unlit residual %.4f)" % [direct,bounce,unlit])
	await _continuous_torch_motion(player.get_node("Eyes/Hold/Torchlight"))
	await _vault_motion(observer, gi, player.get_node("Eyes/Hold/Torchlight"), scene.get_node("Subject/GalleryLight"))
	gi.view = SplitRadianceCascades.View.INDIRECT_ONLY; await _draw(80); var before := _stone()
	fly.set_physics_process(false) # replay actual locomotion intent on physics ticks without taking OS focus
	var origin := player.global_position
	var forward := -player.global_basis.z
	var eye_y := eye.global_position.y
	player.look(Vector2(0, -220))
	await _walk(player, Vector2.UP, 74)
	var travel := player.global_position - origin
	_check(eye.global_basis.z.y < -0.3 and forward.dot(travel) > 2.4 and absf(eye.global_position.y - eye_y) < 0.20 and player.is_on_floor(), "looking up while walking moves the first-person camera along the floor: %s" % travel)
	await _draw(12); var recent := _stone()
	await _draw(240); var after := _stone()
	var change := _diff(before, after, true)
	var residual := _diff(recent, after, true)
	_check(change > 0.008 and residual < change * 0.5, "indirect light follows the walking torch, not its old footprint (step %.4f, residual after 12 draws %.4f)" % [change,residual])
	_key(KEY_T); await _draw(3)
	var extinguished := _stone()
	extinguished.sort()
	_check(extinguished[-1] < 0.008, "extinguishing the light clears the indirect wall image within three draws")
	# The west wall behind the spawn is about two metres from it. Approach it head-on.
	var to_wall := Vector3.LEFT
	var from := player.global_position + Vector3.UP
	var hit := player.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(from, from + 12.0 * to_wall, 1))
	if hit.is_empty():
		_check(false, "architecture wall missing")
	else:
		var local := player.global_basis.inverse() * to_wall
		await _walk(player, Vector2(local.x, local.z), 160, true)
		var clearance := (Vector3(hit.position) - player.global_position).dot(to_wall)
		_check(player.is_on_floor() and clearance > 0.15 and clearance < 0.8, "sprinting hits the real palace wall instead of passing through it (%.3f m clearance)" % clearance)
	observer.queue_free(); eye.make_current(); _key(KEY_TAB); await _draw(4)
	_check(root.get_camera_3d() == fly and not is_instance_valid(player) and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED, "Tab restores the fly camera and removes the carried light")
	_key(KEY_3); _key(KEY_F); await _draw(16)
	_check(root.get_camera_3d().get_parent() is Player, "the existing fly preview can re-enter torch walk with F")
	scene.queue_free(); await process_frame; await process_frame
	print("Sponza torch walk: %d failure(s)" % failures); quit(1 if failures else 0)

func _continuous_torch_motion(torch: OmniLight3D) -> void:
	# Nonzero slow movement every other draw reproduces alternating cold/warm
	# histories. Same stone, fixed observer, no hand mesh in the measured region.
	var origin := torch.global_position
	var previous := _stone()
	var variation := 0.0
	for i in 48:
		await process_frame
		if i % 2 == 0: torch.global_position += Vector3.RIGHT * 0.001
		await RenderingServer.frame_post_draw
		var current := _stone()
		variation += _diff(current, previous, true)
		previous = current
	variation *= 255.0 / 48.0
	_check(variation < 0.5, "1 mm light steps do not pulse the wall (mean interframe change %.3f / 255)" % variation)
	torch.global_position = origin

# Control for false relighting: the gallery lights dominate the vault. Translating
# a nonzero but negligible indirect emitter must not make their bounce fluctuate.
func _vault_motion(observer: Camera3D, gi: SplitRadianceCascades, torch: OmniLight3D, gallery: Light3D) -> void:
	var pose := observer.transform
	var origin := torch.global_position
	var energy := torch.light_indirect_energy
	gallery.show()
	torch.light_indirect_energy = 0.00001
	observer.rotate_object_local(Vector3.RIGHT, deg_to_rad(27))
	observer.reset_physics_interpolation()
	gi.view = SplitRadianceCascades.View.INDIRECT_ONLY
	await _draw(320)
	var previous := PackedFloat32Array()
	var variation := Vector2.ZERO
	for i in 97:
		await process_frame
		if i > 32: torch.global_position += Vector3.RIGHT * 0.04
		await RenderingServer.frame_post_draw
		var im := root.get_texture().get_image()
		var patch := PackedFloat32Array()
		for y in range(im.get_height()/30, im.get_height()/8, 4):
			for x in range(im.get_width()*3/10, im.get_width()/2, 4):
				patch.append(im.get_pixel(x,y).get_luminance())
		if i > 0 and i <= 32: variation.x += 255.0*_diff(patch,previous,true)/32.0
		elif i > 32: variation.y += 255.0*_diff(patch,previous,true)/64.0
		previous = patch
	_check(previous[previous.size()/2] > 0.025 and variation.y < variation.x*2.0 + 0.12,
		"moving a negligible lamp preserves lit vault stability: resting %.3f, moving %.3f / 255" % [variation.x,variation.y])
	torch.global_position = origin
	torch.light_indirect_energy = energy
	gallery.hide()
	observer.transform = pose
	observer.reset_physics_interpolation()

func _walk(player: Player, axis: Vector2, ticks: int, fast := false) -> void:
	for i in ticks:
		await physics_frame
		player.walk(axis, fast, 1.0 / Engine.physics_ticks_per_second)

func _stone() -> PackedFloat32Array:
	var image := root.get_texture().get_image()
	var levels := PackedFloat32Array()
	for y in range(image.get_height()/4, 3*image.get_height()/4, 4):
		for x in range(image.get_width()/20, 2*image.get_width()/5, 4):
			levels.append(image.get_pixel(x,y).get_luminance())
	return levels

func _diff(a: PackedFloat32Array, b: PackedFloat32Array, absolute := false) -> float:
	var sum := 0.0
	for i in a.size(): sum += absf(a[i]-b[i]) if absolute else a[i]-b[i]
	return sum / a.size()

func _draw(n: int) -> void:
	for i in n: await RenderingServer.frame_post_draw

func _key(code: Key) -> void:
	for down: bool in [true, false]:
		var e := InputEventKey.new(); e.keycode = code; e.physical_keycode = code; e.pressed = down
		root.push_input(e, true)

func _check(ok: bool, message: String) -> void:
	if ok: print("PASS: ", message)
	else: failures += 1; push_error(message)
