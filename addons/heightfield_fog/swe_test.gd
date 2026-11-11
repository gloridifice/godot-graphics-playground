extends SceneTree

var failures := 0
var _report: Dictionary = {}

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	# Jagged terrain, a wet/dry shoreline and invalid cells: a horizontal free surface must rest.
	var terrain := Image.create(32,32,false,Image.FORMAT_RGF)
	var initial := Image.create(32,32,false,Image.FORMAT_RF)
	for z in 32:
		for x in 32:
			var b := x*0.035+0.1*sin(z*0.4)
			var valid := not (x>8 and x<13 and z>12 and z<20)
			terrain.set_pixel(x,z,Color(b,1.0 if valid else 0.0,0,0))
			initial.set_pixel(x,z,Color(maxf(0.8-b,0.0) if valid else 0.0,0,0,0))
	var solver := HeightfieldFogSWE.new()
	solver.configure(terrain,initial,Vector2(8,8))
	if not await _wait_ready(solver):
		quit(1)
		return
	var baseline := await _snapshot(solver)
	for i in 120:
		solver.advance(1.0/60,1.2,0.0,2.0,1.8)
		await process_frame
	var rested := await _snapshot(solver)
	var max_error := 0.0
	for i in range(0,rested.state.size(),4):
		max_error = maxf(max_error,absf(rested.state[i]-baseline.state[i]))
		max_error = maxf(max_error,absf(rested.state[i+1])+absf(rested.state[i+2]))
	_check(max_error<0.0002,"lake at rest survives jagged terrain, dry shore and holes")
	_check(absf(_mass(rested)-_mass(baseline))<0.001,"resting lake conserves mass")
	_check(rested.faults==0 and absf(rested.simulated_time-2.0)<0.002,"GPU clock advances requested time without faults")
	solver.close()
	# Flat isolated reservoir: impulse redistributes mass, never erases density or resets on a timer.
	terrain.fill(Color(0,1,0,0))
	initial.fill(Color(0.6,0,0,0))
	solver = HeightfieldFogSWE.new()
	solver.configure(terrain,initial,Vector2(8,8))
	await _wait_ready(solver)
	baseline = await _snapshot(solver)
	solver.impulse(Vector3(0,4,0))
	for i in 4:
		solver.advance(1.0/60,1.2,0.45,2.0,1.8)
		await process_frame
	var separated := await _snapshot(solver)
	_check(_difference(baseline,separated)<0.00001,"jump on another floor does not inject momentum")
	solver.impulse(Vector3.ZERO)
	for i in 30:
		solver.advance(1.0/60,1.2,0.45,2.0,1.8)
		await process_frame
	var pushed := await _snapshot(solver)
	var lowest := 1.0
	var highest := 0.0
	for i in range(0,pushed.state.size(),4):
		lowest = minf(lowest,pushed.state[i])
		highest = maxf(highest,pushed.state[i])
	_check(lowest<0.55 and highest>0.61,"jump transports thickness outwards and piles it up")
	_check(absf(_mass(pushed)-_mass(baseline))/_mass(baseline)<0.0001,"jump preserves total layer mass")
	for i in 150:
		solver.advance(1.0/60,1.2,0.45,2.0,1.8)
		await process_frame
	var later := await _snapshot(solver)
	_check(_difference(baseline,later)>0.0001,"state evolves physically, rather than resetting after a fixed duration")
	_check(later.faults==0 and later.cfl_limited_steps==0,"default impulse is finite and maintains the requested simulation rate")
	_check(absf(_mass(later)-_mass(baseline))/_mass(baseline)<0.0002,"closed reservoir conserves mass after wave/boundary interaction")
	# Strong overlapping impulses exercise adaptive CFL and donor draining without negative depths.
	for i in 4:
		solver.impulse(Vector3.ZERO)
	for i in 20:
		solver.advance(1.0/60,9.81,0,1.0,4.0)
		await process_frame
	var stressed := await _snapshot(solver)
	for i in range(0,stressed.state.size(),4):
		_check(is_finite(stressed.state[i]) and stressed.state[i]>=0,"stressed depth remains finite/nonnegative")
	_check(stressed.faults==0,"strong impulses do not trigger NaN recovery")
	_check(absf(_mass(stressed)-_mass(baseline))/_mass(baseline)<0.0003,"draining limiter preserves mass under strong impulses")
	solver.close()
	# Signed inward impulses must gather existing layer mass, not just invert a visual mask.
	terrain.fill(Color(0,1,0,0))
	initial.fill(Color(0.6,0,0,0))
	solver = HeightfieldFogSWE.new()
	solver.configure(terrain,initial,Vector2(8,8))
	await _wait_ready(solver)
	var gather_start := await _snapshot(solver)
	solver.impulse(Vector3.ZERO, -1.0)
	for i in 8:
		solver.advance(1.0/60,1.2,0.45,2.0,1.8)
		await process_frame
	var gathered := await _snapshot(solver)
	var radial_momentum := 0.0
	for z in 32:
		for x in 32:
			var offset := (Vector2(x,z)+Vector2.ONE*0.5-Vector2(16,16))*0.25
			var cell := (z*32+x)*4
			radial_momentum += Vector2(gathered.state[cell+1],gathered.state[cell+2]).dot(offset)
	_check(radial_momentum < -1.0, "negative radial strength creates inward GPU momentum")
	_check(gathered.state[(16*32+16)*4] > 0.65, "inward SWE transport accumulates thickness at the center")
	_check(absf(_mass(gathered)-_mass(gather_start))/_mass(gather_start)<0.0001 and gathered.faults==0, "gathering preserves mass without numerical faults")
	solver.close()
	# A dam release must wet previously dry terrain, without leaking into invalid cells.
	terrain.fill(Color(0,1,0,0))
	initial.fill(Color(0,0,0,0))
	for z in 32:
		for x in 32:
			if x<12:
				initial.set_pixel(x,z,Color(1,0,0,0))
			if x==20 and z>=12 and z<20:
				terrain.set_pixel(x,z,Color(0,0,0,0))
	solver = HeightfieldFogSWE.new()
	solver.configure(terrain,initial,Vector2(8,8))
	await _wait_ready(solver)
	var dam_start := await _snapshot(solver)
	for i in 180:
		solver.advance(1.0/60,1.2,0.2,2.0,1.8)
		await process_frame
	var dam_end := await _snapshot(solver)
	var newly_wet := 0
	for z in 32:
		for x in 32:
			var h: float = dam_end.state[(z*32+x)*4]
			_check(is_finite(h) and h>=0,"dry-front depth remains nonnegative")
			if x>=12 and h>0.001:
				newly_wet += 1
			if terrain.get_pixel(x,z).g<0.5:
				_check(h==0,"invalid terrain stays impermeable")
	_check(newly_wet>64,"SWE transports mass into previously dry cells")
	_check(absf(_mass(dam_end)-_mass(dam_start))/_mass(dam_start)<0.0003 and dam_end.faults==0,"wetting front conserves mass without faults")
	print("SWE GPU: ","PASS" if failures==0 else "FAIL", " rest_error=",max_error," jump_h_min/max=",lowest,"/",highest," mass_relative_error=",absf(_mass(stressed)-_mass(baseline))/_mass(baseline)," CFL_limited=",stressed.cfl_limited_steps)
	solver.close()
	for i in 5:
		await process_frame
	quit(0 if failures==0 else 1)

func _wait_ready(solver: HeightfieldFogSWE) -> bool:
	for i in 300:
		if solver.ready:
			return true
		await process_frame
	_check(false,"solver initialized")
	quit(1)
	return false

func _snapshot(solver: HeightfieldFogSWE) -> Dictionary:
	_report = {}
	solver.snapshot(func(value: Dictionary): _report = value)
	for i in 300:
		if not _report.is_empty():
			return _report
		await process_frame
	_check(false,"diagnostic snapshot completed")
	quit(1)
	return {}

func _mass(report: Dictionary) -> float:
	var total := 0.0
	for i in range(0,report.state.size(),4):
		total += report.state[i]
	return total

func _difference(a: Dictionary,b: Dictionary) -> float:
	var total := 0.0
	for i in a.state.size():
		total += absf(a.state[i]-b.state[i])
	return total/a.state.size()

func _check(condition: bool,message: String) -> void:
	if not condition:
		failures += 1
		printerr("FAIL: ",message)
