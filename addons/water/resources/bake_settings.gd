@tool
class_name WaterBakeSettings
extends Resource

## 区域原点是盒底中心，Y 区间为 [0,size.y]。默认不凭空填补无采样格。
@export var size: Vector3 = Vector3(64, 16, 64):
	set(value):
		size = value
		emit_changed()
@export var fallback_enabled: bool = false:
	set(value):
		fallback_enabled = value
		emit_changed()
## 补底的盒内局部高度，仅作用于未命中格。
@export var fallback_height: float = 0.0:
	set(value):
		fallback_height = value
		emit_changed()
@export var ignore_group: StringName = &"water_bake_ignore":
	set(value):
		ignore_group = value
		emit_changed()

func validation_error() -> String:
	if not size.is_finite() or size.x < 0.1 or size.y < 0.1 or size.z < 0.1:
		return "Bake Size must be finite and at least 0.1 m on each axis."
	if not is_finite(fallback_height) or (fallback_enabled and (fallback_height < 0.0 or fallback_height > size.y)):
		return "Fallback Height must lie within the bake box."
	return ""
