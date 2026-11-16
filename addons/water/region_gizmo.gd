@tool
extends EditorNode3DGizmoPlugin

var undo_redo: EditorUndoRedoManager

func _init() -> void:
	create_material("region", Color(0.1, 0.65, 1.0))
	create_handle_material("handles")

func _has_gizmo(node: Node3D) -> bool:
	return node is SWEDeformer3D

func _get_gizmo_name() -> String:
	return "Water SWE Region"

func _redraw(gizmo: EditorNode3DGizmo) -> void:
	gizmo.clear()
	var node := gizmo.get_node_3d() as SWEDeformer3D
	if node.bake_settings == null:
		return
	var size := node.bake_settings.size
	var points := PackedVector3Array()
	for y in [0.0, size.y]:
		points.append_array(PackedVector3Array([Vector3(-size.x/2,y,-size.z/2),Vector3(size.x/2,y,-size.z/2),Vector3(size.x/2,y,size.z/2),Vector3(-size.x/2,y,size.z/2)]))
	var lines := PackedVector3Array()
	for i in 4:
		for pair in [[i,(i+1)%4],[i+4,(i+1)%4+4],[i,i+4]]:
			lines.append(points[pair[0]])
			lines.append(points[pair[1]])
	gizmo.add_lines(lines, get_material("region", gizmo))
	gizmo.add_collision_segments(lines)
	gizmo.add_handles(PackedVector3Array([Vector3(size.x/2,0,0),Vector3(0,size.y,0),Vector3(0,0,size.z/2)]),get_material("handles",gizmo),PackedInt32Array([0,1,2]))

func _get_handle_name(_gizmo: EditorNode3DGizmo, id: int, _secondary: bool) -> String:
	return ["Width (m)","Bake height (m)","Depth (m)"][id]

func _get_handle_value(gizmo: EditorNode3DGizmo, _id: int, _secondary: bool) -> Variant:
	return gizmo.get_node_3d().bake_settings.size

func _set_handle(gizmo: EditorNode3DGizmo, id: int, _secondary: bool, camera: Camera3D, point: Vector2) -> void:
	var node := gizmo.get_node_3d() as SWEDeformer3D
	var inverse := node.global_transform.affine_inverse()
	var origin := inverse * camera.project_ray_origin(point)
	var end := inverse * (camera.project_ray_origin(point) + camera.project_ray_normal(point) * 10000.0)
	var axis := Vector3.ZERO
	axis[id] = 1.0
	var closest := Geometry3D.get_closest_points_between_segments(Vector3.ZERO,axis*10000.0,origin,end)
	var size := node.bake_settings.size
	size[id] = maxf(closest[0][id] * (1.0 if id == 1 else 2.0),0.1)
	node.bake_settings.size = size

func _commit_handle(gizmo: EditorNode3DGizmo, _id: int, _secondary: bool, restore: Variant, cancel: bool) -> void:
	var asset: WaterBakeSettings = gizmo.get_node_3d().bake_settings
	if cancel:
		asset.size = restore
		return
	undo_redo.create_action("Resize water SWE region")
	undo_redo.add_do_property(asset,"size",asset.size)
	undo_redo.add_undo_property(asset,"size",restore)
	undo_redo.commit_action()
