extends SkeletonModifier3D
## Sample source pose, then decay-track before foot IK; never feed IK back into matching.
var driver: Node
func _process_modification_with_delta(delta: float) -> void:
	if is_instance_valid(driver) and delta > 0.0:
		driver.capture_pose(get_skeleton(), delta)
