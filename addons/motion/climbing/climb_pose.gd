extends SkeletonModifier3D
## Runs after ground modifiers and before both arm solvers. Never moves the capsule.

var driver: MotionClimbing

func _process_modification_with_delta(_delta: float) -> void:
	if driver == null or not driver.is_attached():
		return
	var skeleton := get_skeleton()
	var weight := driver.pose_weight
	var hips := skeleton.find_bone("Hips")
	var pelvis := skeleton.get_bone_pose(hips)
	pelvis.basis = Basis(Quaternion.IDENTITY.slerp(driver.sway_basis.get_rotation_quaternion(), weight)) * pelvis.basis
	skeleton.set_bone_pose(hips, pelvis)
	for side in driver.hands.size():
		var hand := driver.hands[side]
		var shoulder := skeleton.get_bone_pose(hand.shoulder)
		shoulder.basis = Basis(Vector3.BACK, driver.shoulder_lift(side) * weight) * shoulder.basis
		skeleton.set_bone_pose(hand.shoulder, shoulder)
		var upper := skeleton.global_transform * skeleton.get_bone_global_pose(hand.upper)
		var animated := skeleton.global_transform * skeleton.get_bone_global_pose(hand.wrist)
		var wrist := hand.goal.origin - hand.goal.basis * hand.palm_offset
		hand.target.global_position = animated.origin.lerp(wrist, weight)
		# Pole follows the character's frame, never the prior IK's elbow.
		var facing := skeleton.global_basis.z
		var outward := skeleton.global_basis.x * (1.0 if side == 0 else -1.0)
		hand.pole.global_position = upper.origin + facing * 0.55 + outward * 0.25 + Vector3.UP * 0.15
		hand.ik.influence = 1.0
