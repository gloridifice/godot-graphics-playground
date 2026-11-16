extends SceneTree
## Headless native-pose boundary: actual speed must blend walk/run, not just change a label.
var failures := 0
var _character: MotionCharacter
var _tree: AnimationTree
var _skeleton: Skeleton3D
var _references: Array[Node3D] = []
var _players: Array[AnimationPlayer] = []
var _skeletons: Array[Skeleton3D] = []

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	_character = load("res://addons/motion/motion_character.tscn").instantiate()
	root.add_child(_character)
	_character.set_physics_process(false)
	_character.foot_placement.enabled = false # Inspect animation output without procedural corrections.
	_tree = _character.get_node("AnimationTree")
	_skeleton = _character.get_node("Visual/Model/Skeleton3D")
	(_tree.get("parameters/playback") as AnimationNodeStateMachinePlayback).start("Grounded")
	for side in 2:
		var reference := load("res://addons/motion/assets/guard.scn").instantiate() as Node3D
		root.add_child(reference)
		reference.visible = false
		var skeleton := reference.get_node("Skeleton3D") as Skeleton3D
		var contacts := MotionFootPlacement.new()
		contacts.name = "FootPlacement"
		skeleton.add_child(contacts)
		var player := AnimationPlayer.new()
		reference.add_child(player)
		player.add_animation_library("", load("res://addons/motion/animations/mixamo.res"))
		_references.append(reference)
		_players.append(player)
		_skeletons.append(skeleton)
	var walk := _character.walk_speed
	var run := _character.run_speed
	var span := run - walk
	for sample: Array in [[0.0, 0.0], [walk, 0.0], [walk + span * 0.25, 0.25], [walk + span * 0.5, 0.5], [walk + span * 0.75, 0.75], [run, 1.0], [walk + span * 0.5, 0.5, 0.0], [walk, 0.0, run]]:
		var desired_speed: float = sample[2] if sample.size() > 2 else sample[0]
		var mixed_frames := 0
		var endpoint_frames := 0
		var last_state: Dictionary = {}
		for frame in 100:
			_character.motion_matching.update(1.0 / 60.0, &"Grounded", Vector3.FORWARD * sample[0], Vector3.FORWARD * desired_speed, _character.get_node("Visual").global_basis, 18.0, walk, run, _character.crouch_speed)
			_tree.advance(1.0 / 60.0)
			_skeleton.advance(1.0 / 60.0)
			await process_frame
			var state := _character.motion_matching.get_debug_state()
			last_state = state
			if not state.has("run_blend"):
				_check(false, "actual-speed walk/run blending is missing")
				_finish()
				return
			_check(absf(state.run_blend - sample[1]) < 0.01, "walk/run weight follows actual speed, including intermediate speeds")
			if frame > 30 and sample[1] > 0.0 and sample[1] < 1.0 and not state.walk.blending and not state.run.blending:
				if _is_mixed_pose(state): mixed_frames += 1
			if frame > 30 and (sample[1] == 0.0 or sample[1] == 1.0) and not state.blending:
				_check(_endpoint_error(state.walk if sample[1] == 0.0 else state.run) < 0.025, "speed endpoints actually play the pure selected gait")
				endpoint_frames += 1
		if sample[0] >= walk:
			_check(last_state.walk.clip == "Walk", "walk channel retains authored walking at all forward blend speeds")
		if sample[1] > 0.0:
			_check(last_state.run.clip == "Run", "run channel uses the imported Run Forward, not accelerated walking")
		if sample[1] == 0.0 or sample[1] == 1.0:
			_check(endpoint_frames > 5, "pure-speed endpoint has observable native poses")
		if sample[1] > 0.0 and sample[1] < 1.0:
			_check(mixed_frames > 3, "intermediate speed really blends native bones between both playing gaits, rather than only reporting a weight")
		print("Speed ", sample[0], " run_blend=",sample[1]," native_mixed_frames=",mixed_frames)
	_finish()

func _endpoint_error(channel: Dictionary) -> float:
	_players[0].play(channel.clip)
	_players[0].seek(channel.time, true)
	_skeletons[0].force_update_all_bone_transforms()
	var error := 0.0
	for name in ["LeftUpLeg", "RightUpLeg", "LeftArm", "RightArm"]:
		var expected := _skeletons[0].get_bone_pose_rotation(_skeletons[0].find_bone(name))
		error = maxf(error, expected.angle_to(_skeleton.get_bone_pose_rotation(_skeleton.find_bone(name))))
	return error

func _is_mixed_pose(state: Dictionary) -> bool:
	for side in 2:
		var channel: Dictionary = state.walk if side == 0 else state.run
		_players[side].play(channel.clip)
		_players[side].seek(channel.time, true)
		_skeletons[side].force_update_all_bone_transforms()
	for name in ["LeftUpLeg", "LeftLeg", "RightUpLeg", "RightLeg", "LeftArm", "RightArm"]:
		var walk := _skeletons[0].get_bone_pose_rotation(_skeletons[0].find_bone(name))
		var run := _skeletons[1].get_bone_pose_rotation(_skeletons[1].find_bone(name))
		var actual := _skeleton.get_bone_pose_rotation(_skeleton.find_bone(name))
		var apart := walk.angle_to(run)
		if apart > 0.4 and actual.angle_to(walk) > 0.03 and actual.angle_to(run) > 0.03 and actual.angle_to(walk) + actual.angle_to(run) < apart + 0.12:
			return true
	return false

func _finish() -> void:
	_character.free()
	for reference in _references: reference.free()
	print("Motion speed blend: ", "PASS" if failures == 0 else "FAIL")
	quit(0 if failures == 0 else 1)

func _check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		printerr("FAIL: ", message)
