extends SceneTree

# Real main scene, accepted controller input, contacts, and GPU state. No mocked events.
var failures := 0
var _report: Dictionary = {}

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var main_path: String = ProjectSettings.get_setting("application/run/main_scene")
	var scene := (load(main_path) as PackedScene).instantiate() as Node3D
	# Isolate local interaction conservation from wind sources and background edge drainage.
	for field in scene.get_node("FogFields").get_children():
		if field is HeightfieldFogBox:
			field.initialization.wind_speed = 0.0
			if field.name == &"SpawnPlatformMist":
				# Suppress resting pressure spilling over distant platform edges.
				field.swe_gravity_threshold = 2.0
				# World travel must remain directional when the receiving box is rotated.
				field.rotation.y = 0.45
	root.add_child(scene)
	current_scene = scene
	root.grab_focus()
	var player := scene.get_node_or_null("PlayerCharacter") as CharacterBody3D
	if not _check(player != null, "F5 must load the fog playground and its third-party controller"):
		quit(1)
		return
	var box := scene.get_node("FogFields/SpawnPlatformMist") as HeightfieldFogBox
	var events: Array[String] = []
	player.connect("mist_takeoff", func(_feet: Vector3): events.append("takeoff"))
	player.connect("mist_landed", func(_feet: Vector3): events.append("landed"))
	for i in 300:
		await process_frame
		if player.is_on_floor() and box.swe_metrics().ready:
			break
	if not _check(player.is_on_floor() and box.swe_metrics().ready, "spawn settles on CSG and its mist has a real SWE solver"):
		quit(1)
		return
	await _physics_steps(12)
	_check(events.is_empty(), "initial floor contact must not create a landing impulse")
	_check(Input.mouse_mode == Input.MOUSE_MODE_VISIBLE, "startup leaves the cursor free")
	var start := player.position
	Input.action_press("play_char_move_forward_action")
	Input.action_press("play_char_jump_action")
	await _physics_steps(10)
	Input.action_release("play_char_move_forward_action")
	Input.action_release("play_char_jump_action")
	_check(player.position.distance_to(start)<0.02 and events.is_empty(), "free cursor blocks movement and jump inputs, not gravity")
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	Input.parse_input_event(click)
	var release := click.duplicate() as InputEventMouseButton
	release.pressed = false
	Input.parse_input_event(release)
	_check(Input.mouse_mode == Input.MOUSE_MODE_VISIBLE, "clicking does not capture the cursor")
	await _key(KEY_F)
	_check(Input.mouse_mode == Input.MOUSE_MODE_CAPTURED, "physical F enters control")
	var feet: Vector3 = player.get_feet_position()
	var before := await _snapshot(box)
	Input.action_press("play_char_jump_action")
	for i in 30:
		await physics_frame
		if player.position.y > start.y+0.03:
			break
	# Hold through the gather measurement; the controller supports variable jump height.
	await _physics_steps(5)
	var gathered := await _snapshot(box)
	_check(player.position.y > start.y+0.1 and events == ["takeoff"], "an accepted grounded jump emits exactly one takeoff")
	var inward := _radial_momentum(box,gathered,feet)
	_check(inward < -0.01, "takeoff injects inward momentum into the actual GPU state")
	_check(_center_height(box,gathered,feet)>_center_height(box,before,feet)+0.005, "takeoff physically gathers layer thickness beneath the character")
	Input.action_release("play_char_jump_action")
	await _key(KEY_F)
	_check(Input.mouse_mode == Input.MOUSE_MODE_VISIBLE, "F also exits control while airborne")
	for i in 150:
		await physics_frame
		if player.is_on_floor():
			break
	await _physics_steps(5)
	var landed := await _snapshot(box)
	_check(player.is_on_floor() and events == ["takeoff", "landed"], "released controls still fall and emit exactly one real landing")
	var outward := _radial_momentum(box,landed,feet)
	_check(outward > 0.01, "landing injects outward GPU momentum")
	_check(absf(_mass(landed)-_mass(before))/_mass(before)<0.001 and landed.faults==0, "both interactions transport mass without creating/deleting fog")
	await _physics_steps(12)
	_check(events.size()==2, "resting on the floor does not repeatedly inject impulses")
	await _key(KEY_F)
	await _key(KEY_ESCAPE)
	_check(Input.mouse_mode == Input.MOUSE_MODE_VISIBLE, "Esc releases control")
	await _key(KEY_F)
	root.propagate_notification(Node.NOTIFICATION_WM_WINDOW_FOCUS_OUT)
	_check(Input.mouse_mode == Input.MOUSE_MODE_VISIBLE, "window focus loss releases control")
	root.propagate_notification(Node.NOTIFICATION_WM_WINDOW_FOCUS_IN)
	_check(Input.mouse_mode == Input.MOUSE_MODE_VISIBLE, "focus regain does not capture the cursor")
	# Distinct transport risk: real collision-resolved WASD motion must reach the GPU.
	# Reset jump waves; gravity remains suppressed to isolate walking momentum.
	box.reset_swe()
	await _physics_steps(12)
	var walking_start := await _snapshot(box)
	box.swe_paused = true
	await _key(KEY_F)
	Input.action_press("play_char_move_forward_action")
	await _physics_steps(8)
	Input.action_release("play_char_move_forward_action")
	await _key(KEY_ESCAPE)
	box.swe_paused = false
	await _physics_steps(6)
	var resumed := await _snapshot(box)
	var pause_error := 0.0
	for i in resumed.state.size():
		pause_error = maxf(pause_error,absf(resumed.state[i]-walking_start.state[i]))
	_check(pause_error<0.00001,"walking while paused does not queue a delayed force on resume")
	var walking_feet: Vector3 = player.get_feet_position()
	await _key(KEY_F)
	Input.action_press("play_char_move_forward_action")
	await _physics_steps(20)
	Input.action_release("play_char_move_forward_action")
	var walking_end: Vector3 = player.get_feet_position()
	await _key(KEY_ESCAPE)
	var walked := await _snapshot(box)
	var travel := walking_end-walking_feet
	travel.y = 0.0
	var local_forward := box.global_basis.inverse()*travel.normalized()
	var momentum := Vector2.ZERO
	for i in range(0,walked.state.size(),4):
		momentum += Vector2(walked.state[i+1],walked.state[i+2])
	_check(travel.length()>0.2 and player.is_on_floor() and events.size()==2,"accepted WASD walks on the platform without fabricating jump events")
	_check(momentum.dot(Vector2(local_forward.x,local_forward.z))>0.1,"real player walking delivers directional momentum into the rendered SWE field")
	_check(absf(_mass(walked)-_mass(walking_start))/_mass(walking_start)<0.001 and walked.faults==0,"scene walking redistributes existing fog without boundary loss")
	print("Fog playground GPU: ", "PASS" if failures==0 else "FAIL", " takeoff_radial=",inward," landing_radial=",outward," walk_distance=",travel.length()," walk_momentum=",momentum)
	scene.free()
	await process_frame
	quit(0 if failures==0 else 1)

func _physics_steps(count: int) -> void:
	for i in count:
		await physics_frame
	await process_frame

func _key(code: Key) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = code
	event.pressed = true
	Input.parse_input_event(event)
	await _physics_steps(2)
	event.pressed = false
	Input.parse_input_event(event)
	await _physics_steps(2)

func _snapshot(box: HeightfieldFogBox) -> Dictionary:
	_report = {}
	box.swe_snapshot(func(value: Dictionary): _report = value)
	for i in 300:
		if not _report.is_empty():
			return _report
		await process_frame
	_check(false,"GPU snapshot completed")
	quit(1)
	return {}

func _radial_momentum(box: HeightfieldFogBox, report: Dictionary, world_feet: Vector3) -> float:
	var feet := box.to_local(world_feet)
	var result := 0.0
	var cells := 0
	for z in box.resolution:
		for x in box.resolution:
			var offset := (Vector2(x,z)+Vector2.ONE*0.5)/box.resolution-Vector2.ONE*0.5
			offset = offset*Vector2(box.size.x,box.size.z)-Vector2(feet.x,feet.z)
			if offset.length()<0.25 or offset.length()>2.0:
				continue
			var i := (z*box.resolution+x)*4
			result += Vector2(report.state[i+1],report.state[i+2]).dot(offset.normalized())
			cells += 1
	return result/maxi(cells,1)

func _center_height(box: HeightfieldFogBox, report: Dictionary, world_feet: Vector3) -> float:
	var feet := box.to_local(world_feet)
	var total := 0.0
	var cells := 0
	for z in box.resolution:
		for x in box.resolution:
			var offset := (Vector2(x,z)+Vector2.ONE*0.5)/box.resolution-Vector2.ONE*0.5
			offset = offset*Vector2(box.size.x,box.size.z)-Vector2(feet.x,feet.z)
			if offset.length()<0.65:
				total += report.state[(z*box.resolution+x)*4]
				cells += 1
	return total/maxi(cells,1)

func _mass(report: Dictionary) -> float:
	var result := 0.0
	for i in range(0,report.state.size(),4):
		result += report.state[i]
	return result

func _check(condition: bool, message: String) -> bool:
	if not condition:
		failures += 1
		printerr("FAIL: ",message)
	return condition
