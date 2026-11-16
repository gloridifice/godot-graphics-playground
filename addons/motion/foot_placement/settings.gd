class_name MotionFootSettings
extends Resource
## Guard rig calibration, in meters. Runtime locks/weights never live in this shared resource.

@export_group("Ground sampling")
@export_flags_3d_physics var collision_mask: int = 1
@export_range(0.1, 1.0, 0.01) var ray_up: float = 0.5
@export_range(0.1, 1.5, 0.01) var ray_down: float = 0.7
@export_range(0.05, 0.6, 0.01) var max_correction: float = 0.42
@export_range(0.0, 60.0, 1.0) var max_ground_angle: float = 50.0
# The imported Foot bone has +Y up, +Z forward; its origin is the ankle, not the sole.
@export var sole_offset := Vector3(0.0, -0.17, 0.08)
@export_range(0.0, 0.05, 0.001) var sole_clearance: float = 0.02
@export_range(0.0, 0.2, 0.01) var sole_half_length: float = 0.1
@export_range(0.01, 0.3, 0.01) var full_ik_distance: float = 0.12

@export_group("Contact and locking")
# Critically damped approach response; target height and weight retain their velocities.
@export_range(1.0, 40.0, 0.5) var approach_speed: float = 14.0
@export_range(0.04, 0.25, 0.01) var contact_duration: float = 0.12
@export_range(1.0, 40.0, 0.5) var release_speed: float = 12.0
@export_range(0.1, 1.0, 0.01) var lock_break_distance: float = 0.6
@export_range(10.0, 120.0, 1.0) var lock_break_angle: float = 65.0
@export_range(0.5, 5.0, 0.1) var teleport_distance: float = 1.0

@export_group("Foot orientation")
@export_range(0.0, 50.0, 1.0) var max_pitch: float = 35.0
@export_range(0.0, 40.0, 1.0) var max_roll: float = 25.0

@export_group("Pelvis reach compensation")
@export_range(0.0, 0.4, 0.01) var max_pelvis_drop: float = 0.25
@export_range(0.1, 5.0, 0.1) var pelvis_speed: float = 1.8
