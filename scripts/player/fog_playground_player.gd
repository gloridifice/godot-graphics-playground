extends PlayerCharacter

signal mist_takeoff(feet_position: Vector3)
signal mist_landed(feet_position: Vector3)

var _has_touched_floor := false

func _physics_process(delta: float) -> void:
	var controlling := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	state_machine.set_physics_process(controlling)
	if not controlling:
		# Pausing inputs must not suspend gravity or hide a genuine landing.
		move_dir = Vector2.ZERO
		velocity.x = 0.0
		velocity.z = 0.0
		movement_dust.emitting = false
		gravity_apply(delta)
	var grounded := is_on_floor()
	var feet_before := get_feet_position()
	# The upstream state machine accepts jumps after this body's movement callback.
	# Observe its actual upward velocity on the next tick, not the raw input key.
	var taking_off := grounded and velocity.y > 0.1
	var falling_speed := -velocity.y
	super._physics_process(delta)
	if taking_off and not is_on_floor():
		mist_takeoff.emit(feet_before)
	if not grounded and is_on_floor() and _has_touched_floor and falling_speed > 1.0:
		mist_landed.emit(get_feet_position())
	if is_on_floor():
		_has_touched_floor = true

func get_feet_position() -> Vector3:
	var capsule := collision_shape_3d.shape as CapsuleShape3D
	return collision_shape_3d.to_global(Vector3.DOWN * capsule.height * 0.5)
