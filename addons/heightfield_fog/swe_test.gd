extends SceneTree

var failures := 0
var _report: Dictionary = {}

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	for second_order in [false,true]:
		await _run_order(second_order)
	await _test_advection()
	await _test_movement()
	await _test_support_boundaries()
	print("SWE GPU suite: ","PASS" if failures==0 else "FAIL")
	for i in 5:
		await process_frame
	quit(0 if failures==0 else 1)

func _run_order(second_order: bool) -> void:
	# Jagged terrain, a wet/dry shoreline and a solid ridge: a closed lake must rest.
	var terrain := Image.create(32,32,false,Image.FORMAT_RGF)
	var initial := Image.create(32,32,false,Image.FORMAT_RF)
	for z in 32:
		for x in 32:
			var b := x*0.035+0.1*sin(z*0.4)
			if x==0 or x==31 or z==0 or z==31 or (x>8 and x<13 and z>12 and z<20):
				b = 2.0
			terrain.set_pixel(x,z,Color(b,1,0,0))
			initial.set_pixel(x,z,Color(maxf(0.8-b,0.0),0,0,0))
	var solver := HeightfieldFogSWE.new()
	solver.configure(terrain,initial,Vector2(8,8),null,second_order)
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
	_check(max_error<0.0002,"lake at rest survives jagged terrain, dry shore and a solid ridge")
	_check(absf(_mass(rested)-_mass(baseline))<0.001,"resting lake conserves mass")
	_check(rested.faults==0 and absf(rested.simulated_time-2.0)<0.002,"GPU clock advances requested time without faults")
	# The threshold must also preserve hydrostatic balance where depths cross it.
	for i in 60:
		solver.advance(1.0/60,1.2,0.0,2.0,1.8,0.3)
		await process_frame
	var threshold_rest := await _snapshot(solver)
	_check(_difference(baseline,threshold_rest)<0.00002 and threshold_rest.faults==0,"threshold preserves horizontal free surface over jagged terrain and dry shore")
	solver.close()
	# Uneven resting thin mist: threshold suppresses gravity, not inertial/player transport.
	terrain.fill(Color(0,1,0,0))
	for z in 32:
		for x in 32:
			initial.set_pixel(x,z,Color(0.3 if x<16 else 0.1,0,0,0))
	_solid_border(terrain,initial)
	for threshold in [0.0,0.2,0.4]:
		solver = HeightfieldFogSWE.new()
		solver.configure(terrain,initial,Vector2(8,8),null,second_order)
		if not await _wait_ready(solver):
			return
		var thin_start := await _snapshot(solver)
		for i in 60:
			solver.advance(1.0/60,1.2,0.45,2.0,1.8,threshold)
			await process_frame
		var thin_end := await _snapshot(solver)
		if threshold == 0.4:
			_check(_difference(thin_start,thin_end)<0.000001,"sub-threshold uneven mist stays at rest without numerical creep")
			# A gravity threshold must not disable player-driven transport.
			solver.impulse(Vector3.ZERO)
			for i in 12:
				solver.advance(1.0/60,1.2,0.45,2.0,1.8,threshold)
				await process_frame
			var thin_pushed := await _snapshot(solver)
			_check(_difference(thin_end,thin_pushed)>0.0001,"player impulse still transports sub-threshold mist")
			_check(absf(_mass(thin_pushed)-_mass(thin_start))/_mass(thin_start)<0.0003 and thin_pushed.faults==0,"sub-threshold impulse conserves mass without faults")
		elif threshold == 0.2:
			_check(thin_end.state[(16*32+15)*4]<0.29 and thin_end.state[(16*32+16)*4]>0.11,"excess depth above threshold drives gravity transport across threshold interface")
		else:
			_check(_difference(thin_start,thin_end)>0.0001,"zero threshold retains original gravity-driven spreading")
		_check(absf(_mass(thin_end)-_mass(thin_start))/_mass(thin_start)<0.0003 and thin_end.faults==0,"threshold gravity transport conserves mass without faults")
		solver.close()
	# Flat isolated reservoir: impulse redistributes mass, never erases density or resets on a timer.
	terrain.fill(Color(0,1,0,0))
	initial.fill(Color(0.6,0,0,0))
	_solid_border(terrain,initial)
	solver = HeightfieldFogSWE.new()
	solver.configure(terrain,initial,Vector2(8,8),null,second_order)
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
	# Exclude the deliberately dry solid rim from the thickness-change measurement.
	for z in range(1,31):
		for x in range(1,31):
			var h: float = pushed.state[(z*32+x)*4]
			lowest = minf(lowest,h)
			highest = maxf(highest,h)
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
	_solid_border(terrain,initial)
	solver = HeightfieldFogSWE.new()
	solver.configure(terrain,initial,Vector2(8,8),null,second_order)
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
	# A dam release must wet dry terrain without crossing a genuine solid ridge.
	terrain.fill(Color(0,1,0,0))
	initial.fill(Color(0,0,0,0))
	for z in 32:
		for x in 32:
			if x<12:
				initial.set_pixel(x,z,Color(1,0,0,0))
			if x==20 and z>=12 and z<20:
				terrain.set_pixel(x,z,Color(2,1,0,0))
	_solid_border(terrain,initial)
	solver = HeightfieldFogSWE.new()
	solver.configure(terrain,initial,Vector2(8,8),null,second_order)
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
			if terrain.get_pixel(x,z).r>1.5:
				_check(h==0,"solid high-ground ridge stays dry")
	_check(newly_wet>64,"SWE transports mass into previously dry cells")
	_check(absf(_mass(dam_end)-_mass(dam_start))/_mass(dam_start)<0.0003 and dam_end.faults==0,"wetting front conserves mass without faults")
	print("SWE GPU: ","PASS" if failures==0 else "FAIL", " second_order=",second_order," rest_error=",max_error," jump_h_min/max=",lowest,"/",highest," mass_relative_error=",absf(_mass(stressed)-_mass(baseline))/_mass(baseline)," CFL_limited=",stressed.cfl_limited_steps)
	solver.close()

func _test_advection() -> void:
	# Independent cell-average sine translation: isolate numerical diffusion from gravity.
	var terrain := Image.create(64,16,false,Image.FORMAT_RGF)
	terrain.fill(Color(0,1,0,0))
	var initial := Image.create(64,16,false,Image.FORMAT_RF)
	var dx := 8.0/64.0
	var k := TAU/2.0
	var average_factor := sin(k*dx*0.5)/(k*dx*0.5)
	for z in 16:
		for x in 64:
			initial.set_pixel(x,z,Color(0.4+0.2*average_factor*sin(k*((x+0.5)*dx-4.0)),0,0,0))
	var preset := HeightfieldFogInitialization.new()
	preset.natural_mist_enabled = true
	preset.base_height = 0.4
	preset.wind_direction = 0.0
	preset.wind_speed = 0.5
	var wind := preset.wind_parameters(Transform3D.IDENTITY)
	var errors: Array[float] = []
	for second_order in [false,true]:
		var solver := HeightfieldFogSWE.new()
		solver.configure(terrain,initial,Vector2(8,4),null,second_order)
		if not await _wait_ready(solver):
			return
		for i in 120:
			solver.advance(1.0/60,1.2,0.0,2.0,0.0,1.0,wind)
			await process_frame
		var report := await _snapshot(solver)
		var error := 0.0
		# Keep the measured window away from the prescribed constant inflow.
		for z in 16:
			for x in 64:
				var h: float = report.state[(z*64+x)*4]
				_check(is_finite(h) and h>=0.195 and h<=0.605,"limited transport stays bounded without new oscillations")
				if x>=16 and x<48:
					var exact := 0.4+0.2*average_factor*sin(k*((x+0.5)*dx-4.0-0.5*report.simulated_time))
					error += absf(h-exact)/(16.0*32.0)
		errors.append(error)
		_check(report.faults==0 and absf(report.simulated_time-2.0)<0.002,"advection advances the same physical time without faults")
		solver.close()
	_check(errors[1]<errors[0]*0.8,"limited second-order reconstruction reduces analytic translation error by at least 20 percent")
	print("SWE transport L1 first/second=",errors)

func _test_movement() -> void:
	# Primary owner: actual GPU momentum/transport, not a reimplementation of the force.
	# Orthogonal travel catches swapped X/Z; both spatial orders share the source.
	var terrain := Image.create(64,64,false,Image.FORMAT_RGF)
	terrain.fill(Color(0,1,0,0))
	var initial := Image.create(64,64,false,Image.FORMAT_RF)
	initial.fill(Color(0.4,0,0,0))
	_solid_border(terrain,initial)
	var reference_momentum := Vector2.ZERO
	for second_order in [false,true]:
		for direction in [Vector3.RIGHT,Vector3.BACK]:
			var solver := HeightfieldFogSWE.new()
			solver.configure(terrain,initial,Vector2(8,8),null,second_order)
			if not await _wait_ready(solver):
				return
			var before := await _snapshot(solver)
			# A different storey and a stationary sample must leave this field untouched.
			solver.movement(Vector3(0,3,0),direction*0.05+Vector3(0,3,0),1.0/60,0.65,7.0,0.65)
			solver.movement(Vector3.ZERO,Vector3.ZERO,1.0/60,0.65,7.0,0.65)
			solver.advance(1.0/60,1.2,0.45,2.0,1.8,1.0)
			await process_frame
			var separated := await _snapshot(solver)
			_check(_difference(before,separated)<0.000001,"stationary body and travel on another floor do not disturb mist")
			var feet: Vector3 = -direction*0.5
			for step in 20:
				var next: Vector3 = feet+direction*0.05
				solver.movement(feet,next,1.0/60,0.65,7.0,0.65)
				feet = next
				solver.advance(1.0/60,1.2,0.45,2.0,1.8,1.0)
				await process_frame
			var pushed := await _snapshot(solver)
			if not second_order and direction == Vector3.RIGHT:
				for i in range(0,pushed.state.size(),4):
					reference_momentum += Vector2(pushed.state[i+1],pushed.state[i+2])
			var forward := Vector2(direction.x,direction.z)
			var side := Vector2(-forward.y,forward.x)
			var front := 0.0
			var flanks := 0.0
			var wake := 0.0
			var min_height := 0.4
			var max_height := 0.4
			for z in 64:
				for x in 64:
					var offset := (Vector2(x,z)+Vector2.ONE*0.5)*0.125-Vector2.ONE*4.0-Vector2(feet.x,feet.z)
					var a := offset.dot(forward)
					var b := offset.dot(side)
					var cell := (z*64+x)*4
					var momentum := Vector2(pushed.state[cell+1],pushed.state[cell+2])
					if a>0.1 and a<0.8 and absf(b)<0.35:
						front += momentum.dot(forward)
					if absf(a)<0.5 and absf(b)>0.3 and absf(b)<0.9:
						flanks += momentum.dot(side)*signf(b)
					if a < -0.5 and a > -1.8 and absf(b)<0.3:
						wake += momentum.dot(forward)
					if terrain.get_pixel(x,z).r<1.0:
						min_height = minf(min_height,pushed.state[cell])
						max_height = maxf(max_height,pushed.state[cell])
			_check(front>0.1 and flanks>0.1 and wake>0.1,"moving body pushes forward, diverts both flanks and drags a wake in its travel direction")
			_check(min_height<0.39 and max_height>0.41,"movement redistributes real layer thickness, not just shading")
			_check(absf(_mass(pushed)-_mass(before))/_mass(before)<0.0003 and pushed.faults==0 and pushed.cfl_limited_steps==0,"walking conserves solid-rim reservoir mass and advances without numerical faults or CFL slowdown")
			var peak := _peak_speed(pushed)
			for step in 60:
				solver.advance(1.0/60,1.2,0.45,2.0,1.8,1.0)
				await process_frame
			var stopped := await _snapshot(solver)
			_check(_peak_speed(stopped)<peak*0.85 and _difference(before,stopped)>0.00001,"after stopping the wake decays physically without replaying the last movement or resetting thickness")
			print("SWE walking order=",second_order," direction=",direction," front/flanks/wake=",Vector3(front,flanks,wake)," h_min/max=",min_height,"/",max_height)
			solver.close()

	# Same physical path at 30 Hz submission, retaining both 60 Hz contact samples.
	# Catches per-render-frame scaling and dropped/replayed movement samples.
	var batched := HeightfieldFogSWE.new()
	batched.configure(terrain,initial,Vector2(8,8))
	if not await _wait_ready(batched):
		return
	var feet := Vector3(-0.5,0,0)
	for frame in 10:
		for contact in 2:
			batched.movement(feet,feet+Vector3(0.05,0,0),1.0/60,0.65,7.0,0.65)
			feet.x += 0.05
		batched.advance(2.0/60,1.2,0.45,2.0,1.8,1.0)
		await process_frame
	var report := await _snapshot(batched)
	var batched_momentum := Vector2.ZERO
	for i in range(0,report.state.size(),4):
		batched_momentum += Vector2(report.state[i+1],report.state[i+2])
	var relative_error := batched_momentum.distance_to(reference_momentum)/reference_momentum.length()
	_check(relative_error<0.08 and absf(report.simulated_time-20.0/60)<0.001,"30/60 Hz submissions retain comparable physical forcing and the same simulation time")
	print("SWE walking 30/60 Hz momentum relative error=",relative_error)
	batched.close()

func _peak_speed(report: Dictionary) -> float:
	var peak := 0.0
	for i in range(0,report.state.size(),4):
		if report.state[i]>0.00001:
			peak = maxf(peak,Vector2(report.state[i+1],report.state[i+2]).length()/report.state[i])
	return peak

func _test_support_boundaries() -> void:
	# Every missing-support face opens by wind direction, without a connectivity gate.
	var terrain := Image.create(32,24,false,Image.FORMAT_RGF)
	var initial := Image.create(32,24,false,Image.FORMAT_RF)
	for z in range(4,20):
		for x in range(4,28):
			terrain.set_pixel(x,z,Color(0,1,0,0))
			initial.set_pixel(x,z,Color(0.4,0,0,0))
	var preset := HeightfieldFogInitialization.new()
	preset.natural_mist_enabled = true
	preset.wind_speed = 1.0
	preset.base_height = 0.4
	for second_order in [false,true]:
		for angle in [0.0,90.0,180.0,-90.0]:
			var solver := HeightfieldFogSWE.new()
			solver.configure(terrain,initial,Vector2(8,6),null,second_order)
			if not await _wait_ready(solver):
				return
			preset.wind_direction = angle
			var expected_mass := 24.0*16.0*0.4
			for phase in ["steady","drain","refill"]:
				preset.base_height = 0.0 if phase == "drain" else 0.4
				for step in (120 if phase == "steady" else 480):
					solver.advance(1.0/60,1.2,0.45,2.0,1.8,1.0,preset.wind_parameters(Transform3D.IDENTITY))
					await process_frame
				var report := await _snapshot(solver)
				var maximum_error := 0.0
				var valid_output := true
				for z in 24:
					for x in 32:
						var h: float = report.state[(z*32+x)*4]
						valid_output = valid_output and is_finite(h) and h>=0.0
						if terrain.get_pixel(x,z).g<0.5:
							valid_output = valid_output and h==0.0
						else:
							maximum_error = maxf(maximum_error,absf(h-0.4))
				_check(valid_output and report.faults==0 and report.cfl_limited_steps==0,"open support faces remain finite, leave invalid cells empty and advance without recovery/slowdown")
				if phase == "steady":
					_check(maximum_error<0.0001,"uniform inflow and outflow preserve platform thickness rather than piling up")
				elif phase == "drain":
					_check(_mass(report)<expected_mass*0.05,"platform drains through its downwind void when inflow stops")
				else:
					_check(absf(_mass(report)-expected_mass)<expected_mass*0.05,"wind entering from missing support replenishes platform mist")
			solver.close()
		# Enclosed voids must also drain with no background wind. A nonsensically
		# high stored R value in an invalid cell must not turn it into a tall wall.
		var perforated := Image.create(32,24,false,Image.FORMAT_RGF)
		perforated.fill(Color(0,1,0,0))
		var layer := Image.create(32,24,false,Image.FORMAT_RF)
		layer.fill(Color(0.4,0,0,0))
		for z in range(10,14):
			for x in range(14,18):
				perforated.set_pixel(x,z,Color(1000000,0,0,0))
				layer.set_pixel(x,z,Color(0,0,0,0))
		_solid_border(perforated,layer)
		for threshold in [0.0,1.0]:
			var solver := HeightfieldFogSWE.new()
			solver.configure(perforated,layer,Vector2(8,6),null,second_order)
			if not await _wait_ready(solver):
				return
			var before := await _snapshot(solver)
			if threshold>0.0:
				solver.impulse(Vector3(-1.5,0,0))
			for step in 120:
				solver.advance(1.0/60,1.2,0.45,2.0,1.8,threshold)
				await process_frame
			var after := await _snapshot(solver)
			_check(_mass(after)<_mass(before)*0.999 and after.faults==0,"gravity or player momentum leaves through an enclosed void even at zero wind")
			var valid_output := true
			for z in 24:
				for x in 32:
					var h: float = after.state[(z*32+x)*4]
					valid_output = valid_output and is_finite(h) and h>=0.0
					if perforated.get_pixel(x,z).g<0.5:
						valid_output = valid_output and h==0.0
			_check(valid_output,"exiting mist disappears instead of filling the void; remaining thickness stays finite/nonnegative")
			solver.close()
		# A dry field distinguishes the two sides of an enclosed hole before
		# rectangular-boundary inflow can travel the eight-cell separation.
		var dry := Image.create(32,24,false,Image.FORMAT_RF)
		var solver := HeightfieldFogSWE.new()
		solver.configure(perforated,dry,Vector2(8,6),null,second_order)
		if not await _wait_ready(solver):
			return
		preset.base_height = 0.4
		preset.wind_direction = 0.0
		solver.advance(1.0/60,1.2,0.45,2.0,0.0,1.0,preset.wind_parameters(Transform3D.IDENTITY))
		await process_frame
		var filled := await _snapshot(solver)
		_check(filled.state[(12*32+18)*4]>0.001 and filled.state[(12*32+13)*4]<0.0000001,"wind enters from the upwind-facing void but never generates mist on its outflow side")
		solver.close()

# Closed-reservoir proofs need a real solid rim now that the box edge is open.
func _solid_border(terrain: Image, initial: Image) -> void:
	for z in terrain.get_height():
		for x in terrain.get_width():
			if x==0 or x==terrain.get_width()-1 or z==0 or z==terrain.get_height()-1:
				terrain.set_pixel(x,z,Color(32,1,0,0))
				initial.set_pixel(x,z,Color(0,0,0,0))

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
