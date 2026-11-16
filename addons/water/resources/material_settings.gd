@tool
class_name WaterMaterialSettings
extends Resource

## 所有颜色在 shader 内按线性 RGB 使用。消光单位 m⁻¹，源项单位为每米辐亮度。
@export var extinction: Vector3 = Vector3(0.32, 0.10, 0.055):
	set(value):
		extinction = value
		emit_changed()
@export var scattering: Vector3 = Vector3(0.012, 0.035, 0.045):
	set(value):
		scattering = value
		emit_changed()
@export var reflection_color: Color = Color(0.30, 0.48, 0.65):
	set(value):
		reflection_color = value
		emit_changed()
## 可选的 HDR 经纬环境图；未指定时使用反射颜色，不宣称自动读取场景天空或 SSR。
@export var reflection_panorama: Texture2D:
	set(value):
		reflection_panorama = value
		emit_changed()
@export_range(1.0, 1.6, 0.001) var refractive_index: float = 1.333:
	set(value):
		refractive_index = value
		emit_changed()
@export_range(0.02, 1.0, 0.01) var roughness: float = 0.28:
	set(value):
		roughness = value
		emit_changed()
@export var refraction_enabled: bool = true:
	set(value):
		refraction_enabled = value
		emit_changed()
@export_range(0.0, 2.0, 0.01) var refraction_strength: float = 1.0:
	set(value):
		refraction_strength = value
		emit_changed()
@export_range(0.0, 0.1, 0.001) var refraction_limit: float = 0.025:
	set(value):
		refraction_limit = value
		emit_changed()
@export_range(0.001, 0.1, 0.001) var dry_depth: float = 0.008:
	set(value):
		dry_depth = value
		emit_changed()
@export_enum("Shaded", "Water depth", "Optical path", "Transmittance", "Normal", "SWE weight", "Bake coverage", "Caustics irradiance", "Foam density", "Foam opacity", "Foam material grid", "SSR only", "SSR hits") var debug_view: int = 0:
	set(value):
		debug_view = value
		emit_changed()

func validation_error() -> String:
	if not extinction.is_finite() or not scattering.is_finite() or extinction.x < 0 or extinction.y < 0 or extinction.z < 0 or scattering.x < 0 or scattering.y < 0 or scattering.z < 0:
		return "Water extinction/scattering must be finite and nonnegative."
	if not Vector4(reflection_color.r, reflection_color.g, reflection_color.b, reflection_color.a).is_finite():
		return "Reflection color must be finite."
	for value in [refractive_index, roughness, refraction_strength, refraction_limit, dry_depth]:
		if not is_finite(value):
			return "Water material parameters must be finite."
	if refractive_index < 1.0 or refractive_index > 1.6 or roughness < 0.02 or roughness > 1.0 or refraction_strength < 0.0 or refraction_strength > 2.0 or refraction_limit < 0.0 or refraction_limit > 0.1 or dry_depth <= 0.0 or dry_depth > 0.1 or debug_view < 0 or debug_view > 12:
		return "Water material parameters are outside their supported ranges."
	return ""

func apply(material: ShaderMaterial) -> void:
	material.set_shader_parameter("extinction", extinction)
	material.set_shader_parameter("scattering", scattering)
	material.set_shader_parameter("reflection_color", reflection_color)
	material.set_shader_parameter("reflection_panorama", reflection_panorama)
	material.set_shader_parameter("use_reflection_panorama", reflection_panorama != null)
	material.set_shader_parameter("refractive_index", refractive_index)
	material.set_shader_parameter("water_roughness", roughness)
	material.set_shader_parameter("refraction_enabled", refraction_enabled)
	material.set_shader_parameter("refraction_strength", refraction_strength)
	material.set_shader_parameter("refraction_limit", refraction_limit)
	material.set_shader_parameter("dry_depth", dry_depth)
	material.set_shader_parameter("debug_view", debug_view)
