extends SkeletonModifier3D
## Runs after both native TwoBoneIK3D nodes. IK positions the ankle, not the shoe's orientation.

var driver: SkeletonModifier3D

func _process_modification_with_delta(_delta: float) -> void:
	if is_instance_valid(driver):
		driver.apply_foot_rotations()
