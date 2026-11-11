extends SceneTree

func _initialize() -> void:
	var preset := HeightfieldFogInitialization.new()
	var terrain := Image.create(16, 16, false, Image.FORMAT_RGF)
	terrain.fill(Color(0.25, 1, 0, 1))
	terrain.set_pixel(0, 0, Color(0, 0, 0, 1))
	preset.base_height = 0.5
	preset.height_offset = -0.1
	var extent := Vector2(8, 8)
	var field := preset.create_thickness(terrain, extent)
	assert(is_equal_approx(field.get_pixel(8, 8).r, 0.4))
	assert(field.get_pixel(0, 0).r == 0.0, "Terrain holes never initialize fog")
	preset.horizontal_top = true
	field = preset.create_thickness(terrain, extent)
	assert(is_equal_approx(field.get_pixel(8, 8).r, 0.15), "Horizontal top subtracts the local supporting height")
	preset.height_offset = -1.0
	assert(preset.create_thickness(terrain, extent).get_pixel(8, 8).r == 0.0)
	preset.height_offset = 0.0
	preset.horizontal_top = false
	preset.noise_amplitude = 0.4
	var first := preset.create_thickness(terrain, extent).get_data()
	assert(first == preset.create_thickness(terrain, extent).get_data(), "Same seed reproduces initialization")
	preset.noise_seed += 1
	assert(first != preset.create_thickness(terrain, extent).get_data(), "Seed must affect the actual field")
	var file := "user://heightfield_fog_initialization_test.tres"
	assert(ResourceSaver.save(preset, file) == OK)
	var loaded := ResourceLoader.load(file, "", ResourceLoader.CACHE_MODE_IGNORE) as HeightfieldFogInitialization
	assert(loaded.create_thickness(terrain, extent).get_data() == preset.create_thickness(terrain, extent).get_data(), "Saved assets reproduce the field")
	preset.natural_mist_enabled = true
	preset.horizontal_top = true
	preset.wind_speed = 0.23
	preset.noise_amplitude = 0.0
	field = preset.create_thickness(terrain, extent)
	assert(is_equal_approx(field.get_pixel(8, 8).r, 0.25), "Zero amplitude gives the same horizontal top in natural mode")
	preset.max_thickness = 0.12
	field = preset.create_thickness(terrain, extent)
	assert(is_equal_approx(field.get_pixel(8, 8).r, 0.12), "Deep hollows respect the initial thin-layer cap")
	terrain.set_pixel(1, 0, Color(1.0, 1.0, 0, 1))
	field = preset.create_thickness(terrain, extent)
	assert(field.get_pixel(0, 0).r == 0.0 and field.get_pixel(1, 0).r == 0.0, "Neither holes nor rocks above the horizontal top gain capped fog")
	preset.max_thickness = 0.0
	preset.noise_amplitude = 0.37
	preset.coverage = 0.58
	assert(ResourceSaver.save(preset, file) == OK)
	loaded = ResourceLoader.load(file, "", ResourceLoader.CACHE_MODE_IGNORE) as HeightfieldFogInitialization
	assert(loaded.create_thickness(terrain, extent).get_data() == preset.create_thickness(terrain, extent).get_data(), "Natural noise settings survive persistence")
	assert(is_equal_approx(loaded.wind_speed, 0.23) and is_equal_approx(loaded.coverage, 0.58), "Shading settings survive persistence")
	# Edits must invalidate cached noise, not just change serialized inspector values.
	var before_edit := preset.create_thickness(terrain, extent).get_data()
	var edits := {"noise_seed": 91, "noise_octaves": 6, "noise_offset": Vector2(-7, 13)}
	for property in edits:
		var previous: Variant = preset.get(property)
		preset.set(property, edits[property])
		assert(preset.create_thickness(terrain, extent).get_data() != before_edit, "Editing %s changes the generated natural field" % property)
		preset.set(property, previous)
	# Shared presets sample the same world positions, independent of box origin/rotation.
	terrain.fill(Color(0.25, 1.0, 0, 1))
	field = preset.create_thickness(terrain, extent)
	var shifted := preset.create_thickness(terrain, extent, Transform3D(Basis.IDENTITY, Vector3(4, 0, 0)))
	var rotated := preset.create_thickness(terrain, extent, Transform3D(Basis(Vector3.UP, PI * 0.5), Vector3.ZERO))
	for z in 16:
		for x in 16:
			assert(is_equal_approx(rotated.get_pixel(x, z).r, field.get_pixel(z, 15-x).r), "Rotating a box cannot rotate world-space initial noise")
			if x < 8:
				assert(is_equal_approx(shifted.get_pixel(x, z).r, field.get_pixel(x+8, z).r), "Shared presets align across translated boxes")
	var legacy := "user://heightfield_fog_old_natural.tres"
	var old_file := FileAccess.open(legacy, FileAccess.WRITE)
	old_file.store_string('[gd_resource type="Resource" load_steps=2 format=3]\n[ext_resource type="Script" path="res://addons/heightfield_fog/initialization.gd" id="1"]\n[resource]\nscript = ExtResource("1")\nnatural_mist_enabled = true\ntop_variation = 0.3\ntop_scale = 20.0\n')
	old_file.close()
	var migrated := load(legacy) as HeightfieldFogInitialization
	assert(is_equal_approx(migrated.noise_amplitude, 0.3) and is_equal_approx(migrated.noise_frequency, 0.05), "Old natural presets migrate to the single noise source")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(legacy))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(file))
	var box := HeightfieldFogBox.new()
	box.set("layer_height", 0.7)
	assert(is_equal_approx(box.initialization.base_height, 0.7), "Old scene thickness migrates")
	var other := HeightfieldFogBox.new()
	assert(is_equal_approx(other.initialization.base_height, 0.4), "New boxes do not accidentally share mutable defaults")
	assert(not other.initialization.natural_mist_enabled, "Old resources and new default boxes retain legacy rendering")
	box.free()
	other.free()
	print("PASS: initial heights/cap, holes/rocks, deterministic noise, world-aligned shared resources, persistence and legacy migration")
	quit()
