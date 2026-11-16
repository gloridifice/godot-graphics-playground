@tool
class_name WaterBody3D
extends Node3D

## 水体原点 Y 是平均水位。参数资源可以共享，GPU 状态始终逐水体独立。
const WaterShader = preload("res://addons/water/shaders/water.gdshader")
signal gpu_ready(success: bool)
@export var surface_settings: WaterSurfaceSettings:
	set(value):
		if surface_settings != null and surface_settings.changed.is_connected(_surface_changed):
			surface_settings.changed.disconnect(_surface_changed)
		surface_settings = value
		if surface_settings != null:
			surface_settings.changed.connect(_surface_changed)
		_surface_changed()
@export var material_settings: WaterMaterialSettings:
	set(value):
		if material_settings != null and material_settings.changed.is_connected(_material_changed):
			material_settings.changed.disconnect(_material_changed)
		material_settings = value
		if material_settings != null:
			material_settings.changed.connect(_material_changed)
		_material_changed()
@export var ssr_settings: WaterSSRSettings:
	set(value):
		if ssr_settings != null and ssr_settings.changed.is_connected(_ssr_changed):
			ssr_settings.changed.disconnect(_ssr_changed)
		ssr_settings = value
		if ssr_settings != null:
			ssr_settings.changed.connect(_ssr_changed)
		_ssr_changed()
@export var foam_settings: WaterFoamSettings:
	set(value):
		if foam_settings != null and foam_settings.changed.is_connected(_foam_changed):
			foam_settings.changed.disconnect(_foam_changed)
		foam_settings = value
		if foam_settings != null:
			foam_settings.changed.connect(_foam_changed)
		_foam_changed()
@export var foam_material_settings: WaterFoamMaterialSettings:
	set(value):
		if foam_material_settings != null and foam_material_settings.changed.is_connected(_foam_material_changed):
			foam_material_settings.changed.disconnect(_foam_material_changed)
		foam_material_settings = value
		if foam_material_settings != null:
			foam_material_settings.changed.connect(_foam_material_changed)
		_foam_material_changed()
@export var caustics_settings: WaterCausticsSettings:
	set(value):
		if caustics_settings != null and caustics_settings.changed.is_connected(_refresh_caustics):
			caustics_settings.changed.disconnect(_refresh_caustics)
		caustics_settings = value
		if caustics_settings != null:
			caustics_settings.changed.connect(_refresh_caustics)
		_refresh_caustics()
@export_node_path("DirectionalLight3D") var sun_path: NodePath = NodePath("../Sun"):
	set(value):
		sun_path = value
		_refresh_caustics()
@export var editor_simulate: bool = false:
	set(value):
		editor_simulate = value
		reset()
@export var paused: bool = false
@export_tool_button("Reset water simulation", "Reload") var reset_action: Callable = reset
@export_tool_button("Bake water bed + reset", "Bake") var bake_action: Callable = bake
var status := "Initializing"
var gpu: WaterGPU
var caustics: WaterCausticsGPU
var _caustics_signature: Array = []
var _surface: MeshInstance3D
var _material: ShaderMaterial
var _pending_rebuild := false
var _fft: FFTDeformer3D
var _swe: SWEDeformer3D
var _gpu_signature: Array = []
var _restart_clock := false
var _foam_mode := false

func _init() -> void:
	surface_settings = WaterSurfaceSettings.new()
	material_settings = WaterMaterialSettings.new()
	caustics_settings = WaterCausticsSettings.new()
	foam_settings = WaterFoamSettings.new()
	foam_material_settings = WaterFoamMaterialSettings.new()
	ssr_settings = WaterSSRSettings.new()
	set_notify_transform(true)

func _ready() -> void:
	_material = ShaderMaterial.new()
	_material.shader = WaterShader
	_surface = MeshInstance3D.new()
	_surface.name = "_WaterSurface"
	_surface.set_meta("water_generated", true)
	_surface.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_surface.material_override = _material
	add_child(_surface)
	# No owner: the generated mesh and Texture2DRD handles are never serialized.
	child_entered_tree.connect(_child_added)
	child_exiting_tree.connect(_child_removed)
	for child in get_children():
		_child_added(child)
	_surface_changed()
	_material_changed()
	_foam_material_changed()
	_foam_changed()
	_ssr_changed()
	_request_rebuild()

func _exit_tree() -> void:
	_close_caustics()
	if gpu != null:
		gpu.close()
		gpu = null
	if is_instance_valid(_surface):
		_surface.queue_free()
	_surface = null
	_material = null
	# _ready must run again when the same node re-enters a scene tree.
	request_ready()
	if child_entered_tree.is_connected(_child_added):
		child_entered_tree.disconnect(_child_added)
		child_exiting_tree.disconnect(_child_removed)

func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSFORM_CHANGED and is_inside_tree():
		_request_rebuild()

func _child_added(child: Node) -> void:
	if child is FFTDeformer3D or child is SWEDeformer3D:
		if not child.configuration_changed.is_connected(_request_rebuild):
			child.configuration_changed.connect(_request_rebuild)
		_request_rebuild()

func _child_removed(child: Node) -> void:
	if child is FFTDeformer3D or child is SWEDeformer3D:
		if child.configuration_changed.is_connected(_request_rebuild):
			child.configuration_changed.disconnect(_request_rebuild)
		_request_rebuild()

func _select_deformers() -> String:
	_fft = null
	_swe = null
	for child in get_children():
		if child.is_queued_for_deletion():
			continue
		if child is FFTDeformer3D and child.enabled:
			if _fft != null:
				return "First version supports one enabled FFT deformer per water body."
			_fft = child
		if child is SWEDeformer3D and child.enabled:
			if _swe != null:
				return "First version supports one enabled SWE region; overlapping composition is not defined."
			_swe = child
	return ""

func _validation_error() -> String:
	var error := WaterHeightBaker.transform_error(self)
	if error.is_empty():
		error = _select_deformers()
	if not error.is_empty():
		return error
	if surface_settings == null or material_settings == null:
		return "Assign WaterSurfaceSettings and WaterMaterialSettings assets."
	if foam_settings == null or foam_material_settings == null:
		return "Assign foam simulation and appearance assets."
	if ssr_settings == null:
		return "Assign a WaterSSRSettings asset."
	for asset in [surface_settings, material_settings, foam_settings, foam_material_settings, ssr_settings]:
		error = asset.validation_error()
		if not error.is_empty():
			return error
	if _fft != null:
		if _fft.settings == null:
			return "Assign FFT settings."
		error = _fft.settings.validation_error()
		if not error.is_empty():
			return error
	if _swe != null:
		if _swe.settings == null or _swe.bake_settings == null:
			return "Assign SWE and bake settings."
		for asset in [_swe.settings, _swe.bake_settings]:
			error = asset.validation_error()
			if not error.is_empty():
				return error
		error = WaterHeightBaker.transform_error(_swe)
		if not error.is_empty():
			return error
		if not _swe.is_bake_current():
			return "SWE bed unavailable/stale: " + _swe.bake_status
	return ""

func _request_rebuild() -> void:
	if not is_inside_tree() or _pending_rebuild:
		return
	_pending_rebuild = true
	_rebuild.call_deferred()

func _rebuild() -> void:
	_pending_rebuild = false
	if not is_inside_tree() or _surface == null:
		return
	status = _validation_error()
	update_configuration_warnings()
	if not status.is_empty():
		_close_caustics()
		if gpu != null:
			gpu.close()
			gpu = null
		_surface.visible = false
		return
	var fft_config := _fft.settings if _fft != null else WaterFFTSettings.new()
	var swe_config: WaterSWESettings = _swe.settings if _swe != null else null
	var terrain: Image = _swe.height_map if _swe != null else null
	var region := _swe.global_transform if _swe != null else Transform3D.IDENTITY
	var extent := Vector2(_swe.bake_settings.size.x, _swe.bake_settings.size.z) if _swe != null else Vector2.ONE
	_material.set_shader_parameter("fft_enabled", _fft != null)
	_material.set_shader_parameter("swe_enabled", _swe != null)
	_material.set_shader_parameter("swe_model_blend",swe_config != null and swe_config.surface_mode == 1)
	_material.set_shader_parameter("swe_fft_edges",swe_config.fft_edges if swe_config != null else 0)
	_material.set_shader_parameter("fft_length", fft_config.length)
	_material.set_shader_parameter("fft_resolution", float(fft_config.resolution))
	_material.set_shader_parameter("height_gain", fft_config.height_gain)
	_material.set_shader_parameter("choppiness", fft_config.choppiness)
	_material.set_shader_parameter("sea_level", global_position.y)
	_material.set_shader_parameter("region_origin", Vector2(region.origin.x, region.origin.z))
	_material.set_shader_parameter("region_rotation", Vector2(region.basis.x.x, region.basis.z.x))
	_material.set_shader_parameter("region_size", extent)
	_material.set_shader_parameter("swe_resolution", swe_config.resolution if swe_config != null else 1)
	_material.set_shader_parameter("blend_depth", swe_config.blend_depth if swe_config != null else 2.0)
	_material.set_shader_parameter("edge_width", swe_config.relaxation_width if swe_config != null else 0.2)
	_material.set_shader_parameter("shore_normal_strength",swe_config.normal_strength if swe_config != null else 0.0)
	var signature: Array = [global_transform, _fft != null, fft_config.resolution, fft_config.length, fft_config.amplitude, fft_config.phillips_length, fft_config.wind_angle_degrees, fft_config.seed, fft_config.height_gain,
		terrain, region, extent, foam_settings.dual_population]
	if swe_config != null:
		signature.append_array([swe_config.resolution, swe_config.second_order, swe_config.gravity, swe_config.manning, swe_config.max_substeps, swe_config.fft_edges, swe_config.relaxation_width, swe_config.relaxation_rate, swe_config.input_gain, swe_config.filter_enabled, swe_config.filter_cutoff, swe_config.filter_transition])
	if gpu != null and gpu.error_message.is_empty() and signature == _gpu_signature:
		_foam_changed()
		_refresh_caustics()
		status = "Ready (GPU; bed/state in memory only)" if gpu.ready else "Creating GPU resources"
		return
	_close_caustics()
	var previous := gpu
	var clock_source := previous if previous != null and previous.ready and not _restart_clock else null
	_surface.visible = false
	_gpu_signature = signature
	_foam_mode = foam_settings.dual_population
	_restart_clock = false
	gpu = WaterGPU.new()
	var generation := gpu.get_instance_id()
	gpu.initialized.connect(func(success: bool):
		# Capture an ID, not the RefCounted owner itself (signal/lambda cycle).
		if gpu == null or generation != gpu.get_instance_id() or not is_inside_tree():
			return
		if success:
			_material.set_shader_parameter("fft_map", gpu.fft_texture)
			_material.set_shader_parameter("swe_map", gpu.swe_texture)
			_material.set_shader_parameter("foam_map",gpu.foam_texture)
			_material.set_shader_parameter("foam_flow_map",gpu.foam_flow_texture)
			_material.set_shader_parameter("offshore_foam_map",gpu.offshore_foam_texture)
			_foam_changed()
			_surface.visible = true
			status = "Ready (GPU; bed/state in memory only)"
			_refresh_caustics()
		else:
			status = gpu.error_message
			push_error("Water: " + status)
			gpu.close()
		update_configuration_warnings()
		gpu_ready.emit(success)
	)
	status = "Creating GPU resources"
	gpu.configure(fft_config, swe_config, terrain, region, extent, global_position.y, _fft != null, clock_source, foam_settings)
	if previous != null:
		previous.close()

func _surface_changed() -> void:
	if not is_inside_tree() or _surface == null or surface_settings == null:
		return
	if not surface_settings.validation_error().is_empty():
		_surface.visible = false
		return
	var plane := PlaneMesh.new()
	plane.size = surface_settings.size
	plane.subdivide_width = surface_settings.resolution - 1
	plane.subdivide_depth = surface_settings.resolution - 1
	_surface.mesh = plane
	_surface.extra_cull_margin = surface_settings.displacement_margin
	# Display-only edits do not recreate GPU state or its clock.
	if gpu != null and gpu.ready and material_settings != null and material_settings.validation_error().is_empty():
		_surface.visible = true
	if gpu == null:
		_request_rebuild()

func _material_changed() -> void:
	if _material != null and material_settings != null:
		if material_settings.validation_error().is_empty():
			material_settings.apply(_material)
			if gpu != null and gpu.ready and _surface != null and surface_settings != null and surface_settings.validation_error().is_empty():
				_surface.visible = true
			_refresh_caustics()
		elif _surface != null:
			_surface.visible = false

func _process(delta: float) -> void:
	var moving := not paused and (not Engine.is_editor_hint() or editor_simulate)
	var light := get_node_or_null(sun_path) as DirectionalLight3D
	if light != null and _material != null:
		_material.set_shader_parameter("foam_sun",light.global_basis.z.normalized())
	if gpu != null and gpu.ready and moving:
		gpu.advance(delta)
	if caustics != null and caustics.ready:
		var sun := get_node_or_null(sun_path) as DirectionalLight3D
		if sun != null:
			_material.set_shader_parameter("caustics_sun",sun.global_basis.z.normalized())
			caustics.update(geometry_parameters(),caustics_settings,sun.global_basis.z.normalized(),material_settings.extinction,material_settings.refractive_index,moving)

## 发布场的几何约定也供光束追踪使用，不另建一套水面形状。
func geometry_parameters() -> Dictionary:
	var values := {}
	for key in ["fft_enabled","swe_enabled","fft_length","fft_resolution","height_gain","choppiness","sea_level","region_origin","region_rotation","region_size","swe_resolution","blend_depth","edge_width","dry_depth","shore_normal_strength","swe_model_blend","swe_fft_edges"]:
		values[key] = _material.get_shader_parameter(key)
	values.foam_enabled = foam_settings != null and foam_settings.enabled
	values.foam_opacity_scale = foam_material_settings.opacity_scale if foam_material_settings != null else 2.0
	values.caustics_center = Vector2(_swe.global_position.x,_swe.global_position.z) if _swe != null else Vector2(global_position.x,global_position.z)
	return values

func _ssr_changed() -> void:
	if _material != null and ssr_settings != null:
		var error := ssr_settings.validation_error()
		if error.is_empty():
			ssr_settings.apply(_material)
		else:
			_material.set_shader_parameter("ssr_enabled",false)
			push_warning(error)

func _foam_changed() -> void:
	if _material == null or foam_settings == null:
		return
	var error := foam_settings.validation_error()
	_material.set_shader_parameter("foam_enabled",foam_settings.enabled and error.is_empty())
	_material.set_shader_parameter("foam_dual",foam_settings.dual_population)
	_material.set_shader_parameter("foam_periodic",foam_settings.texture_period>0.0)
	if not error.is_empty():
		push_warning(error)
		return
	if gpu == null or not gpu.ready or _pending_rebuild:
		return
	if _foam_mode != foam_settings.dual_population:
		_request_rebuild()
		return
	var fft_config := _fft.settings if _fft != null else WaterFFTSettings.new()
	var swe_config: WaterSWESettings = _swe.settings if _swe != null else null
	var extent := Vector2(_swe.bake_settings.size.x,_swe.bake_settings.size.z) if _swe != null else Vector2.ONE
	var rotation := Vector2(_swe.global_basis.x.x,_swe.global_basis.z.x) if _swe != null else Vector2(1,0)
	gpu.set_foam_parameters(foam_settings.simulation_data(fft_config,swe_config,extent,rotation,_fft != null))

func _foam_material_changed() -> void:
	if _material != null and foam_material_settings != null:
		var error := foam_material_settings.validation_error()
		if error.is_empty():
			foam_material_settings.apply(_material)
		else:
			push_warning(error)

func _close_caustics() -> void:
	if caustics != null:
		caustics.close()
		caustics = null
	_caustics_signature.clear()
	if _material != null:
		_material.set_shader_parameter("caustics_enabled",false)

func _refresh_caustics() -> void:
	if not is_inside_tree() or _material == null or gpu == null or not gpu.ready:
		return
	var sun := get_node_or_null(sun_path) as DirectionalLight3D
	if caustics_settings == null or not caustics_settings.enabled:
		_close_caustics()
		return
	var error := caustics_settings.validation_error()
	if not error.is_empty() or sun == null:
		_close_caustics()
		push_warning(error if not error.is_empty() else "Physical caustics needs a DirectionalLight3D at Sun Path.")
		return
	var geometry := geometry_parameters()
	_material.set_shader_parameter("caustics_center",geometry.caustics_center)
	_material.set_shader_parameter("caustics_size",caustics_settings.size)
	_material.set_shader_parameter("caustics_strength",caustics_settings.strength)
	_material.set_shader_parameter("caustics_filter",caustics_settings.filter_radius)
	_material.set_shader_parameter("caustics_flat_depth",caustics_settings.flat_bed_depth)
	_material.set_shader_parameter("caustics_sun",sun.global_basis.z.normalized())
	var signature := [gpu.get_instance_id(),caustics_settings.ray_resolution,caustics_settings.texture_resolution,WaterCausticsGPU.SHADER_REVISION]
	if caustics != null and signature == _caustics_signature:
		return
	_close_caustics()
	_caustics_signature = signature
	caustics = WaterCausticsGPU.new()
	var generation := caustics.get_instance_id()
	caustics.initialized.connect(func(success: bool):
		if caustics == null or caustics.get_instance_id() != generation:
			return
		if success:
			_material.set_shader_parameter("caustics_map",caustics.texture)
			_material.set_shader_parameter("caustics_enabled",true)
		else:
			push_error(caustics.error_message)
	)
	caustics.configure(gpu,geometry,caustics_settings,sun.global_basis.z.normalized(),material_settings.extinction,material_settings.refractive_index)

func reset() -> void:
	_restart_clock = true
	_gpu_signature.clear()
	_request_rebuild()

func bake() -> void:
	for child in get_children():
		if child is SWEDeformer3D and child.enabled:
			child.bake()

func _get_configuration_warnings() -> PackedStringArray:
	if not is_inside_tree():
		return []
	var error := _validation_error()
	if not error.is_empty():
		return [error]
	if gpu != null and not gpu.error_message.is_empty():
		return [gpu.error_message]
	return []
