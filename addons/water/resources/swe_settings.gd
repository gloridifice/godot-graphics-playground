@tool
class_name WaterSWESettings
extends Resource

## 水体求解资产；动态水深和动量不属于资源，不会保存或在共享者之间传播。
@export_range(8, 512, 1) var resolution: int = 128:
	set(value):
		resolution = value
		emit_changed()
@export var second_order: bool = false:
	set(value):
		second_order = value
		emit_changed()
@export_range(0.1, 20.0, 0.01) var gravity: float = 9.81:
	set(value):
		gravity = value
		emit_changed()
@export_range(0.0, 0.1, 0.001) var manning: float = 0.03:
	set(value):
		manning = value
		emit_changed()
@export_range(8, 128, 1) var max_substeps: int = 32:
	set(value):
		max_substeps = value
		emit_changed()
@export_group("FFT Input")
## 未选中的区域外边界反射；内部缺失床面始终封闭。
@export_flags("-X", "+X", "-Z", "+Z") var fft_edges: int = 1:
	set(value):
		fft_edges = value
		emit_changed()
@export_range(0.01, 0.45, 0.01) var relaxation_width: float = 0.2:
	set(value):
		relaxation_width = value
		emit_changed()
@export_range(0.1, 20.0, 0.1) var relaxation_rate: float = 4.0:
	set(value):
		relaxation_rate = value
		emit_changed()
@export_range(0.0, 3.0, 0.01) var input_gain: float = 1.0:
	set(value):
		input_gain = value
		emit_changed()
@export var filter_enabled: bool = true:
	set(value):
		filter_enabled = value
		emit_changed()
@export_range(0.0, 100.0, 0.1) var filter_cutoff: float = 12.0:
	set(value):
		filter_cutoff = value
		emit_changed()
@export_range(0.0, 100.0, 0.1) var filter_transition: float = 12.0:
	set(value):
		filter_transition = value
		emit_changed()
@export_group("Surface Transition")
## 烘焙高度场用参考项目的模型分支：内部 SWE，边界／FFT 松弛带过渡。
## Depth Blend 保留旧版按海床深度混合的沙坡外观，仅影响显示。
@export_enum("Depth Blend", "Heightfield") var surface_mode: int = 1:
	set(value):
		surface_mode = value
		emit_changed()
@export_range(0.1, 20.0, 0.1) var blend_depth: float = 2.0:
	set(value):
		blend_depth = value
		emit_changed()

## 参考项目的近岸 FFT 小波法线增益；仅影响水面／泡沫／焦散光学，不修改几何或重置 SWE。
@export_range(0.0, 3.0, 0.01) var normal_strength: float = 1.0:
	set(value):
		normal_strength = value
		emit_changed()

func validation_error() -> String:
	if resolution < 8 or resolution > 512 or max_substeps < 8 or max_substeps > 128 or fft_edges < 0 or fft_edges > 15 or surface_mode < 0 or surface_mode > 1:
		return "SWE resolution/substep budget/edge mask is invalid."
	for value in [gravity, manning, relaxation_width, relaxation_rate, input_gain, filter_cutoff, filter_transition, blend_depth, normal_strength]:
		if not is_finite(value):
			return "SWE parameters must be finite."
	if gravity <= 0.0 or gravity > 20.0 or manning < 0.0 or manning > 0.1 or relaxation_width < 0.01 or relaxation_width > 0.45 or relaxation_rate <= 0.0 or relaxation_rate > 20.0 or input_gain < 0.0 or input_gain > 3.0 or filter_cutoff < 0.0 or filter_transition < 0.0 or blend_depth <= 0.0 or normal_strength < 0.0 or normal_strength > 3.0:
		return "SWE parameters are outside their supported ranges."
	return ""
