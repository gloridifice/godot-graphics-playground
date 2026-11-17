extends SkeletonModifier3D
## Native TwoBoneIK positions the wrist; this final pass orients the palm.

var driver: MotionClimbing

func _process_modification_with_delta(_delta: float) -> void:
	if driver == null or not driver.is_attached():
		return
	var skeleton := get_skeleton()
	for hand in driver.hands:
		var pose := skeleton.get_bone_global_pose(hand.wrist)
		var desired := skeleton.global_basis.inverse() * hand.goal.basis
		pose.basis = pose.basis.slerp(desired, driver.pose_weight).orthonormalized()
		skeleton.set_bone_global_pose(hand.wrist, pose)
