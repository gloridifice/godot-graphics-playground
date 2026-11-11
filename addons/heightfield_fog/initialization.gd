@tool
class_name HeightfieldFogInitialization
extends Resource

# One seamless fBm tile, shared by CPU initialization and GPU density sampling.
# Coordinates are in noise space: Frequency controls meters, not texture resolution.
const NOISE_PERIOD := 32.0
const NOISE_SIZE := 512

## Thickness above each support surface; in Horizontal Top mode, elevation above box bottom.
@export_range(0.0, 8.0, 0.01, "suffix:m") var base_height: float = 0.4
@export_range(-8.0, 8.0, 0.01, "suffix:m") var height_offset: float = 0.0
@export var horizontal_top: bool = false
## Limit initial thickness above the ground, even in deep hollows. Zero = unlimited.
## SWE may subsequently transport/pile up this mass; this is not a simulation clamp.
@export_range(0.0, 8.0, 0.01, "suffix:m") var max_thickness: float = 0.0
## Dimensionless concentration; live shading only, does not reset SWE.
@export_range(0.0, 20.0, 0.01) var concentration: float = 1.0
@export_group("Noise")
## Height amplitude. Used in ALL modes, including the SWE initial condition.
@export_range(0.0, 8.0, 0.01, "suffix:m") var noise_amplitude: float = 0.0
## Spatial frequency in inverse meters. Natural mist is world-aligned; legacy layers are local.
@export_range(0.001, 8.0, 0.001) var noise_frequency: float = 0.32
@export_range(1, 8, 1) var noise_octaves: int = 3
@export var noise_seed: int = 7
## Sampling offset in meters, before wind alignment/stretch.
@export var noise_offset := Vector2.ZERO

@export_group("Natural Mist")
## Soft ground layer with world-space noise. Thickness always comes from the initial/SWE field.
@export var natural_mist_enabled: bool = false
## Fraction of layer height fading smoothly at the top; the lower part stays continuous.
@export_range(0.1, 1.0, 0.01) var top_softness: float = 0.65
## Visible density coverage: 0 = invisible, 1 = continuous. Does not erase simulated mass.
@export_range(0.0, 1.0, 0.01) var coverage: float = 1.0
## Soft transition between clear ground and wisps, in normalized noise units.
@export_range(0.01, 0.5, 0.01) var coverage_softness: float = 0.15
## Additional density modulation; zero disables detail, not the coverage mask.
@export_range(0.0, 0.8, 0.01) var detail_strength: float = 0.3
## Density feature size relative to the height noise. 1 uses the same field/scale.
@export_range(0.25, 8.0, 0.05) var detail_scale: float = 1.0
## Along-wind / cross-wind scale ratio. Also shapes initial height noise.
@export_range(1.0, 8.0, 0.1) var wind_stretch: float = 4.0
## World X/Z direction: 0 degrees is +X, 90 degrees is +Z.
@export_range(-180.0, 180.0, 1.0, "degrees") var wind_direction: float = 25.0
## Density advection only; zero freezes visual drift. Does not force the SWE solver.
@export_range(0.0, 1.0, 0.01, "suffix:m/s") var wind_speed: float = 0.12

var _noise_key: Array = []
var _noise_image: Image
var _noise_texture: ImageTexture

# Only shape parameters reset the initial condition. Shading edits preserve simulated state.
func parameters() -> Array:
	return [base_height, height_offset, horizontal_top, max_thickness, noise_amplitude,
		noise_frequency, noise_octaves, noise_seed, noise_offset, natural_mist_enabled,
		wind_stretch if natural_mist_enabled else 1.0, wind_direction if natural_mist_enabled else 0.0]

func _ensure_noise() -> void:
	var key := [noise_seed, clampi(noise_octaves, 1, 8)]
	if key == _noise_key:
		return
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.frequency = NOISE_PERIOD / NOISE_SIZE
	noise.fractal_octaves = key[1]
	noise.seed = noise_seed
	# No per-tile min/max normalization: changing octaves must not auto-boost contrast.
	_noise_image = noise.get_seamless_image(NOISE_SIZE, NOISE_SIZE, false, false, 0.1, false)
	_noise_texture = null
	_noise_key = key

func noise_texture() -> Texture2D:
	_ensure_noise()
	if _noise_texture == null:
		_noise_texture = ImageTexture.create_from_image(_noise_image)
	return _noise_texture

# Bilinear repeating sampler, matching the fog shader's linear texture lookup.
func _sample_noise(p: Vector2) -> float:
	var pixel := (p * clampf(noise_frequency, 0.001, 8.0) / NOISE_PERIOD).posmod(1.0) * NOISE_SIZE - Vector2.ONE * 0.5
	var cell := Vector2i(floori(pixel.x), floori(pixel.y))
	var f := pixel - Vector2(cell)
	var x0 := posmod(cell.x, NOISE_SIZE)
	var y0 := posmod(cell.y, NOISE_SIZE)
	var x1 := (x0 + 1) % NOISE_SIZE
	var y1 := (y0 + 1) % NOISE_SIZE
	return lerpf(lerpf(_noise_image.get_pixel(x0, y0).r, _noise_image.get_pixel(x1, y0).r, f.x),
		lerpf(_noise_image.get_pixel(x0, y1).r, _noise_image.get_pixel(x1, y1).r, f.x), f.y) * 2.0 - 1.0

## Transient thickness; the resource caches only a box-independent noise tile.
## Natural mist uses the supplied box transform to sample a common world-space field.
func create_thickness(terrain: Image, extent: Vector2, box_transform: Transform3D = Transform3D.IDENTITY) -> Image:
	var amplitude := maxf(noise_amplitude, 0.0)
	if amplitude > 0.0:
		_ensure_noise()
	var image := Image.create(terrain.get_width(), terrain.get_height(), false, Image.FORMAT_RF)
	var direction := Vector2.from_angle(deg_to_rad(wind_direction))
	var across := Vector2(-direction.y, direction.x)
	for z in image.get_height():
		for x in image.get_width():
			var bed := terrain.get_pixel(x, z)
			if bed.g < 0.5:
				continue
			var p := ((Vector2(x, z) + Vector2.ONE * 0.5) / Vector2(image.get_size()) - Vector2.ONE * 0.5) * extent
			if natural_mist_enabled:
				var world := box_transform * Vector3(p.x, 0, p.y)
				p = Vector2(world.x, world.z) + noise_offset
				p = Vector2(p.dot(direction) / clampf(wind_stretch, 1.0, 8.0), p.dot(across))
			else:
				p += noise_offset
			var perturbation := amplitude * _sample_noise(p) if amplitude > 0.0 else 0.0
			var h := base_height + height_offset + perturbation
			if horizontal_top:
				h -= bed.r
			h = maxf(h, 0.0)
			if max_thickness > 0.0:
				h = minf(h, max_thickness)
			image.set_pixel(x, z, Color(h, 0, 0, 1))
	return image

# Read old natural-mist presets without retaining a second, competing noise generator.
func _set(property: StringName, value: Variant) -> bool:
	if property == &"top_variation":
		noise_amplitude = maxf(float(value), 0.0)
		return true
	if property == &"top_scale":
		noise_frequency = 1.0 / maxf(float(value), 0.125)
		return true
	return false
