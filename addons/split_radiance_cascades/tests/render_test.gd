extends SceneTree
## Black environment, no native GI. The camera sees receivers but not the light
## sources. Assertions sample the actual composite after Godot's display transform.

const RC := preload("../split_radiance_cascades.gd")
var failures := 0

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	if RenderingServer.get_current_rendering_method() != "forward_plus" or not RenderingServer.get_rendering_device():
		push_error("render_test requires a real Forward+ device; headless is not a pass")
		quit(2)
		return
	root.unfocusable = true
	root.size = Vector2i(360, 240)
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	var scene := Node3D.new()
	root.add_child(scene)
	current_scene = scene
	# Test a translated source root, not the special case of an origin-centered camera.
	scene.position = Vector3(-31, 6, 11)
	var geometry := Node3D.new()
	geometry.name = "Geometry"
	scene.add_child(geometry)
	var white := StandardMaterial3D.new()
	var red := StandardMaterial3D.new()
	red.emission_enabled = true
	red.emission = Color.RED
	red.emission_energy_multiplier = 4.0
	_box(geometry, Vector3(-2, -0.1, 0), Vector3(6, 0.2, 8), white)
	var lamp := _box(geometry, Vector3(0,4.2,0), Vector3(5,0.1,6), red)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color.BLACK
	env.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	var world := WorldEnvironment.new()
	world.environment = env
	var prior := Compositor.new()
	world.compositor = prior
	scene.add_child(world)
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 1.4
	camera.position = Vector3(0,0.7,0)
	scene.add_child(camera)
	camera.look_at(scene.global_position, Vector3.BACK)
	camera.current = true
	var gi := RC.new()
	gi.prefer_hardware_trace = OS.get_cmdline_user_args().has("--prefer-hardware-trace")
	gi.source_root = ^"../../Geometry"
	gi.first_interval = 0.12
	gi.probe_spacing = 0.18
	gi.ray_stride = 3
	gi.multi_bounce = false
	gi.enabled = false
	world.add_child(gi)
	var off := await _center(5)
	gi.enabled = true
	var far := await _center(35)
	_check(off.r < 0.02 && far.r > 0.24 && far.g + far.b < 0.08, "off-camera emitter reaches receiver through far cascade: off=%s on=%s" % [off,far])
	# All hits are at >4 m. No near-interval emission, but the far interval
	# must contain it; an ordinary full-ray GI filter cannot satisfy both.
	gi.view = RC.View.LOCAL_INTERVAL
	gi.debug_cascade = 0
	var near_interval := await _center(4)
	gi.debug_cascade = 3
	var far_interval := await _center(4)
	_check(near_interval.r < 0.02 && far_interval.r > 0.2, "hit deposited in the distance-selected interval: C0=%s C3=%s" % [near_interval,far_interval])
	# Follow a fixed point inside a cell through a camera translation. The
	# same screen pixel now sees a different cell, but the world probe is stable.
	gi.view = RC.View.PROBE_CELLS
	gi.debug_cascade = 0
	var point := geometry.to_global(Vector3(0.085,0,0.085))
	var old_pixel := Vector2i(camera.unproject_position(point))
	var old_slot := _patch(await _image(5), old_pixel, 2)
	camera.position.x += 0.36
	var shifted := await _image(8)
	var same_slot := _patch(shifted, Vector2i(camera.unproject_position(point)), 2)
	var other_slot := _patch(shifted, old_pixel, 2)
	_check(_rgb_distance(old_slot,same_slot) < 0.025 && _rgb_distance(old_slot,other_slot) > 0.04, "stable slot follows the world cell rather than the screen pixel")
	camera.position.x -= 0.36
	gi.view = RC.View.COMPOSITE
	gi.first_interval = 0.05 # lamp is beyond even the former 64x cutoff (3.2 m)
	var beyond := await _center(20)
	_check(beyond.r > 0.24 && beyond.g + beyond.b < 0.08, "open-ended C3 must retain a real distant hit: %s" % beyond)
	lamp.hide()
	gi.rebuild()
	var missed := await _center(8)
	_check(missed.r < 0.02, "a genuine miss must not manufacture C3 light: %s" % missed)
	lamp.show()
	# A close excluded card used to pick up its backing floor's ID through the
	# short material-lookup ray. Distinct texels on one material also check UVs
	# and sRGB decoding rather than just a per-material average or white tint.
	gi.first_interval = 0.12 # isolate the receiver test from the far-hit policy
	var swatch := Image.create_empty(4,1,false,Image.FORMAT_RGBA8)
	swatch.fill(Color.WHITE)
	swatch.set_pixel(0,0,Color.BLUE) # absorbs red
	swatch.set_pixel(1,0,Color(0.5,0.5,0.5)) # ~21% linear reflectance, not 50%
	# As in a glTF PBR material, the factor is 1: the packed blue channel,
	# not the factor or the red channel alone, decides which texels are metal.
	var packed_mr := Image.create_empty(4,1,false,Image.FORMAT_RGBA8)
	packed_mr.fill(Color.RED)
	packed_mr.set_pixel(3,0,Color.BLUE)
	var textured := StandardMaterial3D.new()
	textured.metallic = 1.0
	textured.metallic_texture = ImageTexture.create_from_image(packed_mr)
	textured.metallic_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_BLUE
	textured.albedo_texture = ImageTexture.create_from_image(swatch)
	textured.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	var card := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(0.28,0.5)
	plane.material = textured
	card.mesh = plane
	card.position = Vector3(-0.30,0.012,0)
	geometry.add_child(card)
	var excluded := _box(geometry, Vector3(0.32,0.003,0), Vector3(0.24,0.002,0.5), white)
	excluded.add_to_group(&"split_rc_ignore")
	camera.projection = Camera3D.PROJECTION_PERSPECTIVE
	camera.far = 30.0
	root.size = Vector2i(385,255)
	# The only trace geometry is a hidden emitter. Neither card nor floor
	# exists in the proxy, so proxy depth/UVs cannot pass as real receivers.
	lamp.hide()
	gi.trace_proxy_root = gi.get_path_to(lamp)
	gi.rebuild()
	var receivers := await _image(30)
	var exposed := _patch(receivers, Vector2i(camera.unproject_position(geometry.global_position)), 3)
	var blue_texel := _patch(receivers, Vector2i(camera.unproject_position(card.to_global(Vector3(-0.105,0,0)))), 3)
	var gray_texel := _patch(receivers, Vector2i(camera.unproject_position(card.to_global(Vector3(-0.035,0,0)))), 3)
	var white_texel := _patch(receivers, Vector2i(camera.unproject_position(card.to_global(Vector3(0.035,0,0)))), 3)
	var metal_texel := _patch(receivers, Vector2i(camera.unproject_position(card.to_global(Vector3(0.105,0,0)))), 3)
	var skipped := _patch(receivers, Vector2i(camera.unproject_position(excluded.global_position)), 3)
	var ratio := gray_texel.srgb_to_linear().r / maxf(0.001,white_texel.srgb_to_linear().r)
	_check(exposed.r > 0.24 && blue_texel.r < 0.02 && white_texel.r > 0.24 && ratio > 0.15 && ratio < 0.30, "red GI resolves blue/gray/white texels: %s / %s / %s (linear gray/white %.3f)" % [blue_texel,gray_texel,white_texel,ratio])
	_check(white_texel.r > 0.24 && metal_texel.r < 0.02, "proxy lights the dielectric texel, not the adjacent metal: %s / %s" % [white_texel,metal_texel])
	_check(exposed.r > 0.24 && skipped.r < 0.02, "excluded surface does not inherit the floor behind it: floor=%s excluded=%s" % [exposed,skipped])
	# A few mm separation must still be distinguishable with linear (ortho)
	# depth. A perspective-relative epsilon would cover centimetres here.
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.far = 4000.0
	receivers = await _image(8)
	exposed = _patch(receivers, Vector2i(camera.unproject_position(geometry.global_position)), 3)
	skipped = _patch(receivers, Vector2i(camera.unproject_position(excluded.global_position)), 3)
	_check(exposed.r > 0.24 && skipped.r < 0.02, "orthographic depth rejects the same excluded card: floor=%s excluded=%s" % [exposed,skipped])
	gi.trace_proxy_root = ^""
	lamp.show()
	card.free()
	excluded.free()
	root.size = Vector2i(360,240)
	# A low shelf encloses the left patch but not its neighbor. They share
	# coarse probes with far light; the near interval must mask that light.
	gi.first_interval = 0.4
	camera.position.y = 0.045
	camera.near = 0.01
	var shelf := _box(geometry, Vector3(-6,0.1,0), Vector3(12,0.04,14), white)
	var edge := _box(geometry, Vector3(-0.01,0.06,0), Vector3(0.02,0.12,14), white)
	gi.rebuild()
	var mask := await _image(35)
	var dark := _patch(mask, Vector2i(camera.unproject_position(geometry.to_global(Vector3(-0.24,0,0.08)))), 4)
	var lit := _patch(mask, Vector2i(camera.unproject_position(geometry.to_global(Vector3(0.24,0,0.08)))), 4)
	# Compare light energy, not gamma-encoded framebuffer values. The cells
	# straddling the shelf edge need not form a pixel-perfect hard shadow.
	_check(dark.srgb_to_linear().r < 0.15*lit.srgb_to_linear().r && lit.r > 0.3, "near occlusion masks far light, not the adjacent open receiver: covered=%s open=%s" % [dark,lit])
	shelf.free()
	edge.free()
	camera.position.y = 0.7
	gi.first_interval = 0.12
	var ceiling := _box(geometry, Vector3(0,1.4,0), Vector3(14,0.12,14), white)
	# Lamp and receiver now share a top plane; no up-going primary ray can
	# connect them. Only a second ray from the off-camera white ceiling can.
	lamp.position = Vector3(3.5,-0.05,0)
	gi.rebuild()
	var single := await _center(20)
	gi.multi_bounce = true
	var bounced := await _center(70)
	_check(single.r < 0.04 && bounced.r > 0.15 && bounced.g + bounced.b < 0.08, "off-screen diffuse relay requires the secondary cache: single=%s multi=%s" % [single,bounced])
	lamp.free()
	gi.rebuild() # Only geometry changed. Start with no packed lights.
	await _image(3)
	await _live_point_light(geometry)
	gi.multi_bounce = false
	await _textured_hit(geometry, ceiling, gi)
	world.remove_child(gi)
	gi.free()
	var removed := await _center(4)
	_check(world.compositor == prior && removed.r < 0.02, "detaching restores the original compositor and unlit image")
	print("Split RC render test: %d failure(s)" % failures)
	quit(1 if failures else 0)

func _live_point_light(geometry: Node3D) -> void:
	var mount := Node3D.new()
	mount.position.y = 1.0
	var lamp := OmniLight3D.new()
	lamp.omni_range = 0.8 # Only the ceiling can be hit; no native light on the floor.
	lamp.light_color = Color.GREEN
	lamp.light_energy = 3.0
	mount.add_child(lamp)
	geometry.add_child(mount)
	var added := await _center(28)
	mount.position.y = 3.0
	var moved := await _center(5)
	mount.position.y = 1.0
	var returned := await _center(28)
	mount.hide()
	var hidden := await _center(5)
	mount.show()
	var shown := await _center(28)
	mount.free()
	var removed := await _center(5)
	_check(minf(added.g, minf(returned.g, shown.g)) > 0.14 and maxf(moved.g, maxf(hidden.g, removed.g)) < 0.025,
		"indirect point light follows add, parent transform/visibility and removal without rebuild: %s %s %s %s %s %s" % [added, moved, returned, hidden, shown, removed])

# The floor cannot see any direct light. Swapping only the off-screen reflector
# must preserve the bounce of an equivalent constant diffuse material.
func _textured_hit(geometry: Node3D, ceiling: MeshInstance3D, gi: RC) -> void:
	var lamp := OmniLight3D.new()
	lamp.position.y = 1.0
	lamp.omni_range = 0.8
	lamp.light_energy = 6.0
	geometry.add_child(lamp)
	var reference := StandardMaterial3D.new()
	# Half the UV tile is sRGB mid-gray dielectric, the other half pure red metal.
	var gray := Color8(128,128,128).srgb_to_linear() * 0.5
	reference.albedo_color = Color(gray.r,gray.g,gray.b).linear_to_srgb()
	ceiling.material_override = reference
	gi.rebuild()
	var expected := await _center(48)
	var color := Image.create_empty(2,1,false,Image.FORMAT_RGBA8)
	color.set_pixel(0,0,Color8(128,128,128))
	color.set_pixel(1,0,Color.RED)
	var metals := Image.create_empty(2,1,false,Image.FORMAT_RGBA8)
	metals.set_pixel(0,0,Color.RED)
	metals.set_pixel(1,0,Color.BLUE)
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = ImageTexture.create_from_image(color)
	mat.metallic = 1.0
	mat.metallic_texture = ImageTexture.create_from_image(metals)
	mat.metallic_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_BLUE
	ceiling.material_override = mat
	gi.rebuild()
	var actual := await _center(48)
	_check(expected.g > 0.05 and _rgb_distance(expected,actual) < 0.035,
		"textured off-screen hits bounce like the equivalent linear diffuse material: reference=%s textured=%s" % [expected,actual])
	lamp.free()

func _box(parent: Node3D, pos: Vector3, size: Vector3, mat: Material) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	mesh.material = mat
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.position = pos
	parent.add_child(node)
	return node

func _image(frames: int) -> Image:
	for i in frames:
		await RenderingServer.frame_post_draw
	return root.get_texture().get_image()

func _center(frames: int) -> Color:
	var image := await _image(frames)
	return _patch(image, image.get_size()/2, 8)

func _patch(image: Image, mid: Vector2i, radius: int) -> Color:
	var summed := Color(0,0,0,0)
	for y in range(mid.y-radius,mid.y+radius):
		for x in range(mid.x-radius,mid.x+radius):
			summed += image.get_pixel(x,y)
	return summed / (4.0*radius*radius)

func _rgb_distance(a: Color, b: Color) -> float:
	return absf(a.r-b.r) + absf(a.g-b.g) + absf(a.b-b.b)

func _check(result: bool, message: String) -> void:
	if result:
		print("PASS: ", message)
	else:
		failures += 1
		push_error(message)
