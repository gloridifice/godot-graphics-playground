extends Node3D

@onready var water: WaterBody3D = $Water
@onready var camera: Camera3D = $Camera3D
@onready var label: Label = $CanvasLayer/Help
var _distance := 72.0
var _yaw := 0.75
var _pitch := 0.46
var _target := Vector3(2, 0, 0)

func _ready() -> void:
	_update_camera()

func _process(_delta: float) -> void:
	var metrics := ""
	if water.gpu != null and water.gpu.ready:
		metrics = " | Sim GPU %.2f ms | CPU submit %.2f ms" % [water.gpu.gpu_time_ms,water.gpu.cpu_submit_ms]
	label.text = "Water: FFT → SWE | RMB drag: orbit | Wheel: zoom\nP: pause | R: reset | B: bake | C: caustics | F: foam | S: SSR | V: debug\n%s%s%s" % [water.status," [paused]" if water.paused else "",metrics]

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		_yaw -= event.relative.x * 0.005
		_pitch = clampf(_pitch + event.relative.y * 0.005,0.08,1.45)
		_update_camera()
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_distance = maxf(8.0,_distance * 0.9)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_distance = minf(180.0,_distance / 0.9)
		_update_camera()
	elif event is InputEventKey and event.pressed and not event.echo:
		match event.physical_keycode:
			KEY_P: water.paused = not water.paused
			KEY_R: water.reset()
			KEY_B: water.bake()
			KEY_C: water.caustics_settings.enabled = not water.caustics_settings.enabled
			KEY_F: water.foam_settings.enabled = not water.foam_settings.enabled
			KEY_S: water.ssr_settings.enabled = not water.ssr_settings.enabled
			KEY_V:
				var views := [0,7,9,11]
				water.material_settings.debug_view = views[(views.find(water.material_settings.debug_view)+1)%views.size()]

func _update_camera() -> void:
	camera.position = _target + Vector3(sin(_yaw)*cos(_pitch),sin(_pitch),cos(_yaw)*cos(_pitch))*_distance
	camera.look_at(_target)
