@tool
extends EditorNode3DGizmoPlugin

const BoxScript = preload("res://addons/heightfield_fog/heightfield_fog_box.gd")
var undo_redo: EditorUndoRedoManager

func _init() -> void:
	create_material("box", Color(0.3, 0.85, 1.0))
	create_handle_material("handles")

func _has_gizmo(node: Node3D) -> bool:
	return node is BoxScript

func _get_gizmo_name() -> String:
	return "Heightfield Fog"

func _redraw(gizmo: EditorNode3DGizmo) -> void:
	gizmo.clear()
	var box = gizmo.get_node_3d()
	var s: Vector3 = box.size
	var points := PackedVector3Array()
	for y in [0.0, s.y]:
		points.append_array(PackedVector3Array([Vector3(-s.x/2,y,-s.z/2), Vector3(s.x/2,y,-s.z/2), Vector3(s.x/2,y,s.z/2), Vector3(-s.x/2,y,s.z/2)]))
	var lines := PackedVector3Array()
	for i in 4:
		for pair in [[i, (i+1)%4], [i+4, (i+1)%4+4], [i, i+4]]:
			lines.append(points[pair[0]])
			lines.append(points[pair[1]])
	gizmo.add_lines(lines, get_material("box", gizmo))
	gizmo.add_collision_segments(lines)
	gizmo.add_handles(PackedVector3Array([Vector3(s.x/2,0,0), Vector3(0,s.y,0), Vector3(0,0,s.z/2)]), get_material("handles", gizmo), PackedInt32Array([0,1,2]))

func _get_handle_name(_gizmo: EditorNode3DGizmo, id: int, _secondary: bool) -> String:
	return ["Width", "Height", "Depth"][id]

func _get_handle_value(gizmo: EditorNode3DGizmo, _id: int, _secondary: bool) -> Variant:
	return gizmo.get_node_3d().size

func _set_handle(gizmo: EditorNode3DGizmo, id: int, _secondary: bool, camera: Camera3D, point: Vector2) -> void:
	var box = gizmo.get_node_3d()
	var inverse: Transform3D = box.global_transform.affine_inverse()
	var origin := inverse * camera.project_ray_origin(point)
	var end := inverse * (camera.project_ray_origin(point) + camera.project_ray_normal(point) * 10000.0)
	var axis := Vector3.ZERO
	axis[id] = 1.0
	var closest := Geometry3D.get_closest_points_between_segments(Vector3.ZERO, axis * 1000.0, origin, end)
	var value: Vector3 = box.size
	value[id] = maxf(closest[0][id] * (1.0 if id == 1 else 2.0), 0.1)
	box.size = value

func _commit_handle(gizmo: EditorNode3DGizmo, _id: int, _secondary: bool, restore: Variant, cancel: bool) -> void:
	var box = gizmo.get_node_3d()
	if cancel:
		box.size = restore
		return
	undo_redo.create_action("Resize fog box")
	undo_redo.add_do_property(box, "size", box.size)
	undo_redo.add_undo_property(box, "size", restore)
	undo_redo.commit_action()
