extends SceneTree

# Bounded, fixed-camera profiling. No personal settings or scene files are written.
func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	Engine.max_fps = 0
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var scene = load("res://addons/heightfield_fog/demo.tscn").instantiate()
	root.add_child(scene)
	current_scene = scene
	for i in 120:
		await process_frame
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	scene.get_node("Player").process_mode = Node.PROCESS_MODE_DISABLED
	scene.get_node("CameraRig").process_mode = Node.PROCESS_MODE_DISABLED
	var boxes: Array = [scene.get_node("ClearingMist"),scene.get_node("DeepForestMist")]
	print("PROFILE viewport=",root.get_visible_rect().size," grid=",boxes[0].resolution," + ",boxes[1].resolution," temporal=",scene.get_node("Environment").environment.volumetric_fog_temporal_reprojection_enabled)
	for mode in ["paused","running","jumping","paused","running"]:
		var running: bool = mode != "paused"
		for box in boxes:
			box.swe_paused = not running
		for i in 120:
			await process_frame
		var frames: Array[float] = []
		var gpu: Array = [[],[]]
		var cpu: Array = [[],[]]
		var seen := [-1,-1]
		var start := Time.get_ticks_usec()
		var last := start
		var next_jump := start
		while Time.get_ticks_usec()-start < 6000000:
			await process_frame
			var now := Time.get_ticks_usec()
			frames.append((now-last)/1000.0)
			last = now
			if mode == "jumping" and now >= next_jump:
				next_jump = now + 1000000
				for box in boxes:
					box.disturb_mist(scene.get_node("Player").get_feet_position())
			if running:
				for j in boxes.size():
					var metrics: Dictionary = boxes[j].swe_metrics()
					if metrics.gpu_frame != seen[j] and metrics.gpu_ms >= 0:
						seen[j] = metrics.gpu_frame
						gpu[j].append(metrics.gpu_ms)
						cpu[j].append(metrics.cpu_submit_ms)
		frames.sort()
		var duration := (Time.get_ticks_usec()-start)/1000000.0
		print("PROFILE ",JSON.stringify({"mode":mode,"running":running,"fps":frames.size()/duration,"frame_mean_ms":duration*1000/frames.size(),"frame_p95_ms":frames[int(frames.size()*0.95)],"gpu_batch_ms":[_stats(gpu[0]),_stats(gpu[1])],"cpu_submit_ms":[_stats(cpu[0]),_stats(cpu[1])],"vram_mib":Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED)/1048576.0,"dropped_time":[boxes[0].swe_metrics().dropped_time,boxes[1].swe_metrics().dropped_time]}))
	# Readbacks happen only after timing, never within measured frames.
	for box in boxes:
		box.swe_paused = true
		var reports: Array = []
		box.swe_snapshot(func(report: Dictionary): reports.append(report))
		for i in 300:
			if not reports.is_empty():
				break
			await process_frame
		if not reports.is_empty():
			var report: Dictionary = reports[0]
			report.erase("state")
			print("DIAGNOSTICS ",box.name," ",JSON.stringify(report))
	var allocated := Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED)
	for box in boxes:
		box.swe_enabled = false
	for i in 120:
		await process_frame
	print("MEMORY SWE_delta_MiB=",(allocated-Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED))/1048576.0)
	scene.queue_free()
	for i in 8:
		await process_frame
	quit()

func _stats(values: Array) -> Dictionary:
	if values.is_empty():
		return {"samples":0,"unavailable":true}
	values.sort()
	var sum := 0.0
	for value in values:
		sum += value
	return {"samples":values.size(),"mean":sum/values.size(),"p95":values[int(values.size()*0.95)]}
