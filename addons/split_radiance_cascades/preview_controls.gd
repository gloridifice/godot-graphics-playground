extends Node3D
## Shared controls for the room and Sponza. Never registers global input actions.
const RC := preload("split_radiance_cascades.gd")
const VIEWS := ["Composite", "Indirect only", "Stable probe slots", "Distance LOD", "Local interval"]
@export var navigation_hint := "← →  orbit"
@onready var gi: RC = $WorldEnvironment/SplitRadianceCascades
@onready var camera: Camera3D = $Camera3D

func _ready() -> void:
	_caption()

func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo:
		return
	match event.keycode:
		KEY_G: gi.enabled = not gi.enabled
		KEY_B: gi.multi_bounce = not gi.multi_bounce
		KEY_V: gi.view = (int(gi.view)+1) % VIEWS.size() as RC.View
		KEY_C: gi.debug_cascade = (gi.debug_cascade+1) % 4
		_: return
	_caption()
	get_viewport().set_input_as_handled()

func _caption() -> void:
	var view_name: String = "Direct only" if gi.view == RC.View.DIRECT_ONLY else VIEWS[gi.view]
	$HUD/Caption.text = "Split Radiance Cascades   |   %s   ·   %s   ·   C%d\nG  effect     B  bounces     V  view     C  cascade     P  timings\n%s" % [view_name if gi.enabled else "Effect off", "Multi-bounce" if gi.multi_bounce else "Single bounce", gi.debug_cascade, navigation_hint]
