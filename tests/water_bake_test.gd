extends SceneTree

# Owner: editor terrain/asset contract. Numeric samples and real scene roundtrips
# catch clipping, missing-vs-zero and accidental heightfield serialization; no GPU mock.
var failures := 0

func _initialize() -> void:
	_run.call_deferred()

func _check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error(message)

func _run() -> void:
	var scene := Node3D.new()
	scene.name = "WaterBakeFixture"
	root.add_child(scene)
	var ground := MeshInstance3D.new()
	ground.name = "Ground"
	var plane := PlaneMesh.new()
	plane.size = Vector2(12, 12)
	ground.mesh = plane
	scene.add_child(ground)
	ground.owner = scene
	var region := SWEDeformer3D.new()
	region.name = "Region"
	region.settings.resolution = 16
	region.bake_settings.size = Vector3(8, 2, 8)
	region.source_root = NodePath("..")
	scene.add_child(region)
	region.owner = scene
	for i in 4:
		await process_frame
	_check(region.is_bake_current(), "Ordinary static meshes automatically bake after scene entry")
	_check(absf(region.height_map.get_pixel(8, 8).r) < 0.00001, "Zero is a valid bed height, not a missing-cell sentinel")
	# Y interval clips sample intersections, never clamps the crossing triangle.
	ground.position.y = 1.0
	ground.rotation.z = atan(0.5)
	region.rotation.y = 0.35
	region.bake()
	var hits := 0
	var misses := 0
	for z in 16:
		for x in 16:
			var local := Vector3((x + 0.5) / 16.0 * 8 - 4, 0, (z + 0.5) / 16.0 * 8 - 4)
			var world := region.global_transform * local
			var expected := 1.0 + world.x * 0.5
			var sample := region.height_map.get_pixel(x, z)
			_check((sample.g > 0.5) == (expected >= 0.0 and expected <= 2.0), "Rotated box samples must clip the actual sloping plane")
			if sample.g > 0.5:
				hits += 1
				_check(absf(sample.r - expected) < 0.0001, "Sloping bed sample must preserve metric height")
			else:
				misses += 1
	_check(hits > 0 and misses > 0, "Slope fixture must exercise both coverage and missing cells")
	# Water accepts steep upward surfaces which the fog support filter excludes.
	ground.rotation.z = atan(3.0)
	region.bake()
	_check(region.is_bake_current(), "Steep projected bed faces must remain eligible")
	region.position.y = 20.0
	_check(not region.is_bake_current(), "Transform edits immediately invalidate the previous heightfield")
	region.bake_settings.fallback_enabled = true
	region.bake_settings.fallback_height = 0.75
	region.bake()
	_check(region.is_bake_current() and absf(region.height_map.get_pixel(8, 8).r - 0.75) < 0.00001, "Only explicit fallback may create a missing sea bed")
	region.position.y = 0.0
	region.rotation.y = 0.0
	region.bake_settings.fallback_enabled = false
	ground.rotation.z = 0.0
	ground.position.y = 0.5
	ground.scale.x = -1.0
	region.bake()
	_check(region.is_bake_current() and absf(region.height_map.get_pixel(8, 8).r - 0.5) < 0.00001, "Mirrored source meshes retain their upward bed orientation")
	ground.scale.x = 1.0
	region.bake()
	var packed := PackedScene.new()
	_check(packed.pack(scene) == OK, "Scene with a memory bake must pack")
	var path := "user://water_bake_roundtrip.tscn"
	_check(ResourceSaver.save(packed, path) == OK, "Scene with a memory bake must save")
	var restored := (ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene).instantiate()
	var restored_region := restored.get_node("Region") as SWEDeformer3D
	_check(restored_region.height_map == null, "Serialized scene must not contain Image/Texture or a baked heightfield reference")
	scene.free()
	restored.get_node("Ground").position.y = 1.25
	root.add_child(restored)
	for i in 4:
		await process_frame
	_check(restored_region.is_bake_current() and absf(restored_region.height_map.get_pixel(8, 8).r - 1.25) < 0.00001, "Reload must sample current geometry, not a saved bake")
	root.remove_child(restored)
	restored.get_node("Ground").position.y = 0.25
	root.add_child(restored)
	for i in 4:
		await process_frame
	_check(absf(restored_region.height_map.get_pixel(8, 8).r - 0.25) < 0.00001, "Re-entry of the same scene must clear the previous bake")
	restored.free()
	await _csg_bake()
	_asset_roundtrip()
	print("Water bake/assets: %d failure(s)" % failures)
	quit(0 if failures == 0 else 1)

func _csg_bake() -> void:
	var scene := Node3D.new()
	root.add_child(scene)
	var csg := CSGCombiner3D.new()
	scene.add_child(csg)
	var block := CSGBox3D.new()
	block.size = Vector3(8, 1, 8)
	block.position.y = 0.5
	csg.add_child(block)
	var region := SWEDeformer3D.new()
	region.settings.resolution = 8
	region.bake_settings.size = Vector3(6, 3, 6)
	region.source_root = NodePath("..")
	scene.add_child(region)
	for i in 4:
		await process_frame
	_check(region.is_bake_current(), "Actual CSG union must be available to automatic baking")
	if region.height_map != null:
		_check(absf(region.height_map.get_pixel(4, 4).r - 1.0) < 0.00001, "CSG bake selects the upward top, not the downward box bottom")
	block.position.y = 1.0
	for i in 2:
		await process_frame
	region.bake()
	if region.height_map != null:
		_check(absf(region.height_map.get_pixel(4, 4).r - 1.5) < 0.00001, "Explicit rebake reads edited CSG, not a stale derived mesh")
	scene.free()

func _asset_roundtrip() -> void:
	var settings := WaterSWESettings.new()
	settings.gravity = 8.5
	settings.second_order = true
	settings.input_gain = 0.4
	var path := "user://water_swe_roundtrip.tres"
	_check(ResourceSaver.save(settings, path) == OK, "SWE settings must save as a reusable .tres asset")
	var loaded := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as WaterSWESettings
	_check(loaded.gravity == 8.5 and loaded.second_order and is_equal_approx(loaded.input_gain, 0.4), "Asset save/load preserves physical and coupling parameters")
	var a := SWEDeformer3D.new()
	var b := SWEDeformer3D.new()
	a.settings = loaded
	b.settings = loaded
	loaded.input_gain = 0.6
	_check(is_equal_approx(a.settings.input_gain, 0.6) and is_equal_approx(b.settings.input_gain, 0.6), "Shared assets intentionally update all consumers")
	b.settings = loaded.duplicate()
	b.settings.input_gain = 0.1
	_check(is_equal_approx(a.settings.input_gain, 0.6), "Make Unique permits per-region tuning")
	a.free()
	b.free()
	var fft := WaterFFTSettings.new()
	fft.resolution = 12
	_check(not fft.validation_error().is_empty(), "Invalid non-power-of-two FFT dimensions must be rejected before allocation")
	fft.resolution = 8
	fft.amplitude = 0.0
	var modes := fft.create_spectrum()
	for i in range(0, modes.size(), 4):
		_check(modes[i] == 0.0 and modes[i + 1] == 0.0, "Zero Phillips power must produce exactly zero waves")
