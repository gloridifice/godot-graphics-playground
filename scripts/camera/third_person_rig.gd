class_name ThirdPersonRig
extends Node3D

@export var sensitivity: float = 0.0025
@export var target: Node3D
@onready var phantom: PhantomCamera3D = $PhantomCamera3D
var _yaw: float = 0.0
var _pitch: float = deg_to_rad(-18.0)

func _ready() -> void:
	phantom.follow_target = target
	_apply_orbit()
	# All scenes start in inspection mode; entering gameplay requires an explicit F press.
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func _exit_tree() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("release_mouse"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("capture_mouse"):
		_capture()
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_yaw = wrapf(_yaw - event.screen_relative.x * sensitivity, -PI, PI)
		_pitch = clampf(_pitch - event.screen_relative.y * sensitivity, deg_to_rad(-65.0), deg_to_rad(10.0))
		_apply_orbit()

func get_movement_basis() -> Basis:
	return Basis(Vector3.UP, _yaw)

func _apply_orbit() -> void:
	phantom.set_third_person_rotation(Vector3(_pitch, _yaw, 0.0))

func _capture() -> void:
	if get_window().has_focus():
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
