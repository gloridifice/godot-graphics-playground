class_name MotionCharacter
extends CharacterBody3D
## Feet-origin controller. Motion matching selects locomotion poses; physics owns displacement.

signal jumped(feet_position: Vector3)
signal landed(feet_position: Vector3)
signal ground_moved(from_feet: Vector3, to_feet: Vector3, duration: float)

@export_group("Movement")
@export_range(0.1, 10.0, 0.1) var walk_speed: float = 1.5
@export_range(0.1, 15.0, 0.1) var run_speed: float = 4.5
@export_range(0.1, 5.0, 0.1) var crouch_speed: float = 0.7
@export_range(1.0, 50.0, 0.5) var acceleration: float = 18.0
@export_range(1.0, 50.0, 0.5) var deceleration: float = 22.0
@export_range(1.0, 20.0, 0.1) var turn_speed: float = 12.0
@export_group("Jump and crouch")
@export_range(0.1, 15.0, 0.1) var jump_speed: float = 5.0
@export_range(0.7, 2.1, 0.05) var crouch_height: float = 1.6

const DEFAULT_KEYS := {
	&"move_left": KEY_A, &"move_right": KEY_D, &"move_forward": KEY_W,
	&"move_back": KEY_S, &"jump": KEY_SPACE, &"sprint": KEY_SHIFT,
	&"crouch": KEY_CTRL, &"capture_mouse": KEY_F, &"release_mouse": KEY_ESCAPE,
}

@onready var _collision: CollisionShape3D = $CollisionShape3D
@onready var _visual: Node3D = $Visual
@onready var _camera: Node3D = $CameraRig
@onready var _tree: AnimationTree = $AnimationTree
@onready var _playback: AnimationNodeStateMachinePlayback = _tree.get("parameters/playback")
@onready var _skeleton: Skeleton3D = $Visual/Model/Skeleton3D
@onready var foot_placement: MotionFootPlacement = $Visual/Model/Skeleton3D/FootPlacement
@onready var motion_matching: MotionMatcher = $MotionMatching
@onready var climbing: MotionClimbing = $Climbing
var _standing_shape: CapsuleShape3D
var _crouching_shape: CapsuleShape3D
var _crouched := false
var _has_touched_floor := false
var _previous_position := Vector3.ZERO
# Scripted/replay control is per character and never changes global Input or mouse mode.
var _external_control := false
var _external_axis := Vector2.ZERO
var _external_sprint := false
var _external_crouch := false
var _external_jump_down := false
var _external_jump_pending := false

func _enter_tree() -> void:
	# Package works in a fresh project; existing Input Map bindings are never overwritten.
	for action: StringName in DEFAULT_KEYS:
		if InputMap.has_action(action):
			continue
		InputMap.add_action(action)
		var event := InputEventKey.new()
		event.physical_keycode = DEFAULT_KEYS[action]
		InputMap.action_add_event(action, event)

func _ready() -> void:
	_standing_shape = _collision.shape.duplicate() as CapsuleShape3D
	_crouching_shape = _standing_shape.duplicate() as CapsuleShape3D
	_crouching_shape.height = clampf(crouch_height, _standing_shape.radius * 2.0, _standing_shape.height)
	_collision.shape = _standing_shape
	_collision.position.y = _standing_shape.height * 0.5
	# One explicit physics-frame pipeline: current body -> animation -> ordered skeleton modifiers.
	_tree.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	_skeleton.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_MANUAL
	foot_placement.bind_character(self)
	motion_matching.bind(_tree, _skeleton, foot_placement)
	var climb_pose := preload("res://addons/motion/climbing/climb_pose.gd").new()
	climb_pose.name = "ClimbPose"
	climb_pose.driver = climbing
	_skeleton.add_child(climb_pose)
	climbing.bind(self, _visual, _skeleton, _collision)
	var hand_rotation := preload("res://addons/motion/climbing/hand_rotation.gd").new()
	hand_rotation.name = "HandRotations"
	hand_rotation.driver = climbing
	_skeleton.add_child(hand_rotation)
	_playback = _tree.get("parameters/playback")
	_playback.start("Fall")
	_previous_position = global_position

func get_feet_position() -> Vector3:
	return global_position

func is_crouching() -> bool:
	return _crouched

func release_climb() -> void:
	climbing.release_from_input()

## Camera-relative input for automation, replays or scripted actors. Held jump is edge-triggered.
## Call clear_external_input() to return ownership to normal mouse-gated player input.
func set_external_input(axis: Vector2, sprint := false, crouch := false, jump := false) -> void:
	_external_control = true
	_external_axis = axis.limit_length(1.0)
	_external_sprint = sprint
	_external_crouch = crouch
	_external_jump_pending = _external_jump_pending or (jump and not _external_jump_down)
	_external_jump_down = jump
	get_node("CameraRig").set_process_input(false)

func clear_external_input() -> void:
	_external_control = false
	_external_axis = Vector2.ZERO
	_external_sprint = false
	_external_crouch = false
	_external_jump_down = false
	_external_jump_pending = false
	get_node("CameraRig").set_process_input(true)

func _physics_process(delta: float) -> void:
	if global_position.distance_to(_previous_position) > 1.0:
		motion_matching.reset()
	var controlling := _external_control or (Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and get_window().has_focus())
	var jump_pressed := _external_jump_pending if _external_control else Input.is_action_just_pressed("jump")
	_external_jump_pending = false # Consume on this tick, even in air; never queue a landing jump.
	var crouch_pressed := _external_crouch if _external_control else Input.is_action_pressed("crouch")
	var sprint_pressed := _external_sprint if _external_control else Input.is_action_pressed("sprint")
	var was_grounded := is_on_floor()
	var feet_before := get_feet_position()
	var wants_crouch := controlling and crouch_pressed and was_grounded and not climbing.is_attached()
	if wants_crouch:
		_set_crouched(true)
	elif _crouched and _can_stand():
		_set_crouched(false)

	var axis := _external_axis if _external_control else (Input.get_vector("move_left", "move_right", "move_forward", "move_back") if controlling else Vector2.ZERO)
	var direction: Vector3 = _camera.get_movement_basis() * Vector3(axis.x, 0.0, axis.y)
	var sprinting := controlling and sprint_pressed and not _crouched
	var speed := crouch_speed if _crouched else (run_speed if sprinting else walk_speed)
	var horizontal := Vector2(velocity.x, velocity.z)
	var target := Vector2(direction.x, direction.z) * speed
	horizontal = horizontal.move_toward(target, (acceleration if axis.length_squared() > 0.0 else deceleration) * delta)
	if not controlling:
		horizontal = Vector2.ZERO
	velocity.x = horizontal.x
	velocity.z = horizontal.y
	if direction.length_squared() > 0.001 and not climbing.is_attached():
		# Standing locomotion faces camera-forward: A/D/S are strafing/backpedalling.
		# Crouch retains turn-to-move because the source set only has forward crouch walking.
		var facing: Vector3 = direction if _crouched else -_camera.get_movement_basis().z
		_visual.rotation.y = rotate_toward(_visual.rotation.y, atan2(facing.x, facing.z), turn_speed * delta)

	var climbing_motion := climbing.physics_step(delta, direction)
	var taking_off := false
	if not climbing_motion:
		if was_grounded:
			velocity.y = 0.0
		else:
			velocity += get_gravity() * delta
		taking_off = was_grounded and controlling and not _crouched and jump_pressed
		if taking_off:
			velocity.y = jump_speed
	var impact_speed := maxf(-velocity.y, 0.0)
	move_and_slide()
	climbing.after_move()
	if not climbing_motion:
		climbing.try_attach()

	if taking_off and not is_on_floor():
		jumped.emit(feet_before)
	if is_on_floor():
		if not was_grounded and _has_touched_floor and impact_speed > 1.0:
			landed.emit(get_feet_position())
		_has_touched_floor = true
		if was_grounded and not taking_off and delta > 0.0:
			var travel := get_feet_position() - feet_before
			if Vector2(travel.x, travel.z).length() > 0.05 * delta:
				ground_moved.emit(feet_before, get_feet_position(), delta)
	_update_animation(delta, target)
	_previous_position = global_position
	_tree.advance(delta)
	_skeleton.advance(delta)
	_camera.position.y = lerpf(_camera.position.y, 1.15 if _crouched else 1.55, 1.0 - exp(-12.0 * delta))

func _set_crouched(value: bool) -> void:
	if _crouched == value:
		return
	_crouched = value
	_collision.shape = _crouching_shape if value else _standing_shape
	# Keep the bottom fixed, rather than lowering the CharacterBody into the floor.
	_collision.position.y = (_collision.shape as CapsuleShape3D).height * 0.5

func _can_stand() -> bool:
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = _standing_shape
	# Small floor clearance avoids treating the supporting surface as a ceiling.
	query.transform = Transform3D(global_basis, to_global(Vector3.UP * (_standing_shape.height * 0.5 + 0.02)))
	query.collision_mask = collision_mask
	query.exclude = [get_rid()]
	return get_world_3d().direct_space_state.intersect_shape(query, 1).is_empty()

func _update_animation(delta: float, target: Vector2) -> void:
	var next: StringName
	if climbing.is_attached():
		next = &"Climb"
	elif not is_on_floor():
		next = &"Jump" if velocity.y > 0.0 else &"Fall"
	else:
		next = &"Crouch" if _crouched else &"Grounded"
	if _playback.get_current_node() != next:
		_playback.travel(next)
	var real_velocity := get_real_velocity()
	if is_on_floor():
		# Platform transport is not a walking gait; planted feet follow platform-local anchors.
		real_velocity -= get_platform_velocity()
	real_velocity.y = 0.0
	var desired := Vector3(target.x, 0.0, target.y)
	# Predict along reachable wall tangents, not through a wall while the body is stopped.
	for index in get_slide_collision_count():
		var normal := get_slide_collision(index).get_normal()
		if normal.y < 0.6 and desired.dot(normal) < 0.0:
			desired = desired.slide(normal)
			desired.y = 0.0
	motion_matching.update(delta, next, real_velocity, desired, _visual.global_basis.orthonormalized(), acceleration if not desired.is_zero_approx() else deceleration, walk_speed, run_speed, crouch_speed)
