class_name MotionMatcher
extends Node
## Axis-constrained pose searches, phase-synced direction/speed mixing, then native IK.

@export var database: MotionDatabase
@export_range(0.03, 0.5, 0.01) var search_interval := 0.1
@export_range(0.05, 0.35, 0.01) var crossfade_time := 0.12
@export_group("Pose Tracking")
## Smooth the evaluated locomotion pose after source sampling, before IK; never move the body.
@export var pose_smoothing_enabled := true:
	set(value):
		if pose_smoothing_enabled != value:
			pose_smoothing_enabled = value
			_tracked_pose.clear()
## Seconds for the remaining pose error to halve. Zero bypasses smoothing.
@export_range(0.0, 0.3, 0.005, "suffix:s") var pose_half_life := 0.06
const POSE_SAMPLE := preload("res://addons/motion/motion_matching/pose_sample.gd")

# A channel owns its match jumps; the separate Speed node blends whole walk/run channels.
class Channel:
	var tree: AnimationTree
	var graph: AnimationNodeBlendTree
	var path: String
	var clip := -1
	var time := 0.0
	var rate := 1.0
	var cost := 0.0
	var active := 0
	var mix := 0.0
	var mix_from := 0.0
	var blend_age := 10.0
	var search_age := 10.0
	var time_advanced := false

	func _init(owner_tree: AnimationTree, node: AnimationNodeBlendTree, parameter_path: String) -> void:
		tree = owner_tree
		graph = node
		path = "parameters/" + parameter_path + "/"

	func reset() -> void:
		clip = -1
		active = 0
		mix = 0.0
		mix_from = 0.0
		blend_age = 10.0
		search_age = 10.0
		tree.set(path + "Mix/blend_amount", 0.0)

	func advance(delta: float, db: MotionDatabase, query: PackedFloat32Array, nominal: float, scale: float, crouch: bool, allow_idle: bool, interval: float, crossfade: float, direction: Vector2 = Vector2.ZERO) -> void:
		search_age += delta
		blend_age += delta
		var sought := false
		if clip < 0 or (search_age >= interval and blend_age >= crossfade):
			var found := db.nearest(query, crouch, nominal, clip, time, allow_idle, nominal, direction)
			cost = found.cost
			search_age = 0.0
			var distance: float = absf(found.time - time)
			if clip >= 0 and found.clip == clip:
				distance = minf(distance, db.lengths[clip] - distance)
			if clip < 0 or found.clip != clip or distance > 0.18:
				seek(db, found.clip, found.time, crossfade)
				sought = true
		rate = clampf(nominal / db.speeds[clip], 0.5, 2.0) * scale if db.speeds[clip] > 0.0 else 1.0
		tree.set(path + ("A" if active == 0 else "B") + "Rate/scale", rate)
		mix = lerpf(mix_from, float(active), clampf(blend_age / crossfade, 0.0, 1.0))
		tree.set(path + "Mix/blend_amount", mix)
		time_advanced = not sought
		if time_advanced: time = fposmod(time + delta * rate, db.lengths[clip])

	func seek(db: MotionDatabase, next_clip: int, next_time: float, crossfade: float) -> void:
		if clip >= 0: active = 1 - active
		mix_from = mix
		blend_age = 0.0 if clip >= 0 else crossfade
		clip = next_clip
		time = fposmod(next_time, db.lengths[clip])
		time_advanced = false
		var slot := "A" if active == 0 else "B"
		(graph.get_node(slot + "Clip") as AnimationNodeAnimation).animation = db.clips[clip]
		tree.set(path + slot + "Seek/seek_request", time)
		tree.set(path + slot + "Rate/scale", rate)
		mix = mix_from if blend_age < crossfade else float(active)
		tree.set(path + "Mix/blend_amount", mix)

	func retime(delta: float, next_rate: float, length: float) -> void:
		if time_advanced: time = fposmod(time + delta * (next_rate - rate), length)
		rate = next_rate
		tree.set(path + ("A" if active == 0 else "B") + "Rate/scale", rate)

	func describe(db: MotionDatabase, crossfade: float) -> Dictionary:
		return {"clip": db.clips[clip] if clip >= 0 else "", "time": time, "rate": rate, "cost": cost, "blending": blend_age < crossfade}

var _tree: AnimationTree
var _feet: MotionFootPlacement
var _walk: Channel
var _run: Channel
var _walk_side: Channel
var _run_side: Channel
var _crouch: Channel
var _state: StringName
var _run_blend := 0.0
var _direction_blend := 0.0
var _forward_axis := Vector2(0, 1)
var _side_axis := Vector2(1, 0)
var _pose := PackedFloat32Array()
var _previous: Array[Vector3] = []
var _trajectory := PackedVector3Array()
var _plant_offsets := PackedFloat32Array()
# Local pre-IK poses only: feeding final locked feet back here would accumulate IK.
var _tracked_pose: Array[Transform3D] = []
# Same two database feature axes for the runtime diagram, captured before any IK.
var _target_projection := Vector2.ZERO
var _current_projection := Vector2.ZERO

func bind(tree: AnimationTree, skeleton: Skeleton3D, feet: MotionFootPlacement) -> void:
	_tree = tree
	_feet = feet
	_plant_offsets.clear()
	for clip in database.clips.size(): _plant_offsets.append(_plant_offset(clip))
	# Animation names are mutable slots; never edit the scene's shared node resources.
	_tree.tree_root = _tree.tree_root.duplicate(true)
	var machine := _tree.tree_root as AnimationNodeStateMachine
	var ground := machine.get_node("Grounded") as AnimationNodeBlendTree
	_walk = Channel.new(tree, ground.get_node("Walk"), "Grounded/Walk")
	_run = Channel.new(tree, ground.get_node("Run"), "Grounded/Run")
	_walk_side = Channel.new(tree, ground.get_node("WalkSide"), "Grounded/WalkSide")
	_run_side = Channel.new(tree, ground.get_node("RunSide"), "Grounded/RunSide")
	_crouch = Channel.new(tree, machine.get_node("Crouch"), "Crouch")
	var sampler := POSE_SAMPLE.new()
	sampler.name = "MotionPoseSample"
	sampler.driver = self
	skeleton.add_child(sampler)
	skeleton.move_child(sampler, 0)

func reset() -> void:
	_state = &""
	_run_blend = 0.0
	_direction_blend = 0.0
	_forward_axis = Vector2(0, 1)
	_side_axis = Vector2(1, 0)
	_previous.clear()
	_pose.clear()
	_tracked_pose.clear()
	_target_projection = Vector2.ZERO
	_current_projection = Vector2.ZERO
	for channel in [_walk, _run, _walk_side, _run_side, _crouch]:
		if channel != null: channel.reset()

func capture_pose(skeleton: Skeleton3D, delta: float) -> void:
	_pose.clear()
	var positions: Array[Vector3] = []
	for name in ["LeftFoot", "RightFoot"]:
		var position := skeleton.get_bone_global_pose(skeleton.find_bone(name)).origin
		positions.append(position)
		_pose.append_array(PackedFloat32Array([position.x, position.y, position.z]))
	for side in 2:
		var velocity := ((positions[side] - _previous[side]) / delta).limit_length(12.0) if _previous.size() == 2 else Vector3.ZERO
		_pose.append_array(PackedFloat32Array([velocity.x, velocity.y, velocity.z]))
	_previous = positions
	_target_projection = Vector2(positions[0].z, positions[1].z)
	_track_pose(skeleton, delta)
	_current_projection = Vector2(skeleton.get_bone_global_pose(skeleton.find_bone("LeftFoot")).origin.z, skeleton.get_bone_global_pose(skeleton.find_bone("RightFoot")).origin.z)

func _track_pose(skeleton: Skeleton3D, delta: float) -> void:
	if not pose_smoothing_enabled or pose_half_life <= 0.0 or _state not in [&"Grounded", &"Crouch"]:
		_tracked_pose.clear()
		return
	var count := skeleton.get_bone_count()
	if _tracked_pose.size() != count:
		_tracked_pose.clear()
		for bone in count: _tracked_pose.append(skeleton.get_bone_pose(bone))
		return
	# p follows the moving animation target P, not just a match-switch snapshot.
	# Exponential decay gives the same half-life at any physics tick rate.
	var weight := 1.0 - exp(-log(2.0) * maxf(delta, 0.0) / pose_half_life)
	for bone in count:
		var target := skeleton.get_bone_pose(bone)
		_tracked_pose[bone] = _tracked_pose[bone].interpolate_with(target, weight)
		skeleton.set_bone_pose(bone, _tracked_pose[bone])

func update(delta: float, state: StringName, velocity: Vector3, desired: Vector3, facing: Basis, acceleration: float, walk_speed: float, run_speed: float, crouch_speed: float = 1.4) -> void:
	var changed := _state != state
	_state = state
	if state not in [&"Grounded", &"Crouch"]:
		_tracked_pose.clear()
		return
	_trajectory = _predict(velocity, desired, acceleration)
	if state == &"Crouch":
		if changed: _crouch.reset()
		var scale := crouch_speed / 1.4
		_crouch.advance(delta, database, _query(velocity, desired, facing, acceleration, scale), 1.4, scale, true, true, search_interval, crossfade_time)
		return
	if changed:
		_walk.reset()
		_run.reset()
		_walk_side.reset()
		_run_side.reset()
	# The key only affects the physics target. Animation weights use collision-resolved,
	# platform-relative velocity: acceleration, deceleration and partial input all blend.
	var speed := Vector2(velocity.x, velocity.z).length()
	_run_blend = clampf((speed - walk_speed) / maxf(run_speed - walk_speed, 0.01), 0.0, 1.0)
	_tree.set("parameters/Grounded/Speed/blend_amount", _run_blend)
	# Blend axes using actual model-space travel, not the input target (walls and
	# braking may disagree with it). Retain axis signs at zero to avoid idle flips.
	var local := facing.inverse() * velocity
	if absf(local.z) > 0.001: _forward_axis.y = signf(local.z)
	if absf(local.x) > 0.001: _side_axis.x = signf(local.x)
	_direction_blend = absf(local.x) / (absf(local.x) + absf(local.z)) if speed > 0.01 else 0.0
	for gait in ["Walk", "Run"]:
		_tree.set("parameters/Grounded/" + gait + "Direction/blend_amount", _direction_blend)
	var walk_scale := walk_speed / 3.0
	var run_scale := run_speed / 6.0
	var walk_query := _query(velocity.limit_length(walk_speed), desired.limit_length(walk_speed), facing, acceleration, walk_scale)
	var run_query := _query(velocity, desired, facing, acceleration, run_scale)
	_walk.advance(delta, database, walk_query, 3.0, walk_scale, false, speed < walk_speed * 0.9, search_interval, crossfade_time, _forward_axis)
	_run.advance(delta, database, run_query, 6.0, run_scale, false, false, search_interval, crossfade_time, _forward_axis)
	_walk_side.advance(delta, database, walk_query, 3.0, walk_scale, false, speed < walk_speed * 0.9, search_interval, crossfade_time, _side_axis)
	_run_side.advance(delta, database, run_query, 6.0, run_scale, false, false, search_interval, crossfade_time, _side_axis)
	_sync_gaits(delta, speed)

func _sync_gaits(delta: float, speed: float) -> void:
	if speed < 0.01: return
	var channels: Array[Channel] = [_walk, _walk_side, _run, _run_side]
	var weights := [(1.0 - _run_blend) * (1.0 - _direction_blend), (1.0 - _run_blend) * _direction_blend, _run_blend * (1.0 - _direction_blend), _run_blend * _direction_blend]
	var master: Channel = channels[weights.find(weights.max())]
	if database.speeds[master.clip] <= 0.0: return
	# Direction mixing shortens net travel per cycle: two perpendicular half-strides
	# are not a full forward stride. Blend stride VECTORS before deriving cadence.
	var stride := Vector2.ZERO
	for index in channels.size():
		var channel := channels[index]
		var row := database.starts[channel.clip] * MotionDatabase.WIDTH
		var velocity := Vector2(database.features[row + 12], database.features[row + 13])
		stride += velocity * database.lengths[channel.clip] * weights[index]
	var frequency := speed / maxf(stride.length(), 0.01)
	for channel in channels:
		if database.speeds[channel.clip] > 0.0:
			channel.retime(delta, database.lengths[channel.clip] * frequency, database.lengths[channel.clip])
	var phase := fposmod(master.time / database.lengths[master.clip] - _plant_offsets[master.clip], 1.0)
	for slave in channels:
		if slave == master or database.speeds[slave.clip] <= 0.0: continue
		var slave_phase := fposmod(slave.time / database.lengths[slave.clip] - _plant_offsets[slave.clip], 1.0)
		var difference := absf(phase - slave_phase)
		if minf(difference, 1.0 - difference) > 0.06 and slave.blend_age >= crossfade_time:
			# Correct through A/B crossfade, never seek a visible active slot.
			slave.seek(database, slave.clip, fposmod(phase + _plant_offsets[slave.clip], 1.0) * database.lengths[slave.clip], crossfade_time)

func _plant_offset(clip: int) -> float:
	var first := database.starts[clip]
	var count := database.counts[clip]
	for frame in count:
		var previous := first + (frame + count - 1) % count
		var current := first + frame
		var before := database.features[previous * MotionDatabase.WIDTH + 20]
		var after := database.features[current * MotionDatabase.WIDTH + 20]
		if before < 0.5 and after >= 0.5:
			var crossing := float((frame + count - 1) % count) + (0.5 - before) / (after - before)
			return fposmod(crossing / count, 1.0)
	return 0.0

func _query(velocity: Vector3, desired: Vector3, facing: Basis, acceleration: float, scale: float) -> PackedFloat32Array:
	var query := _pose.duplicate() if _pose.size() == 12 else PackedFloat32Array([0.1, 0.2, 0, -0.1, 0.2, 0, 0, 0, 0, 0, 0, 0])
	for index in range(6, 12): query[index] /= scale
	var local := facing.inverse() * velocity / scale
	query.append_array(PackedFloat32Array([local.x, local.z]))
	for offset in _predict(velocity, desired, acceleration):
		var future := facing.inverse() * offset / scale
		query.append_array(PackedFloat32Array([future.x, future.z]))
	query.append_array(PackedFloat32Array([_feet.left_contact, _feet.right_contact]))
	return query

func _predict(velocity: Vector3, desired: Vector3, acceleration: float) -> PackedVector3Array:
	var result := PackedVector3Array()
	var predicted := velocity
	var offset := Vector3.ZERO
	var elapsed := 0.0
	for horizon: float in MotionDatabase.HORIZONS:
		while elapsed < horizon - 0.0001:
			var step := minf(1.0 / 30.0, horizon - elapsed)
			predicted = predicted.move_toward(desired, acceleration * step)
			offset += predicted * step
			elapsed += step
		result.append(offset)
	return result

func _describe_gait(forward: Channel, side: Channel) -> Dictionary:
	var longitudinal := forward.describe(database, crossfade_time)
	var lateral := side.describe(database, crossfade_time)
	var result := (lateral if _direction_blend >= 0.5 else longitudinal).duplicate()
	result.blending = (_direction_blend > 0.001 and _direction_blend < 0.999) or (longitudinal.blending and _direction_blend < 0.999) or (lateral.blending and _direction_blend > 0.001)
	result.merge({"longitudinal": longitudinal, "lateral": lateral, "direction_blend": _direction_blend})
	return result

func get_debug_state() -> Dictionary:
	var walk := _describe_gait(_walk, _walk_side)
	var run := _describe_gait(_run, _run_side)
	var primary := _crouch.describe(database, crossfade_time) if _state == &"Crouch" else (run if _run_blend >= 0.5 else walk)
	var result := primary.duplicate()
	if _state == &"Grounded":
		result.blending = (_run_blend > 0.001 and _run_blend < 0.999) or (walk.blending and _run_blend < 0.999) or (run.blending and _run_blend > 0.001)
	result.merge({"state": _state, "run_blend": _run_blend, "walk": walk, "run": run, "trajectory": _trajectory.duplicate(), "pose_target": _target_projection, "pose_current": _current_projection, "pose_available": _pose.size() == 12})
	return result
