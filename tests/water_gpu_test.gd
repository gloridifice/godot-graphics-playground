extends SceneTree

# Owners: spectral transform, SWE invariants, matched inlet ABI. Reference uses a
# direct f64 DFT, not the GPU butterfly or its output as the expected value.
var failures := 0
var _report: Dictionary

func _initialize() -> void:
	_run.call_deferred()

func _check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error(message)

func _snapshot(gpu: WaterGPU) -> Dictionary:
	_report = {}
	gpu.snapshot(func(report: Dictionary): _report = report)
	while _report.is_empty():
		await process_frame
	return _report

func _start(fft: WaterFFTSettings, swe: WaterSWESettings = null, terrain: Image = null, region: Transform3D = Transform3D.IDENTITY, extent: Vector2 = Vector2(16, 16), enabled: bool = true) -> WaterGPU:
	var gpu := WaterGPU.new()
	gpu.configure(fft, swe, terrain, region, extent, 0.0, enabled)
	var success: bool = await gpu.initialized
	_check(success, "Actual global RenderingDevice must initialize: " + gpu.error_message)
	await process_frame
	return gpu

func _advance(gpu: WaterGPU, ticks: int, batch: int = 4) -> Dictionary:
	while ticks > 0:
		var count := mini(ticks, batch)
		gpu.advance(float(count) / 60.0)
		ticks -= count
		await process_frame
	return await _snapshot(gpu)

func _run() -> void:
	await _fft_dft()
	for second_order in [false, true]:
		await _resting_shore(second_order)
		await _wave_mass(second_order)
		await _dry_front_and_hole(second_order)
	await _rotated_inlet_and_schedule()
	await _cfl_budget_clock()
	print("Water GPU: %d failure(s)" % failures)
	quit(0 if failures == 0 else 1)

func _fft_dft() -> void:
	var fft := WaterFFTSettings.new()
	fft.resolution = 8
	fft.length = 32.0
	var swe := WaterSWESettings.new()
	# Filtering belongs to the three inlet channels, never the display channels.
	swe.filter_cutoff = 12.0
	swe.filter_transition = 12.0
	var gpu := await _start(fft, swe)
	if not gpu.ready:
		gpu.close()
		return
	for ticks in [0, 17]:
		var report := await _snapshot(gpu) if ticks == 0 else await _advance(gpu, ticks)
		var expected := _direct_dft(fft, swe, report.simulated_time)
		var actual: PackedFloat32Array = report.spectral
		var error := 0.0
		for i in expected.size():
			error = maxf(error, absf(actual[i * 2] - expected[i].x))
			error = maxf(error, absf(actual[i * 2 + 1] - expected[i].y))
		_check(error < 0.00002, "All six FFT channels must match independent DFT at t=%.6f; max error %.9f" % [report.simulated_time, error])
		_check(absf(report.simulated_time - float(ticks) / 60.0) < 0.00001, "FFT-only clock advances fixed simulation seconds")
	gpu.close()
	await process_frame

func _terrain(n: int, slope: float = 0.0, depth: float = 2.0) -> Image:
	var image := Image.create(n, n, false, Image.FORMAT_RGF)
	for z in n:
		for x in n:
			image.set_pixel(x, z, Color(((x + 0.5) / n * 16.0 - 8.0) * slope - depth, 1, 0, 1))
	return image

func _resting_shore(second_order: bool) -> void:
	var fft := WaterFFTSettings.new()
	var swe := WaterSWESettings.new()
	swe.resolution = 32
	swe.second_order = second_order
	swe.fft_edges = 0
	var terrain := _terrain(32, 0.2, 0.3)
	var gpu := await _start(fft, swe, terrain, Transform3D.IDENTITY, Vector2(16, 16), false)
	if not gpu.ready:
		gpu.close()
		return
	var initial := await _snapshot(gpu)
	var after := await _advance(gpu, 60)
	var error := 0.0
	var momentum := 0.0
	for i in 32 * 32:
		error = maxf(error, absf(after.state[i * 4] - initial.state[i * 4]))
		momentum = maxf(momentum, Vector2(after.state[i * 4 + 1], after.state[i * 4 + 2]).length())
	_check(error < 0.00005 and momentum < 0.0001, "Resting sloped lake/dry land must remain balanced (RK2=%s): dh=%.9f momentum=%.9f" % [second_order, error, momentum])
	_check(after.faults == 0 and after.dropped_gpu_time < 0.00001 and absf(after.simulated_time - 1.0) < 0.00001, "Resting shore must remain finite and advance the full requested time")
	gpu.close()
	await process_frame

func _wave_mass(second_order: bool) -> void:
	var fft := WaterFFTSettings.new()
	fft.resolution = 16
	fft.length = 32.0
	var swe := WaterSWESettings.new()
	swe.resolution = 32
	swe.second_order = second_order
	swe.fft_edges = 0
	swe.manning = 0.0
	var gpu := await _start(fft, swe, _terrain(32))
	if not gpu.ready:
		gpu.close()
		return
	var before := await _snapshot(gpu)
	var after := await _advance(gpu, 90)
	var mass_before := 0.0
	var mass_after := 0.0
	var changed := 0.0
	var minimum := INF
	for i in 32 * 32:
		mass_before += before.state[i * 4]
		mass_after += after.state[i * 4]
		minimum = minf(minimum, after.state[i * 4])
		changed = maxf(changed, absf(before.state[i * 4] - after.state[i * 4]))
	_check(changed > 0.001, "FFT-seeded water must actually propagate rather than remain a static displacement map")
	_check(minimum >= 0.0 and after.faults == 0, "Water propagation remains finite/nonnegative in both orders")
	_check(absf(mass_after - mass_before) / mass_before < 0.000003, "Closed-domain water mass must be conserved (RK2=%s), relative error %.9f" % [second_order, absf(mass_after - mass_before) / mass_before])
	_check(absf(after.simulated_time - 1.5) < 0.00001, "SWE and FFT must publish the same actual simulation clock")
	gpu.close()
	await process_frame

func _dry_front_and_hole(second_order: bool) -> void:
	var fft := WaterFFTSettings.new()
	fft.resolution = 16
	fft.length = 32.0
	fft.amplitude = 0.02
	var swe := WaterSWESettings.new()
	swe.resolution = 32
	swe.second_order = second_order
	swe.fft_edges = 0
	swe.filter_enabled = false
	var terrain := _terrain(32, 0.10, 0.1)
	for z in range(12,20):
		for x in range(8,12):
			terrain.set_pixel(x,z,Color(0,0,0,1))
	var gpu := await _start(fft,swe,terrain)
	var initial := await _snapshot(gpu)
	var after := await _advance(gpu,120)
	var mass_before := 0.0
	var mass_after := 0.0
	var newly_wet := 0
	var nonnegative := true
	var holes_empty := true
	for i in 32*32:
		mass_before += initial.state[i*4]
		mass_after += after.state[i*4]
		nonnegative = nonnegative and after.state[i*4] >= 0.0
		if initial.state[i*4] < 0.00001 and after.state[i*4] > 0.003:
			newly_wet += 1
		if terrain.get_pixel(i%32,i/32).g < 0.5:
			holes_empty = holes_empty and after.state[i*4] == 0.0
	_check(newly_wet > 0, "A real water front must wet previously dry bed cells (RK2=%s)" % second_order)
	_check(nonnegative and holes_empty and after.faults == 0, "Dry front and missing-bed reflection must not create negative water or fill invalid cells")
	_check(absf(mass_after-mass_before)/mass_before < 0.00001, "Dry-front donor limiting must conserve closed-domain water around missing-bed holes")
	gpu.close()
	await process_frame

func _cfl_budget_clock() -> void:
	var fft := WaterFFTSettings.new()
	fft.resolution = 8
	fft.length = 32.0
	var swe := WaterSWESettings.new()
	swe.resolution = 32
	swe.max_substeps = 8
	swe.fft_edges = 0
	var gpu := await _start(fft,swe,_terrain(32,0.0,500.0),Transform3D.IDENTITY,Vector2(1,1))
	var after := await _advance(gpu,1)
	_check(after.simulated_time > 0.0 and after.simulated_time < 0.01 and after.dropped_gpu_time > 0.005 and after.faults == 0, "Exhausting a deliberately tiny CFL budget must report lost time, never take an unstable step")
	var expected := _direct_dft(fft,swe,after.simulated_time)
	var error := 0.0
	for i in expected.size():
		error = maxf(error,absf(expected[i].x-after.spectral[i*2]))
	_check(error < 0.00002, "Display FFT must be evaluated at GPU-accepted time even after a CFL budget shortfall")
	gpu.close()
	await process_frame

func _rotated_inlet_and_schedule() -> void:
	var fft := WaterFFTSettings.new()
	fft.resolution = 8
	fft.length = 32.0
	fft.height_gain = 0.7
	var swe := WaterSWESettings.new()
	swe.resolution = 16
	swe.input_gain = 0.4
	swe.fft_edges = 15
	var region := Transform3D(Basis(Vector3.UP, 0.7), Vector3(3, 0, -5))
	var gpu := await _start(fft, swe, _terrain(16), region)
	if not gpu.ready:
		gpu.close()
		return
	var before := await _snapshot(gpu)
	var reference := _direct_dft(fft, swe, 0.0)
	var error := 0.0
	for z in range(1, 16, 3):
		for x in range(1, 16, 3):
			var local := Vector3((x + 0.5) - 8.0, 0, (z + 0.5) - 8.0)
			var world := region * local
			var incoming := _sample_reference(reference, fft, Vector2(world.x, world.z)) * fft.height_gain * swe.input_gain
			var world_momentum := Vector3(incoming.y, 0, incoming.z)
			var local_momentum := region.basis.inverse() * world_momentum
			var i := (z * 16 + x) * 4
			error = maxf(error, absf(before.state[i] - (2.0 + incoming.x)))
			error = maxf(error, absf(before.state[i + 1] - local_momentum.x))
			error = maxf(error, absf(before.state[i + 2] - local_momentum.z))
	_check(error < 0.00002, "Rotated region/world wrapping and one-time gain must initialize matching height AND momentum; error %.9f" % error)
	var a := await _advance(gpu, 60, 1)
	var other := await _start(fft, swe, _terrain(16), region)
	var b := await _advance(other, 60, 2)
	var difference := 0.0
	for i in a.state.size():
		difference = maxf(difference, absf(a.state[i] - b.state[i]))
	_check(difference < 0.000002 and absf(a.simulated_time - b.simulated_time) < 0.000001, "30/60 Hz submissions must share fixed ticks and FFT substep interpolation")
	_check(a.faults == 0 and b.faults == 0, "Coupled boundary must remain finite")
	gpu.close()
	other.close()
	await process_frame
	# Zero input gain must remove both height and momentum, including all future input.
	swe.input_gain = 0.0
	gpu = await _start(fft, swe, _terrain(16), region)
	var zero := await _advance(gpu, 30)
	var quiet := true
	for i in 16 * 16:
		quiet = quiet and absf(zero.state[i * 4] - 2.0) < 0.000001 and absf(zero.state[i * 4 + 1]) < 0.000001 and absf(zero.state[i * 4 + 2]) < 0.000001
	_check(quiet, "Zero gain must keep SWE still even though the displayed FFT remains nonzero")
	gpu.close()
	await process_frame

func _cmul(a: Vector2, b: Vector2) -> Vector2:
	return Vector2(a.x*b.x-a.y*b.y,a.x*b.y+a.y*b.x)

func _direct_dft(fft: WaterFFTSettings, swe: WaterSWESettings, time: float) -> PackedVector2Array:
	var n := fft.resolution
	var modes := fft.create_spectrum()
	var frequency := PackedVector2Array()
	frequency.resize(6 * n * n)
	for z in n:
		for x in n:
			var i := z * n + x
			var opposite := ((n-z)%n)*n+(n-x)%n
			var k := Vector2(modes[i*4+2],modes[i*4+3])
			var magnitude := k.length()
			var omega := sqrt(9.81 * magnitude)
			var phase := Vector2.from_angle(omega * time)
			var a := _cmul(Vector2(modes[i*4],modes[i*4+1]),phase)
			var b := _cmul(Vector2(modes[opposite*4],-modes[opposite*4+1]),Vector2(phase.x,-phase.y))
			var h := a + b
			var wavelength := TAU / maxf(magnitude,0.000001)
			var lowpass := 1.0
			if swe.filter_enabled:
				if swe.filter_transition > 0.0:
					var t := clampf((wavelength-swe.filter_cutoff)/swe.filter_transition,0,1)
					lowpass = t*t*(3.0-2.0*t)
				else:
					lowpass = 1.0 if wavelength > swe.filter_cutoff else 0.0
			frequency[i] = h
			frequency[n*n+i] = Vector2(h.y,-h.x)*k.x/maxf(magnitude,0.000001)
			frequency[2*n*n+i] = Vector2(h.y,-h.x)*k.y/maxf(magnitude,0.000001)
			frequency[3*n*n+i] = h*lowpass
			frequency[4*n*n+i] = (b-a)*omega*k.x/maxf(magnitude*magnitude,0.00000001)*lowpass
			frequency[5*n*n+i] = (b-a)*omega*k.y/maxf(magnitude*magnitude,0.00000001)*lowpass
	var output := PackedVector2Array()
	output.resize(6*n*n)
	for channel in 6:
		for z in n:
			for x in n:
				var sum := Vector2.ZERO
				for kz in n:
					for kx in n:
						var phase := Vector2.from_angle(TAU * float(kx*x+kz*z)/n)
						sum += _cmul(frequency[channel*n*n+kz*n+kx],phase)/float(n*n)
				output[channel*n*n+z*n+x] = sum
	return output

func _sample_reference(values: PackedVector2Array, fft: WaterFFTSettings, world: Vector2) -> Vector3:
	var n := fft.resolution
	var grid := (world / fft.length + Vector2.ONE * 0.5) * n
	var base := Vector2i(grid.floor())
	var f := grid - grid.floor()
	var result := Vector3.ZERO
	for channel in 3:
		for z in 2:
			for x in 2:
				var c := Vector2i(posmod(base.x+x,n),posmod(base.y+z,n))
				var w := (f.x if x == 1 else 1.0-f.x)*(f.y if z == 1 else 1.0-f.y)
				result[channel] += values[(channel+3)*n*n+c.y*n+c.x].x*w
	return result
