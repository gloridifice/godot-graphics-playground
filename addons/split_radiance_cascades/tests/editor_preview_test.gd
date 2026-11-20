@tool
extends Node3D
## Opt-in test of the real 3D editor, not a game Window standing in for it.
## An ordinary open of this fixture must not change the user's camera or quit.

func _ready() -> void:
	if Engine.is_editor_hint() and OS.get_cmdline_user_args().has("--test-src-editor"):
		_run.call_deferred()

func _run() -> void:
	var tree := get_tree()
	if tree.edited_scene_root != self:
		return
	if not RenderingServer.get_rendering_device() or RenderingServer.get_current_rendering_method() != "forward_plus":
		push_error("Editor preview test requires a real Forward+ editor")
		tree.quit(2)
		return
	tree.root.unfocusable = true
	tree.create_timer(90.0).timeout.connect(func(): push_error("Editor preview test timed out"); tree.quit(2))
	var editor := Engine.get_singleton(&"EditorInterface")
	editor.set_main_screen_editor("3D")
	for i in 6: await tree.process_frame
	var viewport: SubViewport = editor.get_editor_viewport_3d(0)
	var camera := viewport.get_camera_3d()
	camera.global_position = Vector3(0, 3, 0)
	camera.look_at($Receiver.global_position, Vector3.BACK)
	camera.cull_mask = 1 # Exclude the editor grid and gizmos from the light measurement.
	var gi: SplitRadianceCascades = $WorldEnvironment/GI
	gi.prefer_hardware_trace = OS.get_cmdline_user_args().has("--prefer-hardware-trace")
	# The point light reaches the reflector but is too far from the receiver.
	var light: OmniLight3D = $PointLight
	var on := await _patch(viewport, 30)
	# Pack while GI is visible, as saving would. Only the single authored,
	# disabled effect may survive, never the tool's temporary compositor.
	var packed := PackedScene.new()
	var clean := packed.pack(self) == OK
	if clean:
		var copy := packed.instantiate()
		var chain: Compositor = copy.get_node("WorldEnvironment").compositor
		clean = chain != null and chain.compositor_effects.size() == 1 and not chain.compositor_effects[0].enabled
		copy.free()
	gi.preview_in_editor = false
	var off := await _patch(viewport, 1)
	gi.preview_in_editor = true
	var restored := await _patch(viewport, 30)
	# A lamp edit must update radiance, drop the previous red history and NOT
	# pick up this static geometry edit until the user presses Rebuild.
	$Reflector.hide()
	light.light_color = Color.BLUE
	var edited := await _patch(viewport, 8)
	gi.rebuild_snapshot.call() # The Inspector action, with Source Root left empty.
	var hidden := await _patch(viewport, 6)
	$Reflector.show()
	gi.rebuild_snapshot.call()
	var rebuilt := await _patch(viewport, 30)
	light.light_indirect_energy = 0.0
	var lamp_off := await _patch(viewport, 4)
	var live := edited.b > 0.18 and edited.r < 0.035 and lamp_off.b < 0.035
	var preview := gi.enabled and minf(on.r, minf(restored.r, rebuilt.b)) > 0.18 and maxf(off.r, hidden.b) < 0.035
	print("SRC editor: on=%s off=%s restored=%s edited=%s hidden=%s rebuilt=%s lamp_off=%s; clean scene=%s" % [on, off, restored, edited, hidden, rebuilt, lamp_off, clean])
	if not live: push_error("Point light edits must change indirect light without a static rebuild or old radiance")
	if not (preview and clean): push_error("Editor preview toggle, static rebuild or save isolation failed")
	tree.quit(0 if live and preview and clean else 1)

func _patch(viewport: SubViewport, frames: int) -> Color:
	for i in frames: await RenderingServer.frame_post_draw
	var image := viewport.get_texture().get_image()
	var p := image.get_size() / 2
	var sum := Color(0, 0, 0, 0)
	for y in range(-8, 8):
		for x in range(-8, 8):
			sum += image.get_pixel(p.x+x, p.y+y)
	return sum / 256.0
