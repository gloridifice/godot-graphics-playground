extends Node3D
## Native SpringArm3D orbit camera; no Phantom Camera or controller-plugin dependency.

@export_range(0.0001, 0.02, 0.0001) var mouse_sensitivity: float = 0.003
@export_range(1.5, 10.0, 0.1) var follow_distance: float = 4.5
@onready var _arm: SpringArm3D = $SpringArm3D

func _ready() -> void:
	_arm.spring_length = follow_distance
	_arm.add_excluded_object((get_parent() as CollisionObject3D).get_rid())
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func get_movement_basis() -> Basis:
	return Basis(Vector3.UP, global_rotation.y)

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.echo:
		return
	if event.is_action_pressed("capture_mouse"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED else Input.MOUSE_MODE_CAPTURED
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("release_mouse"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		get_viewport().set_input_as_handled()
	elif Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		if event is InputEventMouseMotion:
			rotation.y -= event.screen_relative.x * mouse_sensitivity
			rotation.x = clampf(rotation.x - event.screen_relative.y * mouse_sensitivity, deg_to_rad(-65.0), deg_to_rad(35.0))
		elif event is InputEventMouseButton and event.pressed:
			if event.button_index == MOUSE_BUTTON_WHEEL_UP:
				_arm.spring_length = maxf(1.5, _arm.spring_length - 0.4)
			elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				_arm.spring_length = minf(10.0, _arm.spring_length + 0.4)

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func _exit_tree() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
