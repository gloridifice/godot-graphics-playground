extends SceneTree
## Owning boundary: accepted directional input -> search -> real native animation on the Guard.
## An independent AnimationPlayer checks that the reported match actually reaches the skeleton.

var failures := 0
var _scene: Node3D
var _player: MotionCharacter
var _reference: Node3D
var _reference_player: AnimationPlayer
var _reference_skeleton: Skeleton3D
var _controls := preload("res://addons/motion/tests/control_driver.gd").new()

func _initialize() -> void:
	root.unfocusable = true
	root.add_child(_controls)
	_run.call_deferred()

func _run() -> void:
	_scene = load("res://addons/motion/demo.tscn").instantiate()
	root.add_child(_scene)
	current_scene = _scene
	_player = _scene.get_node("Player")
	_controls.bind(_player)
	_controls.set_enabled(true)
	_player.foot_placement.enabled = false # Public demo A/B switch; expose the unmodified native pose.
	_reference = load("res://addons/motion/assets/guard.scn").instantiate()
	_reference.visible = false
	_scene.add_child(_reference)
	_reference_skeleton = _reference.get_node("Skeleton3D")
	var contacts := MotionFootPlacement.new()
	contacts.name = "FootPlacement"
	_reference_skeleton.add_child(contacts)
	_reference_player = AnimationPlayer.new()
	_reference.add_child(_reference_player)
	_reference_player.add_animation_library("", load("res://addons/motion/animations/mixamo.res"))
	await _steps(35)
	# Real renderer budget, independent of the cloud's mesh/texture implementation.
	# Per-sample AA primitives must not make UI draw calls grow with the library.
	var diagram := _scene.get_node("Controls/MotionMatching") as Control
	await RenderingServer.frame_post_draw
	var visible_calls := Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	diagram.hide()
	await _steps(4)
	await RenderingServer.frame_post_draw
	var hidden_calls := Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	diagram.show()
	var diagram_calls := visible_calls - hidden_calls
	_check(diagram_calls > 0 and diagram_calls <= 80, "live diagram adds at most 80 draw calls, not one AA primitive per sample (added %.0f)" % diagram_calls)
	print("Motion diagram draw calls: ", diagram_calls)
	_check(Input.mouse_mode == Input.MOUSE_MODE_VISIBLE, "scripted controller needs neither focus nor mouse capture")

	for item: Array in [["move_forward", "Walk", Vector3.FORWARD, false], ["move_left", "StrafeLeft", Vector3.LEFT, false], ["move_right", "StrafeRight", Vector3.RIGHT, false], ["move_back", "WalkBack", Vector3.BACK, false], ["move_forward", "Run", Vector3.FORWARD, true], ["move_left", "RunLeft", Vector3.LEFT, true], ["move_right", "RunRight", Vector3.RIGHT, true], ["move_back", "RunBack", Vector3.BACK, true]]:
		_player.position = Vector3(10, 0.03, 7)
		_player.velocity = Vector3.ZERO
		await _steps(20)
		Input.action_press(item[0])
		if item[3]: Input.action_press("sprint")
		await _steps(35)
		var start := _player.position
		var correct := 0
		var samples := 0
		var error := 0.0
		var foot_before := _foot_pose(_player)
		var gait_motion := 0.0
		for tick in 30:
			await _steps(1)
			gait_motion = maxf(gait_motion, _foot_pose(_player).origin.distance_to(foot_before.origin))
			var match_state := _player.motion_matching.get_debug_state()
			if match_state.clip == item[1]: correct += 1
			if not match_state.blending:
				error = maxf(error, _pose_error(_player))
				samples += 1
		var direction: Vector3 = _player.position - start
		_check(direction.dot(item[2]) > (_player.run_speed if item[3] else _player.walk_speed) * 0.43 and _player.get_node("Visual").global_basis.z.dot(Vector3.FORWARD) > 0.98, "%s moves in its own direction without turning the character to face it" % item[0])
		_check(correct >= 24 and samples >= 5 and error < 0.04, "%s selects and really plays its authored clip and matched timestamp (pose error %.4f)" % [item[1], error])
		_check(gait_motion > 0.05, "%s advances its gait instead of freezing on the match frame" % item[1])
		print(item[1], " sprint=", item[3], " matches=", correct, "/30 pose_error=", error, " travel=", direction, " facing=", _player.get_node("Visual").global_basis.z)
		await _capture(item[1])
		Input.action_release(item[0])
		Input.action_release("sprint")
		await _steps(35)
		_check(_player.motion_matching.get_debug_state().clip == "Idle", "stopping %s retrieves idle rather than playing a sliding gait" % item[1])

	# Two simultaneous searches: one character strafes freely, the other is blocked by a real wall.
	var wall := CSGBox3D.new()
	wall.size = Vector3(0.1, 3, 4)
	wall.position = Vector3(15, 1.5, 4)
	wall.use_collision = true
	_scene.add_child(wall)
	var other := load("res://addons/motion/motion_character.tscn").instantiate() as MotionCharacter
	other.position = Vector3(15.41, 0.03, 4)
	_scene.add_child(other)
	_controls.bind(other)
	other.foot_placement.enabled = false
	_player.position = Vector3(10, 0.03, 7)
	await _steps(30)
	Input.action_press("move_left")
	await _steps(70)
	_check(other.get_real_velocity().length() < 0.03 and other.motion_matching.get_debug_state().clip == "Idle", "wall-projected trajectory chooses idle despite a held movement key")
	_check(_player.motion_matching.get_debug_state().clip == "StrafeLeft" and _pose_error(_player) < 0.04, "concurrent idle/strafe searches do not mutate another instance's animation slots")
	Input.action_release("move_left")
	other.free()
	wall.free()
	_scene.free()
	await process_frame
	print("Motion matching: ", "PASS" if failures == 0 else "FAIL")
	quit(0 if failures == 0 else 1)

func _foot_pose(character: MotionCharacter) -> Transform3D:
	var skeleton := character.get_node("Visual/Model/Skeleton3D") as Skeleton3D
	return skeleton.get_bone_global_pose(skeleton.find_bone("LeftFoot"))

func _pose_error(character: MotionCharacter) -> float:
	var match_state := character.motion_matching.get_debug_state()
	_reference_player.play(match_state.clip)
	_reference_player.seek(match_state.time, true)
	_reference_skeleton.force_update_all_bone_transforms()
	var skeleton := character.get_node("Visual/Model/Skeleton3D") as Skeleton3D
	var error := 0.0
	for name in ["LeftFoot", "RightFoot", "LeftHand", "RightHand"]:
		var actual := skeleton.get_bone_global_pose(skeleton.find_bone(name))
		var expected := _reference_skeleton.get_bone_global_pose(_reference_skeleton.find_bone(name))
		error = maxf(error, actual.origin.distance_to(expected.origin))
	return error

func _steps(count: int) -> void:
	for tick in count:
		await physics_frame
	await process_frame
	_check(Input.mouse_mode == Input.MOUSE_MODE_VISIBLE, "automation never captures the mouse")

func _capture(name: String) -> void:
	if "--screenshots" not in OS.get_cmdline_user_args(): return
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(OS.get_environment("TEMP").path_join("motion_matching_%s.png" % name))

func _check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		printerr("FAIL: ", message)
