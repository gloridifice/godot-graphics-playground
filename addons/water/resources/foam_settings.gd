@tool
class_name WaterFoamSettings
extends Resource

## 水上泡沫量/面积，不是除以水深的浓度，不截断至 0..1。
@export var enabled: bool = false:
	set(v):
		enabled = v
		emit_changed()
@export var emission_enabled: bool = true:
	set(v):
		emission_enabled = v
		emit_changed()
@export_range(0.0,100.0,0.1) var generation: float = 2.5:
	set(v):
		generation = v
		emit_changed()
@export_range(0.0,1.0,0.01) var background_multiplier: float = 0.15:
	set(v):
		background_multiplier = v
		emit_changed()
@export_range(0.0,5.0,0.01) var rise_threshold: float = 0.25:
	set(v):
		rise_threshold = v
		emit_changed()
@export_range(0.0,5.0,0.01) var rise_transition: float = 0.4:
	set(v):
		rise_transition = v
		emit_changed()
@export_range(0.0,100.0,0.1) var front_generation: float = 8.0:
	set(v):
		front_generation = v
		emit_changed()
@export_range(0.05,10.0,0.05) var front_distance: float = 1.0:
	set(v):
		front_distance = v
		emit_changed()
@export_range(0.0,20.0,0.01) var closing_threshold: float = 0.1:
	set(v):
		closing_threshold = v
		emit_changed()
@export_range(0.0,20.0,0.01) var closing_transition: float = 0.5:
	set(v):
		closing_transition = v
		emit_changed()
@export_range(0.0,20.0,0.01) var decay: float = 0.6:
	set(v):
		decay = v
		emit_changed()
@export_range(0.0,1.0,0.01) var follow: float = 0.8:
	set(v):
		follow = v
		emit_changed()
@export var drag_enabled: bool = true:
	set(v):
		drag_enabled = v
		emit_changed()
@export_range(0.0,5.0,0.01) var response_time: float = 0.35:
	set(v):
		response_time = v
		emit_changed()
@export_range(0.0,3.0,0.01) var birth_speed: float = 1.0:
	set(v):
		birth_speed = v
		emit_changed()
@export var second_order_transport: bool = false:
	set(v):
		second_order_transport = v
		emit_changed()
@export_range(0.0,20.0,0.1) var texture_period: float = 2.0:
	set(v):
		texture_period = v
		emit_changed()
@export_group("Offshore Jacobian")
@export_range(0.0,2.0,0.01) var offshore_threshold: float = 0.65:
	set(v):
		offshore_threshold = v
		emit_changed()
@export_range(0.0,100.0,0.1) var offshore_generation: float = 4.0:
	set(v):
		offshore_generation = v
		emit_changed()
@export_range(0.0,20.0,0.01) var offshore_decay: float = 0.6:
	set(v):
		offshore_decay = v
		emit_changed()
@export_group("Dual Population Experiment")
## 与源项目一致：SL 输送 N/R，并施加局部面积压缩；不是严格守恒通量模式。
@export var dual_population: bool = false:
	set(v):
		dual_population = v
		emit_changed()
@export_range(0.05,30.0,0.05) var fresh_half_life: float = 1.4:
	set(v):
		fresh_half_life = v
		emit_changed()
@export_range(0.05,60.0,0.05) var residual_half_life: float = 9.0:
	set(v):
		residual_half_life = v
		emit_changed()
@export_range(0.0,1.0,0.01) var conversion: float = 0.65:
	set(v):
		conversion = v
		emit_changed()

func validation_error() -> String:
	for name in ["generation","background_multiplier","rise_threshold","rise_transition","front_generation","front_distance","closing_threshold","closing_transition","decay","follow","response_time","birth_speed","texture_period","offshore_threshold","offshore_generation","offshore_decay","fresh_half_life","residual_half_life","conversion"]:
		var value: float = get(name)
		if not is_finite(value) or value < 0.0:
			return "Foam parameters must be finite and nonnegative: " + name
	if generation>100 or front_generation>100 or offshore_generation>100 or background_multiplier>1 or follow>1 or conversion>1 or front_distance<0.05 or front_distance>10 or fresh_half_life<0.05 or fresh_half_life>30 or residual_half_life<0.05 or residual_half_life>60 or response_time>5 or birth_speed>3 or texture_period>20 or offshore_threshold>2 or decay>20 or offshore_decay>20 or closing_threshold>20 or closing_transition>20 or rise_threshold>5 or rise_transition>5:
		return "Foam parameters are outside supported ranges."
	return ""

func simulation_data(fft: WaterFFTSettings, swe: WaterSWESettings, extent: Vector2, rotation: Vector2, fft_enabled: bool) -> PackedByteArray:
	var n := swe.resolution if swe != null else 0
	var data := PackedFloat32Array([generation,background_multiplier,rise_threshold,rise_transition,
		front_generation,front_distance,closing_threshold,closing_transition,
		decay,follow,response_time,birth_speed,
		offshore_threshold,offshore_generation,offshore_decay,fft.height_gain*fft.choppiness]).to_byte_array()
	data.append_array(PackedInt32Array([1 if enabled else 0,1 if emission_enabled else 0,2 if second_order_transport and swe != null and swe.second_order else 1,1 if dual_population else 0]).to_byte_array())
	data.append_array(PackedFloat32Array([fresh_half_life,residual_half_life,conversion,texture_period,
		extent.x/maxi(n,1),extent.y/maxi(n,1),rotation.x,rotation.y]).to_byte_array())
	data.append_array(PackedInt32Array([n,fft.resolution if fft_enabled else 8,swe.fft_edges if swe != null and fft_enabled else 0,(1 if fft_enabled else 0)+(2 if drag_enabled else 0)]).to_byte_array())
	return data
