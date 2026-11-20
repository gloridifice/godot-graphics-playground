extends Camera3D
## Keyboard-only fly camera: no cursor capture and no project InputMap changes.
@export var viewpoints: Array[Marker3D] = []

func _process(delta: float) -> void:
	if not get_window().has_focus():
		return
	rotation.y += _axis(KEY_RIGHT, KEY_LEFT) * delta * 1.35
	rotation.x = clampf(rotation.x + _axis(KEY_DOWN, KEY_UP) * delta, -1.45, 1.45)
	var move := basis * Vector3(_axis(KEY_A,KEY_D), 0, _axis(KEY_W,KEY_S))
	move.y += _axis(KEY_Q,KEY_E)
	position += move.limit_length() * delta * (7.0 if Input.is_key_pressed(KEY_SHIFT) else 3.0)

func _axis(negative: Key, positive: Key) -> float:
	return float(Input.is_physical_key_pressed(positive)) - float(Input.is_physical_key_pressed(negative))

func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		var index: int = event.keycode - KEY_1
		if index >= 0 and index < viewpoints.size():
			global_transform = viewpoints[index].global_transform
			get_viewport().set_input_as_handled()
