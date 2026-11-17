class_name MotionClimbing
extends Node
## Physics owns the body; surface-local palms constrain the root before arm IK.

@export var settings: MotionClimbSettings
@export var enabled: bool = true

class Hand:
	var shoulder: int
	var upper: int
	var elbow: int
	var wrist: int
	var length: float
	var shoulder_offset: Vector3
	var palm_offset: Vector3
	var local_grip := Transform3D.IDENTITY
	var goal := Transform3D.IDENTITY
	var ik: TwoBoneIK3D
	var target: Node3D
	var pole: Node3D

var hands: Array[Hand] = []
var pose_weight: float = 0.0
var sway_basis := Basis.IDENTITY
var _body: CharacterBody3D
var _visual: Node3D
var _skeleton: Skeleton3D
var _collision: CollisionShape3D
var _support: WeakRef
var _attached := false
var _blocked_until_grounded := false
var _local_facing := Vector3.ZERO
var _normal := Vector3.DOWN
var _age := 0.0
var _swing_hand := -1
var _next_hand := 0
var _swing_time := 0.0
var _swing_from := Transform3D.IDENTITY
var _swing_to := Transform3D.IDENTITY
var _last_position := Vector3.ZERO
var _last_relative_velocity := Vector3.ZERO
var _support_center := Vector3.ZERO
var _sway := Vector3.ZERO
var _sway_velocity := Vector3.ZERO
var _saved_snap := 0.0
var _pelvis := Vector3.ZERO

func bind(body: CharacterBody3D, visual: Node3D, skeleton: Skeleton3D, collision: CollisionShape3D) -> void:
	_body = body
	_visual = visual
	_skeleton = skeleton
	_collision = collision
	if settings == null:
		push_error("Motion climbing requires settings and a calibrated Guard skeleton.")
		enabled = false
		return
	_pelvis = skeleton.get_bone_global_rest(skeleton.find_bone("Hips")).origin
	for side in 2:
		var prefix := "Left" if side == 0 else "Right"
		var hand := Hand.new()
		hand.shoulder = skeleton.find_bone(prefix + "Shoulder")
		hand.upper = skeleton.find_bone(prefix + "Arm")
		hand.elbow = skeleton.find_bone(prefix + "ForeArm")
		hand.wrist = skeleton.find_bone(prefix + "Hand")
		if mini(mini(hand.shoulder, hand.upper), mini(hand.elbow, hand.wrist)) < 0:
			push_error("Motion climbing requires the Guard arm chain: " + prefix)
			hands.clear()
			return
		hand.length = skeleton.get_bone_rest(hand.elbow).origin.length() + skeleton.get_bone_rest(hand.wrist).origin.length()
		var lift := Basis(Vector3.BACK, shoulder_lift(side))
		hand.shoulder_offset = skeleton.get_bone_global_rest(hand.shoulder).origin + lift * skeleton.get_bone_rest(hand.upper).origin
		hand.palm_offset = settings.palm_offset
		hand.palm_offset.x *= 1.0 if side == 0 else -1.0
		hand.target = Node3D.new()
		hand.target.name = prefix + "HandTarget"
		add_child(hand.target)
		hand.pole = Node3D.new()
		hand.pole.name = prefix + "ElbowPole"
		add_child(hand.pole)
		hand.ik = TwoBoneIK3D.new()
		hand.ik.name = prefix + "ArmIK"
		hand.ik.influence = 0.0
		skeleton.add_child(hand.ik)
		hand.ik.set_setting_count(1)
		hand.ik.set_root_bone(0, hand.upper)
		hand.ik.set_middle_bone(0, hand.elbow)
		hand.ik.set_end_bone(0, hand.wrist)
		hand.ik.set_target_node(0, hand.ik.get_path_to(hand.target))
		hand.ik.set_pole_node(0, hand.ik.get_path_to(hand.pole))
		hand.ik.set_pole_direction_vector(0, Vector3.BACK)
		hands.append(hand)
	_last_position = body.global_position

func shoulder_lift(side: int) -> float:
	return deg_to_rad(settings.shoulder_lift_degrees) * (1.0 if side == 0 else -1.0)

func is_attached() -> bool:
	return _attached

func is_blocked_until_grounded() -> bool:
	return _blocked_until_grounded

func release_from_input() -> void:
	# Only an ESC while actually attached consumes this airborne opportunity.
	if _attached:
		_blocked_until_grounded = true
		_detach()

func reset() -> void:
	_detach()
	_blocked_until_grounded = false
	_last_position = _body.global_position

func physics_step(delta: float, direction: Vector3) -> bool:
	if _body.global_position.distance_to(_last_position) > 1.0:
		reset()
	_last_position = _body.global_position
	# Real contact, not the speed-filtered landed signal (soft landings count too).
	if _body.is_on_floor():
		_blocked_until_grounded = false
		if _attached: _detach()
	if Input.is_action_just_pressed("release_mouse"):
		release_from_input()
	if not enabled or hands.size() != 2:
		_detach()
	if not _attached:
		return false
	var area := _area()
	if area == null or not area.enabled or area.global_basis.y.dot(Vector3.UP) < 0.95:
		_detach()
		return false
	_age += delta
	pose_weight = smoothstep(0.0, settings.attach_duration, _age)
	var forward := area.global_basis * _local_facing
	_visual.global_rotation.y = atan2(forward.x, forward.z)
	_update_goals(area)
	for side in 2:
		if side != _swing_hand and not _valid_grip(area, hands[side].goal):
			_detach()
			return false
	if _swing_hand >= 0:
		_swing_time = minf(_swing_time + delta * area.speed_scale / settings.step_duration, 1.0)
		var grip := _swing_from.interpolate_with(_swing_to, smoothstep(0.0, 1.0, _swing_time))
		grip.origin += _swing_from.basis.y * sin(PI * _swing_time) * 0.07
		hands[_swing_hand].goal = area.global_transform * grip
		if _swing_time >= 1.0:
			if not _valid_grip(area, hands[_swing_hand].goal):
				_detach()
				return false
			hands[_swing_hand].local_grip = _swing_to
			_next_hand = 1 - _swing_hand
			_swing_hand = -1
	elif _age > settings.attach_duration and not direction.is_zero_approx():
		_plan_step(area, direction)
	_update_sway(delta, area)
	var desired := _root_goal()
	_body.velocity = (desired - _body.global_position).limit_length(settings.follow_speed * delta) / delta
	return true

func after_move() -> void:
	if _body.is_on_floor():
		if _attached: _detach()
		_blocked_until_grounded = false
		return
	if not _attached:
		return
	# Never stretch a planted arm to hide a body collision or disappearing support.
	if _age > settings.attach_duration:
		for hand in hands:
			var shoulder := _body.global_position + _world_shoulder_offset(hand)
			if shoulder.distance_to(_wrist_goal(hand).origin) > hand.length * 1.025:
				_detach()
				return

func try_attach() -> void:
	if _attached or _blocked_until_grounded or not enabled or hands.size() != 2 or _body.is_on_floor() or _body.is_crouching():
		return
	# Both hands must find the same surface with compatible normals.
	var forward := _visual.global_basis.z
	for ray_direction: Vector3 in [Vector3.UP, (Vector3.UP + forward * 0.9).normalized()]:
		var hits: Array[Dictionary] = []
		for hand in hands:
			var origin := _body.global_position + _world_shoulder_offset(hand)
			hits.append(_surface_ray(origin, origin + ray_direction * settings.probe_distance))
		if hits[0].is_empty() or hits[1].is_empty(): continue
		var area := hits[0].collider as ClimbableArea3D
		if area == null or hits[1].collider != area or not area.accepts_normal(hits[0].normal): continue
		if area.global_basis.y.dot(Vector3.UP) < 0.95 or hits[0].normal.dot(hits[1].normal) < 0.95: continue
		_normal = hits[0].normal
		var old_yaw := _visual.global_rotation.y
		if absf(_normal.y) < 0.7:
			_visual.global_rotation.y = atan2(-_normal.x, -_normal.z)
		for side in 2:
			hands[side].goal = _grip(hits[side].position, _normal, side)
		var desired := _root_goal()
		var valid := desired.distance_to(_body.global_position) <= settings.attach_distance and _space_clear(desired)
		valid = valid and not _body.test_move(_body.global_transform, desired - _body.global_position)
		for hand in hands:
			valid = valid and _unobstructed(_body.global_position + _world_shoulder_offset(hand), hand.goal.origin)
		if not valid:
			_visual.global_rotation.y = old_yaw
			continue
		_support = weakref(area)
		for hand in hands:
			hand.local_grip = area.global_transform.affine_inverse() * hand.goal
		_local_facing = area.global_basis.inverse() * _visual.global_basis.z
		_support_center = area.to_local(_body.global_position)
		_last_relative_velocity = Vector3.ZERO
		_sway = Vector3.ZERO
		_sway_velocity = Vector3.ZERO
		sway_basis = Basis.IDENTITY
		_age = 0.0
		pose_weight = 0.0
		_swing_hand = -1
		_next_hand = 0
		_saved_snap = _body.floor_snap_length
		_body.floor_snap_length = 0.0
		_attached = true
		_body.velocity = Vector3.ZERO
		_body.foot_placement.reset()
		_body.motion_matching.reset()
		return

func _detach() -> void:
	if _attached:
		_body.floor_snap_length = _saved_snap
	_attached = false
	_support = null
	_swing_hand = -1
	pose_weight = 0.0
	sway_basis = Basis.IDENTITY
	for hand in hands: hand.ik.influence = 0.0

func _area() -> ClimbableArea3D:
	return _support.get_ref() as ClimbableArea3D if _support != null else null

func _surface_ray(from: Vector3, to: Vector3) -> Dictionary:
	var query := PhysicsRayQueryParameters3D.create(from, to, settings.surface_mask, [_body.get_rid()])
	query.collide_with_areas = true
	query.collide_with_bodies = false
	return _body.get_world_3d().direct_space_state.intersect_ray(query)

func _unobstructed(from: Vector3, to: Vector3) -> bool:
	var query := PhysicsRayQueryParameters3D.create(from, to, _body.collision_mask, [_body.get_rid()])
	var hit := _body.get_world_3d().direct_space_state.intersect_ray(query)
	return hit.is_empty() or hit.position.distance_to(to) < 0.06

func _valid_grip(area: ClimbableArea3D, grip: Transform3D) -> bool:
	var normal := grip.basis.y
	var hit := _surface_ray(grip.origin + normal * 0.08, grip.origin - normal * 0.08)
	return not hit.is_empty() and hit.collider == area and area.accepts_normal(hit.normal) and hit.normal.dot(normal) > 0.95 and hit.position.distance_to(grip.origin) < 0.04

func _grip(point: Vector3, normal: Vector3, side: int) -> Transform3D:
	var fingers := Vector3.UP.slide(normal)
	if fingers.length_squared() < 0.05:
		fingers = _visual.global_basis.z.slide(normal)
	fingers = fingers.normalized()
	var x := fingers * (1.0 if side == 0 else -1.0)
	return Transform3D(Basis(x, normal, x.cross(normal)).orthonormalized(), point + normal * 0.015)

func _wrist_goal(hand: Hand) -> Transform3D:
	return Transform3D(hand.goal.basis, hand.goal.origin - hand.goal.basis * hand.palm_offset)

func _world_shoulder_offset(hand: Hand) -> Vector3:
	return _visual.position + _visual.global_basis * (_pelvis + sway_basis * (hand.shoulder_offset - _pelvis))

func _root_goal() -> Vector3:
	var desired := Vector3.ZERO
	var total := 0.0
	for side in 2:
		var hand := hands[side]
		var horizontal := hand.goal.basis.y.slide(Vector3.UP) * settings.wall_clearance
		var reach := hand.length * settings.arm_extension
		var drop := sqrt(maxf(reach * reach - horizontal.length_squared(), 0.01))
		var weight := 0.2 if side == _swing_hand else 1.0
		desired += (_wrist_goal(hand).origin + horizontal - Vector3.UP * drop - _world_shoulder_offset(hand)) * weight
		total += weight
	desired /= total
	# Project into the intersection of both arm-reach spheres; no bone scaling.
	for iteration in 5:
		for hand in hands:
			var center := _wrist_goal(hand).origin - _world_shoulder_offset(hand)
			desired = center + (desired - center).limit_length(hand.length * 0.985)
	return desired

func _space_clear(root_position: Vector3) -> bool:
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = _collision.shape
	query.transform = _collision.global_transform
	query.transform.origin += root_position - _body.global_position
	query.collision_mask = _body.collision_mask
	query.exclude = [_body.get_rid()]
	return _body.get_world_3d().direct_space_state.intersect_shape(query, 1).is_empty()

func _update_goals(area: ClimbableArea3D) -> void:
	for hand in hands:
		hand.goal = area.global_transform * hand.local_grip
	_normal = hands[0].goal.basis.y

func _plan_step(area: ClimbableArea3D, direction: Vector3) -> void:
	var tangent := direction.slide(_normal)
	if absf(_normal.y) < 0.7:
		# Camera-relative W/S becomes up/down on a wall; A/D follows its tangent.
		var right := _visual.global_basis.x
		tangent = right * direction.dot(right) + Vector3.UP * direction.dot(_visual.global_basis.z)
	if tangent.length_squared() < 0.01: return
	tangent = tangent.normalized() * settings.step_distance
	# Alternate, but bring the trailing hand alongside before reaching farther.
	var side := _next_hand
	var other := hands[1 - side]
	var hand := hands[side]
	var current := hand.goal.origin
	var lateral := _visual.global_basis * (hand.shoulder_offset - other.shoulder_offset)
	var point := other.goal.origin + lateral + tangent
	var hit := _surface_ray(point + _normal * 0.16, point - _normal * 0.18)
	if hit.is_empty() or hit.collider != area or hit.normal.dot(_normal) < 0.95: return
	var next := _grip(hit.position, hit.normal, side)
	if not _valid_grip(area, next) or not _unobstructed(current + _normal * 0.06, next.origin + _normal * 0.06): return
	var old := hand.goal
	hand.goal = next
	var desired := _root_goal()
	var valid := _space_clear(desired) and not _body.test_move(_body.global_transform, desired - _body.global_position)
	for check_hand in hands:
		valid = valid and (desired + _world_shoulder_offset(check_hand)).distance_to(_wrist_goal(check_hand).origin) < check_hand.length * 0.99
	hand.goal = old
	if not valid: return
	_swing_hand = side
	_swing_time = 0.0
	_swing_from = hand.local_grip
	_swing_to = area.global_transform.affine_inverse() * next

func _update_sway(delta: float, area: ClimbableArea3D) -> void:
	var center := area.to_local(_body.global_position)
	var relative_velocity := area.global_basis * (center - _support_center) / delta
	var acceleration := (relative_velocity - _last_relative_velocity) / delta
	_support_center = center
	_last_relative_velocity = relative_velocity
	# Small substeps keep the damped response stable at 30/60/120 Hz.
	var remaining := delta
	while remaining > 0.00001:
		var dt := minf(remaining, 1.0 / 120.0)
		var omega := settings.sway_frequency
		_sway_velocity += (-acceleration.limit_length(12.0) * 0.06 - _sway * omega * omega - _sway_velocity * 2.0 * settings.sway_damping * omega) * dt
		_sway += _sway_velocity * dt
		_sway = _sway.limit_length(deg_to_rad(settings.max_sway_degrees))
		remaining -= dt
	var local := _visual.global_basis.inverse() * _sway
	sway_basis = Basis.from_euler(Vector3(local.z, 0.0, -local.x))

func get_debug_state() -> Dictionary:
	var result := {"attached": _attached, "blocked_until_grounded": _blocked_until_grounded, "phase": "Move" if _swing_hand >= 0 else ("Attach" if _age < settings.attach_duration else "Hang"), "hands": []}
	for side in hands.size():
		result.hands.append({"grip": hands[side].goal, "planted": _attached and side != _swing_hand})
	return result
