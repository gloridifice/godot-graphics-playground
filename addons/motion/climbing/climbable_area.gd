@tool
class_name ClimbableArea3D
extends Area3D
## Shape boundary IS the grasp surface: fit it to visible, solid geometry.
## Layer 3 is query-only; use a separate environment body for blocking collision.

@export var enabled: bool = true
@export_range(0.1, 3.0, 0.05) var speed_scale: float = 1.0
@export_range(0.0, 1.0, 0.05) var max_up_normal: float = 0.35

func _init() -> void:
	collision_layer = 4
	collision_mask = 0
	monitoring = false

func accepts_normal(normal: Vector3) -> bool:
	return enabled and normal.dot(Vector3.UP) <= max_up_normal
