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
	Engine.physics_ticks_per_second = 60
	await _touchdown(60, false, true)
	await _touchdown(60, false, false, true)
	await _mixed_gait()
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

func _mixed_gait() -> void:
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
	var speed := (character.walk_speed + character.run_speed) * 0.5
	var planted := [0, 0]
	var previous_phase := ["", ""]
	var previous := [Vector3.ZERO, Vector3.ZERO]
	var slip := 0.0
	# Enter the blend from an established walk, rather than a lucky shared rest phase.
	for frame in 420:
		await physics_frame
		var velocity := Vector3.FORWARD * (character.walk_speed if frame < 180 else speed)
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
	_check(planted.min() > 5 and slip < 0.012, "50% walk/run with real blended contact curves still produces bilateral stationary support")
	print("Mixed gait stance=",planted," slip=",slip)
	stage.free()
	await process_frame

func _capture_soles(skeleton: Skeleton3D, output: Array[Vector3]) -> void:
	for side in 2:
		output[side] = skeleton.global_transform * skeleton.get_bone_global_pose(skeleton.find_bone("LeftFoot" if side == 0 else "RightFoot")) * SOLE

func _check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		printerr("FAIL: ",message)
