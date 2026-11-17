class_name MotionClimbSettings
extends Resource
## Guard calibration; runtime anchors and input latches never live in this resource.

@export_flags_3d_physics var surface_mask: int = 4
@export_range(0.2, 2.0, 0.05) var probe_distance: float = 0.95
@export_range(0.1, 1.0, 0.05) var attach_distance: float = 0.5
@export_range(0.05, 0.5, 0.01) var attach_duration: float = 0.18
@export_range(0.1, 1.0, 0.01) var step_distance: float = 0.28
@export_range(0.15, 1.0, 0.01) var step_duration: float = 0.32
@export_range(0.1, 8.0, 0.1) var follow_speed: float = 4.0
@export_range(0.5, 0.98, 0.01) var arm_extension: float = 0.90
@export_range(0.2, 0.6, 0.01) var wall_clearance: float = 0.42
@export_range(0.0, 60.0, 1.0) var shoulder_lift_degrees: float = 35.0
# Guard hands point along +/-X in rest; palm faces -Y. X is mirrored per hand.
@export var palm_offset: Vector3 = Vector3(0.09, -0.025, 0.0)
@export_range(0.0, 12.0, 0.1) var max_sway_degrees: float = 6.0
@export_range(0.1, 20.0, 0.1) var sway_frequency: float = 7.0
@export_range(0.1, 2.0, 0.05) var sway_damping: float = 0.65
