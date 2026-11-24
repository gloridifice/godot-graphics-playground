extends "res://addons/split_radiance_cascades/preview_controls.gd"
const MODES := ["ReSTIR DI", "Raw ReSTIR DI", "Single-frame RIS", "All lights"]

func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_R: gi.direct_mode = (int(gi.direct_mode)+1) % MODES.size() as RC.DirectMode
			KEY_I: gi.view = RC.View.DIRECT_ONLY if gi.view != RC.View.DIRECT_ONLY else RC.View.COMPOSITE
			_:
				super._unhandled_key_input(event)
				return
		_caption()
		get_viewport().set_input_as_handled()

func _caption() -> void:
	super._caption()
	$HUD/Caption.text += "\nR  sampler: %s     I  direct only" % MODES[gi.direct_mode]
