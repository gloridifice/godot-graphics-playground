extends Camera3D
## Fly by default. Opt into a grounded, first-person torch without replacing the scene.
const Walker := preload("res://scenes/sponza_walk/player.gd")
const WalkScene := preload("res://scenes/sponza_walk/torch_player.tscn")
@export var viewpoints: Array[Marker3D] = []
@export var start_on_foot := false
var _walker: Walker
var _surface: StaticBody3D
var _owns_mouse := false

func _ready() -> void:
	get_parent().navigation_hint = "Fly: " + get_parent().navigation_hint + "\nF  torch walk / lock mouse    Mouse  look    WASD / Shift  walk / run    T  torch    Esc  release    Tab  fly"
	get_window().focus_exited.connect(_release_mouse)
	set_physics_process(false)
	if start_on_foot:
		_enter_walk.call_deferred(_arcade()) # show the torch at launch; capture only on F

func _arcade() -> Transform3D:
	return viewpoints[2].global_transform if viewpoints.size() > 2 and viewpoints[2] else global_transform

func _enter_walk(pose: Transform3D) -> void:
	if _walker: return
	var subject: Node3D = get_node("../Subject")
	if not _surface:
		_surface = Walker.make_walk_surface(subject.get_node("TraceProxy/Palace"))
		if not _surface:
			push_warning("Sponza torch walk: missing palace walk surface."); return
	_walker = WalkScene.instantiate()
	subject.add_child(_walker) # the live OmniLight must be below SRC's source root
	_walker.enter(pose, _arcade())
	set_physics_process(true)

func _leave_walk() -> void:
	_release_mouse()
	global_transform = _walker.eyes.global_transform
	reset_physics_interpolation()
	make_current()
	_walker.hide() # withdraw the light immediately, even before deferred deletion
	_walker.queue_free()
	_walker = null
	set_physics_process(false)

func _release_mouse() -> void:
	if _owns_mouse and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_owns_mouse = false

func _locked() -> bool:
	return _owns_mouse and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and get_window().has_focus()

func _physics_process(delta: float) -> void:
	if not _walker: return
	var axis := Input.get_vector("move_left", "move_right", "move_forward", "move_back") if _locked() else Vector2.ZERO
	_walker.walk(axis, _locked() and Input.is_physical_key_pressed(KEY_SHIFT), delta)

func _process(delta: float) -> void:
	if _walker or not get_window().has_focus(): return
	rotation.y += _axis(KEY_RIGHT, KEY_LEFT) * delta * 1.35
	rotation.x = clampf(rotation.x + _axis(KEY_DOWN, KEY_UP) * delta, -1.45, 1.45)
	var move := basis * Vector3(_axis(KEY_A,KEY_D), 0, _axis(KEY_W,KEY_S))
	move.y += _axis(KEY_Q,KEY_E)
	position += move.limit_length() * delta * (7.0 if Input.is_key_pressed(KEY_SHIFT) else 3.0)

func _axis(negative: Key, positive: Key) -> float:
	return float(Input.is_physical_key_pressed(positive)) - float(Input.is_physical_key_pressed(negative))

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and _walker and _locked():
		_walker.look(event.screen_relative)
		get_viewport().set_input_as_handled()

func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo: return
	if event.is_action_pressed("capture_mouse"):
		if not _walker: _enter_walk(global_transform)
		if _locked(): _release_mouse()
		elif _walker and get_window().has_focus():
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			_owns_mouse = true
	elif _walker:
		match event.keycode:
			KEY_ESCAPE: _release_mouse()
			KEY_T: _walker.toggle_torch()
			KEY_TAB: _leave_walk()
			_: return # G/B/V/C/P still belong to the GI preview
	else:
		var index: int = event.keycode - KEY_1
		if index < 0 or index >= viewpoints.size(): return
		global_transform = viewpoints[index].global_transform
	get_viewport().set_input_as_handled()

func _exit_tree() -> void:
	_release_mouse()
