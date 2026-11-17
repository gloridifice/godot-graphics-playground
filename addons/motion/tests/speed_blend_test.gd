extends SceneTree
## Headless native-pose boundary: actual speed/direction must blend bones, not labels.
var failures := 0
var _character: MotionCharacter
var _tree: AnimationTree
var _skeleton: Skeleton3D
var _references: Array[Node3D] = []
var _players: Array[AnimationPlayer] = []
var _skeletons: Array[Skeleton3D] = []
var _evaluated_poses: Array[Transform3D] = []
var _evaluated_projection := Vector2.ZERO

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	_character = load("res://addons/motion/motion_character.tscn").instantiate()
	root.add_child(_character)
	_character.set_physics_process(false)
	_character.foot_placement.enabled = false # Inspect animation output without procedural corrections.
	# Exact native-blend checks below compare the unsmoothed animation target.
	_character.motion_matching.set("pose_smoothing_enabled", false)
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
	await _direction_blends(walk, run)
	await _pose_tracking(walk, run)
	_finish()

func _direction_blends(walk: float, run: float) -> void:
	# Sweep both sides of every quadrant boundary, including reversals and sprint.
	# The previous suite only exercised forward speed changes: a pure strafe at
	# 45 degrees passed all of it. Check native bones, not just reported weights.
	for speed in [walk, run]:
		for angle in [20.0, 45.0, 70.0, 110.0, 135.0, 160.0, -20.0, -45.0, -70.0, -110.0, -135.0, -160.0]:
			var direction := Vector3(-sin(deg_to_rad(angle)), 0, -cos(deg_to_rad(angle)))
			var side_weight := absf(direction.x) / (absf(direction.x) + absf(direction.z))
			# Target disagreement must not override collision-resolved travel direction.
			var desired := Vector3.FORWARD if absf(angle) == 45.0 else direction
			var mixed_frames := 0
			var max_error := 0.0
			for frame in 150:
				_character.motion_matching.update(1.0 / 60.0, &"Grounded", direction * speed, desired * speed, _character.get_node("Visual").global_basis, 18.0, walk, run, _character.crouch_speed)
				_tree.advance(1.0 / 60.0)
				_skeleton.advance(1.0 / 60.0)
				await process_frame
				if frame < 60: continue
				var state := _character.motion_matching.get_debug_state()
				var gait: Dictionary = state.walk if speed == walk else state.run
				var longitudinal: Dictionary = gait.get("longitudinal", gait)
				var lateral_state: Dictionary = gait.get("lateral", gait)
				if longitudinal.blending or lateral_state.blending: continue
				# This native-bone check also runs on the old single-match graph:
				# all its diagonal poses equal the dominant pure clip, so it fails.
				if _endpoint_error(gait) > 0.03: mixed_frames += 1
				if not gait.has("lateral"): continue
				var expected_forward := ("WalkBack" if speed == walk else "RunBack") if direction.z > 0 else ("Walk" if speed == walk else "Run")
				var expected_side := ("StrafeLeft" if direction.x < 0 else "StrafeRight") if speed == walk else ("RunLeft" if direction.x < 0 else "RunRight")
				_check(gait.longitudinal.clip == expected_forward and gait.lateral.clip == expected_side, "directional retrieval keeps the correct two authored axes")
				for side in 2:
					var channel: Dictionary = gait.longitudinal if side == 0 else gait.lateral
					_players[side].play(expected_forward if side == 0 else expected_side)
					_players[side].seek(channel.time, true)
					_skeletons[side].force_update_all_bone_transforms()
				for name in ["LeftUpLeg", "LeftLeg", "RightUpLeg", "RightLeg", "LeftArm", "RightArm"]:
					var forward := _skeletons[0].get_bone_pose_rotation(_skeletons[0].find_bone(name))
					var lateral := _skeletons[1].get_bone_pose_rotation(_skeletons[1].find_bone(name))
					var actual := _skeleton.get_bone_pose_rotation(_skeleton.find_bone(name))
					# Godot accumulates weighted rotations relative to RESET, rather
					# than pairwise-slerping already evaluated bone poses.
					var rest := _skeleton.get_bone_rest(_skeleton.find_bone(name)).basis.get_rotation_quaternion()
					var expected := rest * Quaternion.IDENTITY.slerp(rest.inverse() * forward, 1.0 - side_weight) * Quaternion.IDENTITY.slerp(rest.inverse() * lateral, side_weight)
					max_error = maxf(max_error, actual.angle_to(expected.normalized()))
			_check(mixed_frames > 15 and max_error < 0.025, "diagonal %.0f degrees at %.2f m/s really blends forward/back and lateral native bones (frames %d, error %.4f)" % [angle, speed, mixed_frames, max_error])

func _pose_tracking(walk: float, run: float) -> void:
	var matcher := _character.motion_matching
	if not "pose_smoothing_enabled" in matcher:
		_check(false, "motion matching needs switchable decay tracking of the actual native pose")
		return
	matcher.set("pose_half_life", 0.1)
	# Skeleton3D restores raw animation poses after modifiers; observe rendered output
	# during its native completion signal, not the restored get_bone_pose() values.
	_skeleton.get_node("FootRotations").modification_processed.connect(func(): _evaluated_poses = _bone_poses())
	_skeleton.get_node("MotionPoseSample").modification_processed.connect(func(): _evaluated_projection = _foot_projection())
	_skeleton.get_node("MotionPoseSample").modification_processed.connect(func(): _evaluated_projection = _foot_projection())
	# Compare real modifier output to a frozen AnimationTree target, at three tick rates.
	# No IK or copied matcher math supplies the target: it is the native bone pose.
	for hz in [30, 60, 120]:
		matcher.set("pose_smoothing_enabled", false)
		matcher.reset()
		for frame in 90:
			matcher.update(1.0 / 60.0, &"Grounded", Vector3.FORWARD * walk, Vector3.FORWARD * walk, _character.get_node("Visual").global_basis, 18.0, walk, run)
			_tree.advance(1.0 / 60.0)
			_skeleton.advance(1.0 / 60.0)
			await process_frame
		matcher.set("pose_smoothing_enabled", true)
		_tree.advance(0.0)
		_skeleton.advance(1.0 / hz) # Seed p from the current pose, not from RESET.
		await process_frame
		var initial: Array[Transform3D] = _evaluated_poses.duplicate()
		matcher.update(0.2, &"Grounded", Vector3.LEFT * run, Vector3.LEFT * run, _character.get_node("Visual").global_basis, 18.0, walk, run)
		_tree.advance(0.2)
		var target := _bone_poses()
		var target_projection := _foot_projection()
		var separation := 0.0
		for bone in initial.size():
			separation = maxf(separation, initial[bone].basis.get_rotation_quaternion().angle_to(target[bone].basis.get_rotation_quaternion()))
		_check(separation > 0.2, "tracking fixture has a genuinely different animation target")
		for frame in hz / 10:
			if frame > 0: _tree.advance(0.0) # Re-evaluate the same P, without advancing animation time.
			_skeleton.advance(1.0 / hz)
			await process_frame
		var actual: Array[Transform3D] = _evaluated_poses.duplicate()
		var error := 0.0
		for bone in initial.size():
			var expected := initial[bone].interpolate_with(target[bone], 0.5)
			error = maxf(error, actual[bone].origin.distance_to(expected.origin))
			error = maxf(error, actual[bone].basis.get_rotation_quaternion().angle_to(expected.basis.get_rotation_quaternion()))
		_check(error < 0.002, "pose error halves after one half-life at %d Hz (error %.5f)" % [hz, error])
		var diagram := matcher.get_debug_state()
		_check(diagram.pose_available and diagram.pose_target.distance_to(target_projection) < 0.00001, "diagram P reports the native animation target, not a UI-only point")
		_check(diagram.pose_current.distance_to(_evaluated_projection) < 0.00001, "diagram p reports the actual tracked pre-IK bones")
		_check(diagram.pose_current.distance_to(diagram.pose_target) > 0.001, "diagram exposes real pose lag instead of placing both markers at P")
		# Disabling, teleport/reset, and leaving locomotion must not retain stale p.
		for mode in ["disabled", "zero half-life", "reset", "airborne"]:
			# Establish fresh lag before EACH operation; otherwise a previous bypass
			# could make the reset/airborne checks pass without clearing stale history.
			matcher.set("pose_smoothing_enabled", true)
			matcher.set("pose_half_life", 0.1)
			for frame in 2:
				matcher.update(0.05, &"Grounded", Vector3.LEFT * run, Vector3.LEFT * run, _character.get_node("Visual").global_basis, 18.0, walk, run)
				_tree.advance(0.05)
				_skeleton.advance(1.0 / hz)
				await process_frame
			if mode == "disabled": matcher.set("pose_smoothing_enabled", false)
			elif mode == "zero half-life": matcher.set("pose_half_life", 0.0)
			elif mode == "reset": matcher.reset()
			else: matcher.update(1.0 / hz, &"Fall", Vector3.ZERO, Vector3.ZERO, Basis.IDENTITY, 18.0, walk, run)
			_tree.advance(0.0)
			var raw := _bone_poses()
			_skeleton.advance(1.0 / hz)
			await process_frame
			actual = _evaluated_poses.duplicate()
			var bypass_error := 0.0
			for bone in raw.size():
				bypass_error = maxf(bypass_error, actual[bone].origin.distance_to(raw[bone].origin))
				bypass_error = maxf(bypass_error, actual[bone].basis.get_rotation_quaternion().angle_to(raw[bone].basis.get_rotation_quaternion()))
			_check(bypass_error < 0.002, "%s bypasses old tracking history" % mode)

func _foot_projection() -> Vector2:
	return Vector2(_skeleton.get_bone_global_pose(_skeleton.find_bone("LeftFoot")).origin.z, _skeleton.get_bone_global_pose(_skeleton.find_bone("RightFoot")).origin.z)

func _bone_poses() -> Array[Transform3D]:
	var poses: Array[Transform3D] = []
	for bone in _skeleton.get_bone_count(): poses.append(_skeleton.get_bone_pose(bone))
	return poses

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
