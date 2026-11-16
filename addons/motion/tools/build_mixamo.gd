extends SceneTree
## Rebuild native resources from the bundled, matching Mixamo skeletons.
## godot --headless --path . --script res://addons/motion/tools/build_mixamo.gd

const ROOT := "res://addons/motion/"
const SOURCES := {
	"Idle": "idle", "Walk": "character", "Run": "run", "Jump": "jump",
	"Fall": "fall", "CrouchIdle": "crouch_idle", "CrouchWalk": "crouch_walk",
	"StrafeLeft": "strafe_left", "StrafeRight": "strafe_right", "WalkBack": "walk_back",
}

# Canonical bake speeds; runtime TimeScale adapts to the configured controller speeds.
const LOCOMOTION_SPEEDS := {"Walk": 3.0, "Run": 6.0, "CrouchWalk": 1.4, "StrafeLeft": 3.0, "StrafeRight": 3.0, "WalkBack": 3.0}
const BAKE := preload("res://addons/motion/motion_matching/bake.gd")

func _initialize() -> void:
	_build.call_deferred()

func _build() -> void:
	var library := AnimationLibrary.new()
	var velocities := {"Idle": Vector3.ZERO, "CrouchIdle": Vector3.ZERO}
	var reference := (load(ROOT + "assets/mixamo/character.fbx") as PackedScene).instantiate()
	root.add_child(reference)
	var target_skeleton := reference.get_node("Skeleton3D") as Skeleton3D
	for name: String in SOURCES:
		var source := (load(ROOT + "assets/mixamo/%s.fbx" % SOURCES[name]) as PackedScene).instantiate()
		root.add_child(source)
		var player := source.get_node("AnimationPlayer") as AnimationPlayer
		var animation := player.get_animation("mixamo_com").duplicate() as Animation
		if name in ["Run", "StrafeLeft", "StrafeRight", "WalkBack"]:
			animation = _retarget(source, animation, target_skeleton)
		animation.resource_name = name
		animation.loop_mode = Animation.LOOP_NONE if name == "Jump" else Animation.LOOP_LINEAR
		var travel := Vector2.ZERO
		# Matching bone rests: no runtime retargeter, Blender, or root-motion locomotion.
		for track in range(animation.get_track_count() - 1, -1, -1):
			var path := animation.track_get_path(track)
			if path.get_concatenated_names() != "Skeleton3D" or path.get_subname_count() != 1:
				animation.remove_track(track)
				continue
			if animation.track_get_type(track) == Animation.TYPE_POSITION_3D and path.get_subname(0) == "Hips":
				var rest := target_skeleton.get_bone_rest(target_skeleton.find_bone("Hips")).origin
				var first: Vector3 = animation.track_get_key_value(track, 0)
				var last: Vector3 = animation.track_get_key_value(track, animation.track_get_key_count(track) - 1)
				travel = Vector2(last.x - first.x, last.z - first.z)
				for key in animation.track_get_key_count(track):
					var position: Vector3 = animation.track_get_key_value(track, key)
					position.x = rest.x
					position.z = rest.z
					# Airborne height belongs exclusively to CharacterBody3D gravity.
					if name in ["Jump", "Fall"]:
						position.y = rest.y
					animation.track_set_key_value(track, key, position)
		if name == "Run" and travel.length() < 0.01:
			# User's Run Forward is in-place: recover its stride from planted-foot motion.
			travel = Vector2(0.0, _in_place_stride(animation, reference))
		if name in LOCOMOTION_SPEEDS and travel.length() > 0.01:
			_retime(animation, travel.length() / LOCOMOTION_SPEEDS[name] / animation.length)
		if name in LOCOMOTION_SPEEDS:
			velocities[name] = Vector3(travel.x, 0, travel.y).normalized() * LOCOMOTION_SPEEDS[name]
		_add_contacts(name, animation, reference)
		if name == "Walk":
			library.add_animation("RESET", _reset_pose(target_skeleton))
		if library.add_animation(name, animation) != OK:
			quit(1)
			return
		source.free()
	if ResourceSaver.save(library, ROOT + "animations/mixamo.res", ResourceSaver.FLAG_COMPRESS) != OK:
		quit(1)
		return

	var machine := AnimationNodeStateMachine.new()
	machine.add_node("Grounded", _ground_tree(), Vector2(330, 100))
	machine.add_node("Crouch", _matching_tree("CrouchIdle"), Vector2(330, 290))
	machine.add_node("Jump", _clip("Jump"), Vector2(570, 100))
	machine.add_node("Fall", _clip("Fall"), Vector2(570, 290))
	machine.set_node_position("Start", Vector2(100, 100))
	var start := AnimationNodeStateMachineTransition.new()
	start.advance_mode = AnimationNodeStateMachineTransition.ADVANCE_MODE_AUTO
	machine.add_transition("Start", "Grounded", start)
	for from: String in ["Grounded", "Crouch", "Jump", "Fall"]:
		for to: String in ["Grounded", "Crouch", "Jump", "Fall"]:
			if from == to:
				continue
			var transition := AnimationNodeStateMachineTransition.new()
			transition.xfade_time = 0.12
			machine.add_transition(from, to, transition)
	if ResourceSaver.save(machine, ROOT + "animations/locomotion.tres") != OK:
		quit(1)
		return
	var database := BAKE.build(library, reference, velocities)
	if ResourceSaver.save(database, ROOT + "motion_matching/guard.res", ResourceSaver.FLAG_COMPRESS) != OK:
		quit(1)
		return
	reference.free()
	var model := (load(ROOT + "assets/mixamo/character.fbx") as PackedScene).instantiate()
	model.name = "Guard"
	model.get_node("AnimationPlayer").free()
	for mesh: MeshInstance3D in model.find_children("*", "MeshInstance3D", true, false):
		var material := mesh.get_active_material(0).duplicate() as StandardMaterial3D
		material.albedo_texture = load(ROOT + "assets/mixamo/Guard Texture.png")
		material.roughness = 0.85
		mesh.material_override = material
	var packed := PackedScene.new()
	if packed.pack(model) != OK or ResourceSaver.save(packed, ROOT + "assets/guard.scn", ResourceSaver.FLAG_COMPRESS) != OK:
		model.free()
		quit(1)
		return
	model.free()
	print("Motion: rebuilt model, retargeted animations, native matching slots and ", database.features.size() / MotionDatabase.WIDTH, " motion-matching frames.")
	quit()

func _retarget(source: Node3D, original: Animation, target: Skeleton3D) -> Animation:
	# Rest-space rotation mapping, rather than copying Charlotte's local rotations/limb lengths.
	var skeleton := source.get_node("Skeleton3D") as Skeleton3D
	var player := source.get_node("AnimationPlayer") as AnimationPlayer
	player.play("mixamo_com")
	var result := Animation.new()
	result.length = original.length
	var mapping: Array[int] = []
	for bone in target.get_bone_count():
		var name := target.get_bone_name(bone)
		var index := skeleton.find_bone(name)
		if index < 0:
			# Mixamo exports can carry different namespace suffixes (mixamorig_, mixamorig1_...).
			for candidate in skeleton.get_bone_count():
				if skeleton.get_bone_name(candidate).ends_with("_" + name):
					index = candidate
					break
		mapping.append(index)
		var track := result.add_track(Animation.TYPE_ROTATION_3D)
		result.track_set_path(track, NodePath("Skeleton3D:" + name))
	var hips := target.find_bone("Hips")
	var source_hips := mapping[hips]
	var ratio := target.get_bone_global_rest(hips).origin.y / skeleton.get_bone_global_rest(source_hips).origin.y
	var position_track := result.add_track(Animation.TYPE_POSITION_3D)
	result.track_set_path(position_track, NodePath("Skeleton3D:Hips"))
	var count := ceili(original.length * 60.0)
	for frame in count + 1:
		var time := original.length * frame / count
		player.seek(time, true)
		skeleton.force_update_all_bone_transforms()
		var rotations: Array[Quaternion] = []
		for bone in target.get_bone_count():
			var rest := target.get_bone_global_rest(bone).basis.get_rotation_quaternion()
			var index := mapping[bone]
			var rotation := rest
			if index >= 0:
				rotation = skeleton.get_bone_global_pose(index).basis.get_rotation_quaternion() * skeleton.get_bone_global_rest(index).basis.get_rotation_quaternion().inverse() * rest
			rotations.append(rotation.normalized())
			var parent := target.get_bone_parent(bone)
			var local := rotations[parent].inverse() * rotation if parent >= 0 else rotation
			result.rotation_track_insert_key(bone, time, local.normalized())
		var delta := skeleton.get_bone_pose_position(source_hips) - skeleton.get_bone_rest(source_hips).origin
		result.position_track_insert_key(position_track, time, target.get_bone_rest(hips).origin + delta * ratio)
	player.stop()
	return result

func _in_place_stride(animation: Animation, model: Node3D) -> float:
	var skeleton := model.get_node("Skeleton3D") as Skeleton3D
	var player := model.get_node("AnimationPlayer") as AnimationPlayer
	var library := AnimationLibrary.new()
	library.add_animation("pose", animation)
	player.add_animation_library("stride_bake", library)
	player.play("stride_bake/pose")
	var sole := (load(ROOT + "foot_placement/guard.tres") as MotionFootSettings).sole_offset
	var samples: Array[PackedVector3Array] = [PackedVector3Array(), PackedVector3Array()]
	var count := ceili(animation.length * 120.0)
	for frame in count + 1:
		player.seek(minf(animation.length - 0.00001, animation.length * frame / count), true)
		skeleton.force_update_all_bone_transforms()
		for side in 2:
			samples[side].append(skeleton.get_bone_global_pose(skeleton.find_bone("LeftFoot" if side == 0 else "RightFoot")) * sole)
	var total_speed := 0.0
	var total_weight := 0.0
	for points in samples:
		var floor_y := INF
		for point in points:
			floor_y = minf(floor_y, point.y)
		for frame in range(1, points.size()):
			var speed := -(points[frame].z - points[frame - 1].z) * count / animation.length
			var weight := 1.0 - smoothstep(floor_y + 0.015, floor_y + 0.055, (points[frame].y + points[frame - 1].y) * 0.5)
			if speed > 0.05:
				total_speed += speed * weight
				total_weight += weight
	player.stop()
	player.remove_animation_library("stride_bake")
	assert(total_weight > 0.01, "In-place Run needs usable planted-foot motion for stride calibration.")
	var stride := total_speed / total_weight * animation.length
	print("Motion: in-place Run stride=", stride, "m, calibrated duration=", stride / LOCOMOTION_SPEEDS.Run, "s")
	return stride

func _reset_pose(skeleton: Skeleton3D) -> Animation:
	var reset := Animation.new()
	reset.length = 0.001
	for bone in skeleton.get_bone_count():
		var rest := skeleton.get_bone_rest(bone)
		var path := NodePath("Skeleton3D:" + skeleton.get_bone_name(bone))
		var position := reset.add_track(Animation.TYPE_POSITION_3D)
		reset.track_set_path(position, path)
		reset.position_track_insert_key(position, 0.0, rest.origin)
		var rotation := reset.add_track(Animation.TYPE_ROTATION_3D)
		reset.track_set_path(rotation, path)
		reset.rotation_track_insert_key(rotation, 0.0, rest.basis.get_rotation_quaternion())
		var scale := reset.add_track(Animation.TYPE_SCALE_3D)
		reset.track_set_path(scale, path)
		reset.scale_track_insert_key(scale, 0.0, rest.basis.get_scale())
	for side in ["left", "right"]:
		var contact := reset.add_track(Animation.TYPE_VALUE)
		reset.track_set_path(contact, NodePath("Skeleton3D/FootPlacement:%s_contact" % side))
		reset.track_insert_key(contact, 0.0, 0.0)
	return reset

func _retime(animation: Animation, ratio: float) -> void:
	for track in animation.get_track_count():
		var keys: Array = []
		for key in animation.track_get_key_count(track):
			keys.append([animation.track_get_key_time(track, key) * ratio, animation.track_get_key_value(track, key), animation.track_get_key_transition(track, key)])
		for key in range(animation.track_get_key_count(track) - 1, -1, -1):
			animation.track_remove_key(track, key)
		for key: Array in keys:
			animation.track_insert_key(track, key[0], key[1], key[2])
	animation.length *= ratio

func _add_contacts(name: String, animation: Animation, source: Node3D) -> void:
	var player := source.get_node("AnimationPlayer") as AnimationPlayer
	var skeleton := source.get_node("Skeleton3D") as Skeleton3D
	var temporary := AnimationLibrary.new()
	temporary.add_animation("pose", animation)
	player.add_animation_library("contact_bake", temporary)
	player.play("contact_bake/pose")
	var calibration := load(ROOT + "foot_placement/guard.tres") as MotionFootSettings
	var count := maxi(2, ceili(animation.length * 60.0))
	var heights: Array[PackedFloat32Array] = [PackedFloat32Array(), PackedFloat32Array()]
	for frame in count + 1:
		player.seek(minf(animation.length - 0.00001, animation.length * frame / count), true)
		skeleton.force_update_all_bone_transforms()
		for side in 2:
			var bone := skeleton.find_bone("LeftFoot" if side == 0 else "RightFoot")
			heights[side].append((skeleton.get_bone_global_pose(bone) * calibration.sole_offset).y)
	player.stop()
	for side in 2:
		var track := animation.add_track(Animation.TYPE_VALUE)
		animation.track_set_path(track, NodePath("Skeleton3D/FootPlacement:%s_contact" % ("left" if side == 0 else "right")))
		animation.value_track_set_update_mode(track, Animation.UPDATE_CONTINUOUS)
		var floor_height: float = heights[side][0]
		for height in heights[side]:
			floor_height = minf(floor_height, height)
		for frame in count + 1:
			var contact := 1.0 - smoothstep(floor_height + 0.015, floor_height + 0.055, heights[side][frame])
			if name in ["Jump", "Fall"]:
				contact = 0.0
			elif name in ["Idle", "CrouchIdle"]:
				contact = 1.0
			# Close the periodic curve explicitly; no frame-zero seam at loop boundaries.
			if frame == count and animation.loop_mode != Animation.LOOP_NONE:
				contact = animation.track_get_key_value(track, 0)
			animation.track_insert_key(track, animation.length * frame / count, contact)
	player.remove_animation_library("contact_bake")

func _ground_tree() -> AnimationNodeBlendTree:
	var tree := AnimationNodeBlendTree.new()
	tree.add_node("Walk", _matching_tree("Idle"), Vector2(0, 0))
	tree.add_node("Run", _matching_tree("Run"), Vector2(0, 200))
	var speed := AnimationNodeBlend2.new()
	# Keep the zero-weight gait advancing, so entering the blend never resumes a stale frame.
	speed.sync = true
	tree.add_node("Speed", speed, Vector2(250, 100))
	tree.connect_node("Speed", 0, "Walk")
	tree.connect_node("Speed", 1, "Run")
	tree.connect_node("output", 0, "Speed")
	tree.set_node_position("output", Vector2(500, 100))
	return tree

func _matching_tree(idle: String) -> AnimationNodeBlendTree:
	var tree := AnimationNodeBlendTree.new()
	for index in 2:
		var slot := "A" if index == 0 else "B"
		var y := index * 200.0
		tree.add_node(slot + "Clip", _clip(idle), Vector2(0, y))
		tree.add_node(slot + "Seek", AnimationNodeTimeSeek.new(), Vector2(200, y))
		tree.add_node(slot + "Rate", AnimationNodeTimeScale.new(), Vector2(400, y))
		tree.connect_node(slot + "Seek", 0, slot + "Clip")
		tree.connect_node(slot + "Rate", 0, slot + "Seek")
	var mix := AnimationNodeBlend2.new()
	mix.sync = true
	tree.add_node("Mix", mix, Vector2(600, 100))
	tree.set_node_position("output", Vector2(850, 100))
	tree.connect_node("Mix", 0, "ARate")
	tree.connect_node("Mix", 1, "BRate")
	tree.connect_node("output", 0, "Mix")
	return tree

func _clip(name: StringName) -> AnimationNodeAnimation:
	var node := AnimationNodeAnimation.new()
	node.animation = name
	return node
