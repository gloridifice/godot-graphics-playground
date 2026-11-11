extends Node3D

func _ready() -> void:
	for child in get_children():
		if child is HeightfieldFogBox and not child.is_bake_current():
			child.bake()
