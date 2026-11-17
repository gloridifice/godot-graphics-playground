extends SceneTree
## Focus-free scripted integration: area rays, capsule motion and FINAL palms; no mouse capture.
## godot --path . --script res://addons/motion/tests/climbing_test.gd --max-fps 120

var failures := 0
var _scene: Node3D
var _course: Node3D
var _player: MotionCharacter
var _skeleton: Skeleton3D
var _palms: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
var _arms: Array[float] = [0.0, 0.0]
var _hips_up := Vector3.UP
var _normals: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
var _grasp_body: Node3D
var _ground_events := 0
var _land_events := 0
var _controls := preload("res://addons/motion/tests/control_driver.gd").new()

func _initialize() -> void:
	root.unfocusable = true
	root.add_child(_controls)
	_run.call_deferred()

func _run() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--rate="):
			Engine.physics_ticks_per_second = int(argument.trim_prefix("--rate="))
	_scene = load("res://addons/motion/demo.tscn").instantiate()
	root.add_child(_scene)
	current_scene = _scene
	_course = _scene.get_node("ClimbingCourse")
	_player = _scene.get_node("Player")
	_controls.bind(_player)
	_skeleton = _player.get_node("Visual/Model/Skeleton3D")
	_skeleton.get_node("HandRotations").modification_processed.connect(_capture)
	_player.ground_moved.connect(func(_a: Vector3, _b: Vector3, _d: float): _ground_events += 1)
	_player.landed.connect(func(_a: Vector3): _land_events += 1)
	await _steps(20)
	await _control()
	_check(Input.mouse_mode == Input.MOUSE_MODE_VISIBLE, "scripted input leaves desktop focus and mouse untouched")
	var roof := _scene.get_node("ClimbingCourse/Roof") as StaticBody3D
	_grasp_body = roof
	# A reachable ceiling while grounded must not attach. Preserve real floor contact.
	roof.position.y -= 0.45
	_player.global_position = _course.to_global(Vector3(10, 0.001, 7))
	await _steps(12)
	_check(_player.is_on_floor() and not _player.climbing.is_attached(), "a valid overhead surface never grabs a grounded character")
	await _jump()
	_check(_player.climbing.is_attached() and not _player.is_on_floor(), "jump automatically attaches without a grab key")
	await _steps(20)
	await _key(KEY_ESCAPE)
	_check(not _player.climbing.is_attached() and _player.climbing.is_blocked_until_grounded(), "ESC detaches and latches the airborne block")
	_check(Input.mouse_mode == Input.MOUSE_MODE_VISIBLE, "the same ESC also releases the cursor")
	# Create a genuine soft landing (<1 m/s), which intentionally emits no landed event.
	var platform := StaticBody3D.new()
	_scene.add_child(platform)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(2, 0.1, 2)
	shape.shape = box
	platform.add_child(shape)
	platform.position = _course.to_global(Vector3(10, _player.position.y - 0.06, 7))
	var lands_before := _land_events
	var regrabbed := false
	for frame in 20:
		await _steps(1)
		regrabbed = regrabbed or _player.climbing.is_attached()
		if _player.is_on_floor(): break
	await _steps(2)
	_check(not regrabbed and _player.is_on_floor(), "ESC blocks every airborne retry, even with the same reachable ceiling")
	_check(not _player.climbing.is_blocked_until_grounded() and _land_events == lands_before, "real soft contact resets the block without a landed signal")
	platform.free()
	roof.position.y = 3.1
	await _relocate(Vector3(10, 0.01, 7))
	await _control()
	await _jump()
	await _steps(25)
	_check(_player.climbing.is_attached(), "the next jump can grab again after landing")
	_check(_animation_state() == &"Climb", "native AnimationTree enters Climb, not Jump/Fall")
	var start := _player.position
	var events_before := _ground_events
	for frame in 20:
		await _steps(1)
		_assert_palms("ceiling hang")
	_check(start.distance_to(_player.position) < 0.02 and _hips_up.dot(Vector3.UP) > 0.98, "idle suspension stays vertical and stable")
	await _capture_window("ceiling")
	Input.action_press("move_right")
	var planted_frames := [0, 0]
	for frame in 95:
		await _steps(1)
		var state := _player.climbing.get_debug_state()
		for side in 2:
			if state.hands[side].planted: planted_frames[side] += 1
		_assert_palms("traverse")
	_check(_player.position.x > start.x + 0.35 and planted_frames[0] > 15 and planted_frames[1] > 15, "real D input traverses by alternating supported hands")
	await _steps(Engine.physics_ticks_per_second * 3)
	var edge_position := _player.position
	await _steps(Engine.physics_ticks_per_second)
	Input.action_release("move_right")
	_check(_player.climbing.is_attached() and _player.position.distance_to(edge_position) < 0.025 and _course.to_local(_player.global_position).x < 12.95, "held movement stops at the surface edge instead of drifting into air")
	_assert_palms("edge stop")
	_check(_ground_events == events_before, "suspended movement never emits ground_moved")
	await _steps(90)
	_check(_hips_up.dot(Vector3.UP) > 0.995, "inertial sway settles back toward vertical after stopping")
	# Surface-local anchors must survive rigid motion, not just static world locking.
	start = _player.position
	var roof_start := roof.transform
	for frame in 45:
		roof.position.x += 0.004
		roof.rotation.y += 0.001
		await _steps(1)
		_assert_palms("moving support")
	_check(_player.climbing.is_attached() and _player.position.distance_to(start) > 0.12, "body follows translating/yawing grasp support")
	# Automatic loss does not consume ESC's airborne opportunity; restore before landing.
	var surface := roof.get_node("GraspSurface") as ClimbableArea3D
	surface.enabled = false
	await _steps(2)
	_check(not _player.climbing.is_attached() and not _player.climbing.is_blocked_until_grounded(), "support loss detaches without the ESC-only block")
	surface.enabled = true
	await _steps(8)
	_check(_player.climbing.is_attached(), "automatic support loss permits catching a valid surface again")
	# ESC while still airborne but not attached only releases the cursor.
	surface.enabled = false
	await _steps(2)
	await _key(KEY_ESCAPE)
	_check(not _player.climbing.is_blocked_until_grounded(), "ESC outside attachment does not consume an airborne catch")
	surface.enabled = true
	roof.transform = roof_start
	await _relocate(Vector3(10, 0.01, 3.1), PI)
	_grasp_body = _scene.get_node("ClimbingCourse/Wall")
	# Disable top probe so this proves the diagonal-forward wall path independently.
	surface.enabled = false
	await _control()
	await _jump()
	await _steps(30)
	_check(_player.climbing.is_attached(), "forward-up rays acquire a wall without an overhead catch")
	_assert_palms("wall hang")
	start = _player.position
	Input.action_press("move_forward")
	for frame in 80:
		await _steps(1)
		_assert_palms("wall ascent")
	Input.action_release("move_forward")
	_check(_player.position.y > start.y + 0.35 and _course.to_local(_player.global_position).z < 3.26, "W ascends the wall while the capsule remains outside it")
	await _capture_window("wall")
	await _key(KEY_ESCAPE)
	# A second instance can catch while the first is ESC-blocked: no shared latch/anchors.
	surface.enabled = true
	var other := load("res://addons/motion/motion_character.tscn").instantiate() as MotionCharacter
	other.position = _course.to_global(Vector3(8, 0.6, 7))
	_scene.add_child(other)
	await _steps(2)
	_check(_player.climbing.is_blocked_until_grounded() and not _player.climbing.is_attached() and other.climbing.is_attached(), "ESC block and grasp state belong to each character, not the shared settings")
	other.free()
	surface.enabled = false
	var stayed_detached := true
	for frame in 120:
		await _steps(1)
		stayed_detached = stayed_detached and not _player.climbing.is_attached()
		if _player.is_on_floor(): break
	await _steps(2)
	_check(stayed_detached and _player.is_on_floor() and not _player.climbing.is_blocked_until_grounded(), "full fall stays detached and resets on physical landing")
	# Negative control: the same visible/collidable roof with its region disabled cannot grab.
	await _relocate(Vector3(10, 0.6, 7))
	await _steps(15)
	_check(not _player.climbing.is_attached(), "ordinary solid geometry without an enabled climb region is not graspable")
	# Independent obstruction: area remains reachable, but its required body volume is blocked.
	surface.enabled = true
	var blocker := StaticBody3D.new()
	_scene.add_child(blocker)
	var blocker_shape := CollisionShape3D.new()
	var blocker_box := BoxShape3D.new()
	blocker_box.size = Vector3(4, 0.1, 4)
	blocker_shape.shape = blocker_box
	blocker.add_child(blocker_shape)
	blocker.position = _course.to_global(Vector3(10, 2.65, 7))
	await _relocate(Vector3(10, 0.4, 7))
	await _steps(12)
	_check(not _player.climbing.is_attached() and _player.position.y < 0.51, "reachable region behind a solid lower ceiling cannot pull the capsule through it")
	_scene.free()
	await process_frame
	print("Motion procedural climbing ", Engine.physics_ticks_per_second, "Hz: ", "PASS" if failures == 0 else "FAIL", " failures=", failures)
	quit(0 if failures == 0 else 1)

func _capture() -> void:
	for side in 2:
		var prefix := "Left" if side == 0 else "Right"
		var wrist := _skeleton.global_transform * _skeleton.get_bone_global_pose(_skeleton.find_bone(prefix + "Hand"))
		var offset := Vector3(0.09 if side == 0 else -0.09, -0.025, 0)
		_palms[side] = wrist * offset
		_normals[side] = wrist.basis.y.normalized()
		var shoulder := _skeleton.global_transform * _skeleton.get_bone_global_pose(_skeleton.find_bone(prefix + "Arm"))
		_arms[side] = shoulder.origin.distance_to(wrist.origin)
	_hips_up = (_skeleton.global_basis * _skeleton.get_bone_global_pose(_skeleton.find_bone("Hips")).basis.y).normalized()

func _assert_palms(label: String) -> void:
	var state := _player.climbing.get_debug_state()
	_check(state.attached, label + ": retains suspension")
	for side in 2:
		if state.hands[side].planted:
			_check(_palms[side].distance_to(state.hands[side].grip.origin) < 0.035, label + ": final planted palm remains on the surface, not only its target (error %.4f)" % _palms[side].distance_to(state.hands[side].grip.origin))
			# Compare to independently authored box planes, not values produced by the solver.
			var local := _grasp_body.to_local(_palms[side])
			var normal := -_grasp_body.global_basis.y if _grasp_body.name == "Roof" else -_grasp_body.global_basis.z
			var plane_error := absf(local.y + 0.215) if _grasp_body.name == "Roof" else absf(local.z + 0.215)
			_check(plane_error < 0.035 and _normals[side].dot(normal) > 0.98, label + ": final palm contacts the actual authored box face with matching orientation")
		_check(_arms[side] < 0.655, label + ": arm does not stretch")

func _animation_state() -> StringName:
	return (_player.get_node("AnimationTree").get("parameters/playback") as AnimationNodeStateMachinePlayback).get_current_node()

func _relocate(position: Vector3, yaw: float = 0.0) -> void:
	_player.global_position = _course.to_global(position)
	_player.velocity = Vector3.ZERO
	_player.get_node("Visual").rotation.y = yaw + PI
	_player.get_node("CameraRig").rotation.y = yaw
	_player.climbing.reset()
	_player.motion_matching.reset()
	_player.foot_placement.reset()
	await _steps(10)

func _control() -> void:
	_controls.set_enabled(true)
	await _steps(2)

func _jump() -> void:
	Input.action_press("jump")
	await _steps(8)
	Input.action_release("jump")

func _key(code: Key) -> void:
	assert(code == KEY_ESCAPE)
	_player.release_climb()
	_controls.set_enabled(false)
	await _steps(2)

func _steps(count: int) -> void:
	for frame in count: await physics_frame
	await process_frame
	_check(Input.mouse_mode == Input.MOUSE_MODE_VISIBLE, "automation never captures the mouse")

func _capture_window(label: String) -> void:
	if "--screenshots" not in OS.get_cmdline_user_args(): return
	# Hold a real rendered pose long enough for external cutty inspection if requested.
	print("Climb visual checkpoint: ", label, " PID=", OS.get_process_id())
	await create_timer(8.0).timeout

func _check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		if failures <= 30: printerr("FAIL: ", message)
