extends AnimatableBody3D
## Physics-driven translation AND rotation exercise platform-local foot anchors.

@export var travel := Vector3(0.9, 0.12, 0.0)
@export var period: float = 6.0
var _origin := Vector3.ZERO
var _time := 0.0

func _ready() -> void:
	_origin = position

func _physics_process(delta: float) -> void:
	_time += delta
	var phase := TAU * _time / maxf(period, 0.1)
	# sync_to_physics defers transforms: separate position/rotation writes would overwrite each other.
	transform = Transform3D(Basis(Vector3.UP, 0.16 * sin(phase)), _origin + travel * sin(phase))
