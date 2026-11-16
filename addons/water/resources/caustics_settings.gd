@tool
class_name WaterCausticsSettings
extends Resource

## 折射光束网格与世界空间接收贴图；不是滚动噪声焦散。
@export var enabled: bool = false:
	set(value):
		enabled = value
		emit_changed()
## 光束格边长约为 1.5 * Size / Ray Resolution；接收贴图不能弥补光束欠采样。
@export_range(16, 1024, 1) var ray_resolution: int = 256:
	set(value):
		ray_resolution = value
		emit_changed()
@export_range(32, 4096, 1) var texture_resolution: int = 1024:
	set(value):
		texture_resolution = value
		emit_changed()
@export var size: Vector2 = Vector2(64, 64):
	set(value):
		size = value
		emit_changed()
## 无 SWE 高度场时的明确平面接收深度（相对平均水位，m）。
@export_range(0.01, 100.0, 0.1) var flat_bed_depth: float = 6.0:
	set(value):
		flat_bed_depth = value
		emit_changed()
@export_range(1.0, 1000.0, 1.0) var maximum_distance: float = 100.0:
	set(value):
		maximum_distance = value
		emit_changed()
@export_range(16, 1024, 1) var traversal_budget: int = 256:
	set(value):
		traversal_budget = value
		emit_changed()
@export_range(0.0, 3.0, 0.05) var strength: float = 1.0:
	set(value):
		strength = value
		emit_changed()
## 接收贴图 texel 单位；增大仅过滤，不增加光束细节。
@export_range(0.0, 4.0, 0.1) var filter_radius: float = 1.0:
	set(value):
		filter_radius = value
		emit_changed()

func validation_error() -> String:
	if ray_resolution < 16 or ray_resolution > 1024 or texture_resolution < 32 or texture_resolution > 4096 or traversal_budget < 16 or traversal_budget > 1024:
		return "Caustics grid, texture size or traversal budget is invalid."
	if not size.is_finite() or minf(size.x,size.y) <= 0.0:
		return "Caustics size must be finite and positive."
	for value in [flat_bed_depth,maximum_distance,strength,filter_radius]:
		if not is_finite(value):
			return "Caustics parameters must be finite."
	if flat_bed_depth <= 0.0 or flat_bed_depth > 100.0 or maximum_distance <= 0.0 or maximum_distance > 1000.0 or strength < 0.0 or strength > 3.0 or filter_radius < 0.0 or filter_radius > 4.0:
		return "Caustics parameters are outside supported ranges."
	return ""
