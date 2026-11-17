extends Node3D
## Demo-only comparison controls and checkpoints, not part of character movement or IK.

const CHECKPOINTS := ["Flat", "Split-height blocks", "Stairs (W goes down)", "Sphere", "Slope", "Cross-slope", "Moving platform", "Climb: ceiling (jump)", "Climb: wall (jump + W)"]
@onready var _player: MotionCharacter = $Player
@onready var _status: Label = $Controls/FootPanel/Rows/Status
@onready var _toggle_all: CheckButton = $Controls/FootPanel/Rows/Enabled
@onready var _toggle_smoothing: CheckButton = $Controls/FootPanel/Rows/PoseSmoothing
@onready var _half_life_slider: HSlider = $Controls/FootPanel/Rows/PoseHalfLife
@onready var _half_life_label: Label = $Controls/FootPanel/Rows/PoseHalfLifeLabel
@onready var _toggle_debug: CheckButton = $Controls/FootPanel/Rows/Debug
@onready var _toggle_left: CheckButton = $Controls/FootPanel/Rows/Legs/Left
@onready var _toggle_right: CheckButton = $Controls/FootPanel/Rows/Legs/Right
@onready var _pelvis_slider: HSlider = $Controls/FootPanel/Rows/PelvisLimit
var _checkpoint := 0

func _ready() -> void:
	var feet := _player.foot_placement
	_toggle_smoothing.toggled.connect(func(value: bool): _player.motion_matching.pose_smoothing_enabled = value)
	_half_life_slider.value = _player.motion_matching.pose_half_life
	_half_life_slider.value_changed.connect(func(value: float): _player.motion_matching.pose_half_life = value)
	# The panel edits this demo instance, never the shared preset or another character.
	feet.settings = feet.settings.duplicate() as MotionFootSettings
	_toggle_all.toggled.connect(func(value: bool): feet.enabled = value)
	_toggle_debug.toggled.connect(func(value: bool): feet.draw_debug = value)
	_toggle_left.toggled.connect(func(value: bool): feet.left_enabled = value)
	_toggle_right.toggled.connect(func(value: bool): feet.right_enabled = value)
	_pelvis_slider.value = feet.settings.max_pelvis_drop
	_pelvis_slider.value_changed.connect(func(value: float): feet.settings.max_pelvis_drop = value)

func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo:
		return
	var feet := _player.foot_placement
	match event.physical_keycode:
		KEY_F3:
			feet.draw_debug = not feet.draw_debug
		KEY_F4:
			feet.enabled = not feet.enabled
		KEY_F5:
			_player.motion_matching.pose_smoothing_enabled = not _player.motion_matching.pose_smoothing_enabled
		KEY_1:
			feet.left_enabled = not feet.left_enabled
		KEY_2:
			feet.right_enabled = not feet.right_enabled
		KEY_TAB:
			_checkpoint = (_checkpoint + 1) % CHECKPOINTS.size()
			_go_to_checkpoint()
		KEY_R:
			_go_to_checkpoint()
		_:
			return
	get_viewport().set_input_as_handled()

func _go_to_checkpoint() -> void:
	var yaw := 0.0
	match _checkpoint:
		0: _player.position = Vector3(0, 0.04, 0)
		1: _player.position = Vector3(4.5, 0.35, -9)
		2:
			_player.position = Vector3(0, 0.77, -15.3)
			yaw = PI
		3: _player.position = Vector3(-5.5, 0.78, -13)
		4: _player.position = Vector3(7, 0.6, -12.7)
		5: _player.position = Vector3(-8.5, 0.65, -15.5)
		6:
			var platform := $ValidationCourse/MovingPlatform as AnimatableBody3D
			_player.global_position = platform.global_position + Vector3.UP * 0.2
		7: _player.global_position = $ClimbingCourse.to_global(Vector3(10, 0.04, 7))
		8:
			_player.global_position = $ClimbingCourse.to_global(Vector3(10, 0.04, 3.1))
			yaw = PI
	_player.climbing.reset()
	_player.velocity = Vector3.ZERO
	_player.get_node("CameraRig").rotation.y = yaw
	_player.get_node("Visual").rotation.y = yaw + PI
	_player.foot_placement.reset()
	_player.motion_matching.reset()
	_player.reset_physics_interpolation()

func _process(_delta: float) -> void:
	var feet := _player.foot_placement
	_toggle_smoothing.set_pressed_no_signal(_player.motion_matching.pose_smoothing_enabled)
	_half_life_slider.set_value_no_signal(_player.motion_matching.pose_half_life)
	_half_life_label.text = "Pose half-life: %.3f s" % _player.motion_matching.pose_half_life
	_toggle_all.set_pressed_no_signal(feet.enabled)
	_toggle_debug.set_pressed_no_signal(feet.draw_debug)
	_toggle_left.set_pressed_no_signal(feet.left_enabled)
	_toggle_right.set_pressed_no_signal(feet.right_enabled)
	var state := feet.get_debug_state()
	var text := "\nTERRAIN / %s\nPelvis %.3f / %.2f m\n" % [CHECKPOINTS[_checkpoint], absf(state.pelvis_drop), feet.settings.max_pelvis_drop]
	for foot: Dictionary in state.feet:
		var detail := " / %.2f m/s" % foot.contact_velocity.length() if foot.phase == "Contact" else (" / reach limit" if foot.reach_limited else "")
		text += "\n%s / %s%s\nBlend %.2f  Contact %.2f  Ground %.2f\n" % [foot.side.to_upper(), foot.phase, detail, foot.weight, foot.contact, foot.distance_weight]
	var climb := _player.climbing.get_debug_state()
	text += "\nCLIMB / %s\n" % (climb.phase if climb.attached else ("ESC blocked until landing" if climb.blocked_until_grounded else "Airborne auto grab ready"))
	_status.text = text + "\nBlue: source  /  Yellow: approach\nOrange: braking  /  Green: locked\nMagenta: release  /  Cyan: normal"
