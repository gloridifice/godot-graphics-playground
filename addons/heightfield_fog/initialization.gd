@tool
class_name HeightfieldFogInitialization
extends Resource

## Thickness above each support surface; in Horizontal Top mode, elevation above box bottom.
@export_range(0.0, 8.0, 0.01, "suffix:m") var base_height: float = 0.4
@export_range(-8.0, 8.0, 0.01, "suffix:m") var height_offset: float = 0.0
@export var horizontal_top: bool = false
## Dimensionless concentration; does not change thickness.
@export_range(0.0, 20.0, 0.01) var concentration: float = 1.0
@export_group("Initial Noise")
@export_range(0.0, 8.0, 0.01, "suffix:m") var noise_amplitude: float = 0.0
## Spatial frequency in inverse meters, sampled in box-local X/Z.
@export_range(0.001, 8.0, 0.001) var noise_frequency: float = 0.32
@export_range(1, 8, 1) var noise_octaves: int = 3
@export var noise_seed: int = 7
@export var noise_offset := Vector2.ZERO

@export_group("Natural Mist")
## Use a broad world-space mist top and wind-stretched density detail. Live; no terrain rebake.
## Initial Noise amplitude/frequency/octaves are bypassed in this mode; seed/offset still apply.
@export var natural_mist_enabled: bool = false
## Maximum top displacement in meters. Horizontal Top is recommended for low-lying mist.
@export_range(0.0, 2.0, 0.01, "suffix:m") var top_variation: float = 0.25
## Broad top feature scale, in meters; world-aligned across rotated boxes.
@export_range(4.0, 80.0, 0.1, "suffix:m") var top_scale: float = 20.0
## Fraction of layer height fading smoothly at the top; the lower part stays continuous.
@export_range(0.1, 1.0, 0.01) var top_softness: float = 0.65
## Density modulation strength, not height modulation. Zero gives a continuous smooth layer.
@export_range(0.0, 0.8, 0.01) var detail_strength: float = 0.3
## Cross-wind detail scale in meters. Avoid sub-froxel details.
@export_range(1.0, 16.0, 0.1, "suffix:m") var detail_scale: float = 3.0
## Along-wind / cross-wind scale ratio.
@export_range(1.0, 8.0, 0.1) var wind_stretch: float = 4.0
## World X/Z direction: 0 degrees is +X, 90 degrees is +Z.
@export_range(-180.0, 180.0, 1.0, "degrees") var wind_direction: float = 25.0
## Procedural advection speed, not a fluid solver. Zero makes the mist static.
@export_range(0.0, 1.0, 0.01, "suffix:m/s") var wind_speed: float = 0.12

func parameters() -> Array:
	return [base_height, height_offset, horizontal_top, concentration, noise_amplitude, noise_frequency, noise_octaves, noise_seed, noise_offset, natural_mist_enabled]

## Generated transient initial thickness, not baked terrain. Safe for shared resources:
## no box-specific state is written back into this asset.
func create_thickness(terrain: Image, extent: Vector2) -> Image:
	var image := Image.create(terrain.get_width(), terrain.get_height(), false, Image.FORMAT_RF)
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.frequency = clampf(noise_frequency, 0.001, 8.0)
	noise.fractal_octaves = clampi(noise_octaves, 1, 8)
	noise.seed = noise_seed
	for z in image.get_height():
		for x in image.get_width():
			var bed := terrain.get_pixel(x, z)
			if bed.g < 0.5:
				continue
			var p := ((Vector2(x, z) + Vector2.ONE * 0.5) / Vector2(image.get_size()) - Vector2.ONE * 0.5) * extent + noise_offset
			# Natural mode stores only the baseline; animated world-space detail stays on the GPU.
			var perturbation := 0.0 if natural_mist_enabled else maxf(noise_amplitude, 0.0) * noise.get_noise_2d(p.x, p.y)
			var h := base_height + height_offset + perturbation
			if horizontal_top:
				h -= bed.r
			image.set_pixel(x, z, Color(maxf(h, 0.0), 0, 0, 1))
	return image
