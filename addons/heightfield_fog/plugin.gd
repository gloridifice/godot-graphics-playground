@tool
extends EditorPlugin

const Gizmo = preload("res://addons/heightfield_fog/box_gizmo.gd")
var _gizmo: EditorNode3DGizmoPlugin

func _enter_tree() -> void:
	_gizmo = Gizmo.new()
	_gizmo.undo_redo = get_undo_redo()
	add_node_3d_gizmo_plugin(_gizmo)

func _exit_tree() -> void:
	remove_node_3d_gizmo_plugin(_gizmo)
	_gizmo = null
