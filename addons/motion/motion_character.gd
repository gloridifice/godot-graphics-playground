class_name MotionCharacter
extends CharacterBody3D
## Feet-origin controller. Motion matching selects locomotion poses; physics owns displacement.

signal jumped(feet_position: Vector3)
signal landed(feet_position: Vector3)
signal ground_moved(from_feet: Vector3, to_feet: Vector3, duration: float)

@export_group("Movement")
@export_range(0.1, 10.0, 0.1) var walk_speed: float = 1.5
@export_range(0.1, 15.0, 0.1) var run_speed: float = 3.0
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
var _standing_shape: CapsuleShape3D
var _crouching_shape: CapsuleShape3D
var _crouched := false
var _has_touched_floor := false
var _previous_position := Vector3.ZERO

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
	_playback = _tree.get("parameters/playback")
	_playback.start("Fall")
	_previous_position = global_position

func get_feet_position() -> Vector3:
	return global_position

func is_crouching() -> bool:
	return _crouched

func _physics_process(delta: float) -> void:
	if global_position.distance_to(_previous_position) > 1.0:
		motion_matching.reset()
	var controlling := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and get_window().has_focus()
	var was_grounded := is_on_floor()
	var feet_before := get_feet_position()
	var wants_crouch := controlling and Input.is_action_pressed("crouch") and was_grounded
	if wants_crouch:
		_set_crouched(true)
	elif _crouched and _can_stand():
		_set_crouched(false)

	var axis := Input.get_vector("move_left", "move_right", "move_forward", "move_back") if controlling else Vector2.ZERO
	var direction: Vector3 = _camera.get_movement_basis() * Vector3(axis.x, 0.0, axis.y)
	var sprinting := controlling and Input.is_action_pressed("sprint") and not _crouched
	var speed := crouch_speed if _crouched else (run_speed if sprinting else walk_speed)
	var horizontal := Vector2(velocity.x, velocity.z)
	var target := Vector2(direction.x, direction.z) * speed
	horizontal = horizontal.move_toward(target, (acceleration if axis.length_squared() > 0.0 else deceleration) * delta)
	if not controlling:
		horizontal = Vector2.ZERO
	velocity.x = horizontal.x
	velocity.z = horizontal.y
	if direction.length_squared() > 0.001:
		# Standing locomotion faces camera-forward: A/D/S are strafing/backpedalling.
		# Crouch retains turn-to-move because the source set only has forward crouch walking.
		var facing: Vector3 = direction if _crouched else -_camera.get_movement_basis().z
		_visual.rotation.y = rotate_toward(_visual.rotation.y, atan2(facing.x, facing.z), turn_speed * delta)

	if was_grounded:
		velocity.y = 0.0
	else:
		velocity += get_gravity() * delta
	var taking_off := was_grounded and controlling and not _crouched and Input.is_action_just_pressed("jump")
	if taking_off:
		velocity.y = jump_speed
	var impact_speed := maxf(-velocity.y, 0.0)
	move_and_slide()

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
	if not is_on_floor():
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
