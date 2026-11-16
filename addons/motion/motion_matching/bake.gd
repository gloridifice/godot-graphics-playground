extends RefCounted
## Build search features from the same retargeted library used by AnimationTree.

static func build(library: AnimationLibrary, model: Node3D, velocities: Dictionary) -> MotionDatabase:
	var database := MotionDatabase.new()
	var skeleton := model.get_node("Skeleton3D") as Skeleton3D
	var contacts := MotionFootPlacement.new()
	contacts.name = "FootPlacement"
	skeleton.add_child(contacts)
	var player := AnimationPlayer.new()
	model.add_child(player)
	player.add_animation_library("", library)
	for name: String in velocities:
		var animation := library.get_animation(name)
		var velocity: Vector3 = velocities[name]
		var count := mini(120 if velocity.is_zero_approx() else 180, maxi(2, ceili(animation.length * 30.0)))
		database.clips.append(name)
		database.lengths.append(animation.length)
		database.crouched.append(1 if name.begins_with("Crouch") else 0)
		database.speeds.append(velocity.length())
		database.starts.append(database.features.size() / MotionDatabase.WIDTH)
		database.counts.append(count)
		player.play(name)
		for frame in count:
			var time := animation.length * frame / count
			var before := _feet(player, skeleton, fposmod(time - 1.0 / 60.0, animation.length))
			var after := _feet(player, skeleton, fposmod(time + 1.0 / 60.0, animation.length))
			var positions := _feet(player, skeleton, time)
			for position in positions:
				database.features.append_array(PackedFloat32Array([position.x, position.y, position.z]))
			for side in 2:
				var speed: Vector3 = (after[side] - before[side]) * 30.0
				database.features.append_array(PackedFloat32Array([speed.x, speed.y, speed.z]))
			database.features.append_array(PackedFloat32Array([velocity.x, velocity.z]))
			for horizon: float in MotionDatabase.HORIZONS:
				database.features.append_array(PackedFloat32Array([velocity.x * horizon, velocity.z * horizon]))
			database.features.append_array(PackedFloat32Array([contacts.left_contact, contacts.right_contact]))
	player.stop()
	player.free()
	contacts.free()
	var rows := database.features.size() / MotionDatabase.WIDTH
	for column in MotionDatabase.WIDTH:
		var mean := 0.0
		for row in rows:
			mean += database.features[row * MotionDatabase.WIDTH + column] / rows
		var variance := 0.0
		for row in rows:
			variance += pow(database.features[row * MotionDatabase.WIDTH + column] - mean, 2.0) / rows
		database.inverse_std.append(1.0 / maxf(sqrt(variance), 0.15 if column < 12 else 0.3))
	return database

static func _feet(player: AnimationPlayer, skeleton: Skeleton3D, time: float) -> Array[Vector3]:
	player.seek(time, true)
	skeleton.force_update_all_bone_transforms()
	return [skeleton.get_bone_global_pose(skeleton.find_bone("LeftFoot")).origin, skeleton.get_bone_global_pose(skeleton.find_bone("RightFoot")).origin]
