extends "preview_controls.gd"

var _angle := 0.0

func _process(delta: float) -> void:
	var turn := float(Input.is_key_pressed(KEY_RIGHT)) - float(Input.is_key_pressed(KEY_LEFT))
	if turn != 0.0:
		_angle = clampf(_angle + turn*delta*0.35, -0.55, 0.55)
		camera.position = Vector3(sin(_angle)*8.3, 2.05, cos(_angle)*8.3)
		camera.look_at(Vector3(0,2,0))
