extends SceneTree

# Owner: actual foam GPU source/transport/history. Exact far-field ODE and closed
# waterborne integral decay are independent oracles; do not seed test-only state.
var failures := 0
var _report: Dictionary

func _initialize() -> void:
	_run.call_deferred()

func _check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error(message)

func _snapshot(gpu: WaterGPU) -> Dictionary:
	_report = {}
	gpu.snapshot(func(report: Dictionary): _report=report)
	while _report.is_empty():
		await process_frame
	return _report

func _advance(gpu: WaterGPU, ticks: int, batch: int = 4) -> Dictionary:
	while ticks>0:
		var count := mini(ticks,batch)
		gpu.advance(float(count)/60.0)
		ticks -= count
		await process_frame
	return await _snapshot(gpu)

func _start(fft: WaterFFTSettings, swe: WaterSWESettings, terrain: Image, foam: WaterFoamSettings) -> WaterGPU:
	var gpu := WaterGPU.new()
	gpu.configure(fft,swe,terrain,Transform3D.IDENTITY,Vector2(16,16),0.0,true,null,foam)
	var ok: bool = await gpu.initialized
	_check(ok,"Foam GPU resources must initialize: "+gpu.error_message)
	await process_frame
	return gpu

func _run() -> void:
	await _offshore_ode()
	for second_order in [false,true]:
		await _nearshore(second_order)
	await _dual_population()
	print("Water foam: %d failure(s)"%failures)
	quit(0 if failures==0 else 1)

func _offshore_ode() -> void:
	var fft := WaterFFTSettings.new()
	fft.resolution = 8
	fft.amplitude = 0.0
	var foam := WaterFoamSettings.new()
	foam.enabled = true
	foam.offshore_threshold = 1.2
	var gpu := await _start(fft,null,null,foam)
	var after := await _advance(gpu,60)
	var source := foam.offshore_generation*(foam.offshore_threshold-1.0)
	var rate := source+foam.offshore_decay
	var expected := source/rate*(1.0-exp(-rate*after.simulated_time))
	var error := 0.0
	for i in 8*8:
		error = maxf(error,absf(after.offshore_foam[i*4]-expected))
		_check(absf(after.offshore_foam[i*4+1]-1.0)<0.000001,"Flat FFT displacement must have Jacobian exactly one")
	_check(error<0.000002,"Offshore history must match the independent frozen-source ODE, error %.9f"%error)
	foam.emission_enabled = false
	gpu.set_foam_parameters(foam.simulation_data(fft,null,Vector2(16,16),Vector2(1,0),true))
	var stopped := await _advance(gpu,60)
	expected *= exp(-foam.offshore_decay*(stopped.simulated_time-after.simulated_time))
	_check(absf(stopped.offshore_foam[0]-expected)<0.000002,"Stopping emission preserves existing offshore history and decays per simulation second")
	foam.texture_period = 4.0
	gpu.set_foam_parameters(foam.simulation_data(fft,null,Vector2(16,16),Vector2(1,0),true))
	var changed := await _advance(gpu,15)
	var expected_phase := fposmod(stopped.offshore_foam[2]+(changed.simulated_time-stopped.simulated_time)/4.0,1.0)
	var phase_error := absf(changed.offshore_foam[2]-expected_phase)
	_check(minf(phase_error,1.0-phase_error)<0.00001,"Editing texture period must continue the existing material phase, not recompute absolute time/period")
	var rebuilt := WaterGPU.new()
	rebuilt.configure(fft,null,null,Transform3D.IDENTITY,Vector2(16,16),0.0,true,gpu,foam)
	gpu.close()
	var ok: bool = await rebuilt.initialized
	_check(ok,"Independent-state rebuild must initialize")
	await process_frame
	var retained := await _snapshot(rebuilt)
	_check(absf(retained.offshore_foam[0]-changed.offshore_foam[0])<0.000001 and retained.simulated_time==changed.simulated_time,"SWE/physics resource rebuilds must preserve independent offshore foam when spectrum and clock are unchanged")
	rebuilt.close()
	await process_frame

func _settings() -> WaterFoamSettings:
	var foam := WaterFoamSettings.new()
	foam.enabled = true
	foam.generation = 60.0
	foam.background_multiplier = 1.0
	foam.rise_threshold = 0.0
	foam.rise_transition = 0.01
	foam.front_generation = 60.0
	foam.closing_threshold = 0.0
	foam.closing_transition = 0.02
	foam.decay = 0.0
	return foam

func _terrain() -> Image:
	var terrain := Image.create(32,32,false,Image.FORMAT_RGF)
	terrain.fill(Color(-2,1,0,1))
	for z in range(12,20):
		for x in range(12,16):
			terrain.set_pixel(x,z,Color(0,0,0,1))
	return terrain

func _nearshore(second_order: bool) -> void:
	var fft := WaterFFTSettings.new()
	fft.resolution = 16
	fft.length = 32.0
	fft.amplitude = 0.02
	var swe := WaterSWESettings.new()
	swe.resolution = 32
	swe.second_order = second_order
	swe.fft_edges = 0
	swe.manning = 0.0
	var foam := _settings()
	foam.second_order_transport = second_order
	var terrain := _terrain()
	var gpu := await _start(fft,swe,terrain,foam)
	var before := await _advance(gpu,60)
	var total := 0.0
	var maximum := 0.0
	for i in 32*32:
		total += before.foam[i*8]
		maximum = maxf(maximum,before.foam[i*8])
		if terrain.get_pixel(i%32,i/32).g<0.5:
			_check(before.foam[i*8]==0.0,"Missing-bed holes must not store foam")
	_check(total>1.0 and maximum>1.0,"Production wave/front source must generate unclipped waterborne density, RK2=%s max=%.4f"%[second_order,maximum])
	foam.emission_enabled = false
	foam.decay = 0.6
	gpu.set_foam_parameters(foam.simulation_data(fft,swe,Vector2(16,16),Vector2(1,0),true))
	var after := await _advance(gpu,30)
	var mass := 0.0
	for i in 32*32:
		mass += after.foam[i*8]
		_check(after.foam[i*8]>=0.0,"Foam transport remains nonnegative")
	var expected := total*exp(-foam.decay*(after.simulated_time-before.simulated_time))
	_check(absf(mass-expected)/expected<0.00003,"Closed-domain conservative transport must leave exactly the independent integrated decay, RK2=%s relative error %.8f"%[second_order,absf(mass-expected)/expected])
	_check(after.faults==0,"Foam must not introduce numeric faults")
	# Same initial physical path submitted at 30 and 60 Hz, no alternate solver mock.
	foam.emission_enabled = true
	foam.decay = 0.0
	var a := await _start(fft,swe,terrain,foam)
	var b := await _start(fft,swe,terrain,foam)
	var result_a := await _advance(a,30,1)
	var result_b := await _advance(b,30,2)
	_check(result_a.foam == result_b.foam,"Foam amount, momentum and material coordinates must be independent of 30/60 Hz submission batching")
	gpu.close()
	a.close()
	b.close()
	await process_frame

func _dual_population() -> void:
	var fft := WaterFFTSettings.new()
	fft.resolution = 16
	fft.length = 32.0
	fft.amplitude = 0.02
	var swe := WaterSWESettings.new()
	swe.resolution = 32
	swe.second_order = true
	swe.fft_edges = 0
	var foam := _settings()
	foam.dual_population = true
	var gpu := await _start(fft,swe,_terrain(),foam)
	var before := await _advance(gpu,60)
	var fresh := 0.0
	var residual := 0.0
	for i in 32*32:
		fresh += before.foam[i*8]-before.foam[i*8+3]
		residual += before.foam[i*8+3]
		_check(before.foam[i*8]>=before.foam[i*8+3] and before.foam[i*8+3]>=0.0,"N/R must be distinct nonnegative waterborne amounts")
	_check(fresh>1.0 and residual>0.1 and before.faults==0,"Actual source, SL flow and N→R reaction must produce both populations")
	gpu.close()
	await process_frame
