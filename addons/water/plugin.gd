@tool
extends EditorPlugin

const RegionGizmo = preload("res://addons/water/region_gizmo.gd")
var _gizmo: EditorNode3DGizmoPlugin

func _enter_tree() -> void:
	_gizmo = RegionGizmo.new()
	_gizmo.undo_redo = get_undo_redo()
	add_node_3d_gizmo_plugin(_gizmo)

func _exit_tree() -> void:
	remove_node_3d_gizmo_plugin(_gizmo)
	_gizmo = null
