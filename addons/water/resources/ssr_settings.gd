@tool
class_name WaterSSRSettings
extends Resource

## 自定义水面 SSR。Godot 原生 SSR 不作用于当前屏幕取样/自定义光学路径。
@export var enabled: bool = false:
	set(v):
		enabled = v
		emit_changed()
@export_range(1.0,500.0,1.0) var maximum_distance: float = 100.0:
	set(v):
		maximum_distance = v
		emit_changed()
@export_range(8,1024,1) var max_steps: int = 256:
	set(v):
		max_steps = v
		emit_changed()
@export_range(0.1,5.0,0.05) var tolerance: float = 1.0:
	set(v):
		tolerance = v
		emit_changed()
@export_range(0.001,0.2,0.001) var normal_bias: float = 0.02:
	set(v):
		normal_bias = v
		emit_changed()
@export_range(0.0,1.0,0.01) var strength: float = 1.0:
	set(v):
		strength = v
		emit_changed()

func validation_error() -> String:
	for value in [maximum_distance,tolerance,normal_bias,strength]:
		if not is_finite(value):
			return "SSR parameters must be finite."
	if maximum_distance<1 or maximum_distance>500 or max_steps<8 or max_steps>1024 or tolerance<0.1 or tolerance>5 or normal_bias<0.001 or normal_bias>0.2 or strength<0 or strength>1:
		return "SSR parameters are outside supported ranges."
	return ""

func apply(material: ShaderMaterial) -> void:
	material.set_shader_parameter("ssr_enabled",enabled)
	material.set_shader_parameter("ssr_maximum",maximum_distance)
	material.set_shader_parameter("ssr_max_steps",max_steps)
	material.set_shader_parameter("ssr_tolerance",tolerance)
	material.set_shader_parameter("ssr_bias",normal_bias)
	material.set_shader_parameter("ssr_strength",strength)
