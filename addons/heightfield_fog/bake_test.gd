extends SceneTree

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var scene := load("res://addons/heightfield_fog/fixtures/stacked_floors.tscn").instantiate() as Node3D
	for child in scene.get_children():
		if child is HeightfieldFogBox:
			child.source_root = NodePath("..")
	root.add_child(scene)
	current_scene = scene
	var lower = scene.get_node("LowerFog")
	var upper = scene.get_node("UpperFog")
	for entry in [[lower, 0.0], [upper, 3.0]]:
		var box: Node3D = entry[0]
		assert(box.height_map != null, "Actual Godot clockwise meshes must bake")
		var image: Image = box.height_map.get_image()
		var count := 0
		for y in image.get_height():
			for x in image.get_width():
				var sample := image.get_pixel(x, y)
				if sample.g > 0.5:
					assert(absf(sample.r + box.position.y - entry[1]) < 0.001, "Separate box ceilings must select the correct floor")
					count += 1
		assert(count > image.get_width() * image.get_height() / 2)
	var previous: Texture2D = lower.height_map
	lower.position.y = 20.0
	assert(not lower.is_bake_current(), "Moved boxes must not render a stale bake")
	lower.bake()
	assert(lower.height_map == previous, "Empty rebakes must preserve the previous resource")
	lower.position.y = -0.2
	assert(lower.is_bake_current())
	# Crossing slopes: evaluate the original continuous plane, not clamped vertices.
	var slope_root := Node3D.new()
	root.add_child(slope_root)
	var slope := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(8, 8)
	slope.mesh = plane
	slope_root.add_child(slope)
	slope.position.y = 0.5
	slope.rotation.z = atan(0.25)
	var box := HeightfieldFogBox.new()
	slope_root.add_child(box)
	box.size = Vector3(6, 1, 6)
	box.resolution = 32
	box.source_root = NodePath("..")
	box.bake()
	assert(box.height_map != null)
	var slope_image := box.height_map.get_image()
	for x in 32:
		var expected_y := 0.5 + (-3.0 + (x + 0.5) * 6.0 / 32.0) * 0.25
		var value := slope_image.get_pixel(x, 16)
		assert((value.g > 0.5) == (expected_y >= 0.0 and expected_y <= 1.0), "Clip crossing surfaces per query")
		if value.g > 0.5:
			assert(absf(value.r - expected_y) < 0.001)
	print("PASS: stacked floors, rotated boxes, stale/failed bake handling, crossing-slope clipping")
	scene.free()
	slope_root.free()
	quit()
