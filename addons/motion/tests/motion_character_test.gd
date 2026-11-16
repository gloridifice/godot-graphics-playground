extends SceneTree
## Real package scene, native physics, accepted input, AnimationTree and skeleton poses.
## Run in a focused graphical window (not headless).

var failures := 0
var _player: MotionCharacter
var _scene: Node3D
var _events: Array[String] = []

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	_scene = (load("res://addons/motion/demo.tscn") as PackedScene).instantiate()
	root.add_child(_scene)
	current_scene = _scene
	root.grab_focus()
	_player = _scene.get_node("Player") as MotionCharacter
	_player.jumped.connect(func(_feet: Vector3): _events.append("jump"))
	_player.landed.connect(func(_feet: Vector3): _events.append("land"))
	await _steps(30)
	_check(_player.is_on_floor() and _events.is_empty(), "spawn settles without a fabricated landing")
	_check(Input.mouse_mode == Input.MOUSE_MODE_VISIBLE, "startup leaves the cursor free")
	var start := _player.position
	Input.action_press("move_forward")
	Input.action_press("jump")
	await _steps(10)
	Input.action_release("move_forward")
	Input.action_release("jump")
	_check(_player.position.distance_to(start) < 0.02 and _events.is_empty(), "free cursor blocks movement and jumping")
	await _key(KEY_F)
	_check(Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and root.has_focus(), "physical F enters control in a focused window")
	await _capture("idle")

	Input.action_press("move_forward")
	await _steps(20)
	start = _player.position
	await _steps(15)
	var walk_distance := start.distance_to(_player.position)
	_check(walk_distance > _player.walk_speed * 0.2 and _player.position.z < start.z, "W walks relative to the camera")
	_check(_state() == &"Grounded", "walking stays in the native grounded state while matching selects poses")
	var skeleton := _player.get_node("Visual/Model/Skeleton3D") as Skeleton3D
	var leg := skeleton.find_bone("LeftUpLeg")
	var leg_before := skeleton.get_bone_pose_rotation(leg)
	await _steps(ceili(8.0 * 3.0 / _player.walk_speed))
	_check(leg_before.angle_to(skeleton.get_bone_pose_rotation(leg)) > 0.05, "walking really animates the imported skeleton, not just its controller")
	await _capture("walk")
	Input.action_press("sprint")
	await _steps(25)
	start = _player.position
	await _steps(15)
	var run_distance := start.distance_to(_player.position)
	_check(run_distance > walk_distance * 1.65, "held Shift runs faster than walking")
	await _capture("run")
	Input.action_release("sprint")
	Input.action_release("move_forward")
	await _steps(25)

	# Equal time and settled speed: diagonal travel must not gain sqrt(2) speed.
	_player.position = Vector3(4, 0.03, 2)
	await _steps(5)
	Input.action_press("move_forward")
	Input.action_press("move_right")
	await _steps(20)
	start = _player.position
	await _steps(15)
	_check(_player.position.distance_to(start) <= walk_distance * 1.04, "diagonal movement is normalized")
	Input.action_release("move_forward")
	Input.action_release("move_right")
	await _steps(25)

	Input.action_press("jump")
	await _steps(8)
	Input.action_release("jump")
	_check(not _player.is_on_floor() and _player.position.y > 0.2 and _events == ["jump"], "grounded Space performs exactly one real jump")
	_check(_state() == &"Jump", "upward motion selects the native jump state")
	await _capture("jump")
	Input.action_press("jump")
	await _steps(2)
	Input.action_release("jump")
	_check(_events == ["jump"], "airborne Space cannot create a second jump")
	await _key(KEY_ESCAPE)
	var saw_fall := false
	for i in 100:
		await _steps(1)
		saw_fall = saw_fall or _state() == &"Fall"
		if _player.is_on_floor():
			break
	_check(saw_fall and _player.is_on_floor() and _events == ["jump", "land"], "released controls still fall, animate falling, and land once")
	await _key(KEY_F)

	# Enter the actual demo tunnel while crouching, then release Ctrl underneath it.
	_player.position = Vector3(-3, 0.03, -3)
	await _steps(8)
	var feet_y := _player.get_feet_position().y
	Input.action_press("crouch")
	await _steps(20)
	_check(_player.is_crouching() and absf(_player.get_feet_position().y - feet_y) < 0.03, "crouching lowers the collision capsule without moving the feet")
	_check(_state() == &"Crouch" and skeleton.get_bone_global_pose(skeleton.find_bone("Hips")).origin.y < 0.85, "crouch animation visibly lowers the Mixamo hips")
	await _capture("crouch_idle")
	Input.action_press("jump")
	await _steps(3)
	Input.action_release("jump")
	_check(_player.is_on_floor() and _events.size() == 2, "held crouch blocks jumping")
	Input.action_press("move_forward")
	Input.action_press("sprint")
	await _steps(ceili(80.0 * 1.4 / _player.crouch_speed))
	_check(_player.position.z < -4.5 and _player.is_crouching(), "crouch walking physically enters the low tunnel")
	var crouch_velocity := _player.get_real_velocity()
	_check(Vector2(crouch_velocity.x, crouch_velocity.z).length() <= _player.crouch_speed + 0.05, "sprint cannot override crouch speed")
	await _capture("crouch_walk")
	Input.action_release("move_forward")
	Input.action_release("sprint")
	Input.action_release("crouch")
	await _steps(20)
	_check(_player.is_crouching(), "releasing Ctrl under a solid ceiling cannot stand up through it")
	await _key(KEY_ESCAPE)
	await _steps(5)
	_check(_player.is_crouching(), "releasing mouse control cannot force standing through a ceiling")
	await _key(KEY_F)
	Input.action_press("move_forward")
	await _steps(ceili(180.0 * 1.4 / _player.crouch_speed))
	Input.action_release("move_forward")
	await _steps(20)
	_check(_player.position.z < -8.5 and not _player.is_crouching() and _state() == &"Grounded", "after crawling out, headroom permits a full return to standing")

	# Independent instances must not share the mutable playback or collision stance.
	var other := (load("res://addons/motion/motion_character.tscn") as PackedScene).instantiate() as MotionCharacter
	other.position = Vector3(8, 0.03, 4)
	_scene.add_child(other)
	await _steps(8)
	await _key(KEY_F)
	Input.action_press("crouch")
	await _steps(20)
	_player.position = Vector3(-3, 0.03, -6)
	Input.action_release("crouch")
	await _steps(20)
	var other_tree := other.get_node("AnimationTree") as AnimationTree
	var other_state := (other_tree.get("parameters/playback") as AnimationNodeStateMachinePlayback).get_current_node()
	_check(_player.is_crouching() and not other.is_crouching() and _state() == &"Crouch" and other_state == &"Grounded", "two instances retain different physical stances and animation states")
	other.free()
	root.propagate_notification(Node.NOTIFICATION_WM_WINDOW_FOCUS_OUT)
	_check(Input.mouse_mode == Input.MOUSE_MODE_VISIBLE, "focus loss releases the mouse")
	root.propagate_notification(Node.NOTIFICATION_WM_WINDOW_FOCUS_IN)
	_check(Input.mouse_mode == Input.MOUSE_MODE_VISIBLE, "focus regain does not recapture the mouse")
	print("Motion native controller: ", "PASS" if failures == 0 else "FAIL", " walk=", walk_distance, " run=", run_distance)
	_scene.free()
	await process_frame
	quit(0 if failures == 0 else 1)

func _state() -> StringName:
	var tree := _player.get_node("AnimationTree") as AnimationTree
	return (tree.get("parameters/playback") as AnimationNodeStateMachinePlayback).get_current_node()

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
	var path := OS.get_environment("TEMP").path_join("motion_%s.png" % label)
	root.get_texture().get_image().save_png(path)
	print("Motion screenshot: ", path)

func _check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		printerr("FAIL: ", message)
