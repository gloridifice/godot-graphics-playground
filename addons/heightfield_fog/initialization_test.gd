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
	preset.top_variation = 0.37
	field = preset.create_thickness(terrain, extent)
	assert(is_equal_approx(field.get_pixel(8, 8).r, 0.25), "Natural baseline must not bake the old noise a second time")
	assert(field.get_pixel(0, 0).r == 0.0, "Natural mode keeps terrain holes dry")
	assert(ResourceSaver.save(preset, file) == OK)
	loaded = ResourceLoader.load(file, "", ResourceLoader.CACHE_MODE_IGNORE) as HeightfieldFogInitialization
	assert(loaded.natural_mist_enabled and is_equal_approx(loaded.wind_speed, 0.23) and is_equal_approx(loaded.top_variation, 0.37), "Natural settings survive resource persistence")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(file))
	var box := HeightfieldFogBox.new()
	box.set("layer_height", 0.7)
	assert(is_equal_approx(box.initialization.base_height, 0.7), "Old scene thickness migrates")
	var other := HeightfieldFogBox.new()
	assert(is_equal_approx(other.initialization.base_height, 0.4), "New boxes do not accidentally share mutable defaults")
	assert(not other.initialization.natural_mist_enabled, "Old resources and new default boxes retain legacy rendering")
	box.free()
	other.free()
	print("PASS: initialization heights, holes, horizontal top, nonnegative thickness, seeds, resource persistence and legacy defaults")
	quit()
