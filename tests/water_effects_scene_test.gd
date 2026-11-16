extends SceneTree

# Owner: physical effect textures must reach the actual water optical/material
# path; parameter edits must not reset frozen water or foam history.
var failures := 0
var _report: Dictionary
func _initialize() -> void:
	_run.call_deferred()
func _check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error(message)
func _capture() -> Image:
	for i in 4:
		await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()
func _snapshot(water: WaterBody3D) -> Dictionary:
	_report = {}
	water.gpu.snapshot(func(value: Dictionary): _report=value)
	while _report.is_empty():
		await process_frame
	return _report
func _difference(a: Image,b: Image) -> float:
	var difference := 0.0
	var count := 0
	for y in range(120,a.get_height(),6):
		for x in range(0,a.get_width(),6):
			var av := a.get_pixel(x,y)
			var bv := b.get_pixel(x,y)
			difference += Vector3(av.r-bv.r,av.g-bv.g,av.b-bv.b).length()
			count += 1
	return difference/count
func _run() -> void:
	var scene := load("res://scenes/water_playground.tscn").instantiate() as Node3D
	var water := scene.get_node("Water") as WaterBody3D
	water.material_settings = water.material_settings.duplicate()
	water.caustics_settings = water.caustics_settings.duplicate()
	water.foam_settings = water.foam_settings.duplicate()
	water.foam_material_settings = water.foam_material_settings.duplicate()
	var fft := scene.get_node("Water/FFT") as FFTDeformer3D
	fft.settings = fft.settings.duplicate()
	fft.settings.amplitude = 0.01
	water.paused = true
	root.add_child(scene)
	current_scene = scene
	for i in 300:
		if water.caustics != null and water.caustics.ready:
			break
		await process_frame
	_check(water.caustics != null and water.caustics.ready,"Showcase must create physical caustics from asset parameters")
	var focused := await _capture()
	water.caustics_settings.enabled = false
	var unfocused := await _capture()
	var caustic_difference := _difference(focused,unfocused)
	_check(caustic_difference>0.0002,"Physical irradiance map must alter visible underwater receivers, difference %.6f"%caustic_difference)
	water.caustics_settings.enabled = true
	water.foam_settings.generation = 60.0
	water.foam_settings.front_generation = 60.0
	water.foam_settings.background_multiplier = 1.0
	water.foam_settings.rise_threshold = 0.0
	water.foam_settings.rise_transition = 0.01
	water.foam_settings.closing_threshold = 0.0
	water.foam_settings.closing_transition = 0.02
	water.paused = false
	for i in 120:
		for frame in 6:
			await process_frame
		var report := await _snapshot(water)
		if report.simulated_time>=2.0:
			break
	water.paused = true
	var before := await _snapshot(water)
	_check(before.simulated_time>=2.0 and before.faults==0,"Real coupled scene must generate/transport foam without numeric faults")
	water.material_settings.debug_view = 9
	var opacity := await _capture()
	var white := 0
	for y in range(120,opacity.get_height(),4):
		for x in range(0,opacity.get_width(),4):
			if opacity.get_pixel(x,y).r>0.08:
				white += 1
	_check(white>20,"NSH material must display actual generated waterborne/offshore foam, not only store a buffer")
	water.material_settings.debug_view = 0
	var a := await _capture()
	water.foam_material_settings.color = Color(1.0,0.1,0.1)
	water.foam_material_settings.texture_source = 2
	water.foam_material_settings.height_maximum = 0.12
	var b := await _capture()
	_check(_difference(a,b)>0.0005,"NSH texture/color/visual-height assets must reach real rendering")
	var after := await _snapshot(water)
	_check(before.state==after.state and before.foam==after.foam and before.simulated_time==after.simulated_time,"Foam material edits and optical toggles must preserve paused physics, density, momentum and material coordinates")
	_texture_contract()
	scene.free()
	for i in 5:
		await process_frame
	print("Water effects rendering: %d failure(s)"%failures)
	quit(0 if failures==0 else 1)

func _texture_contract() -> void:
	# Packed NSH alpha is HEIGHT, not transparency. Import must not color-correct,
	# premultiply, repair alpha borders, or discard channels; mip scalar averaging
	# is independently checked from four raw PNG texels.
	for name in ["shorewaves_nsh","crest_foam_nsh","crest_foam2_nsh"]:
		var path: String = "res://addons/water/textures/foam/"+name+".png"
		var raw := Image.new()
		if raw.load_png_from_buffer(FileAccess.get_file_as_bytes(path)) != OK:
			_check(false,"Raw reference PNG must decode: "+name)
			continue
		var texture := load(path) as Texture2D
		var actual := texture.get_image()
		var error := 0.0
		for y in range(0,raw.get_height(),31):
			for x in range(0,raw.get_width(),31):
				var a := raw.get_pixel(x,y)
				var b := actual.get_pixel(x,y)
				error = maxf(error,Vector4(a.r-b.r,a.g-b.g,a.b-b.b,a.a-b.a).length())
		_check(error<0.005,"Packed NSH channels must survive actual texture import: "+name)
		_check(actual.has_mipmaps(),"NSH must provide real filtered mip levels: "+name)
		if actual.has_mipmaps():
			var width := actual.get_width()/2
			var height := actual.get_height()/2
			var offset := actual.get_mipmap_offset(1)
			var mip := Image.create_from_data(width,height,false,Image.FORMAT_RGBA8,actual.get_data().slice(offset,offset+width*height*4))
			var expected := (raw.get_pixel(0,0)+raw.get_pixel(1,0)+raw.get_pixel(0,1)+raw.get_pixel(1,1))/4.0
			var value := mip.get_pixel(0,0)
			_check(Vector4(value.r-expected.r,value.g-expected.g,value.b-expected.b,value.a-expected.a).length()<0.012,"NSH mip filters scalar data linearly without sRGB decoding: "+name)
