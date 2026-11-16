@tool
class_name WaterSurfaceSettings
extends Resource

## 显示网格资产，分辨率独立于 FFT 和 SWE；更改只重建网格，不重置模拟。
@export var size: Vector2 = Vector2(128, 128):
	set(value):
		size = value
		emit_changed()
@export_range(8, 512, 1) var resolution: int = 192:
	set(value):
		resolution = value
		emit_changed()
## 为 GPU 顶点位移扩展 CPU 裁剪包围盒，单位米。
@export_range(1.0, 100.0, 1.0) var displacement_margin: float = 16.0:
	set(value):
		displacement_margin = value
		emit_changed()

func validation_error() -> String:
	if not size.is_finite() or minf(size.x, size.y) <= 0.0 or resolution < 8 or resolution > 512 or not is_finite(displacement_margin) or displacement_margin <= 0.0:
		return "Water surface dimensions/resolution/margin are invalid."
	return ""
