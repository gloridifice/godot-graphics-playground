extends SceneTree

# Physical caustics owner: real photon hits and additive receiver map, compared
# with independent Snell/Beer-Lambert plane solutions, not a scrolling texture.
var failures := 0
var _report: Dictionary
var _normal_input := Texture2DRD.new()

func _initialize() -> void:
	_run.call_deferred()

func _check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error(message)

func _wait(water: WaterBody3D) -> bool:
	for i in 300:
		if water.caustics != null and water.caustics.ready:
			return true
		await process_frame
	_check(false,"Physical caustics must initialize: "+water.status)
	return false

func _snapshot(effect: WaterCausticsGPU) -> Dictionary:
	await process_frame
	_report = {}
	effect.snapshot(func(value: Dictionary): _report=value)
	while _report.is_empty():
		await process_frame
	return _report

func _run() -> void:
	var scene := Node3D.new()
	root.add_child(scene)
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees.x = -90.0
	scene.add_child(sun)
	var water := WaterBody3D.new()
	water.paused = true
	water.caustics_settings.enabled = true
	water.caustics_settings.ray_resolution = 32
	water.caustics_settings.texture_resolution = 64
	water.caustics_settings.size = Vector2(8,8)
	water.caustics_settings.flat_bed_depth = 2.0
	water.material_settings.extinction = Vector3(0.1,0.2,0.3)
	scene.add_child(water)
	if not await _wait(water):
		scene.free()
		quit(1)
		return
	var report := await _snapshot(water.caustics)
	var n := water.caustics_settings.ray_resolution
	var index := ((n/2)*(n+1)+n/2)*12
	_check(absf(report.hits[index+7]-2.0)<0.0001 and absf(report.hits[index+5]+2.0)<0.0001,"Vertical Snell ray must hit the known 2 m bed")
	var f0 := pow((1.333-1.0)/(1.333+1.0),2.0)
	var expected := Vector3(exp(-0.2),exp(-0.4),exp(-0.6))*(1.0-f0)
	var image: Image = report.image
	var error := 0.0
	for y in range(12,52):
		for x in range(12,52):
			var color := image.get_pixel(x,y)
			error = maxf(error,Vector3(color.r,color.g,color.b).distance_to(expected))
	_check(error<0.004,"A flat interface must conserve uniform irradiance, include Fresnel and RGB entry attenuation; error %.6f"%error)
	# Change only the actual sun; cached paused maps must still update.
	sun.rotation_degrees.x = -60.0
	for i in 3:
		await process_frame
	report = await _snapshot(water.caustics)
	var direction := sun.global_basis.z.normalized()
	var refracted_xz := Vector2(direction.x,direction.z)/1.333
	var ray_y := -sqrt(1.0-refracted_xz.length_squared())
	var distance := 2.0/(-ray_y)
	_check(absf(report.hits[index+7]-distance)<0.0002,"Oblique sun must use Snell angle, not vertical-depth attenuation")
	_check(absf(report.hits[index+4])<0.0002 and absf(report.hits[index+6])<0.0002,"Upstream emitter translation must supply the receiver tile center")
	var gpu := water.gpu
	water.caustics_settings.strength = 0.6
	for i in 3:
		await process_frame
	_check(water.gpu == gpu,"Caustics display edits must not reset water physics")
	# Bed is now a real baked sloping mesh; no flat-plane shortcut is valid.
	sun.rotation_degrees.x = -90.0
	var bed := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(24,24)
	bed.mesh = plane
	bed.position.y = -2.0
	bed.rotation.x = -atan(0.2)
	scene.add_child(bed)
	var region := SWEDeformer3D.new()
	region.position.y = -4.0
	region.settings.resolution = 32
	region.bake_settings.size = Vector3(16,8,16)
	region.source_root = NodePath("../..")
	water.add_child(region)
	if await _wait(water):
		# Wait for the new region's automatic bake/replacement effect, not the old map.
		for i in 6:
			await process_frame
		await _wait(water)
		report = await _snapshot(water.caustics)
		var hits: PackedFloat32Array = report.hits
		var max_error := 0.0
		for i in range(0,hits.size(),12):
			if hits[i+3] > 0.5:
				max_error = maxf(max_error,absf(hits[i+5]-(-2.0+0.2*hits[i+6])))
		_check(max_error<0.0003,"DDA bilinear heightfield intersection must match the independent sloping plane")
		image = report.image
		_check(image.get_pixel(32,48).b > image.get_pixel(32,16).b+0.08,"Receiver texture world Z orientation and path-dependent attenuation must not be inverted")
		# Independent quality oracle: this planar receiver has smooth exponential
		# attenuation, even with a coarse photon mesh. Flat per-face illumination
		# creates long constant plateaus; a larger target texture alone cannot fix it.
		water.caustics_settings.ray_resolution = 16
		water.caustics_settings.texture_resolution = 256
		for i in 6:
			await process_frame
		if await _wait(water):
			report = await _snapshot(water.caustics)
			image = report.image
			var plateaus := 0
			var optical_error := 0.0
			for y in range(32,224):
				var value := image.get_pixel(128,y).b
				var next := image.get_pixel(128,y+1).b
				if absf(next-value)<0.0001:
					plateaus += 1
				var world_z := ((float(y)+0.5)/256.0-0.5)*8.0
				var analytic := (1.0-f0)*exp(-0.3*(2.0-0.2*world_z))/sqrt(1.04)
				optical_error = maxf(optical_error,absf(value-analytic))
			_check(plateaus<20,"Smooth physical irradiance must not become constant photon-triangle tiles; plateau pixels %d/192"%plateaus)
			_check(optical_error<0.006,"Resolved irradiance must preserve the independent sloped-plane optical solution; error %.6f"%optical_error)
			print("Caustics gradient: plateaus %d/192; optical error %.6f"%[plateaus,optical_error])
	scene.free()
	for i in 5:
		await process_frame
	await _reference_detail_normals()
	print("Water physical caustics: %d failure(s)"%failures)
	quit(0 if failures==0 else 1)

# Same Fourier-mode oracle as the reference project's surface verification,
# exercised through actual production photons, not a copy of its cubic helper.
# Infer the interface normal by inverse Snell from published origin/hit pairs.
func _photon_slopes(effect: WaterCausticsGPU, geometry: Dictionary, config: WaterCausticsSettings, points: Array[Vector2]) -> PackedVector2Array:
	var result := PackedVector2Array()
	var index := ((config.ray_resolution/2)*(config.ray_resolution+1)+config.ray_resolution/2)*12
	for point in points:
		geometry.caustics_center = (point/32.0-Vector2(0.5,0.5))*64.0
		effect.update(geometry,config,Vector3.UP,Vector3.ZERO,1.333,true)
		var data := await _snapshot(effect)
		var h: PackedFloat32Array = data.hits
		var origin := Vector3(h[index],h[index+1],h[index+2])
		var hit := Vector3(h[index+4],h[index+5],h[index+6])
		_check(h[index+3]>0.5,"Analytic normal probe must produce a real valid photon")
		var ray := (hit-origin).normalized()
		var normal := (Vector3.DOWN/1.333-ray).normalized()
		result.append(Vector2(-normal.x,-normal.z)/normal.y)
	return result

func _reference_detail_normals() -> void:
	var scene := Node3D.new()
	var bed := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(512,512)
	bed.mesh = plane
	bed.position.y = -2.0
	scene.add_child(bed)
	var water := WaterBody3D.new()
	water.paused = true
	var fft := FFTDeformer3D.new()
	fft.settings.resolution = 32
	fft.settings.length = 64.0
	fft.settings.height_gain = 1.7
	fft.settings.choppiness = 0.0
	fft.settings.amplitude = 0.0
	water.add_child(fft)
	var region := SWEDeformer3D.new()
	region.position.y = -4.0
	region.settings.resolution = 32
	region.bake_settings.size = Vector3(256,8,256)
	region.source_root = NodePath("../..")
	water.add_child(region)
	scene.add_child(water)
	root.add_child(scene)
	for i in 300:
		if water.gpu != null and water.gpu.ready:
			break
		await process_frame
	if water.gpu == null or not water.gpu.ready:
		_check(false,"Reference normal fixture must initialize")
		scene.free()
		return
	var modes := [Vector4(0.15,3,2,0.4),Vector4(0.09,-1,5,-0.2)]
	var heights := PackedFloat32Array()
	heights.resize(32*32*4)
	for z in 32:
		for x in 32:
			for mode in modes:
				heights[(z*32+x)*4] += mode.x*sin(TAU/32.0*(mode.y*x+mode.z*z)+mode.w)
	# Published FFT is the production input boundary. Physics stays paused and
	# flat, isolating render-only detail from filtered SWE geometry and momentum.
	RenderingServer.call_on_render_thread(_normal_texture_rd.bind(heights.to_byte_array()))
	for i in 300:
		if _normal_input.texture_rd_rid.is_valid():
			break
		await process_frame
	water.gpu.fft_texture.texture_rd_rid = _normal_input.texture_rd_rid
	var config := WaterCausticsSettings.new()
	config.ray_resolution = 16
	config.texture_resolution = 32
	config.size = Vector2(0.125,0.125)
	var geometry := water.geometry_parameters()
	var effect := WaterCausticsGPU.new()
	effect.configure(water.gpu,geometry,config,Vector3.UP,Vector3.ZERO,1.333)
	var ok: bool = await effect.initialized
	_check(ok,"Reference normal photons must initialize")
	if ok:
		var points: Array[Vector2] = []
		# Unlike the reference's direct slope probe, inverse Snell subtracts f32
		# world hit coordinates. Use 1/128 cell to resolve derivatives above their
		# quantization noise, keeping the same strict derivative-jump bound.
		var epsilon := 1.0/128.0
		for axis in 2:
			for edge in [-1.0,0.0,5.0,31.0,32.0]:
				for delta in [-epsilon,0.0,epsilon]:
					var point := Vector2(2.375,3.625)
					point[axis] = edge+delta
					points.append(point)
		var smooth_count := points.size()
		points.append_array([Vector2(2.25,-3.375),Vector2(34.25,28.625)])
		var node_start := points.size()
		points.append_array([Vector2.ZERO,Vector2(1,2),Vector2(7,4)])
		var slopes := await _photon_slopes(effect,geometry,config,points)
		var jump := 0.0
		for i in range(0,smooth_count,3):
			jump = maxf(jump,((slopes[i+2]-slopes[i+1])/epsilon-(slopes[i+1]-slopes[i])/epsilon).length())
		_check(jump<0.002,"Photon normal first derivatives must agree across FFT grid boundaries; jump %.6f"%jump)
		_check(slopes[smooth_count].distance_to(slopes[smooth_count+1])<0.00001,"Detail normal must be periodic at negative and wrapped FFT coordinates")
		var node_error := 0.0
		for i in range(node_start,points.size()):
			var expected := Vector2.ZERO
			for mode in modes:
				var k := Vector2(mode.y,mode.z)*TAU/32.0
				var response := Vector2(sin(k.x)-sin(4.0*k.x)/4.0,sin(k.y)-sin(4.0*k.y)/4.0)
				expected += mode.x*cos(k.dot(points[i])+mode.w)*response*1.7*32.0/64.0
			node_error = maxf(node_error,slopes[i].distance_to(expected))
		_check(node_error<0.00001,"Reference small-wave nodal amplitude and metric/gain must reach real refracted rays; error %.6f"%node_error)
		# Footprint rejection must operate on real normal transport, not a flag.
		var probe: Array[Vector2] = [Vector2(1,2)]
		var full := (await _photon_slopes(effect,geometry,config,probe))[0]
		config.size = Vector2.ONE*(1.25*16.0*64.0/32.0/1.5)
		var half := (await _photon_slopes(effect,geometry,config,probe))[0]
		_check(half.distance_to(full*0.5)<0.00001,"Reference photon footprint 1.25 FFT cells must halve the detail slope")
		config.size = Vector2.ONE*(2.0*16.0*64.0/32.0/1.5)
		var faded := (await _photon_slopes(effect,geometry,config,probe))[0]
		_check(faded.length()<0.00001,"Unresolved small waves must fade out at a two-cell photon footprint")
		config.size = Vector2(0.125,0.125)
		geometry.shore_normal_strength = 0.0
		var disabled := (await _photon_slopes(effect,geometry,config,probe))[0]
		_check(disabled.length()<0.00001,"Zero shore-normal strength must preserve the unperturbed flat normal")
		geometry.shore_normal_strength = 1.0
		geometry.fft_enabled = false
		var no_fft := (await _photon_slopes(effect,geometry,config,probe))[0]
		_check(no_fft.length()<0.00001,"Without FFT there must be no invented short-wave normal")
		geometry.fft_enabled = true
		geometry.swe_enabled = false
		var offshore := (await _photon_slopes(effect,geometry,config,probe))[0]
		geometry.shore_normal_strength = 0.0
		var offshore_base := (await _photon_slopes(effect,geometry,config,probe))[0]
		_check(offshore.distance_to(offshore_base)<0.00001,"No-SWE photons must retain their FFT base normal without a second detail contribution")
		geometry.swe_enabled = true
		geometry.swe_model_blend = true
		geometry.swe_fft_edges = 1
		geometry.blend_depth = 0.1
		# Baked model interiors use SWE irrespective of bed depth. The analytic
		# FFT is non-flat, so the legacy depth blend cannot accidentally pass.
		var model_base := (await _photon_slopes(effect,geometry,config,probe))[0]
		_check(model_base.length()<0.00001,"Reference heightfield composition must not leak coarse FFT geometry back into a deep, fully covered SWE interior")
		var gpu := water.gpu
		region.settings.normal_strength = 0.5
		for i in 4:
			await process_frame
		_check(water.gpu==gpu and water.geometry_parameters().shore_normal_strength==0.5,"Shore normal Resource changes must reach shared optical parameters without rebuilding physical GPU state")
		print("Reference photon normals: C1 jump %.6f; nodal error %.6f"%[jump,node_error])
	effect.close()
	scene.free()
	RenderingServer.call_on_render_thread(_free_normal_texture_rd.bind(_normal_input.texture_rd_rid))
	_normal_input.texture_rd_rid = RID()
	for i in 5:
		await process_frame

func _normal_texture_rd(bytes: PackedByteArray) -> void:
	var format := RDTextureFormat.new()
	format.width = 32
	format.height = 32
	format.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	var texture := RenderingServer.get_rendering_device().texture_create(format,RDTextureView.new(),[bytes])
	_normal_input.set_deferred("texture_rd_rid",texture)

func _free_normal_texture_rd(texture: RID) -> void:
	RenderingServer.get_rendering_device().free_rid(texture)
