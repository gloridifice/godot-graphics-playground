@tool
class_name SWEDeformer3D
extends Node3D

signal configuration_changed
signal baked(success: bool)
@export var enabled: bool = true:
	set(value):
		enabled = value
		configuration_changed.emit()
@export var settings: WaterSWESettings:
	set(value):
		if settings != null and settings.changed.is_connected(_settings_changed):
			settings.changed.disconnect(_settings_changed)
		settings = value
		if settings != null:
			settings.changed.connect(_settings_changed)
		_settings_changed()
@export var bake_settings: WaterBakeSettings:
	set(value):
		if bake_settings != null and bake_settings.changed.is_connected(_bake_changed):
			bake_settings.changed.disconnect(_bake_changed)
		bake_settings = value
		if bake_settings != null:
			bake_settings.changed.connect(_bake_changed)
		_bake_changed()
## 节点引用属于场景，不放入可跨场景共享的参数资产。
@export_node_path("Node3D") var source_root: NodePath = NodePath("../.."):
	set(value):
		source_root = value
		_bake_changed()
@export_tool_button("Bake water bed", "Bake") var bake_action: Callable = bake

# 未导出：场景和 .tres 只保存参数，不保存高度图及求解状态。
var height_map: Image
var bake_status: String = "Not baked"
var _signature: Array = []
var _entry_generation := 0

func _init() -> void:
	settings = WaterSWESettings.new()
	bake_settings = WaterBakeSettings.new()
	set_notify_transform(true)

func _enter_tree() -> void:
	height_map = null
	_signature.clear()
	_entry_generation += 1
	_auto_bake.call_deferred(_entry_generation)

func _exit_tree() -> void:
	_entry_generation += 1
	height_map = null
	_signature.clear()

func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSFORM_CHANGED and is_inside_tree():
		_bake_changed()

func _auto_bake(generation: int) -> void:
	for i in 2:
		await get_tree().process_frame
		if not is_inside_tree() or generation != _entry_generation:
			return
	bake()

func _bake_signature() -> Array:
	if not is_inside_tree() or settings == null or bake_settings == null:
		return []
	return [global_transform, bake_settings.size, settings.resolution, source_root, bake_settings.fallback_enabled, bake_settings.fallback_height, bake_settings.ignore_group]

func is_bake_current() -> bool:
	return height_map != null and _signature == _bake_signature()

func bake() -> void:
	if not is_inside_tree() or settings == null or bake_settings == null:
		return
	var result := WaterHeightBaker.bake(self, get_node_or_null(source_root), bake_settings, settings.resolution)
	if not String(result.error).is_empty():
		# 失败时即使签名未变也停止使用旧结果。
		_signature.clear()
		bake_status = result.error
		push_warning("Water bake: " + bake_status)
		baked.emit(false)
	else:
		height_map = result.image
		_signature = _bake_signature()
		bake_status = "%d sampled, %d fallback cells (memory only)" % [result.hits, result.fallback_cells]
		baked.emit(true)
	configuration_changed.emit()
	update_configuration_warnings()

func _settings_changed() -> void:
	configuration_changed.emit()
	if is_inside_tree():
		update_configuration_warnings()

func _bake_changed() -> void:
	if is_inside_tree():
		bake_status = "Region/source changed — bake again"
		update_gizmos()
		update_configuration_warnings()
	configuration_changed.emit()

func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if not get_parent() is WaterBody3D:
		warnings.append("SWEDeformer3D must be a direct child of WaterBody3D.")
	if settings == null or bake_settings == null:
		warnings.append("Assign WaterSWESettings and WaterBakeSettings assets.")
		return warnings
	for error in [settings.validation_error(), bake_settings.validation_error()]:
		if not error.is_empty():
			warnings.append(error)
	if is_inside_tree():
		var error := WaterHeightBaker.transform_error(self)
		if not error.is_empty():
			warnings.append(error)
		if enabled and not is_bake_current():
			warnings.append(bake_status)
	return warnings
