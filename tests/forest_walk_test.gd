extends SceneTree

var failures: int = 0

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var scene := load("res://addons/heightfield_fog/demo.tscn").instantiate() as Node3D
	root.add_child(scene)
	current_scene = scene
	root.grab_focus()
	var player := scene.get_node("Player") as CharacterBody3D
	for i in 90:
		await physics_frame
	if not root.has_focus():
		printerr("Forest walk test requires a focused graphical game window")
		quit(1)
		return
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_check(player.is_on_floor(), "spawn settles on generated terrain")
	var start := player.global_position
	Input.action_press("move_forward")
	for i in 60:
		await physics_frame
	Input.action_release("move_forward")
	var walked := player.global_position - start
	_check(walked.z < -2.7 and Vector2(walked.x,walked.z).length() < 3.3, "W walks into forest at 3 m/s")
	_check(player.is_on_floor(), "walking follows rolling terrain")
	start = player.global_position
	Input.action_press("jump")
	for i in 16:
		await physics_frame
	Input.action_release("jump")
	_check(player.position.y > start.y + 0.3 and not player.is_on_floor(), "space jumps")
	var reports: Array = []
	scene.get_node("ClearingMist").swe_snapshot(func(report: Dictionary): reports.append(report))
	for i in 120:
		if not reports.is_empty():
			break
		await process_frame
	_check(not reports.is_empty() and not reports[0].is_empty(), "jump reaches a live SWE field")
	if not reports.is_empty() and not reports[0].is_empty():
		var momentum := 0.0
		for i in range(0,reports[0].state.size(),4):
			momentum = maxf(momentum,absf(reports[0].state[i+1])+absf(reports[0].state[i+2]))
		_check(momentum>0.01 and reports[0].faults==0,"player takeoff injects real GPU momentum")
	for i in 90:
		await physics_frame
	_check(player.is_on_floor(), "jump lands back on terrain")
	var event := InputEventAction.new()
	event.action = "release_mouse"
	event.pressed = true
	Input.parse_input_event(event)
	await process_frame
	await process_frame
	_check(Input.mouse_mode == Input.MOUSE_MODE_VISIBLE, "Esc action releases mouse")
	start = player.global_position
	Input.action_press("move_forward")
	for i in 20:
		await physics_frame
	Input.action_release("move_forward")
	_check(player.global_position.distance_to(start) < 0.05, "released cursor disables walking")
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	click.position = Vector2(700,400)
	Input.parse_input_event(click)
	await process_frame
	await process_frame
	_check(Input.mouse_mode == Input.MOUSE_MODE_CAPTURED, "click resumes control")
	# Actual generated perimeter collider, not a player-coordinate clamp.
	var ray := PhysicsRayQueryParameters3D.create(Vector3(23,10,0),Vector3(23,-5,0),1)
	var hit := player.get_world_3d().direct_space_state.intersect_ray(ray)
	_check(not hit.is_empty(), "terrain collision exists near map edge")
	if not hit.is_empty():
		player.global_position = hit.position + Vector3(0,0.95,0)
		player.velocity = Vector3.ZERO
		player.reset_physics_interpolation()
		Input.action_press("move_right")
		for i in 90:
			await physics_frame
		Input.action_release("move_right")
		_check(player.global_position.x < 23.8 and player.is_on_floor(), "boundary prevents falling off finite terrain")
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	scene.queue_free()
	for i in 5:
		await process_frame
	print("Forest physics/input: ", "PASS" if failures == 0 else "FAIL")
	quit(0 if failures == 0 else 1)

func _check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		printerr("FAIL: ",message)
