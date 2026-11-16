extends SkeletonModifier3D
## Ordered before foot placement: search sees animation, never IK-corrected feet.
var driver: Node
func _process_modification_with_delta(delta: float) -> void:
	if is_instance_valid(driver) and delta > 0.0:
		driver.capture_pose(get_skeleton(), delta)
