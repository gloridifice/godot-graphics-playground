@tool
class_name FFTDeformer3D
extends Node

signal configuration_changed
@export var enabled: bool = true:
	set(value):
		enabled = value
		configuration_changed.emit()
@export var settings: WaterFFTSettings:
	set(value):
		if settings != null and settings.changed.is_connected(_changed):
			settings.changed.disconnect(_changed)
		settings = value
		if settings != null:
			settings.changed.connect(_changed)
		_changed()

func _init() -> void:
	settings = WaterFFTSettings.new()

func _changed() -> void:
	configuration_changed.emit()

func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if not get_parent() is WaterBody3D:
		warnings.append("FFTDeformer3D must be a direct child of WaterBody3D.")
	if settings == null:
		warnings.append("Assign a WaterFFTSettings asset.")
	elif not settings.validation_error().is_empty():
		warnings.append(settings.validation_error())
	return warnings
