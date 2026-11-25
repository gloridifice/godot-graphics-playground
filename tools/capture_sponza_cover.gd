extends SceneTree
## Regenerate the README cover: godot --rendering-driver vulkan --script res://tools/capture_sponza_cover.gd
const ReSTIR := preload("res://scenes/sponza_restir_di.tscn")
const TorchWalk := preload("res://scenes/sponza_torch_walk.tscn")
const PreviewCamera := preload("res://scripts/camera/sponza_preview_camera.gd")
const OUTPUT := "res://readme/images/sponza-restir.jpg"
const VIEWS := ["Nave", "Arcade", "AtriumWide", "Courtyard"]
const SIZE := Vector2i(1600, 900)
const PANEL := Vector2i(1200, 675)
# Above the midpoint of the outermost ground-floor column pairs.
const ATRIUM_CENTER := Vector3(0.13, 4.2, -0.03)

func _initialize() -> void:
	root.unfocusable = true
	_capture.call_deferred()

func _capture() -> void:
	if RenderingServer.get_current_rendering_method() != "forward_plus" or RenderingServer.get_current_rendering_driver_name() != "vulkan":
		push_error("Sponza cover requires Vulkan Forward+")
		quit(2)
		return
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.size = SIZE
	var cover := Image.create_empty(PANEL.x * 2, PANEL.y * 2, false, Image.FORMAT_RGB8)
	for i in VIEWS.size():
		var view: String = VIEWS[i]
		var scene := (TorchWalk if view == "AtriumWide" else ReSTIR).instantiate()
		_configure_shot(scene, view)
		root.add_child(scene)
		current_scene = scene
		print("Rendering ", view, " (pid ", OS.get_process_id(), ")")
		for frame in 300: await RenderingServer.frame_post_draw
		var image := root.get_texture().get_image()
		if not image or image.get_size() != SIZE:
			push_error("Could not capture the 1600 × 900 game viewport")
			quit(1)
			return
		image.convert(Image.FORMAT_RGB8)
		image.resize(PANEL.x, PANEL.y, Image.INTERPOLATE_LANCZOS)
		cover.blit_rect(image, Rect2i(Vector2i.ZERO, PANEL), Vector2i(i % 2, i / 2) * PANEL)
		print("Captured ", view, " from ", root.get_camera_3d().get_path(), " at ", root.get_camera_3d().global_position)
		current_scene = null
		scene.queue_free()
		await process_frame
	var error := cover.save_jpg(ProjectSettings.globalize_path(OUTPUT), 0.8)
	if error != OK: push_error("Could not save %s: %s" % [OUTPUT, error_string(error)])
	quit(0 if error == OK else 1)

func _configure_shot(scene: Node, view: String) -> void:
	scene.get_node("HUD").hide()
	if view in ["AtriumWide", "Courtyard"]:
		var world: WorldEnvironment = scene.get_node("WorldEnvironment")
		var sky_off: Environment = world.environment.duplicate()
		sky_off.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
		sky_off.ambient_light_energy = 0.0
		sky_off.ambient_light_sky_contribution = 0.0
		sky_off.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
		world.environment = sky_off
		scene.get_node("Subject/Sun").show()
	var camera: PreviewCamera = scene.get_node("Camera3D")
	camera.process_mode = Node.PROCESS_MODE_DISABLED
	if view == "AtriumWide":
		camera.start_on_foot = false # Keep the gallery lights without spawning the hand, torch or its light.
		camera.position = ATRIUM_CENTER
		camera.rotation_degrees = Vector3(13, -90, 0)
		camera.fov = 84.0
	elif view == "Courtyard":
		scene.get_node("Subject/PointLights").hide()
		scene.get_node("Subject/GalleryLight").hide()
		camera.transform = Transform3D(Basis.IDENTITY, Vector3(5.5, 2.2, 2.3)).looking_at(Vector3(-1.5, 2.5, -4.5))
	else:
		camera.transform = scene.get_node("Views/" + view).transform
