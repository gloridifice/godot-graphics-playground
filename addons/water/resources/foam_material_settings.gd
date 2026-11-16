@tool
class_name WaterFoamMaterialSettings
extends Resource

## 仅外观，编辑不清空泡沫量/动量/输运坐标。
@export var color: Color = Color(0.87,0.92,0.90):
	set(v):
		color = v
		emit_changed()
@export_enum("Shorewaves NSH","Crest Foam NSH","Crest Foam2 NSH") var texture_source: int = 0:
	set(v):
		texture_source = v
		emit_changed()
@export_range(0.1,64.0,0.1) var tile_size: float = 12.0:
	set(v):
		tile_size = v
		emit_changed()
@export_range(0.0,3.0,0.01) var micro_normal: float = 0.65:
	set(v):
		micro_normal = v
		emit_changed()
@export_range(0.15,1.0,0.01) var roughness: float = 0.85:
	set(v):
		roughness = v
		emit_changed()
@export_range(0.01,20.0,0.01) var opacity_scale: float = 2.0:
	set(v):
		opacity_scale = v
		emit_changed()
@export_range(0.01,20.0,0.01) var coverage_reference: float = 2.0:
	set(v):
		coverage_reference = v
		emit_changed()
@export_range(0.0,0.5,0.005) var height_maximum: float = 0.05:
	set(v):
		height_maximum = v
		emit_changed()
@export_range(0.0,10.0,0.01) var height_threshold: float = 0.1:
	set(v):
		height_threshold = v
		emit_changed()
@export_range(0.001,10.0,0.01) var height_transition: float = 1.9:
	set(v):
		height_transition = v
		emit_changed()
@export var texture_distortion: bool = true:
	set(v):
		texture_distortion = v
		emit_changed()

func validation_error() -> String:
	if not Vector4(color.r,color.g,color.b,color.a).is_finite() or texture_source<0 or texture_source>2:
		return "Invalid foam color or NSH texture selection."
	for v in [tile_size,micro_normal,roughness,opacity_scale,coverage_reference,height_maximum,height_threshold,height_transition]:
		if not is_finite(v):
			return "Foam appearance must be finite."
	if tile_size<0.1 or tile_size>64 or micro_normal<0 or micro_normal>3 or roughness<0.15 or roughness>1 or opacity_scale<=0 or opacity_scale>20 or coverage_reference<=0 or coverage_reference>20:
		return "Foam appearance is outside supported ranges."
	if height_maximum<0 or height_maximum>0.5 or height_threshold<0 or height_threshold>10 or height_transition<0.001 or height_transition>10:
		return "Foam visual height is outside supported ranges."
	return ""

func apply(material: ShaderMaterial) -> void:
	material.set_shader_parameter("foam_color",color)
	material.set_shader_parameter("foam_tile_size",tile_size)
	material.set_shader_parameter("foam_micro_normal",micro_normal)
	material.set_shader_parameter("foam_roughness",roughness)
	material.set_shader_parameter("foam_opacity_scale",opacity_scale)
	material.set_shader_parameter("foam_coverage_reference",coverage_reference)
	material.set_shader_parameter("foam_distortion",texture_distortion)
	material.set_shader_parameter("foam_height",Vector3(height_maximum,height_threshold,height_transition))
	var paths := ["shorewaves_nsh","crest_foam_nsh","crest_foam2_nsh"]
	material.set_shader_parameter("foam_nsh",load("res://addons/water/textures/foam/"+paths[texture_source]+".png"))
