@tool
extends Node3D

## CSG stays editable; a render-invisible mesh exposes its final union to the baker.
@export_tool_button("Bake all playground fog", "Bake") var bake_fog_action: Callable = bake_fog_fields

@export_group("Player Mist Interaction")
@export_range(0.0, 1.0, 0.05) var takeoff_pull: float = 0.8
@export_range(0.0, 1.0, 0.05) var landing_push: float = 1.0

var _solver_label: Label

func _ready() -> void:
	if not Engine.is_editor_hint():
		$PlayerCharacter.mist_takeoff.connect(_on_takeoff)
		$PlayerCharacter.mist_landed.connect(_on_landed)
		$PlayerCharacter.mist_moved.connect(_on_moved)
		var overlay := CanvasLayer.new()
		_solver_label = Label.new()
		_solver_label.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
		_solver_label.offset_left = 20
		_solver_label.offset_top = -70
		_solver_label.offset_right = 900
		_solver_label.offset_bottom = -40
		_solver_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_solver_label.add_theme_color_override("font_shadow_color",Color.BLACK)
		_solver_label.add_theme_constant_override("shadow_offset_x",2)
		_solver_label.add_theme_constant_override("shadow_offset_y",2)
		overlay.add_child(_solver_label)
		add_child(overlay)
		if "--stable-fluids" in OS.get_cmdline_user_args():
			_set_simulation_method(HeightfieldFogBox.SimulationMethod.STABLE_FLUIDS)
		_update_solver_label()

func _unhandled_key_input(event: InputEvent) -> void:
	if Engine.is_editor_hint() or not event is InputEventKey or not event.pressed or event.echo:
		return
	if event.physical_keycode == KEY_F2:
		var current: int = $FogFields/GroundMist.simulation_method
		_set_simulation_method(HeightfieldFogBox.SimulationMethod.STABLE_FLUIDS if current == HeightfieldFogBox.SimulationMethod.SWE else HeightfieldFogBox.SimulationMethod.SWE)
		get_viewport().set_input_as_handled()

func _set_simulation_method(method: HeightfieldFogBox.SimulationMethod) -> void:
	for box in $FogFields.get_children():
		if box is HeightfieldFogBox:
			box.simulation_method = method
	_update_solver_label()

func _update_solver_label() -> void:
	if _solver_label == null:
		return
	var stable: bool = $FogFields/GroundMist.simulation_method == HeightfieldFogBox.SimulationMethod.STABLE_FLUIDS
	_solver_label.text = "Fog: %s | F2: switch + reset" % ("Stable Fluids (reference + height gain)" if stable else "SWE")

func _on_takeoff(feet_position: Vector3) -> void:
	_disturb_fields(feet_position, -takeoff_pull)

func _on_landed(feet_position: Vector3) -> void:
	_disturb_fields(feet_position, landing_push)

func _on_moved(from_feet: Vector3, to_feet: Vector3, duration: float) -> void:
	for box in $FogFields.get_children():
		if box is HeightfieldFogBox:
			box.push_mist(from_feet, to_feet, duration)

func _disturb_fields(feet_position: Vector3, radial_strength: float) -> void:
	for box in $FogFields.get_children():
		if box is HeightfieldFogBox:
			box.disturb_mist(feet_position, radial_strength)

func _enter_tree() -> void:
	# Prepare CSG before each box's deferred automatic bake, in editor and runtime.
	_prepare_fog.call_deferred()

func _prepare_fog() -> void:
	if not is_inside_tree():
		return
	await get_tree().process_frame
	if is_inside_tree():
		_refresh_csg_source()

func _refresh_csg_source() -> bool:
	var structures := $Structures
	var previous := structures.get_node_or_null("_FogCSGSurface")
	if previous != null:
		structures.remove_child(previous)
		previous.queue_free()
	var csg := $Structures/CSGCombiner3D as CSGCombiner3D
	var meshes := csg.get_meshes()
	if meshes.size() < 2 or meshes[1] == null:
		push_error("Fog playground: CSG mesh is unavailable; cannot bake platforms and ramps.")
		return false
	var source := MeshInstance3D.new()
	source.name = "_FogCSGSurface"
	source.mesh = meshes[1]
	# Keep visible=true for heightfield sampling, but never render or cast shadows.
	source.layers = 0
	source.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	structures.add_child(source)
	source.global_transform = csg.global_transform * meshes[0]
	# No owner: this derived mesh is rebuilt, not serialized into the scene.
	return true

func bake_fog_fields() -> void:
	# CSG rebuilds at the end of the frame after an edit.
	await get_tree().process_frame
	if not _refresh_csg_source():
		return
	for box in $FogFields.get_children():
		if box is HeightfieldFogBox:
			box.bake()
