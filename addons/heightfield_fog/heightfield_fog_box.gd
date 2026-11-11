@tool
class_name HeightfieldFogBox
extends Node3D

const Initialization = preload("res://addons/heightfield_fog/initialization.gd")
const Solver = preload("res://addons/heightfield_fog/swe_solver.gd")
const Baker = preload("res://addons/heightfield_fog/baker.gd")
const FogShader = preload("res://addons/heightfield_fog/heightfield_fog.gdshader")

## Origin is the bottom center. Use Move/Rotate (Y) and the three size handles.
@export var size := Vector3(8.0, 4.0, 8.0):
	set(value):
		size = value.max(Vector3.ONE * 0.1)
		update_gizmos()
@export_range(16, 512, 16) var resolution: int = 128
## Empty selects the scene root. Static visible MeshInstance3D only.
@export_node_path("Node3D") var source_root: NodePath
@export_tool_button("Bake local heightfield", "Bake") var bake_action: Callable = bake
## Assign a .tres preset, create a new resource, or Make Unique to edit one box only.
@export var initialization: HeightfieldFogInitialization = Initialization.new()
@export_group("Appearance")
## Horizontal inward fade width in local meters; zero disables it.
@export_range(0.0, 8.0, 0.01, "suffix:m") var edge_fade: float = 1.0
@export_range(0.0, 20.0, 0.01) var extinction: float = 3.0
@export var tint := Color(0.85, 0.9, 1.0)
@export_range(0.0, 2.0, 0.01) var brightness: float = 0.3
@export_range(0.002, 0.5, 0.002, "suffix:m") var vertical_filter: float = 0.1

@export_group("SWE Simulation")
## Runtime GPU shallow-layer solver. Disabling resets to static initialization; editor stays static.
@export var swe_enabled: bool = false
## Freeze the current state, without resetting it. Useful for visual/performance comparison.
@export var swe_paused: bool = false
## Reduced gravity for a dense mist layer, not water's 9.81 m/s².
@export_range(0.05, 9.81, 0.05, "suffix:m/s²") var swe_gravity: float = 1.2
## Momentum damping rate; mass is not decayed.
@export_range(0.0, 4.0, 0.05, "suffix:1/s") var swe_drag: float = 0.45
## Conservative display guard for dynamic pile-up; does not clamp simulated thickness.
@export_range(1.0, 32.0, 0.5, "suffix:m") var swe_render_height: float = 8.0
@export_tool_button("Reset SWE state") var reset_swe_action: Callable = reset_swe
@export_group("Interaction")
@export_range(0.2, 6.0, 0.1, "suffix:m") var jump_radius: float = 2.5
## Instantaneous radial velocity increment at takeoff, not a density eraser. Zero disables.
@export_range(0.0, 4.0, 0.1, "suffix:m/s") var jump_speed: float = 1.8

# Derived per-instance cache. Never stored in PackedScene or resource files.
var height_map: Texture2D
var baked_transform := Transform3D.IDENTITY
var baked_size := Vector3.ZERO
var baked_resolution: int = 0
var baked_source_root: NodePath

var _solver: HeightfieldFogSWE
var _volume: FogVolume
var _material: ShaderMaterial
var _was_current: bool = false
var _initialization_key: Array = []
var _maximum_thickness: float = 0.0
var _thickness_texture: ImageTexture

func _enter_tree() -> void:
	height_map = null
	baked_size = Vector3.ZERO
	_initialization_key.clear()
	_bake_on_entry.call_deferred()

func _bake_on_entry() -> void:
	if not is_inside_tree():
		return
	# Parent _ready() may build terrain; CSG needs a frame to expose its final mesh.
	for i in 2:
		await get_tree().process_frame
		if not is_inside_tree():
			return
	if not is_bake_current():
		bake()

func _ready() -> void:
	_volume = FogVolume.new()
	_volume.name = "_HeightfieldFogPreview"
	_material = ShaderMaterial.new()
	_material.shader = FogShader
	_volume.material = _material
	add_child(_volume, false, Node.INTERNAL_MODE_BACK)

func _process(delta: float) -> void:
	if not is_instance_valid(_volume):
		return
	var current := is_bake_current()
	_volume.visible = current
	if current != _was_current:
		_was_current = current
		update_configuration_warnings()
	if not current:
		_stop_solver()
		return
	if initialization == null:
		initialization = Initialization.new()
	var key := [initialization, initialization.parameters(), height_map, size, global_transform, swe_enabled]
	if key != _initialization_key:
		_stop_solver()
		var image := initialization.create_thickness(height_map.get_image(), Vector2(size.x, size.z), global_transform)
		_maximum_thickness = 0.0
		for value in image.get_data().to_float32_array():
			_maximum_thickness = maxf(_maximum_thickness, value)
		_thickness_texture = ImageTexture.create_from_image(image)
		_initialization_key = key
		_material.set_shader_parameter("thickness_map", _thickness_texture)
		if swe_enabled and not Engine.is_editor_hint():
			_solver = Solver.new()
			_solver.initialized.connect(_on_solver_initialized)
			_solver.configure(height_map.get_image(), image, Vector2(size.x,size.z))
	if _solver != null and _solver.ready and not swe_paused:
		_solver.advance(delta,clampf(swe_gravity,0.05,9.81),clampf(swe_drag,0.0,4.0),clampf(jump_radius,0.2,6.0),clampf(jump_speed,0.0,4.0))
	# Guard band for thin-layer filtering; the bake ceiling is not a fog ceiling.
	var margin := _maximum_thickness + maxf(vertical_filter, 0.002)
	if _solver != null:
		margin = maxf(margin,clampf(swe_render_height,1.0,32.0))
	_volume.size = size + Vector3(0, 2.0 * margin, 0)
	_volume.position = Vector3(0, size.y * 0.5, 0)
	_material.set_shader_parameter("world_to_box", global_transform.affine_inverse())
	_material.set_shader_parameter("height_map", height_map)
	_material.set_shader_parameter("box_size", size)
	_material.set_shader_parameter("concentration", maxf(initialization.concentration, 0.0))
	_material.set_shader_parameter("edge_fade", maxf(edge_fade, 0.0))
	_material.set_shader_parameter("extinction", maxf(extinction, 0.0))
	_material.set_shader_parameter("tint", Vector3(tint.r, tint.g, tint.b))
	_material.set_shader_parameter("brightness", brightness)
	_material.set_shader_parameter("vertical_filter", vertical_filter)
	_material.set_shader_parameter("natural_mist_enabled", initialization.natural_mist_enabled)
	_material.set_shader_parameter("mist_time", Time.get_ticks_msec() * 0.001)
	if initialization.natural_mist_enabled:
		var angle := deg_to_rad(initialization.wind_direction)
		_material.set_shader_parameter("noise_map", initialization.noise_texture())
		_material.set_shader_parameter("noise_uv_scale", clampf(initialization.noise_frequency, 0.001, 8.0) / Initialization.NOISE_PERIOD)
		_material.set_shader_parameter("coverage", clampf(initialization.coverage, 0.0, 1.0))
		_material.set_shader_parameter("coverage_softness", clampf(initialization.coverage_softness, 0.01, 0.5))
		_material.set_shader_parameter("top_softness", clampf(initialization.top_softness, 0.1, 1.0))
		_material.set_shader_parameter("detail_strength", clampf(initialization.detail_strength, 0.0, 0.8))
		_material.set_shader_parameter("detail_scale", clampf(initialization.detail_scale, 0.25, 8.0))
		_material.set_shader_parameter("wind_stretch", clampf(initialization.wind_stretch, 1.0, 8.0))
		_material.set_shader_parameter("wind_direction", Vector2(cos(angle), sin(angle)))
		_material.set_shader_parameter("wind_speed", clampf(initialization.wind_speed, 0.0, 1.0))
		_material.set_shader_parameter("noise_offset", initialization.noise_offset)

## Signed radial impulse: negative gathers, positive spreads. No static visual fallback.
func disturb_mist(feet_position: Vector3, radial_strength: float = 1.0) -> void:
	if _solver == null or swe_paused or not feet_position.is_finite() or not is_finite(radial_strength):
		return
	_solver.impulse(to_local(feet_position), radial_strength)

## Last completed GPU batch, not CPU wall time. -1 means no timestamp available.
func swe_metrics() -> Dictionary:
	if _solver == null:
		return {"ready":false,"gpu_ms":-1.0,"gpu_frame":-1,"cpu_submit_ms":0.0,"dropped_time":0.0}
	return {"ready":_solver.ready,"gpu_ms":_solver.gpu_time_ms,"gpu_frame":_solver.gpu_sample_frame,"cpu_submit_ms":_solver.cpu_submit_ms,"dropped_time":_solver.dropped_time}

## On-demand diagnostic readback. Not used for normal rendering; can wait for the GPU.
func swe_snapshot(callback: Callable) -> void:
	if _solver != null and _solver.ready:
		_solver.snapshot(callback)
	else:
		callback.call_deferred({})

func reset_swe() -> void:
	_initialization_key.clear()

func _on_solver_initialized(success: bool) -> void:
	if _solver == null or not is_instance_valid(_material):
		return
	if success:
		_material.set_shader_parameter("thickness_map", _solver.texture)
	else:
		push_error("Heightfield Fog SWE requires a working Forward+ RenderingDevice; showing static initialization")

func _stop_solver() -> void:
	if _solver != null:
		_solver.close()
		_solver = null
	if is_instance_valid(_material):
		_material.set_shader_parameter("thickness_map", _thickness_texture)

func _exit_tree() -> void:
	_stop_solver()

# Read old scenes without writing a stale scalar override into new scenes.
func _set(property: StringName, value: Variant) -> bool:
	if property == &"layer_height":
		if initialization == null:
			initialization = Initialization.new()
		initialization.base_height = float(value)
		return true
	return false

func is_bake_current() -> bool:
	return height_map != null and baked_size.is_equal_approx(size) and baked_resolution == resolution and baked_source_root == source_root and baked_transform.is_equal_approx(global_transform) and _supported_transform()

func _supported_transform() -> bool:
	var b := global_basis
	return b.y.is_equal_approx(Vector3.UP) and b.get_scale().is_equal_approx(Vector3.ONE) and absf(b.x.dot(b.z)) < 0.0001 and b.determinant() > 0.0

func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if not _supported_transform():
		warnings.append("Only Y rotation and unit world scale are supported; resize using Size/gizmo handles.")
	if not is_bake_current():
		warnings.append("Heightfield bakes in memory on scene entry. After editing, click Bake local heightfield.")
	return warnings

func bake() -> void:
	if not is_inside_tree() or not _supported_transform():
		push_warning("Heightfield Fog: requires an upright box with unit scale.")
		return
	var root: Node = get_node_or_null(source_root) if not source_root.is_empty() else null
	if root == null and source_root.is_empty():
		root = get_tree().edited_scene_root if Engine.is_editor_hint() else get_tree().current_scene
	if root == null or root == self:
		push_warning("Heightfield Fog: choose a valid source root containing static meshes.")
		return
	var result := Baker.bake(self, root, size, clampi(resolution, 16, 512))
	if result == null:
		push_warning("Heightfield Fog: no upward surface inside box; previous bake retained.")
		return
	height_map = result
	baked_transform = global_transform
	baked_size = size
	baked_resolution = resolution
	baked_source_root = source_root
	update_configuration_warnings()
	print("Heightfield Fog baked: ", get_path(), " ", resolution, "²")
