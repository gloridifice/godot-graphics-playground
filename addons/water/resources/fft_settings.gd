@tool
class_name WaterFFTSettings
extends Resource

## 周期波谱资产。长度为米；amplitude 是 Phillips 功率，不是直接波高。
@export_range(8, 512, 1) var resolution: int = 128:
	set(value):
		resolution = value
		emit_changed()
@export_range(1.0, 1024.0, 1.0) var length: float = 128.0:
	set(value):
		length = value
		emit_changed()
@export_range(0.0, 0.1, 0.0001) var amplitude: float = 0.002:
	set(value):
		amplitude = value
		emit_changed()
@export_range(0.1, 200.0, 0.1) var phillips_length: float = 19.98:
	set(value):
		phillips_length = value
		emit_changed()
@export_range(-180.0, 180.0, 0.1) var wind_angle_degrees: float = 28.65:
	set(value):
		wind_angle_degrees = value
		emit_changed()
@export var seed: int = 42:
	set(value):
		seed = value
		emit_changed()
@export_range(0.0, 3.0, 0.01) var height_gain: float = 1.0:
	set(value):
		height_gain = value
		emit_changed()
@export_range(0.0, 3.0, 0.01) var choppiness: float = 1.0:
	set(value):
		choppiness = value
		emit_changed()

func validation_error() -> String:
	if resolution < 8 or resolution > 512 or (resolution & (resolution - 1)) != 0:
		return "FFT Resolution must be a power of two in 8..512."
	for value in [length, amplitude, phillips_length, wind_angle_degrees, height_gain, choppiness]:
		if not is_finite(value):
			return "FFT parameters must be finite."
	if length <= 0.0 or phillips_length <= 0.0 or amplitude < 0.0 or amplitude > 1.0 or height_gain < 0.0 or height_gain > 3.0 or choppiness < 0.0 or choppiness > 3.0:
		return "FFT length/power/gain is outside its supported range."
	return ""

## 固定种子的 Phillips 波谱；布局为复数 h0 和波向量 kx/kz。
## Godot RNG 与 Rust SplitMix64 不同，种子可复现但不保证跨语言逐位一致。
func create_spectrum() -> PackedFloat32Array:
	var modes := PackedFloat32Array()
	if not validation_error().is_empty():
		return modes
	modes.resize(resolution * resolution * 4)
	var random := RandomNumberGenerator.new()
	random.seed = seed
	var wind := Vector2.from_angle(deg_to_rad(wind_angle_degrees))
	var scale := float(resolution * resolution) * TAU / length
	for z in resolution:
		for x in resolution:
			var k := Vector2(x if x < resolution / 2 else x - resolution, z if z < resolution / 2 else z - resolution) * TAU / length
			var i := (z * resolution + x) * 4
			modes[i + 2] = k.x
			modes[i + 3] = k.y
			var k2 := k.length_squared()
			if k2 == 0.0 or x == resolution / 2 or z == resolution / 2:
				continue
			var alignment := k.dot(wind) / sqrt(k2)
			var directional := alignment * alignment * (1.0 if alignment < 0.0 else 0.07)
			var power := amplitude * exp(-1.0 / (k2 * phillips_length * phillips_length)) * exp(-k2 * 0.0144) * directional / (k2 * k2)
			var sigma := sqrt(0.5 * power) * scale
			modes[i] = random.randfn() * sigma
			modes[i + 1] = random.randfn() * sigma
	return modes
