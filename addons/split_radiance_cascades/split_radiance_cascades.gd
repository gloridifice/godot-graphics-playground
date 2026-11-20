@tool
class_name SplitRadianceCascades
extends Node
## Diffuse GI for the game and the 3D editor. Add as a direct child of a WorldEnvironment (Forward+).
## Geometry snapshots are explicit; supported scene lights update automatically.

const Effect := preload("cascade_effect.gd")
const Snapshot := preload("scene_snapshot.gd")
const Lights := preload("scene_lights.gd")
const Profiler := preload("stage_profiler.gd")
## One completed callback, milliseconds per stage: Vector2(CPU submission, GPU execution).
## An empty sample invalidates old timings (effect off, reset or no session).
signal timings_updated(times_ms: Dictionary)
enum View { COMPOSITE, INDIRECT_ONLY, PROBE_CELLS, LOD_BLEND, LOCAL_INTERVAL }

@export var enabled := true:
	set(value):
		enabled = value
		if Engine.is_editor_hint():
			_update_editor_preview()
		elif _effect:
			set_process(value and _live_lights != null)
			if value:
				_sync_lights()
			_sync(true)
			_effect.enabled = value
## Show GI in the edited scene without changing whether the game uses it.
@export var preview_in_editor := false:
	set(value):
		preview_in_editor = value
		if Engine.is_editor_hint():
			_update_editor_preview()
## Refresh after editing static meshes or materials. Light and camera edits do not need this.
@export_tool_button("Rebuild GI Snapshot", "Reload") var rebuild_snapshot := rebuild
## Static MeshInstance3Ds and Directional/Omni lights below this root. Empty = current scene.
@export_node_path("Node3D") var source_root := NodePath("")
## Optional world-aligned subtree for ray hits only. Hide its root to keep it out
## of the viewport; receivers and lights still come from Source Root.
@export_node_path("Node3D") var trace_proxy_root := NodePath("")
## Use the experimental RD raytracing pipeline when supported. Same source or
## proxy, materials and cascades; devices without the feature use the software BVH.
@export var prefer_hardware_trace := false:
	set(value):
		if value == prefer_hardware_trace: return
		prefer_hardware_trace = value
		if _effect: rebuild()
@export_range(0.0, 4.0, 0.01) var strength := 1.0:
	set(value):
		strength = maxf(0.0, value)
		_sync(false)
@export_range(0.05, 8.0, 0.05, "suffix:m") var probe_spacing := 0.4:
	set(value):
		probe_spacing = maxf(0.05, value)
		_sync(true)
## C0 ends at this distance at LOD 0. C1/C2 end at 4x/16x; C3 is open-ended.
@export_range(0.05, 8.0, 0.05, "suffix:m") var first_interval := 0.6:
	set(value):
		first_interval = maxf(0.05, value)
		_sync(true)
@export_range(1.0, 128.0, 0.5, "suffix:m") var lod_distance := 8.0:
	set(value):
		lod_distance = maxf(1.0, value)
		_sync(true)
## One primary sample per N x N pixels, with a rotating subpixel offset.
@export_range(1, 12) var ray_stride := 4:
	set(value):
		ray_stride = clampi(value, 1, 12)
		_sync(false)
@export_range(0.0, 0.99, 0.01) var history_retention := 0.94:
	set(value):
		history_retention = clampf(value, 0.0, 0.99)
		_sync(false)
@export var multi_bounce := true:
	set(value):
		multi_bounce = value
		_sync(true)
@export_group("Debug")
@export var profile_stages := false:
	set(value):
		profile_stages = value
		_reset_profiler()
@export var view: View = View.COMPOSITE:
	set(value):
		view = value
		_sync(false)
@export_range(0, 3) var debug_cascade := 0:
	set(value):
		debug_cascade = clampi(value, 0, 3)
		_sync(false)

var _effect: Effect
var _host: WorldEnvironment
var _original: Compositor
var _installed: Compositor
var _editor_scenario: RID
var _session := 0
var _live_lights: Lights
var _light_data := PackedVector4Array()

func _ready() -> void:
	set_process(false)
	_install.call_deferred() # current_scene and sibling meshes are ready by then

func _process(_delta: float) -> void:
	_sync_lights()

func _sync_lights() -> void:
	if not _live_lights:
		return
	# Light3D has no general property-change signal. Check only candidate lights;
	# identical packed values cause no upload, history reset or editor redraw.
	var data := _live_lights.pack()
	if data != _light_data:
		_light_data = data
		RenderingServer.call_on_render_thread(_effect.replace_lights.bind(data))

func _update_editor_preview() -> void:
	if not is_node_ready() or not is_inside_tree():
		return
	if preview_in_editor and enabled:
		_install.call_deferred()
	else:
		_uninstall()

func _install() -> void:
	if not is_inside_tree() or _effect:
		return
	if Engine.is_editor_hint():
		var edited := get_tree().edited_scene_root
		if not preview_in_editor or not enabled or not edited or not edited.is_ancestor_of(self):
			return # Not in the active scene (e.g. an asset thumbnail).
	_host = get_parent() as WorldEnvironment
	if not _host:
		push_warning("SplitRadianceCascades must be a child of WorldEnvironment.")
		return
	if RenderingServer.get_current_rendering_method() != "forward_plus" or not RenderingServer.get_rendering_device():
		push_warning("SplitRadianceCascades requires Forward+ and a RenderingDevice; rendering unchanged.")
		return
	_original = _host.compositor
	var effects: Array[CompositorEffect] = []
	if _original:
		effects.append_array(_original.compositor_effects)
		for existing in effects:
			if existing is Effect:
				push_warning("Split RC: only one instance per WorldEnvironment is needed.")
				return
	if Engine.is_editor_hint():
		var scenario := get_viewport().find_world_3d().scenario
		var group := _preview_group(scenario)
		if get_tree().has_group(group):
			push_warning("Split RC: only one editor preview per World3D is supported.")
			return
		_editor_scenario = scenario
		add_to_group(group)
	_installed = Compositor.new()
	_effect = Effect.new()
	_effect.enabled = enabled
	effects.append(_effect)
	_installed.compositor_effects = effects
	if _editor_scenario.is_valid():
		# WorldEnvironment.compositor is serialized. Override only the live scenario,
		# shared by the editor viewports and Camera3D preview, never the edited node.
		var editor := Engine.get_singleton(&"EditorInterface")
		var ui: Control = editor.get_base_control()
		_effect.editor_redraw = ui.queue_redraw
		RenderingServer.scenario_set_compositor(_editor_scenario, _installed.get_rid())
	else:
		_host.compositor = _installed
	_sync(false)
	rebuild()

## Recollect after moving/editing static geometry or materials.
## Reject an empty/over-budget snapshot instead of rendering stale occluders.
func rebuild() -> void:
	if not _effect:
		return
	var scene := get_tree().edited_scene_root if Engine.is_editor_hint() else get_tree().current_scene
	var source := scene if source_root.is_empty() else get_node_or_null(source_root)
	var proxy := get_node_or_null(trace_proxy_root) as Node3D if not trace_proxy_root.is_empty() else null
	var snapshot := Snapshot.new()
	if not source:
		push_warning("Split RC: Source Root not found.")
		snapshot = null
	elif not trace_proxy_root.is_empty() and not proxy:
		push_warning("Split RC: Trace Proxy Root not found.")
		snapshot = null
	elif not snapshot.build(source, proxy, prefer_hardware_trace and RenderingServer.get_rendering_device().has_feature(RenderingDevice.SUPPORTS_RAYTRACING_PIPELINE)):
		snapshot = null
	_live_lights = Lights.new(source, proxy, snapshot.origin) if snapshot else null
	_light_data = _live_lights.pack() if _live_lights else PackedVector4Array()
	set_process(enabled and _live_lights != null)
	_reset_profiler()
	RenderingServer.call_on_render_thread(_effect.replace_scene.bind(snapshot, _light_data))

func _reset_profiler() -> void:
	if not _effect:
		return
	_session += 1
	var profiler: Profiler
	if enabled and profile_stages:
		profiler = Profiler.new()
		profiler.measured.connect(_receive_timings.bind(_session), CONNECT_DEFERRED)
	RenderingServer.call_on_render_thread(_effect.set_profiler.bind(profiler))
	timings_updated.emit({})

func _receive_timings(times: Dictionary, session: int) -> void:
	if session == _session and _effect:
		timings_updated.emit(times)

func _sync(reset: bool) -> void:
	if _effect:
		if reset:
			_reset_profiler()
		var tuning := Vector4(probe_spacing, first_interval, lod_distance, history_retention)
		var options := Vector4i(ray_stride, int(multi_bounce), view, debug_cascade)
		RenderingServer.call_on_render_thread(_effect.configure.bind(tuning, options, strength, reset))

func _exit_tree() -> void:
	_uninstall()
	request_ready()

static func _preview_group(scenario: RID) -> StringName:
	return "_split_rc_preview_%d" % scenario.get_id()

func _uninstall() -> void:
	set_process(false)
	_live_lights = null
	if _effect:
		_effect.enabled = false
		if _editor_scenario.is_valid():
			# Use the current authored chain, including edits made while previewing.
			var authored := _host.compositor
			RenderingServer.scenario_set_compositor(_editor_scenario, authored.get_rid() if authored else RID())
			remove_from_group(_preview_group(_editor_scenario))
			_editor_scenario = RID()
		elif _host.compositor == _installed:
			_host.compositor = _original
		# A method Callable only weakly references its target. Bind a strong
		# reference until the render thread finishes all queued work and disposal.
		RenderingServer.call_on_render_thread(_dispose.bind(_effect))
		_effect = null
	_installed = null
	_original = null
	_host = null

static func _dispose(effect: Effect) -> void:
	effect.close()
