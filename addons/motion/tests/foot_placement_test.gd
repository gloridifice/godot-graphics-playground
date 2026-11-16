extends SceneTree
## Owning boundary: final rendered skeleton poses against real demo collision geometry.
## Protects planting/lock/release, modifier order, terrain orientation and lifecycle recovery.
## Run graphically with focus. -- --screenshots saves terrain comparisons to TEMP.

const SOLE := Vector3(0.0, -0.17, 0.08) # Independently calibrated Guard ankle-to-sole point.
var failures := 0
var _scene: Node3D
var _player: MotionCharacter
var _skeleton: Skeleton3D
var _final: Array[Transform3D] = []
var _history: Array[Dictionary] = []
var _record := false

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	_scene = load("res://addons/motion/demo.tscn").instantiate() as Node3D
	root.add_child(_scene)
	current_scene = _scene
	root.grab_focus()
	_player = _scene.get_node("Player") as MotionCharacter
	_skeleton = _player.get_node("Visual/Model/Skeleton3D") as Skeleton3D
	_skeleton.skeleton_updated.connect(_sample_final_pose)
	await _steps(40)
	_check(_player.is_on_floor() and _final.size() == 2, "real physics and final skeleton update are running")
	for foot in _final:
		_check(absf((foot * SOLE).y - 0.02) < 0.025, "idle shoe rests on the floor, not at the ankle's height")
	await _key(KEY_F)
	_check(root.has_focus() and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED, "focused graphical window accepts real controller input")

	await _settle(Vector3(12, 0.04, 12))
	for gait in ["walk", "run", "crouch", "tuned walk", "left", "right", "back"]:
		if gait == "run": Input.action_press("sprint")
		if gait == "crouch": Input.action_press("crouch")
		if gait == "tuned walk": _player.walk_speed = 2.1
		var action: String = "move_" + gait if gait in ["left", "right", "back"] else "move_forward"
		Input.action_press(action)
		await _steps(30)
		_history.clear()
		_record = true
		var cycle_scale: float = 1.4 / _player.crouch_speed if gait == "crouch" else (6.0 / _player.run_speed if gait == "run" else 3.0 / _player.walk_speed)
		await _steps(ceili(90.0 * maxf(cycle_scale, 1.0)))
		_record = false
		_check_gait(gait)
		Input.action_release(action)
		Input.action_release("sprint")
		Input.action_release("crouch")
	Input.action_release("move_forward")
	await _steps(30)

	Input.action_press("jump")
	await _steps(8)
	Input.action_release("jump")
	var air := _player.foot_placement.get_debug_state()
	_check(not _player.is_on_floor() and air.feet.all(func(f: Dictionary): return f.phase == "Swing" and f.weight == 0.0), "jump immediately removes both ground constraints")
	for side in 2:
		var raw: Transform3D = air.feet[side].animated
		_check(_final[side].origin.distance_to(raw.origin + Vector3.UP * air.pelvis_drop) < 0.01, "airborne feet retain animation, not an old ground lock")
	await _steps(90)

	# Both soles must be supported by different actual stair treads; a capsule alone cannot do this.
	await _settle(Vector3(0, 0.85, -12.62), PI * 1.5)
	await _capture("stairs")
	var soles := [_final[0] * SOLE, _final[1] * SOLE]
	_check(absf(soles[0].y - soles[1].y) > 0.09, "separate feet occupy different stair heights")
	_check(_player.foot_placement.get_debug_state().feet.all(func(f: Dictionary): return f.weight > 0.95), "both legs participate on split-height stairs")
	for sole: Vector3 in soles:
		var hit := _ray(sole)
		_check(not hit.is_empty() and absf(sole.y - hit.position.y - 0.02) < 0.035, "stair sole height agrees with real tread collision")
	var pelvis := _player.foot_placement.get_debug_state().pelvis_drop as float
	_check(pelvis >= -0.251 and pelvis <= 0.0, "reach-based pelvis adjustment remains bounded")

	# Actual descent: frame-order errors tend to appear at tread changes, not in a static pose.
	await _settle(Vector3(0, 0.77, -15.4), 0.0)
	_player.get_node("CameraRig").rotation.y = PI
	_history.clear()
	_record = true
	Input.action_press("move_forward")
	await _steps(160)
	Input.action_release("move_forward")
	_record = false
	var penetrating := 0.0
	var split_support := 0
	for frame: Dictionary in _history:
		var left: Transform3D = frame.pose[0]
		var right: Transform3D = frame.pose[1]
		if absf((left * SOLE).y - (right * SOLE).y) > 0.07:
			split_support += 1
		for side in 2:
			var foot: Dictionary = frame.state.feet[side]
			if foot.phase == "Stance" and foot.weight > 0.99:
				var sole: Vector3 = frame.pose[side] * SOLE
				# Stair treads are analytic 12 cm levels (no solver-produced target as oracle).
				var step := clampi(floori((-sole.z - 10.675) / 0.65) + 1, 0, 6)
				penetrating = maxf(penetrating, step * 0.12 - sole.y)
	_check(_player.position.z > -10.2 and _player.position.y < 0.03 and split_support > 5 and penetrating < 0.025, "real stair descent crosses tread heights without planted shoes penetrating the stairs")
	_player.get_node("CameraRig").rotation.y = 0.0
	await _steps(25)

	# Analytic plane normals, rather than the foot solver's own target values.
	for ramp_name in ["Pitch", "CrossSlope"]:
		var ramp := _scene.get_node("ValidationCourse/Ramps/" + ramp_name) as CSGBox3D
		await _settle(ramp.global_position + Vector3.UP * 0.35)
		await _capture(ramp_name)
		var normal := ramp.global_basis.y.normalized()
		for foot in _final:
			_check(foot.basis.y.dot(normal) > 0.995, "%s shoe normal follows the tilted collision plane" % ramp_name)
			var sole := foot * SOLE
			var plane_point := ramp.global_position + normal * ramp.size.y * 0.5
			_check(absf((sole - plane_point).dot(normal) - 0.02) < 0.035, "%s sole is on the plane, not buried or floating" % ramp_name)

	# A spherical collision surface has different normals under the two feet.
	var sphere := _scene.get_node("ValidationCourse/Spheres/Large") as StaticBody3D
	await _settle(sphere.global_position + Vector3(0.22, 1.45, 0.0))
	await _capture("sphere")
	for foot in _final:
		var sole := foot * SOLE
		var normal := (sole - sphere.global_position).normalized()
		_check(foot.basis.y.dot(normal) > 0.98, "sphere shoe aligns to a curved surface, not world up")
		_check(absf(sole.distance_to(sphere.global_position) - 1.35 - 0.02) < 0.04, "sphere sole follows the real radius")

	await _settle(Vector3(4.5, 0.35, -9))
	await _capture("blocks")
	var before := _player.foot_placement.get_debug_state()
	_check(before.feet.all(func(f: Dictionary): return f.weight > 0.95), "small-block checkpoint acquires two contacts")
	await _key(KEY_1)
	await _steps(15)
	var one := _player.foot_placement.get_debug_state()
	_check(one.feet[0].weight == 0.0 and one.feet[1].weight > 0.95, "demo's left-foot switch leaves the right foot planted")
	await _key(KEY_1)
	await _steps(20)
	# A filtered/lost ground hit must release even if the BODY remains supported.
	var mask := _player.foot_placement.settings.collision_mask
	_player.foot_placement.settings.collision_mask = 0
	await _steps(20)
	var lost := _player.foot_placement.get_debug_state()
	_check(_player.is_on_floor() and lost.feet.all(func(f: Dictionary): return f.weight < 0.01 and f.phase != "Stance"), "ground query loss cannot keep a stale lock while the capsule stays grounded")
	_player.foot_placement.settings.collision_mask = mask
	await _steps(30)
	# Do NOT call reset here: automatic relocation detection is the behavior under test.
	_player.position = Vector3(-12, 0.04, 8)
	_player.velocity = Vector3.ZERO
	await _steps(30)
	_check(_player.foot_placement.get_debug_state().feet.all(func(f: Dictionary): return f.weight > 0.95 and f.lock.origin.x < -11.0), "teleport reacquires local ground instead of dragging old anchors across the map")

	var platform := _scene.get_node("ValidationCourse/MovingPlatform") as AnimatableBody3D
	platform.set_physics_process(false)
	await _steps(3)
	await _settle(platform.global_position + Vector3.UP * 0.2)
	var local_feet: Array[Transform3D] = []
	for foot in _final:
		local_feet.append(platform.global_transform.affine_inverse() * foot)
	var start := _player.position
	var carried := 0.0
	var platform_error := 0.0
	platform.set_physics_process(true)
	for frame in 100:
		await _steps(1)
		carried = maxf(carried, start.distance_to(_player.position))
		for side in 2:
			var local := platform.global_transform.affine_inverse() * _final[side]
			platform_error = maxf(platform_error, local.origin.distance_to(local_feet[side].origin))
	await _capture("platform")
	_check(carried > 0.15 and platform_error < 0.025, "moving/rotating platform carries the body and preserves local shoe anchors (error %.4f)" % platform_error)
	_check(_player.foot_placement.get_debug_state().feet.all(func(f: Dictionary): return f.phase == "Stance"), "platform motion alone does not fabricate walking/toe-off")

	# Independent locks and switches, despite a common model and preset.
	var other := load("res://addons/motion/motion_character.tscn").instantiate() as MotionCharacter
	other.position = Vector3(-12, 0.04, 5)
	_scene.add_child(other)
	await _steps(40)
	other.foot_placement.enabled = false
	await _steps(3)
	_check(other.foot_placement.get_debug_state().feet.all(func(f: Dictionary): return f.weight == 0.0) and _player.foot_placement.get_debug_state().feet.all(func(f: Dictionary): return f.weight > 0.95), "instances do not share runtime locks or enabled state")
	other.free()
	print("Motion foot placement: ", "PASS" if failures == 0 else "FAIL", " platform_error=", platform_error)
	_scene.free()
	await process_frame
	quit(0 if failures == 0 else 1)

func _sample_final_pose() -> void:
	_final.clear()
	for name in ["LeftFoot", "RightFoot"]:
		_final.append(_skeleton.global_transform * _skeleton.get_bone_global_pose(_skeleton.find_bone(name)))
	if _record:
		_history.append({"body": _player.global_position, "pose": _final.duplicate(), "state": _player.foot_placement.get_debug_state()})

func _check_gait(gait: String) -> void:
	var planted := [0, 0]
	var swings := [0, 0]
	var releases := [0, 0]
	var approaches := 0
	var max_slip := 0.0
	var max_plant_error := 0.0
	var root_travel := 0.0
	for i in range(1, _history.size()):
		var now := _history[i]
		var previous := _history[i - 1]
		root_travel += (now.body as Vector3).distance_to(previous.body)
		for side in 2:
			var foot: Dictionary = now.state.feet[side]
			var old: Dictionary = previous.state.feet[side]
			var pose: Transform3D = now.pose[side]
			_check(pose.is_finite(), "gait never produces NaN/Inf skeleton transforms")
			if foot.phase == "Release": releases[side] += 1
			if foot.phase == "Swing" and foot.weight < 0.05: swings[side] += 1
			if foot.phase == "Approach":
				var goal: Vector3 = foot.target * SOLE
				var animated: Vector3 = foot.animated * SOLE
				_check(Vector2(goal.x - animated.x, goal.z - animated.z).length() < 0.005, "approach preserves this frame's horizontal animated trajectory")
				approaches += 1
			if foot.phase == "Stance" and foot.weight > 0.999:
				max_plant_error = maxf(max_plant_error, pose.origin.distance_to(foot.lock.origin))
			if foot.phase == "Stance" and old.phase == "Stance" and foot.weight > 0.999 and old.weight > 0.999:
				planted[side] += 1
				var previous_pose: Transform3D = previous.pose[side]
				max_slip = maxf(max_slip, pose.origin.distance_to(previous_pose.origin))
	_check(root_travel > 1.0 and planted.min() > 2 and swings.min() > 0 and releases.min() > 0, "%s contains real travel plus independent bilateral support, swing and release" % gait)
	_check(max_plant_error < 0.035, "%s final ankle actually reaches its plant anchor (error %.4f)" % [gait, max_plant_error])
	_check(max_slip < 0.012, "%s final planted shoe stays in WORLD space while root advances (slip %.4f)" % [gait, max_slip])
	_check(approaches > 0, "%s has a late-swing approach, not ray-hit-implies-lock" % gait)
	print("Gait ", gait, " travel=", root_travel, " planted=", planted, " swing=", swings, " release=", releases, " max_slip=", max_slip, " plant_error=", max_plant_error)

func _ray(sole: Vector3) -> Dictionary:
	return _player.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(sole + Vector3.UP, sole - Vector3.UP, 1, [_player.get_rid()]))

func _settle(position: Vector3, yaw: float = PI) -> void:
	_player.position = position
	_player.velocity = Vector3.ZERO
	_player.get_node("Visual").rotation.y = yaw
	_player.foot_placement.reset()
	_player.reset_physics_interpolation()
	await _steps(50)

func _steps(count: int) -> void:
	for i in count:
		await physics_frame
	await process_frame

func _key(code: Key) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = code
	event.pressed = true
	Input.parse_input_event(event)
	await _steps(2)
	event.pressed = false
	Input.parse_input_event(event)
	await _steps(2)

func _capture(label: String) -> void:
	if "--screenshots" not in OS.get_cmdline_user_args():
		return
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(OS.get_environment("TEMP").path_join("motion_foot_%s.png" % label))

func _check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		printerr("FAIL: ", message)
