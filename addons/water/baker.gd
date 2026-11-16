@tool
class_name WaterHeightBaker
extends RefCounted

static func transform_error(node: Node3D) -> String:
	var basis := node.global_basis
	if not node.global_position.is_finite() or not basis.is_finite():
		return "Water transforms must be finite."
	if not basis.y.is_equal_approx(Vector3.UP) or not basis.get_scale().is_equal_approx(Vector3.ONE) or basis.determinant() < 0.0 or absf(basis.x.dot(basis.z)) > 0.0001 or absf(basis.x.y) > 0.0001 or absf(basis.z.y) > 0.0001:
		return "Water supports translation and Y rotation only; remove scale, pitch and roll (including ancestors)."
	return ""

## 单元中心最高向上表面。缺失标记不是干格，也不是高度零的海床。
static func bake(box: Node3D, root: Node, settings: WaterBakeSettings, resolution: int) -> Dictionary:
	var error := settings.validation_error()
	if error.is_empty():
		error = transform_error(box)
	if not error.is_empty() or root == null or resolution < 8 or resolution > 512:
		return {"error": error if not error.is_empty() else "Invalid source root or bake resolution."}
	var image := Image.create(resolution, resolution, false, Image.FORMAT_RGF)
	var inverse := box.global_transform.affine_inverse()
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node := stack.pop_back() as Node
		if node == box or (not settings.ignore_group.is_empty() and node.is_in_group(settings.ignore_group)) or node.has_meta("water_generated"):
			continue
		for child in node.get_children():
			stack.append(child)
		if node is MeshInstance3D:
			var instance := node as MeshInstance3D
			if instance.mesh != null and instance.skin == null and instance.is_visible_in_tree():
				_sample_mesh(image, instance.mesh, inverse * instance.global_transform, settings.size)
		elif node is CSGShape3D and node.is_root_shape() and node.is_visible_in_tree():
			# CSG 的最终布尔网格，不生成场景节点，也不改写碰撞或可编辑几何。
			var meshes: Array = node.get_meshes()
			if meshes.size() >= 2 and meshes[1] is Mesh:
				_sample_mesh(image, meshes[1], inverse * node.global_transform * meshes[0], settings.size)
	var hits := 0
	var filled := 0
	for z in resolution:
		for x in resolution:
			if image.get_pixel(x, z).g > 0.5:
				hits += 1
			elif settings.fallback_enabled:
				image.set_pixel(x, z, Color(settings.fallback_height, 1, 0, 1))
				filled += 1
	if hits + filled == 0:
		return {"error": "No bed surface intersects this region; choose a source, change the height interval, or explicitly enable fallback."}
	return {"image": image, "hits": hits, "fallback_cells": filled, "error": ""}

static func _sample_mesh(image: Image, mesh: Mesh, transform: Transform3D, size: Vector3) -> void:
	var resolution := image.get_width()
	var faces := mesh.get_faces()
	var extent := Vector2(size.x, size.z)
	var orientation := signf(transform.basis.determinant())
	for i in range(0, faces.size(), 3):
		var a := transform * faces[i]
		var b := transform * faces[i + 1]
		var c := transform * faces[i + 2]
		# Godot 顺时针正面。只剔除向下和投影退化面，不沿用雾的 60° 坡度限制。
		if (c - a).cross(b - a).y * orientation <= 0.00000001:
			continue
		var aa := Vector2(a.x, a.z)
		var bb := Vector2(b.x, b.z)
		var cc := Vector2(c.x, c.z)
		var area := (bb - aa).cross(cc - aa)
		if absf(area) < 0.00000001:
			continue
		var low := Vector2i(((aa.min(bb).min(cc) / extent + Vector2.ONE * 0.5) * resolution - Vector2.ONE * 0.5).ceil()).max(Vector2i.ZERO)
		var high := Vector2i(((aa.max(bb).max(cc) / extent + Vector2.ONE * 0.5) * resolution - Vector2.ONE * 0.5).floor()).min(Vector2i.ONE * (resolution - 1))
		for z in range(low.y, high.y + 1):
			for x in range(low.x, high.x + 1):
				var p := ((Vector2(x, z) + Vector2.ONE * 0.5) / resolution - Vector2.ONE * 0.5) * extent
				var u := (p - aa).cross(cc - aa) / area
				var v := (bb - aa).cross(p - aa) / area
				if u < -0.00001 or v < -0.00001 or u + v > 1.00001:
					continue
				var height := a.y + u * (b.y - a.y) + v * (c.y - a.y)
				if height < 0.0 or height > size.y:
					continue
				var old := image.get_pixel(x, z)
				if old.g < 0.5 or height > old.r:
					image.set_pixel(x, z, Color(height, 1, 0, 1))
