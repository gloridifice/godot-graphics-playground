extends SceneTree

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	if not await _memory_lifecycle():
		quit(1)
		return
	var scene := load("res://addons/heightfield_fog/fixtures/stacked_floors.tscn").instantiate() as Node3D
	for child in scene.get_children():
		if child is HeightfieldFogBox:
			child.source_root = NodePath("..")
	root.add_child(scene)
	current_scene = scene
	for i in 4:
		await process_frame
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
	print("PASS: memory-only save/load/re-entry, auto bake, stacked floors, rotated boxes, stale/failed bake handling, crossing-slope clipping")
	scene.free()
	slope_root.free()
	quit()

func _memory_lifecycle() -> bool:
	var scene := Node3D.new()
	scene.name = "MemoryFog"
	var surface := MeshInstance3D.new()
	surface.name = "Support"
	var plane := PlaneMesh.new()
	plane.size = Vector2(4, 4)
	surface.mesh = plane
	scene.add_child(surface)
	surface.owner = scene
	var box := HeightfieldFogBox.new()
	box.name = "Fog"
	box.size = Vector3(4, 3, 4)
	box.resolution = 16
	box.source_root = NodePath("..")
	scene.add_child(box)
	box.owner = scene
	root.add_child(scene)
	for i in 4:
		await process_frame
	if not _memory_check(box.is_bake_current(), "Entering an ordinary scene must automatically bake its static meshes"):
		return false
	var packed := PackedScene.new()
	if not _memory_check(packed.pack(scene) == OK, "Baked scene must pack successfully"):
		return false
	var path := "user://heightfield_fog_memory_test.tscn"
	if not _memory_check(ResourceSaver.save(packed, path) == OK, "Baked scene must save successfully"):
		return false
	var saved := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	var restored := saved.instantiate() as Node3D
	var restored_box := restored.get_node("Fog") as HeightfieldFogBox
	if not _memory_check(restored_box.height_map == null, "Saving and loading a baked scene must not retain its heightfield texture"):
		return false
	scene.free()
	restored.get_node("Support").position.y = 1.0
	root.add_child(restored)
	for i in 4:
		await process_frame
	if not _memory_check(restored_box.is_bake_current(), "A loaded scene must rebuild its in-memory bake"):
		return false
	if not _memory_check(is_equal_approx(restored_box.height_map.get_image().get_pixel(8, 8).r, 1.0), "Reloading must sample the new geometry, not the saved heightfield"):
		return false
	root.remove_child(restored)
	restored.get_node("Support").position.y = 2.0
	root.add_child(restored)
	for i in 4:
		await process_frame
	if not _memory_check(restored_box.is_bake_current(), "Re-entering the tree must rebuild the heightfield"):
		return false
	if not _memory_check(is_equal_approx(restored_box.height_map.get_image().get_pixel(8, 8).r, 2.0), "Re-entering the tree must sample the new geometry even when reusing the same scene instance"):
		return false
	restored.free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	return true

func _memory_check(condition: bool, message: String) -> bool:
	if not condition:
		printerr(message)
	return condition
