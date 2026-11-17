extends SceneTree
## Real physics + native animation curves + final IK bones. No input focus or renderer required.
const SOLE := Vector3(0.0, -0.17, 0.08)
var failures := 0

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	for rate in [60, 120]:
		Engine.physics_ticks_per_second = rate
		await _touchdown(rate)
		await _touchdown(rate, true)
	for moving in [false, true]:
		var previous: Dictionary = {}
		for rate in [60, 120, 240]:
			Engine.physics_ticks_per_second = rate
			var boundary := await _release(rate, moving)
			if not previous.is_empty():
				for metric in boundary:
					_check(boundary[metric] < previous[metric] * 0.7 + 0.002, "release %s converges with tick size at %d Hz, moving=%s (%.4f -> %.4f)" % [metric, rate, moving, previous[metric], boundary[metric]])
			previous = boundary
	for rate in [60, 120, 240]:
		Engine.physics_ticks_per_second = rate
		await _walking_release(rate)
	Engine.physics_ticks_per_second = 60
	await _walking_release(60, true)
	await _touchdown(60, false, true)
	await _touchdown(60, false, false, true)
	await _mixed_gait()
	for sample: Array in [[Vector3(-1, 0, -1), 0.0], [Vector3(1, 0, -1), 0.5], [Vector3(-1, 0, 1), 1.0], [Vector3(1, 0, 1), 0.0]]:
		await _mixed_gait(sample[0].normalized(), sample[1])
	print("Motion contact transition: ", "PASS" if failures == 0 else "FAIL")
	quit(0 if failures == 0 else 1)

func _stage() -> Node3D:
	var stage := Node3D.new()
	root.add_child(stage)
	var floor_body := StaticBody3D.new()
	floor_body.name = "Floor"
	stage.add_child(floor_body)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(160, 1, 160)
	shape.shape = box
	shape.position.y = -0.5
	floor_body.add_child(shape)
	return stage

func _touchdown(rate: int, moving := false, raised := false, interrupt := false) -> void:
	var stage := _stage()
	var floor_body := stage.get_node("Floor") as StaticBody3D
	var support: Node3D = floor_body
	if raised:
		# Real IK-query geometry on a separate, production-configurable collision layer.
		# The body stays on its floor while the foot must approach an 8 cm higher plane.
		var ledge := StaticBody3D.new()
		ledge.collision_layer = 4
		ledge.position.y = 0.08
		stage.add_child(ledge)
		ledge.add_child(floor_body.get_child(0).duplicate())
		support = ledge
	var character := load("res://addons/motion/motion_character.tscn").instantiate() as MotionCharacter
	character.position.y = 0.04
	stage.add_child(character)
	character.set_physics_process(false)
	character.foot_placement.settings = character.foot_placement.settings.duplicate()
	if raised: character.foot_placement.settings.collision_mask = 4
	(character.get_node("AnimationTree") as AnimationTree).active = false
	var player := character.get_node("AnimationPlayer") as AnimationPlayer
	player.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	var clip := player.get_animation("Idle").duplicate(true) as Animation
	clip.length = 1.0
	clip.loop_mode = Animation.LOOP_NONE
	for side in ["left", "right"]:
		var track := clip.find_track(NodePath("Skeleton3D/FootPlacement:%s_contact" % side), Animation.TYPE_VALUE)
		for key in range(clip.track_get_key_count(track) - 1, -1, -1): clip.track_remove_key(track, key)
		for key: Vector2 in [Vector2(0,0), Vector2(0.15,0), Vector2(0.35,1), Vector2(1,1)]:
			clip.track_insert_key(track, key.x, key.y)
	var library := AnimationLibrary.new()
	library.add_animation("landing", clip)
	player.add_animation_library("fixture", library)
	player.play("fixture/landing")
	var skeleton := character.get_node("Visual/Model/Skeleton3D") as Skeleton3D
	var final_sole: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
	character.foot_placement.get_node("../FootRotations").modification_processed.connect(_capture_soles.bind(skeleton, final_sole))
	var history: Array[Dictionary] = []
	var delta := 1.0 / rate
	for frame in ceili(0.58 * rate):
		await physics_frame
		var time := frame * delta
		if moving:
			stage.transform = Transform3D(Basis(Vector3.UP, time * 0.45), Vector3(time * 0.8, 0, time * 0.25))
		character.velocity = stage.global_basis * Vector3(1.5, 3.0 if interrupt and time >= 0.39 else -0.5, 0)
		character.move_and_slide()
		player.advance(delta)
		skeleton.advance(delta)
		await process_frame
		var state: Dictionary = character.foot_placement.get_debug_state().feet[0]
		history.append({"sole": support.global_transform.affine_inverse() * final_sole[0], "state": state})
		if state.phase == "Approach":
			var animated: Vector3 = state.animated * SOLE
			_check(Vector2(final_sole[0].x - animated.x, final_sole[0].z - animated.z).length() < 0.006, "Approach changes height/orientation without stealing horizontal motion")
		if state.contact < 0.08:
			_check(state.phase == "Swing" and state.weight < 0.001, "a ground hit alone cannot fabricate contact")
	if interrupt:
		var last: Dictionary = history[-1].state
		var animated: Vector3 = last.animated * SOLE
		_check(last.phase == "Swing" and last.weight == 0.0 and final_sole[0].distance_to(animated + Vector3.UP * character.foot_placement.get_debug_state().pelvis_drop) < 0.01, "jump during braking discards the unfinished trajectory and renders the airborne animation")
		stage.free()
		await process_frame
		return
	var braking_frames := 0
	var peak_speed_jump := 0.0
	var previous_velocity := Vector3(1.5, 0, 0)
	var terminal_speed := 1.5
	for frame in range(1, history.size()):
		var velocity: Vector3 = (history[frame].sole - history[frame - 1].sole) / delta
		if history[frame].state.contact >= 0.88:
			peak_speed_jump = maxf(peak_speed_jump, velocity.distance_to(previous_velocity))
			if velocity.x > 0.12 and velocity.x < 1.38: braking_frames += 1
			terminal_speed = velocity.length()
		previous_velocity = velocity
	_check(braking_frames >= ceili(0.035 * rate), "touchdown decelerates the FINAL shoe over several frames, not a one-frame stop")
	_check(peak_speed_jump < 0.65 * 60.0 / rate, "touchdown velocity changes remain bounded at %d Hz (jump %.3f)" % [rate, peak_speed_jump])
	_check(absf(terminal_speed) < 0.06 and history[-1].state.phase == "Stance", "deceleration ends in an actual stationary plant")
	_check(absf(history[-1].sole.y - 0.02) < 0.015, "the final shoe rests on the independently defined support plane")
	print("Contact ",rate,"Hz moving=",moving," raised=",raised," braking_frames=",braking_frames," peak_delta_v=",peak_speed_jump," terminal_speed=",terminal_speed)
	stage.free()
	await process_frame

func _release(rate: int, moving: bool) -> Dictionary:
	var stage := _stage()
	var character := load("res://addons/motion/motion_character.tscn").instantiate() as MotionCharacter
	character.position.y = 0.04
	stage.add_child(character)
	character.set_physics_process(false)
	(character.get_node("AnimationTree") as AnimationTree).active = false
	var player := character.get_node("AnimationPlayer") as AnimationPlayer
	player.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	# A held, bent-leg native pose leaves ample reach. Only body/support transport
	# and a real animation contact track move the target; no IK history is injected.
	var clip := player.get_animation("CrouchIdle").duplicate(true) as Animation
	clip.length = 1.2
	clip.loop_mode = Animation.LOOP_NONE
	for track in clip.get_track_count():
		var value: Variant = clip.track_get_key_value(track, 0)
		for key in range(clip.track_get_key_count(track) - 1, -1, -1): clip.track_remove_key(track, key)
		clip.track_insert_key(track, 0.0, value)
	for side in ["left", "right"]:
		var track := clip.find_track(NodePath("Skeleton3D/FootPlacement:%s_contact" % side), Animation.TYPE_VALUE)
		clip.track_set_key_value(track, 0, 1.0)
		clip.track_insert_key(track, 0.65, 1.0)
		clip.track_insert_key(track, 0.651, 0.0)
	var library := AnimationLibrary.new()
	library.add_animation("release", clip)
	player.add_animation_library("fixture", library)
	player.play("fixture/release")
	var skeleton := character.get_node("Visual/Model/Skeleton3D") as Skeleton3D
	var poses: Array[Transform3D] = [Transform3D.IDENTITY, Transform3D.IDENTITY]
	character.foot_placement.get_node("../FootRotations").modification_processed.connect(_capture_poses.bind(skeleton, poses))
	var history: Array[Dictionary] = []
	var delta := 1.0 / rate
	for frame in ceili(rate * 1.05):
		await physics_frame
		var time := frame * delta
		if moving:
			stage.transform = Transform3D(Basis(Vector3.UP, time * 0.4), Vector3(time * 0.3, 0, time * -0.2))
		character.get_node("Visual").rotation.y = PI + time * 0.35
		character.velocity = stage.global_basis * Vector3(0.4, -0.5, 0)
		character.move_and_slide()
		player.advance(delta)
		var raw := skeleton.global_transform * skeleton.get_bone_global_pose(skeleton.find_bone("LeftFoot"))
		skeleton.advance(delta)
		await process_frame
		var state := character.foot_placement.get_debug_state()
		history.append({"pose": poses[0], "raw": raw, "state": state.feet[0], "pelvis": state.pelvis_drop})
	var boundary := {"entry_velocity": 0.0, "entry_spin": 0.0, "exit_velocity": 0.0, "exit_spin": 0.0}
	var entries := 0
	var exits := 0
	for frame in range(2, history.size() - 1):
		var state: Dictionary = history[frame].state
		var previous: Dictionary = history[frame - 1].state
		if state.phase == "Release" and previous.phase == "Stance":
			entries += 1
			boundary.entry_velocity = _velocity_jump(history, frame, delta)
			boundary.entry_spin = _spin_jump(history, frame, delta)
			_check(history[frame - 1].pose.origin.distance_to(history[frame - 1].raw.origin) > 0.08, "release fixture accumulates a real lock/animation gap")
		if state.phase == "Swing" and previous.phase == "Release":
			exits += 1
			# Include the adjoining intervals: floating-point completion may leave
			# one extra zero-residual Release tick before the phase changes.
			for offset in [-1, 0, 1]:
				boundary.exit_velocity = maxf(boundary.exit_velocity, _velocity_jump(history, frame + offset, delta))
				boundary.exit_spin = maxf(boundary.exit_spin, _spin_jump(history, frame + offset, delta))
		if state.phase == "Release":
			_check(not state.reach_limited, "release continuity fixture remains inside leg reach")
	var last: Dictionary = history[-1]
	var expected: Transform3D = last.raw
	expected.origin.y += last.pelvis
	_check(entries == 1 and exits == 1, "one actual stance releases completely at %d Hz, moving=%s" % [rate, moving])
	_check(last.pose.origin.distance_to(expected.origin) < 0.002 and last.pose.basis.get_rotation_quaternion().angle_to(expected.basis.get_rotation_quaternion()) < 0.002, "release rejoins the independently sampled native pose without a residual lock")
	print("Release ",rate,"Hz moving=",moving," ",boundary)
	stage.free()
	await process_frame
	return boundary

func _walking_release(rate: int, interrupt := false) -> void:
	# Full production controller + scripted input, not manual body/animation advancement.
	# The held crouch fixture never straightens its knees: an ankle-only C1 test
	# misses the IK reach singularity inside Release.
	var stage := _stage()
	var character := load("res://addons/motion/motion_character.tscn").instantiate() as MotionCharacter
	character.position.y = 0.04
	stage.add_child(character)
	character.set_external_input(Vector2.ZERO)
	var skeleton := character.get_node("Visual/Model/Skeleton3D") as Skeleton3D
	var raw: Array[Quaternion] = []
	var history: Array[Dictionary] = []
	skeleton.get_node("MotionPoseSample").modification_processed.connect(_capture_leg_rotations.bind(skeleton, raw))
	skeleton.get_node("FootRotations").modification_processed.connect(_record_walking_frame.bind(skeleton, character, raw, history))
	var interrupted := false
	var began := Engine.get_physics_frames()
	var ticks := 0
	while ticks < rate * (8 if interrupt else 6):
		await physics_frame
		ticks = Engine.get_physics_frames() - began
		character.set_external_input(Vector2(0, -1) if ticks >= rate / 2 else Vector2.ZERO)
		await process_frame
		var feet: Array = character.foot_placement.get_debug_state().feet
		if interrupt and not interrupted and ticks > rate and feet.any(func(foot: Dictionary): return foot.phase == "Release"):
			character.set_external_input(Vector2(0, -1), false, false, true)
			interrupted = true
		_check(Input.mouse_mode == Input.MOUSE_MODE_VISIBLE, "walking regression never captures the mouse")
	var releases := [0, 0]
	var peak_step := [0.0, 0.0]
	var peak_raw := 0.0
	var airborne := 0
	var landed := false
	# Inspect EVERY skeleton tick, including physics catch-up ticks within one
	# render frame; render sampling would turn two valid steps into a false pop.
	for frame in range(rate + 1, history.size()):
		var now: Dictionary = history[frame]
		var previous: Dictionary = history[frame - 1]
		if interrupt and not now.grounded:
			airborne += 1
			_check(now.feet.all(func(foot: Dictionary): return foot.phase == "Swing" and foot.weight == 0.0), "jump during Release immediately discards both ground constraints")
			for index in now.final.size():
				_check(_quaternion_angle(now.final[index] * now.raw[index].inverse()) < 0.002, "jump during Release renders the native leg pose without stale joint residuals")
		elif interrupt and airborne > 0:
			landed = true
		for side in 2:
			if now.grounded and (now.feet[side].phase == "Release" or previous.feet[side].phase == "Release"):
				for joint in 2:
					var index := side * 2 + joint
					peak_step[side] = maxf(peak_step[side], _quaternion_angle(now.final[index] * previous.final[index].inverse()))
					peak_raw = maxf(peak_raw, _quaternion_angle(now.raw[index] * previous.raw[index].inverse()))
				if now.feet[side].phase == "Swing":
					releases[side] += 1
					for joint in 2:
						var index := side * 2 + joint
						_check(_quaternion_angle(now.final[index] * now.raw[index].inverse()) < 0.002, "released thigh/knee return to the native animation, not a stale IK pose")
	if interrupt: _check(interrupted and airborne > 10 and landed, "real jump interrupts Release and lands before the walking regression resumes")
	# 7 degrees per 60 Hz tick (420 deg/s): no single-frame straight-to-bent pop,
	# including the middle of Release, not only its mathematically smooth endpoints.
	var limit := deg_to_rad(7.0) * 60.0 / rate
	_check(releases.min() >= 4 and peak_raw < limit, "native walking exercises repeated bilateral releases without an input pose jump")
	_check(peak_step.max() < limit, "walking final thigh/knee stay below release angular-speed limit at %d Hz: %s deg/tick" % [rate, [rad_to_deg(peak_step[0]), rad_to_deg(peak_step[1])]])
	print("Walking release ", rate, "Hz interrupted=", interrupt, " exits=", releases, " peak_deg=", [rad_to_deg(peak_step[0]), rad_to_deg(peak_step[1])])
	stage.free()
	await process_frame

func _record_walking_frame(skeleton: Skeleton3D, character: MotionCharacter, raw: Array[Quaternion], history: Array[Dictionary]) -> void:
	var final: Array[Quaternion] = []
	_capture_leg_rotations(skeleton, final)
	history.append({"final": final, "raw": raw.duplicate(), "feet": character.foot_placement.get_debug_state().feet, "grounded": character.is_on_floor()})

func _capture_leg_rotations(skeleton: Skeleton3D, output: Array[Quaternion]) -> void:
	output.clear()
	for name in ["LeftUpLeg", "LeftLeg", "RightUpLeg", "RightLeg"]:
		output.append(skeleton.get_bone_pose_rotation(skeleton.find_bone(name)))

func _quaternion_angle(rotation: Quaternion) -> float:
	return 2.0 * atan2(Vector3(rotation.x, rotation.y, rotation.z).length(), absf(rotation.w))

func _capture_poses(skeleton: Skeleton3D, output: Array[Transform3D]) -> void:
	for side in 2:
		output[side] = skeleton.global_transform * skeleton.get_bone_global_pose(skeleton.find_bone("LeftFoot" if side == 0 else "RightFoot"))

func _velocity_jump(history: Array[Dictionary], frame: int, delta: float) -> float:
	var before: Vector3 = (history[frame - 1].pose.origin - history[frame - 2].pose.origin) / delta
	var after: Vector3 = (history[frame].pose.origin - history[frame - 1].pose.origin) / delta
	return after.distance_to(before)

func _spin_jump(history: Array[Dictionary], frame: int, delta: float) -> float:
	var spins: Array[Vector3] = []
	for index in [frame - 1, frame]:
		var rotation: Quaternion = (history[index].pose.basis * history[index - 1].pose.basis.inverse()).orthonormalized().get_rotation_quaternion()
		if rotation.w < 0.0: rotation = -rotation
		var vector := Vector3(rotation.x, rotation.y, rotation.z)
		spins.append(vector.normalized() * (2.0 * atan2(vector.length(), rotation.w)) / delta)
	return spins[0].distance_to(spins[1])

func _mixed_gait(direction: Vector3 = Vector3.FORWARD, run_blend: float = 0.5) -> void:
	var stage := _stage()
	var character := load("res://addons/motion/motion_character.tscn").instantiate() as MotionCharacter
	character.position.y = 0.04
	stage.add_child(character)
	character.set_physics_process(false)
	var tree := character.get_node("AnimationTree") as AnimationTree
	var skeleton := character.get_node("Visual/Model/Skeleton3D") as Skeleton3D
	(tree.get("parameters/playback") as AnimationNodeStateMachinePlayback).start("Grounded")
	var soles: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
	character.foot_placement.get_node("../FootRotations").modification_processed.connect(_capture_soles.bind(skeleton, soles))
	var speed := lerpf(character.walk_speed, character.run_speed, run_blend)
	var planted := [0, 0]
	var previous_phase := ["", ""]
	var previous := [Vector3.ZERO, Vector3.ZERO]
	var slip := 0.0
	# Enter the blend from an established walk, rather than a lucky shared rest phase.
	for frame in 420:
		await physics_frame
		var velocity := Vector3.FORWARD * character.walk_speed if frame < 180 else direction * speed
		character.velocity = velocity + Vector3(0, -0.5, 0)
		character.move_and_slide()
		character.motion_matching.update(1.0 / 60.0, &"Grounded", velocity, velocity, character.get_node("Visual").global_basis, 18.0, character.walk_speed, character.run_speed, character.crouch_speed)
		tree.advance(1.0 / 60.0)
		skeleton.advance(1.0 / 60.0)
		await process_frame
		var feet: Array = character.foot_placement.get_debug_state().feet
		if frame < 180: continue
		for side in 2:
			if feet[side].phase == "Stance":
				planted[side] += 1
				if previous_phase[side] == "Stance": slip = maxf(slip, soles[side].distance_to(previous[side]))
			previous_phase[side] = feet[side].phase
			previous[side] = soles[side]
	_check(planted.min() > 5 and slip < 0.012, "direction %s, run %.0f%%: blended contacts produce bilateral stationary support" % [direction, run_blend * 100.0])
	print("Mixed gait direction=",direction," run_blend=",run_blend," stance=",planted," slip=",slip)
	stage.free()
	await process_frame

func _capture_soles(skeleton: Skeleton3D, output: Array[Vector3]) -> void:
	for side in 2:
		output[side] = skeleton.global_transform * skeleton.get_bone_global_pose(skeleton.find_bone("LeftFoot" if side == 0 else "RightFoot")) * SOLE

func _check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		printerr("FAIL: ",message)
