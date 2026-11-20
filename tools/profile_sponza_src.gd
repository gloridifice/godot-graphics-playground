extends SceneTree
## No args: Nave. User arg software|hardware|visible|no-proxy: fixed Arcade view,
## identical lights/sampling, compare the intersection backends and trace geometry.
## GPU timestamps after warm-up, not an FPS estimate.
const Preview := preload("res://scenes/sponza_src_preview.tscn")
var _capturing := false
var _rows := {}

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	if not RenderingServer.get_rendering_device() or RenderingServer.get_current_rendering_method() != "forward_plus":
		push_error("Sponza profiling requires a real Forward+ device")
		quit(2)
		return
	var args := OS.get_cmdline_user_args()
	var mode := "nave" if args.is_empty() else String(args[0])
	if mode not in ["nave", "software", "hardware", "visible", "no-proxy"]:
		push_error("Expected software, hardware, visible or no-proxy after --")
		quit(2)
		return
	var ab := mode != "nave"
	var hardware := mode in ["hardware", "visible", "no-proxy"]
	if hardware and not RenderingServer.get_rendering_device().has_feature(RenderingDevice.SUPPORTS_RAYTRACING_PIPELINE):
		push_error("Hardware trace requested but unsupported; refusing to time a software fallback")
		quit(2)
		return
	root.unfocusable = true
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.size = Vector2i(1280,720)
	var scene := Preview.instantiate()
	var gi: SplitRadianceCascades = scene.get_node("WorldEnvironment/SplitRadianceCascades")
	if ab: gi.prefer_hardware_trace = hardware
	root.add_child(scene)
	current_scene = scene
	var camera: Camera3D = scene.get_node("Camera3D")
	camera.process_mode = Node.PROCESS_MODE_DISABLED
	gi.timings_updated.connect(_sample)
	var vp := root.get_viewport_rid()
	if ab:
		camera.global_transform = scene.get_node("Views/Arcade").global_transform
		camera.reset_physics_interpolation()
		if mode == "visible":
			var exact := _visible_trace(scene.get_node("Subject"))
			if not exact:
				quit(2)
				return
			gi.trace_proxy_root = gi.get_path_to(exact)
		elif mode == "no-proxy":
			gi.trace_proxy_root = NodePath() # Use the original textured hit materials, as in the editor.
		else:
			gi.trace_proxy_root = gi.get_path_to(scene.get_node("Subject/TraceProxy"))
		scene.get_node("HUD").hide()
		gi.profile_stages = true
		RenderingServer.viewport_set_measure_render_time(vp, true)
	for size: Vector2i in [Vector2i(1280,720),Vector2i(1920,1080)]:
		root.size = size
		var until := Time.get_ticks_msec() + (2400 if ab else 1700)
		var frames := 0
		while Time.get_ticks_msec() < until or (ab and frames < 100):
			await RenderingServer.frame_post_draw
			frames += 1
		if Vector2i(root.get_texture().get_size()) != size or root.scaling_3d_scale != 1.0:
			push_error("Unexpected viewport size / render scale")
			quit(2)
			return
		_rows.clear()
		_capturing = true
		until = Time.get_ticks_msec() + (20000 if ab else 4000)
		while Time.get_ticks_msec() < until and (not ab or _rows.get("Trace", []).size() < 28):
			await RenderingServer.frame_post_draw
			var gpu_ms := RenderingServer.viewport_get_measured_render_time_gpu(vp)
			if gpu_ms > 0.0: _record("Viewport",gpu_ms)
		_capturing = false
		if not _rows.has("Viewport") or not _rows.has("SRC total") or (ab and _rows.Trace.size() < 28):
			push_error("No completed GPU timings for %s" % size)
			quit(2)
			return
		print("Sponza ","Arcade / "+mode if ab else "Nave", " ",root.get_texture().get_size(), "; render scale ",root.scaling_3d_scale,"; stride ",gi.ray_stride,"; multi ",gi.multi_bounce,"; GPU ms (median / p95, sample count):")
		for key: String in _rows:
			var values: Array = _rows[key]
			values.sort()
			print("  %s: %.3f / %.3f (%d)" % [key,values[(values.size()-1)/2],values[roundi((values.size()-1)*0.95)],values.size()])
	quit()

func _sample(times: Dictionary) -> void:
	if not _capturing or times.is_empty(): return
	var total := 0.0
	for t: Vector2 in times.values():
		if t.y < 0.0: return # discard the entire sample if any timestamp was invalid
		total += t.y
	for key: String in times: _record(key,times[key].y)
	_record("SRC total",total)
	_record("Receiver + Apply",times.Receiver.y + times.Apply.y)

func _record(key: String, ms: float) -> void:
	if not _rows.has(key): _rows[key] = []
	_rows[key].append(ms)

# Isolate geometry cost. Trace the opaque display triangles with the SAME hit
# reflectance as the proxy. Never override visible receiver materials or save.
func _visible_trace(subject: Node3D) -> Node3D:
	var exact := Node3D.new()
	exact.visible = false
	subject.add_child(exact)
	var triangle_count := 0
	for pair in [["Sponza", "Palace"], ["Curtains", "Curtains"]]:
		var model := String(pair[1])
		var mats := {}
		for mesh in _meshes(subject.get_node("TraceProxy/"+model)):
			for i in mesh.mesh.get_surface_count():
				var mat := mesh.get_active_material(i)
				if mat: mats[mat.resource_name] = mat
		# Small fixtures removed by simplification can still have an entry in the GLB.
		var bytes := FileAccess.get_file_as_bytes("res://assets/sponza/%s_trace.glb" % model.to_lower())
		var doc: Dictionary = JSON.parse_string(bytes.slice(20,20+bytes.decode_u32(12)).get_string_from_utf8())
		for entry: Dictionary in doc.materials:
			if mats.has(entry.name): continue
			var pbr: Dictionary = entry.get("pbrMetallicRoughness", {})
			var c: Array = pbr.get("baseColorFactor", [1,1,1,1])
			var e: Array = entry.get("emissiveFactor", [0,0,0])
			var m := StandardMaterial3D.new()
			m.albedo_color = Color(c[0],c[1],c[2]).linear_to_srgb()
			m.metallic = pbr.get("metallicFactor", 1.0)
			m.emission_enabled = e.max() > 0
			m.emission = Color(e[0],e[1],e[2]).linear_to_srgb()
			mats[entry.name] = m
		for mesh in _meshes(subject.get_node(pair[0])):
			if not mesh.is_visible_in_tree(): continue
			var copy := MeshInstance3D.new()
			copy.mesh = mesh.mesh
			exact.add_child(copy)
			copy.global_transform = mesh.global_transform
			for i in mesh.mesh.get_surface_count():
				var mat := mesh.get_active_material(i) as BaseMaterial3D
				if not mat or mat.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED: continue
				if not mats.has(mat.resource_name):
					push_error("Missing proxy hit material: " + mat.resource_name)
					return null
				copy.set_surface_override_material(i,mats[mat.resource_name])
				var arrays := mesh.mesh.surface_get_arrays(i)
				triangle_count += (arrays[Mesh.ARRAY_INDEX].size() if arrays[Mesh.ARRAY_INDEX] != null else arrays[Mesh.ARRAY_VERTEX].size()) / 3
	print("Exact opaque trace geometry: ",triangle_count," triangles")
	return exact

func _meshes(root_node: Node) -> Array[MeshInstance3D]:
	var meshes: Array[MeshInstance3D] = []
	meshes.assign(root_node.find_children("*", "MeshInstance3D", true, false))
	if root_node is MeshInstance3D: meshes.append(root_node)
	return meshes
