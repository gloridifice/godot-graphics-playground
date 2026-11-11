class_name PlaygroundPlayer
extends CharacterBody3D

signal jumped(feet_position: Vector3)
signal landed(feet_position: Vector3, impact_speed: float)

@export var walk_speed: float = 3.0
@export var jump_speed: float = 4.5
@export var camera_rig: Node3D
@onready var _capsule: CapsuleShape3D = $CollisionShape3D.shape
var _has_ground_contact: bool = false

func get_feet_position() -> Vector3:
	return global_position - Vector3.UP * (_capsule.height * 0.5)

func _physics_process(delta: float) -> void:
	var direction := Vector3.ZERO
	var controls_active := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and get_window().has_focus()
	var was_grounded := is_on_floor()
	if controls_active:
		var axis := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
		var movement_basis: Basis = camera_rig.get_movement_basis()
		direction = movement_basis * Vector3(axis.x, 0.0, axis.y)
	velocity.x = direction.x * walk_speed
	velocity.z = direction.z * walk_speed
	if not was_grounded:
		velocity += get_gravity() * delta
	else:
		velocity.y = 0.0
		if controls_active and Input.is_action_just_pressed("jump"):
			velocity.y = jump_speed
			jumped.emit(get_feet_position())
	var impact_speed := maxf(-velocity.y, 0.0)
	move_and_slide()
	if is_on_floor():
		# Initial spawn settling is not a landing action.
		if not was_grounded and _has_ground_contact and impact_speed > 0.5:
			landed.emit(get_feet_position(), impact_speed)
		_has_ground_contact = true
