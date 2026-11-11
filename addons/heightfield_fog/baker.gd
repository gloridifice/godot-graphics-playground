@tool
extends RefCounted

# Sample triangle interiors at cell centers, accepting only intersections inside
# the box's Y interval. This clips crossing slopes instead of rejecting whole faces.
static func bake(box: Node3D, root: Node, size: Vector3, resolution: int) -> ImageTexture:
	var image := Image.create(resolution, resolution, false, Image.FORMAT_RGF)
	var inverse := box.global_transform.affine_inverse()
	var stack: Array[Node] = [root]
	var hits := 0
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node == box or node is FogVolume:
			continue
		for child in node.get_children():
			stack.append(child)
		if not node is MeshInstance3D:
			continue
		var instance := node as MeshInstance3D
		if instance.mesh == null or instance.skin != null or not instance.is_visible_in_tree():
			continue
		if instance.is_in_group("heightfield_fog_ignore"):
			continue
		var transform := inverse * instance.global_transform
		var faces := instance.mesh.get_faces()
		for i in range(0, faces.size(), 3):
			var a := transform * faces[i]
			var b := transform * faces[i + 1]
			var c := transform * faces[i + 2]
			# Godot front faces are clockwise; reverse mathematical cross product.
			if (c - a).cross(b - a).normalized().y <= 0.5:
				continue
			var aa := Vector2(a.x, a.z)
			var bb := Vector2(b.x, b.z)
			var cc := Vector2(c.x, c.z)
			var area := (bb - aa).cross(cc - aa)
			if absf(area) < 0.0000001:
				continue
			var extent := Vector2(size.x, size.z)
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
					if old.g == 0.0:
						hits += 1
					if old.g == 0.0 or height > old.r:
						image.set_pixel(x, z, Color(height, 1.0, 0.0, 1.0))
	if hits == 0:
		return null
	return ImageTexture.create_from_image(image)
