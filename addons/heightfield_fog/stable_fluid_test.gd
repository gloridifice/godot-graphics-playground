extends SceneTree

# Owner-boundary GPU checks: reference-height transport, temporary gain, projection,
# and the real playground's backend switch/pause lifecycle. No source-shape assertions.
var failures := 0
var _report: Dictionary = {}

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	await _rest_and_projection()
	await _radial_transport()
	await _height_gain()
	await _translation()
	await _open_boundaries()
	await _inlet_reference()
	await _playground_switch()
	print("Stable Fluids GPU suite: ","PASS" if failures == 0 else "FAIL")
	for i in 5:
		await process_frame
	quit(0 if failures == 0 else 1)

func _terrain(size: Vector2i) -> Image:
	var image := Image.create(size.x,size.y,false,Image.FORMAT_RGF)
	image.fill(Color(0,1,0,0))
	return image

func _height(size: Vector2i, h: float) -> Image:
	var image := Image.create(size.x,size.y,false,Image.FORMAT_RF)
	image.fill(Color(h,0,0,0))
	return image

func _wind(velocity: Vector2, h: float, transform: Transform3D = Transform3D.IDENTITY) -> PackedFloat32Array:
	var resource := HeightfieldFogInitialization.new()
	resource.base_height = h
	var result := resource.wind_parameters(transform)
	result[0] = velocity.x
	result[1] = velocity.y
	return result

func _ready_solver(solver: HeightfieldFogStableFluid) -> bool:
	for i in 180:
		if solver.ready:
			return true
		await process_frame
	_check(false,"real RenderingDevice initialized the solver")
	return false

func _snapshot(solver: Variant) -> Dictionary:
	_report = {}
	var callback := func(value: Dictionary) -> void: _report = value
	if solver is HeightfieldFogBox:
		solver.swe_snapshot(callback)
	else:
		solver.snapshot(callback)
	for i in 180:
		await process_frame
		if not _report.is_empty():
			return _report
	_check(false,"GPU snapshot completed")
	return {}

# Existing reference/projection cases disable height gain, independently of radial motion.
func _advance(solver: HeightfieldFogStableFluid, count: int, wind: PackedFloat32Array, radius: float = 1.0, drag: float = 0.45, gains: Vector3 = Vector3(1,1,0.8), speed: float = 1.8) -> void:
	for i in count:
		solver.advance(1.0/60.0,drag,radius,speed,64,wind,gains)
		await process_frame

func _rest_and_projection() -> void:
	var size := Vector2i(32,24)
	var terrain := _terrain(size)
	var height := _height(size,0.4)
	for y in size.y:
		for x in size.x:
			terrain.set_pixel(x,y,Color(0.15*sin(x*0.4),1,0,0))
			height.set_pixel(x,y,Color(0.35+0.1*sin(x*0.5)*cos(y*0.3),0,0,0))
	var solver := HeightfieldFogStableFluid.new()
	solver.configure(terrain,height,Vector2(8,6))
	if not await _ready_solver(solver):
		solver.close()
		return
	var baseline := await _snapshot(solver)
	await _advance(solver,30,_wind(Vector2.ZERO,0.35))
	var rest := await _snapshot(solver)
	_check(_scalar_difference(baseline,rest)<0.000001,"uneven initial thickness stays at rest without gravity spreading")
	_check(absf(rest.simulated_time-0.5)<0.00001 and rest.faults==0,"fixed simulation clock advances without numerical recovery")
	# Height isolation is measured through the public swept-body entry point.
	solver.movement(Vector3(-0.1,4,0),Vector3(0.1,4,0),0.05,0.8,12,1)
	await _advance(solver,1,_wind(Vector2.ZERO,0.35))
	var isolated := await _snapshot(solver)
	_check(_maximum_velocity(isolated)<0.000001,"a different floor does not inject air velocity")
	solver.movement(Vector3(-0.1,0,0),Vector3(0.1,0,0),0.05,0.8,12,1)
	await _advance(solver,1,_wind(Vector2.ZERO,0.35))
	var pushed := await _snapshot(solver)
	print("Projection max divergence: ",pushed.divergence_before," -> ",pushed.divergence_after)
	_check(pushed.divergence_before>0.05 and pushed.divergence_after<pushed.divergence_before*0.25,"pressure projection removes most source divergence")
	_check(_maximum_velocity(pushed)>0.05,"walking retains a nonzero projected wake")
	await _advance(solver,30,_wind(Vector2.ZERO,0.35))
	var transported := await _snapshot(solver)
	_check(_scalar_difference(rest,transported)>0.0001,"projected wake transports existing thickness detail")
	_check(transported.maximum_height<=0.450001 and transported.faults==0,"passive height creates no new maximum or numerical faults")
	solver.close()
	# An incompressible air wake must not manufacture depth variations in a uniform layer.
	height.fill(Color(0.4,0,0,0))
	solver = HeightfieldFogStableFluid.new()
	solver.configure(_terrain(size),height,Vector2(8,6))
	if not await _ready_solver(solver):
		solver.close()
		return
	solver.movement(Vector3(-0.1,0,0),Vector3(0.1,0,0),0.05,0.8,12,1)
	await _advance(solver,8,_wind(Vector2.ZERO,0.4))
	var uniform := await _snapshot(solver)
	var error := 0.0
	var drift := 0.0
	for y in range(5,19):
		for x in range(6,26):
			var i := (y*size.x+x)*4
			error = maxf(error,absf(uniform.scalar[i]-0.4))
			drift = maxf(drift,Vector2(uniform.scalar[i+1],uniform.scalar[i+2]).length())
	_check(error<0.000001 and drift>0.001,"uniform interior height stays constant while visual material is advected")
	solver.close()

func _radial_transport() -> void:
	# Public impulses must move the reference map, not manufacture heights. The affine
	# h0 gives an independent exact lookup for every source point inside this domain.
	var size := Vector2i(64,64)
	for uniform in [false,true]:
		var initial := _height(size,0.5)
		if not uniform:
			for y in size.y:
				for x in size.x:
					var point := (Vector2(x,y)+Vector2.ONE*0.5-Vector2(size)*0.5)*0.25
					initial.set_pixel(x,y,Color(0.5+0.015*point.x+0.01*point.y,0,0,0))
		for strength in [-1.0,1.0]:
			var solver := HeightfieldFogStableFluid.new()
			solver.configure(_terrain(size),initial,Vector2(16,16))
			if not await _ready_solver(solver):
				solver.close()
				return
			var baseline := await _snapshot(solver)
			solver.impulse(Vector3(0,4,0),strength)
			await _advance(solver,1,_wind(Vector2.ZERO,0.5),2.0)
			var isolated := await _snapshot(solver)
			_check(_maximum_velocity(isolated)<0.000001 and isolated.scalar==baseline.scalar,"a radial event on another floor cannot change the map or height")
			solver.impulse(Vector3.ZERO,strength)
			await _advance(solver,15,_wind(Vector2.ZERO,0.5),2.0)
			var moved := await _snapshot(solver)
			var radial := 0.0
			var cells := 0
			var error := 0.0
			var far_error := 0.0
			for y in size.y:
				for x in size.x:
					var point := (Vector2(x,y)+Vector2.ONE*0.5-Vector2(size)*0.5)*0.25
					var i := y*size.x+x
					var displacement := Vector2(moved.scalar[i*4+1],moved.scalar[i*4+2])
					var origin := point-displacement
					var expected: float = 0.5 if uniform else 0.5+0.015*origin.x+0.01*origin.y
					error = maxf(error,absf(moved.scalar[i*4]-expected))
					if point.length()>0.3 and point.length()<1.6:
						radial += Vector2(moved.velocity[i*2],moved.velocity[i*2+1]).dot(point.normalized())
						cells += 1
					if point.length()>4.0:
						far_error = maxf(far_error,maxf(displacement.length(),absf(moved.scalar[i*4]-baseline.scalar[i*4])))
			print("Radial reference transport: strength=",strength," uniform=",uniform," mean_radial=",radial/maxi(cells,1)," lookup_error=",error," far_error=",far_error)
			_check(radial*strength/maxi(cells,1)>0.1,"signed jump/landing transport survives pressure projection for more than one tick")
			_check(error<0.000002 and moved.faults==0,"each moved parcel keeps the height of its h0 source, including a uniform field")
			_check(far_error<0.000001,"a local radial event does not flatten or reset untouched distant height detail")
			if not uniform:
				var speed := _maximum_velocity(moved)
				await _advance(solver,120,_wind(Vector2.ZERO,0.5),2.0,4.0)
				var settled := await _snapshot(solver)
				_check(_maximum_velocity(settled)<speed*0.01 and _scalar_difference(baseline,settled)>0.001,"velocity can decay without restoring the displaced thickness pattern")
			solver.close()

func _height_gain() -> void:
	# Zero radial speed isolates vertical response. An odd grid puts an exact cell at
	# the event center; affine h0 and closed-form decay give independent expectations.
	var size := Vector2i(33,25)
	var terrain := _terrain(size)
	var initial := _height(size,0.4)
	var center := 12*size.x+16
	for y in size.y:
		terrain.set_pixel(27,y,Color(0,0,0,0))
		for x in size.x:
			var point := (Vector2(x,y)+Vector2.ONE*0.5-Vector2(size)*0.5)*0.25
			var h := 0.4+0.02*point.x+0.015*point.y
			initial.set_pixel(x,y,Color(0.0 if x>=7 and x<=9 else h,0,0,0))
	var solver := HeightfieldFogStableFluid.new()
	solver.configure(terrain,initial,Vector2(size)*0.25)
	if not await _ready_solver(solver):
		solver.close()
		return
	var gains := Vector3(2,0,0.5)
	var wind := _wind(Vector2.ZERO,0.4)
	var baseline := await _snapshot(solver)
	_check(Array(baseline.height_gain).min()==1.0 and Array(baseline.height_gain).max()==1.0,"height gain initializes at one in valid, dry and invalid cells")
	solver.impulse(Vector3(0,4,0),-1)
	await _advance(solver,1,wind,3.0,0.0,gains,0.0)
	var isolated := await _snapshot(solver)
	_check(isolated.height_gain==baseline.height_gain and isolated.scalar==baseline.scalar,"another floor cannot inject height gain")
	solver.impulse(Vector3.ZERO,-1)
	await _advance(solver,1,wind,3.0,0.0,gains,0.0)
	var lifted := await _snapshot(solver)
	_check(absf(lifted.height_gain[center]-2.0)<0.000001 and absf(lifted.scalar[center*4]-0.8)<0.000001,"takeoff gain reaches two and directly doubles base thickness even with zero radial speed")
	# Catch-up ticks must not consume the same event again after its first tick.
	solver.impulse(Vector3.ZERO,-1)
	solver.advance(4.0/60.0,0.0,3.0,0.0,64,wind,gains)
	var batched := await _snapshot(solver)
	var expected := 1.0+pow(0.5,3.0/60.0/gains.z)
	_check(absf(batched.height_gain[center]-expected)<0.000002,"one event is injected only once across a four-tick catch-up batch")
	await _advance(solver,30,wind,3.0,4.0,gains,0.0)
	var recovered := await _snapshot(solver)
	expected = 1.0+(expected-1.0)*0.5
	var error := 0.0
	var far_error := 0.0
	var dry_gain := 1.0
	for y in size.y:
		for x in size.x:
			var i := y*size.x+x
			var point := (Vector2(x,y)+Vector2.ONE*0.5-Vector2(size)*0.5)*0.25
			var base := initial.get_pixel(x,y).r if x!=27 else 0.0
			error = maxf(error,absf(recovered.scalar[i*4]-base*recovered.height_gain[i]))
			if point.length()>3.0:
				far_error = maxf(far_error,absf(recovered.height_gain[i]-1.0))
			if x==8:
				dry_gain = maxf(dry_gain,recovered.height_gain[i])
	_check(absf(recovered.height_gain[center]-expected)<0.000003,"gain deviation halves in the configured simulation time independently of velocity drag")
	_check(error<0.000002 and far_error==0.0 and dry_gain>1.05,"gain multiplies unchanged h0 without flattening distant detail or creating fog in an affected dry patch")
	solver.impulse(Vector3.ZERO,1)
	await _advance(solver,1,wind,3.0,0.0,gains,0.0)
	var landed := await _snapshot(solver)
	_check(landed.height_gain[center]==0.0 and landed.scalar[center*4]==0.0,"full landing overrides a remaining lift and can reach zero thickness")
	_check(Array(landed.height_gain).min()>=0.0 and Array(landed.height_gain).max()<=2.0 and landed.faults==0,"repeated opposing interactions remain bounded in the zero-to-two encoding")
	await _advance(solver,30,wind,3.0,0.0,gains,0.0)
	var rising := await _snapshot(solver)
	_check(absf(rising.height_gain[center]-0.5)<0.000003,"depressed height also recovers toward one with the same half-life")
	# An exact four-cell translation proves the gain follows material, not world space.
	await _advance(solver,1,_wind(Vector2(60,0),0.4),3.0,0.0,gains,0.0)
	var moved := await _snapshot(solver)
	var destination := center+4
	expected = 1.0+(rising.height_gain[center]-1.0)*pow(0.5,1.0/60.0/gains.z)
	_check(absf(moved.height_gain[destination]-expected)<0.000003 and absf(moved.scalar[destination*4]-0.4*expected)<0.000003 and absf(moved.scalar[destination*4+1]-1.0)<0.000001,"gain and the immutable height reference move together under wind")
	_check(moved.height_gain[12*size.x]==1.0 and moved.height_gain[12*size.x+27]==1.0 and moved.height_gain[12*size.x+30]==1.0,"fresh inflow and invalid cells are neutral and a trace cannot import gain across a hole")
	solver.close()

func _translation() -> void:
	var size := Vector2i(96,12)
	var initial := _height(size,0.35)
	for y in size.y:
		for x in size.x:
			var position := (x+0.5)*0.25
			initial.set_pixel(x,y,Color(0.35+0.1*sin(TAU*position/1.5),0,0,0))
	for angle in [0.0,PI*0.5]:
		var transform := Transform3D(Basis(Vector3.UP,angle),Vector3.ZERO)
		var solver := HeightfieldFogStableFluid.new()
		solver.configure(_terrain(size),initial,Vector2(24,3))
		if not await _ready_solver(solver):
			solver.close()
			return
		var elapsed := 0
		var report: Dictionary
		# Integer-cell translations of a six-cell wave have exact independent samples.
		# Repeated height interpolation loses its amplitude; a reference map must not.
		for tick in [60,360]:
			await _advance(solver,tick-elapsed,_wind(Vector2(0.75,0),0.35,transform))
			elapsed = tick
			report = await _snapshot(solver)
			var error := 0.0
			var drift_error := 0.0
			var distance: float = 0.75*tick/60.0
			var world_drift := transform.basis*Vector3(distance,0,0)
			for y in size.y:
				for x in range(40,94):
					var expected := 0.35+0.1*sin(TAU*((x+0.5)*0.25-distance)/1.5)
					var i := (y*size.x+x)*4
					error = maxf(error,absf(report.scalar[i]-expected))
					drift_error = maxf(drift_error,absf(report.scalar[i+1]-world_drift.x)+absf(report.scalar[i+2]-world_drift.z))
			print("Reference translation max error: ",error," material drift error: ",drift_error," rotation=",angle," tick=",tick)
			_check(error<0.0002 and drift_error<0.0002,"fine height detail survives long wind translation in a rotated box")
			_check(report.maximum_height<=0.450001 and report.faults==0 and report.trace_limited==0,"wind translation remains bounded and finite")
		await _advance(solver,15,_wind(Vector2.ZERO,0.35,transform))
		var stopped := await _snapshot(solver)
		var movement := 0.0
		for i in report.scalar.size():
			movement = maxf(movement,absf(report.scalar[i]-stopped.scalar[i]))
		_check(movement<0.00001,"changing wind speed to zero preserves the accumulated height and material phase")
		solver.close()

func _open_boundaries() -> void:
	var size := Vector2i(24,16)
	var terrain := _terrain(size)
	for y in size.y:
		terrain.set_pixel(11,y,Color(0,0,0,0))
	for velocity in [Vector2.RIGHT,Vector2.LEFT,Vector2.UP,Vector2.DOWN]:
		var solver := HeightfieldFogStableFluid.new()
		solver.configure(terrain,_height(size,0.0),Vector2(6,4))
		if not await _ready_solver(solver):
			solver.close()
			return
		await _advance(solver,45,_wind(velocity,0.4))
		var report := await _snapshot(solver)
		var inlet := Vector2i(0,8) if velocity.x>0 else Vector2i(23,8)
		if velocity.y != 0:
			inlet = Vector2i(4,0) if velocity.y>0 else Vector2i(4,15)
		_check(report.scalar[(inlet.y*size.x+inlet.x)*4]>0.37,"open upstream perimeter fills from resource height: "+str(velocity))
		var valid := true
		for y in size.y:
			for x in size.x:
				var h: float = report.scalar[(y*size.x+x)*4]
				valid = valid and is_finite(h) and h>=0.0 and h<=0.400001 and (x!=11 or h==0.0)
		_check(valid and report.faults==0,"open transport is bounded and invalid support remains empty: "+str(velocity))
		solver.close()
	var uniform_solver := HeightfieldFogStableFluid.new()
	uniform_solver.configure(terrain,_height(size,0.4),Vector2(6,4))
	if not await _ready_solver(uniform_solver):
		uniform_solver.close()
		return
	await _advance(uniform_solver,60,_wind(Vector2.RIGHT,0.4))
	var uniform := await _snapshot(uniform_solver)
	var seam_error := 0.0
	for y in size.y:
		for x in size.x:
			if x!=11:
				seam_error = maxf(seam_error,absf(uniform.scalar[(y*size.x+x)*4]-0.4))
	_check(seam_error<0.00001,"matching initial and inlet heights stay uniform across box and hole source transitions")
	uniform_solver.close()
	# One tick travels several cells: sampling only the endpoint would import the
	# 0.9 layer through the hole instead of using its local 0.25 inflow reservoir.
	var initial := _height(size,0.1)
	for y in size.y:
		for x in range(11):
			initial.set_pixel(x,y,Color(0.9,0,0,0))
	var solver := HeightfieldFogStableFluid.new()
	solver.configure(terrain,initial,Vector2(6,4))
	if not await _ready_solver(solver):
		solver.close()
		return
	await _advance(solver,1,_wind(Vector2(60,0),0.25))
	var crossing := await _snapshot(solver)
	_check(absf(crossing.scalar[(8*24+12)*4]-0.25)<0.00001 and crossing.scalar[(8*24+14)*4]<=0.250001,"backtrace stops at a hole rather than importing from its far side")
	solver.close()

func _inlet_reference() -> void:
	var size := Vector2i(24,16)
	var terrain := _terrain(size)
	for y in size.y:
		terrain.set_pixel(11,y,Color(0,0,0,0))
		for x in range(12,24):
			terrain.set_pixel(x,y,Color(0.2 if x<16 else 0.5,1,0,0))
	var solver := HeightfieldFogStableFluid.new()
	solver.configure(terrain,_height(size,0.9),Vector2(6,4))
	if not await _ready_solver(solver):
		solver.close()
		return
	var wind := _wind(Vector2.RIGHT,0.6)
	wind[7] = 1.0 # Horizontal top: supply at the hole is 0.6 - 0.2 = 0.4.
	await _advance(solver,480,wind)
	var supplied := await _snapshot(solver)
	_check(absf(supplied.scalar[(8*24+20)*4]-0.4)<0.0001,"inlet material keeps entry support height rather than adopting downstream terrain or h0")
	wind[0] = -1.0 # New inflow from the opposite edge has depth 0.6 - 0.5 = 0.1.
	await _advance(solver,30,wind)
	var reversed := await _snapshot(solver)
	_check(reversed.scalar[(8*24+14)*4]>0.39 and reversed.scalar[(8*24+23)*4]<0.2,"wind reversal retains old inlet material while admitting the new edge's height")
	solver.close()
	# A sampled sine texture gives an independent analytic inlet. Its source differs
	# from h0, so neither clamping a reference to h0 nor freezing entry height can pass.
	var noise := Image.create(64,1,false,Image.FORMAT_RF)
	for x in 64:
		noise.set_pixel(x,0,Color(0.5+0.5*sin(TAU*(x+0.5)/64.0),0,0,0))
	solver = HeightfieldFogStableFluid.new()
	solver.configure(_terrain(size),_height(size,0.9),Vector2(6,4),noise)
	if not await _ready_solver(solver):
		solver.close()
		return
	wind = _wind(Vector2.RIGHT,0.4)
	wind[12] = 0.2
	wind[14] = 0.25 # Four-meter wavelength; no wind-aligned stretch.
	wind[15] = 1.0
	wind[16] = 1.0
	wind[17] = 0.0
	await _advance(solver,480,wind)
	var patterned := await _snapshot(solver)
	var error := 0.0
	for x in range(13):
		var origin := (x+0.5)*0.25-3.0-8.0
		var expected := 0.4+0.2*sin(TAU*origin*0.25)
		error = maxf(error,absf(patterned.scalar[(8*24+x)*4]-expected))
	print("Inlet reference analytic max error: ",error)
	_check(error<0.001 and patterned.faults==0,"fresh inlet noise is reconstructed from its reference coordinates after long transport")
	wind[0] = 0.0
	await _advance(solver,15,wind)
	var stopped := await _snapshot(solver)
	_check(patterned.scalar==stopped.scalar,"stopping wind does not erase or reinitialize previously admitted material")
	solver.close()

func _playground_switch() -> void:
	var scene := load("res://scenes/fog_playground.tscn").instantiate() as Node3D
	root.add_child(scene)
	current_scene = scene
	var box := scene.get_node("FogFields/GroundMist") as HeightfieldFogBox
	box.swe_paused = true
	for i in 120:
		await process_frame
		if box.swe_metrics().ready:
			break
	var original := await _snapshot(box)
	_check(original.has("state") and original.simulated_time==0.0,"existing scene still starts with paused SWE")
	var event := InputEventKey.new()
	event.physical_keycode = KEY_F2
	event.pressed = true
	Input.parse_input_event(event)
	for i in 120:
		await process_frame
		if box.simulation_method == HeightfieldFogBox.SimulationMethod.STABLE_FLUIDS and box.swe_metrics().ready:
			break
	var stable := await _snapshot(box)
	_check(stable.has("scalar") and stable.simulated_time==0.0,"real F2 switch initializes Stable Fluids without advancing a paused box")
	if stable.has("scalar"):
		var error := 0.0
		for i in range(0,stable.scalar.size(),4):
			error = maxf(error,absf(stable.scalar[i]-original.state[i]))
		_check(error<0.000001,"backend switch uses exactly the same resource initial thickness")
	box.swe_paused = false
	var peak := 0
	for i in box.resolution*box.resolution:
		if stable.scalar[i*4]>stable.scalar[peak*4]:
			peak = i
	var x := peak%box.resolution
	var z := peak/box.resolution
	var support := box.height_map.get_image().get_pixel(x,z)
	var local_feet := Vector3(((x+0.5)/box.resolution-0.5)*box.size.x,support.r/support.g,((z+0.5)/box.resolution-0.5)*box.size.z)
	box.disturb_mist(box.to_global(local_feet),-1.0)
	for i in 15:
		await process_frame
	box.swe_paused = true
	var advanced := await _snapshot(box)
	_check(Array(advanced.height_gain).max()>1.05,"real box parameters and impulse produce non-neutral gain before pausing")
	box.push_mist(box.global_position,box.global_position+Vector3(0.1,0,0),0.05)
	box.disturb_mist(box.global_position)
	for i in 10:
		await process_frame
	var paused := await _snapshot(box)
	_check(advanced.simulated_time>0.0 and advanced.simulated_time==paused.simulated_time and advanced.scalar==paused.scalar and advanced.height_gain==paused.height_gain,"pause freezes height, gain recovery, material transport and the simulation clock")
	box.reset_swe()
	for i in 120:
		await process_frame
		if box.swe_metrics().ready:
			break
	var reset := await _snapshot(box)
	_check(reset.simulated_time==0.0 and reset.faults==0 and Array(reset.height_gain).min()==1.0 and Array(reset.height_gain).max()==1.0,"explicit reset rebuilds the selected paused backend with neutral height gain")
	Input.parse_input_event(event)
	for i in 120:
		await process_frame
		if box.simulation_method == HeightfieldFogBox.SimulationMethod.SWE and box.swe_metrics().ready:
			break
	var restored := await _snapshot(box)
	_check(restored.has("state") and restored.simulated_time==0.0,"F2 returns to initialized SWE without stale GPU resources")
	scene.queue_free()
	current_scene = null
	for i in 5:
		await process_frame

func _scalar_difference(a: Dictionary, b: Dictionary) -> float:
	var difference := 0.0
	for i in range(0,a.scalar.size(),4):
		difference = maxf(difference,absf(a.scalar[i]-b.scalar[i]))
	return difference

func _maximum_velocity(report: Dictionary) -> float:
	var maximum := 0.0
	for value in report.velocity:
		maximum = maxf(maximum,absf(value))
	return maximum

func _check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error("FAIL: "+message)
	else:
		print("PASS: ",message)
