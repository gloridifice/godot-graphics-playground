class_name MotionFootPlacement
extends SkeletonModifier3D
## First modifier: samples the unmodified animation, manages contacts, then offsets the pelvis.
## Sibling order is this -> left IK -> right IK -> foot rotations. All run in one physics tick.

enum Phase { SWING, APPROACH, CONTACT, STANCE, RELEASE }
const PHASE_NAMES := ["Swing", "Approach", "Contact", "Stance", "Release"]
const CONTACT_TRANSITION := preload("res://addons/motion/foot_placement/contact_transition.gd")
const ROTATION_MODIFIER := preload("res://addons/motion/foot_placement/foot_rotation.gd")

@export var settings: MotionFootSettings
@export var enabled := true
@export var left_enabled := true
@export var right_enabled := true
@export var draw_debug := false
# Continuous value tracks in the native AnimationLibrary; automatically blended by AnimationTree.
@export_range(0.0, 1.0) var left_contact: float = 0.0
@export_range(0.0, 1.0) var right_contact: float = 0.0

class Foot:
	var label: String
	var hip: int
	var knee: int
	var ankle: int
	var length: float
	var ik: TwoBoneIK3D
	var target: Node3D
	var pole: Node3D
	var phase: Phase = Phase.SWING
	var weight := 0.0
	var weight_velocity := 0.0
	var height_offset := Vector2.ZERO # displacement and velocity, before pelvis compensation
	var transition := CONTACT_TRANSITION.new()
	var previous_support: WeakRef
	var previous_support_sole := Vector3.ZERO
	var contact := 0.0
	var distance_weight := 0.0
	var animated := Transform3D.IDENTITY
	var previous_local_sole := Vector3.ZERO
	var vertical_speed := 0.0
	var sampled := false
	var hit: Dictionary = {}
	var ray_from := Vector3.ZERO
	var ray_to := Vector3.ZERO
	var goal := Transform3D.IDENTITY
	var resolved := Transform3D.IDENTITY
	var lock_world := Transform3D.IDENTITY
	var lock_local := Transform3D.IDENTITY
	var support: WeakRef
	# Completed pre-IK target history, in world space (includes platform transport).
	var previous_animated := Transform3D.IDENTITY
	var resolved_velocity := Vector3.ZERO
	var resolved_spin := Vector3.ZERO
	var output_sampled := false
	var release_position := Vector3.ZERO
	var release_rotation := Vector3.ZERO
	var release_velocity := Vector3.ZERO
	var release_spin := Vector3.ZERO
	var release_time := 0.0
	var release_weight := 0.0
	var leg_animated: Array[Quaternion] = []
	var leg_previous: Array[Quaternion] = []
	var leg_spin: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
	var leg_release: Array[Vector3] = []
	var leg_release_spin: Array[Vector3] = []
	var lock_error := 0.0
	var reach_limited := false
	var reason := ""

var _body: CharacterBody3D
var _skeleton: Skeleton3D
var _feet: Array[Foot] = []
var _pelvis: int
var _pelvis_drop := 0.0
var _previous_body := Vector3.ZERO
var _previous_crouch := false
var _debug_mesh: ImmediateMesh
var _debug_instance: MeshInstance3D
var _debug_material: StandardMaterial3D

func bind_character(body: CharacterBody3D) -> void:
	_body = body
	_skeleton = get_skeleton()
	_pelvis = _skeleton.find_bone("Hips")
	if settings == null or _pelvis < 0:
		push_error("Motion FootPlacement requires Guard settings and a Hips bone.")
		return
	for side in ["Left", "Right"]:
		var foot := Foot.new()
		foot.label = side
		foot.hip = _skeleton.find_bone(side + "UpLeg")
		foot.knee = _skeleton.find_bone(side + "Leg")
		foot.ankle = _skeleton.find_bone(side + "Foot")
		if mini(foot.hip, mini(foot.knee, foot.ankle)) < 0:
			_feet.clear()
			push_error("Motion FootPlacement: incompatible leg bones: " + side)
			return
		foot.length = _skeleton.get_bone_rest(foot.knee).origin.length() + _skeleton.get_bone_rest(foot.ankle).origin.length()
		_feet.append(foot)
	for foot in _feet:
		foot.target = Node3D.new()
		foot.target.name = foot.label + "Target"
		add_child(foot.target)
		foot.pole = Node3D.new()
		foot.pole.name = foot.label + "Pole"
		add_child(foot.pole)
		foot.ik = TwoBoneIK3D.new()
		foot.ik.name = foot.label + "LegIK"
		foot.ik.influence = 0.0
		_skeleton.add_child(foot.ik)
		foot.ik.set_setting_count(1)
		foot.ik.set_root_bone(0, foot.hip)
		foot.ik.set_middle_bone(0, foot.knee)
		foot.ik.set_end_bone(0, foot.ankle)
		foot.ik.set_target_node(0, foot.ik.get_path_to(foot.target))
		foot.ik.set_pole_node(0, foot.ik.get_path_to(foot.pole))
		foot.ik.set_pole_direction_vector(0, Vector3.BACK)
	var rotation_modifier := ROTATION_MODIFIER.new()
	rotation_modifier.name = "FootRotations"
	rotation_modifier.driver = self
	_skeleton.add_child(rotation_modifier)
	rotation_modifier.modification_processed.connect(_update_debug)
	_debug_mesh = ImmediateMesh.new()
	_debug_material = StandardMaterial3D.new()
	_debug_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_debug_material.vertex_color_use_as_albedo = true
	_debug_material.no_depth_test = true
	_debug_instance = MeshInstance3D.new()
	_debug_instance.name = "FootDebug"
	_debug_instance.mesh = _debug_mesh
	_debug_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_debug_instance)
	_debug_instance.top_level = true
	_debug_instance.global_transform = Transform3D.IDENTITY
	_previous_body = body.global_position
	_previous_crouch = body.is_crouching()

func reset() -> void:
	# Public lifecycle operation for explicit teleports; large relocations are also detected below.
	for foot in _feet:
		foot.phase = Phase.SWING
		foot.weight = 0.0
		foot.ik.influence = 0.0
		foot.support = null
		foot.previous_support = null
		foot.height_offset = Vector2.ZERO
		foot.weight_velocity = 0.0
		foot.sampled = false
		foot.output_sampled = false
		foot.leg_previous.clear()
		foot.leg_animated.clear()
		foot.hit = {}
		foot.reason = "reset"
	_pelvis_drop = 0.0
	if is_instance_valid(_body):
		_previous_body = _body.global_position

func _process_modification_with_delta(delta: float) -> void:
	if _feet.size() != 2 or not is_instance_valid(_body) or delta <= 0.0:
		return
	if _body.global_position.distance_to(_previous_body) > settings.teleport_distance:
		reset()
	_previous_body = _body.global_position
	var posture_changed: bool = _previous_crouch != _body.is_crouching()
	_previous_crouch = _body.is_crouching()
	var supported := enabled and _body.is_on_floor()
	for i in _feet.size():
		var foot := _feet[i]
		foot.animated = _bone_world(foot.ankle)
		foot.contact = clampf(left_contact if i == 0 else right_contact, 0.0, 1.0)
		var local_sole := _body.to_local(foot.animated * settings.sole_offset)
		foot.vertical_speed = (local_sole.y - foot.previous_local_sole.y) / delta if foot.sampled else 0.0
		foot.previous_local_sole = local_sole
		foot.sampled = true
		foot.reach_limited = false
		var allowed := supported and (left_enabled if i == 0 else right_enabled)
		if not allowed:
			# In air, never drag a Jump/Fall pose back toward a ground anchor.
			foot.phase = Phase.SWING
			foot.weight = 0.0
			foot.support = null
			foot.previous_support = null
			foot.height_offset = Vector2.ZERO
			foot.weight_velocity = 0.0
			foot.output_sampled = false
			foot.hit = {}
			foot.goal = foot.animated
			foot.reason = "airborne" if not _body.is_on_floor() else "disabled"
		elif posture_changed:
			_release(foot, "posture changed", delta)
			_update_foot(foot, delta)
		else:
			_update_foot(foot, delta)
	_apply_pelvis(delta)
	for foot in _feet:
		_drive_leg(foot, delta)
		# Measure the resolved output in support space, not animation-local speed or
		# last frame's world point (which would include platform translation/rotation).
		if not foot.hit.is_empty():
			var platform := foot.hit.collider as Node3D
			foot.previous_support = weakref(platform)
			foot.previous_support_sole = platform.global_transform.affine_inverse() * (foot.resolved * settings.sole_offset)
		else:
			foot.previous_support = null

func _update_foot(foot: Foot, delta: float) -> void:
	var animated_sole := foot.animated * settings.sole_offset
	var sole := animated_sole
	var platform: Node3D = foot.support.get_ref() if foot.support != null else null
	if foot.phase in [Phase.CONTACT, Phase.STANCE]:
		if not is_instance_valid(platform) or not platform.is_inside_tree():
			_release(foot, "support removed", delta)
		elif foot.phase == Phase.STANCE:
			foot.lock_world = platform.global_transform * foot.lock_local
			sole = foot.lock_world * settings.sole_offset
		else:
			sole = platform.global_transform * foot.transition.sample().origin
	foot.hit = _ground(sole, foot.animated.basis.z, foot)
	var surface := foot.animated.basis
	var ground_sole := animated_sole
	foot.distance_weight = 0.0
	if not foot.hit.is_empty():
		var normal: Vector3 = foot.hit.normal
		var gap: float = animated_sole.y - foot.hit.position.y
		foot.distance_weight = 1.0 - smoothstep(settings.full_ik_distance, settings.max_correction, absf(gap))
		surface = _surface_basis(foot.animated.basis.z, normal)
		# Height and orientation must not move the animated sole sideways in Approach.
		ground_sole.y = foot.hit.position.y + settings.sole_clearance / normal.y
		if absf(ground_sole.y - animated_sole.y) > settings.max_correction:
			foot.hit = {}
			foot.distance_weight = 0.0

	foot.lock_error = Vector2(foot.lock_world.origin.x - foot.animated.origin.x, foot.lock_world.origin.z - foot.animated.origin.z).length()
	if foot.phase in [Phase.CONTACT, Phase.STANCE]:
		var yaw_basis := foot.lock_world.basis if foot.phase == Phase.STANCE else foot.goal.basis
		var yaw_error := yaw_basis.z.slide(Vector3.UP).angle_to(foot.animated.basis.z.slide(Vector3.UP))
		if foot.hit.is_empty():
			_release(foot, "ground lost", delta)
		elif platform != foot.hit.collider:
			_release(foot, "support changed", delta)
		elif foot.phase == Phase.STANCE and absf((sole - (foot.hit.position as Vector3)).dot(foot.hit.normal) - settings.sole_clearance) > 0.06:
			_release(foot, "support height changed", delta)
		elif foot.contact < 0.45 or (foot.vertical_speed > 0.25 and foot.contact < 0.85):
			_release(foot, "toe off", delta)
		elif (foot.phase == Phase.STANCE and foot.lock_error > settings.lock_break_distance) or yaw_error > deg_to_rad(settings.lock_break_angle):
			_release(foot, "lock limit", delta)

	if foot.phase in [Phase.SWING, Phase.APPROACH]:
		# A ray hit is never sufficient: animation timing gates all correction/planting.
		foot.phase = Phase.APPROACH if not foot.hit.is_empty() and foot.contact >= 0.08 else Phase.SWING
		var weight := _spring(Vector2(foot.weight, foot.weight_velocity), foot.contact * foot.distance_weight if foot.phase == Phase.APPROACH else 0.0, delta)
		foot.weight = clampf(weight.x, 0.0, 1.0)
		foot.weight_velocity = weight.y
		foot.height_offset = _spring(foot.height_offset, (ground_sole.y - animated_sole.y) * foot.contact * foot.distance_weight, delta)
		var basis := foot.animated.basis.orthonormalized().slerp(surface.orthonormalized(), foot.weight)
		foot.goal = _ankle_pose(Transform3D(basis, animated_sole + Vector3.UP * foot.height_offset.x))
		if foot.phase == Phase.APPROACH and foot.contact >= 0.88 and foot.distance_weight > 0.05 and foot.vertical_speed < 0.2:
			_start_contact(foot, surface, delta)
		return

	match foot.phase:
		Phase.STANCE:
			foot.goal = foot.lock_world
			foot.weight = 1.0
		Phase.CONTACT:
			foot.transition.advance(delta)
			var local_pose: Transform3D = foot.transition.sample()
			foot.goal = _ankle_pose(platform.global_transform * local_pose)
			foot.weight = 1.0
			if foot.transition.finished():
				# Only now is support-relative velocity zero. Capture the actual endpoint.
				foot.phase = Phase.STANCE
				foot.lock_local = _ankle_pose(local_pose)
				foot.lock_world = foot.goal
				foot.reason = "touchdown settled"
		Phase.RELEASE:
			foot.release_time = minf(1.0, foot.release_time + settings.release_speed * delta)
			if is_equal_approx(foot.release_time, 1.0): foot.release_time = 1.0
			var u := foot.release_time
			# Hermite residual: preserve the incoming correction velocity, then reach
			# zero offset AND zero relative velocity against the moving animation.
			var residual := (1.0 - u) * (1.0 - u) * (1.0 + 2.0 * u)
			var tangent := u * (1.0 - u) * (1.0 - u) / settings.release_speed
			var rotation := foot.release_rotation * residual + foot.release_spin * tangent
			foot.goal = Transform3D(_rotation_basis(rotation) * foot.animated.basis, foot.animated.origin + foot.release_position * residual + foot.release_velocity * tangent)
			foot.weight = foot.release_weight * residual
			foot.height_offset = Vector2.ZERO
			foot.weight_velocity = 0.0
			if foot.release_time >= 1.0:
				foot.phase = Phase.SWING
				foot.goal = foot.animated

func _start_contact(foot: Foot, surface: Basis, delta: float) -> void:
	var platform := foot.hit.collider as Node3D
	if foot.previous_support == null or foot.previous_support.get_ref() != platform:
		return # One real support-local sample is required; never invent touchdown velocity.
	var inverse := platform.global_transform.affine_inverse()
	var start := foot.goal
	start.origin = start * settings.sole_offset + Vector3.UP * _pelvis_drop * (1.0 - foot.weight)
	var local_start := inverse * start
	var velocity := (local_start.origin - foot.previous_support_sole) / delta
	var end := start.origin + platform.global_basis * velocity * (settings.contact_duration * 0.5)
	var normal: Vector3 = foot.hit.normal
	var hit: Vector3 = foot.hit.position
	end.y = hit.y - (normal.x * (end.x - hit.x) + normal.z * (end.z - hit.z)) / normal.y + settings.sole_clearance / normal.y
	foot.transition.begin(local_start, velocity, inverse * Transform3D(surface, end), settings.contact_duration)
	foot.support = weakref(platform)
	foot.phase = Phase.CONTACT
	foot.goal = _ankle_pose(start)
	foot.weight = 1.0
	foot.weight_velocity = 0.0
	foot.reason = "touchdown braking"

func _ankle_pose(sole_pose: Transform3D) -> Transform3D:
	return Transform3D(sole_pose.basis, sole_pose.origin - sole_pose.basis * settings.sole_offset)

func _spring(state: Vector2, target: float, delta: float) -> Vector2:
	# Exact critically damped response for a held target. No frame-rate-dependent lerp.
	var omega := settings.approach_speed * 2.0
	var offset := state.x - target
	var impulse := state.y + offset * omega
	var decay := exp(-omega * delta)
	return Vector2(target + (offset + impulse * delta) * decay, (state.y - impulse * omega * delta) * decay)

func _release(foot: Foot, reason: String, delta: float) -> void:
	if foot.phase == Phase.RELEASE:
		return
	if foot.weight <= 0.0001 and foot.phase in [Phase.SWING, Phase.APPROACH]:
		foot.phase = Phase.SWING
		return
	foot.release_position = foot.resolved.origin - foot.previous_animated.origin
	foot.release_velocity = foot.resolved_velocity - (foot.animated.origin - foot.previous_animated.origin) / delta
	var previous_basis := foot.resolved.basis.orthonormalized()
	foot.release_rotation = _rotation_vector(previous_basis * foot.previous_animated.basis.orthonormalized().transposed())
	# Predict the previous output one tick forward, rather than inheriting an
	# animation velocity from an older tick (important at fast gait changes).
	var predicted := _rotation_basis(foot.resolved_spin * delta) * previous_basis
	foot.release_spin = (_rotation_vector(predicted * foot.animated.basis.orthonormalized().transposed()) - foot.release_rotation) / delta
	foot.leg_release.clear()
	foot.leg_release_spin.clear()
	for index in 2:
		var bone := foot.hip if index == 0 else foot.knee
		var animated := _skeleton.get_bone_pose_rotation(bone)
		var before := foot.leg_previous[index]
		var error := _rotation_vector(Basis(before * foot.leg_animated[index].inverse()))
		var predicted_leg := _rotation_basis(foot.leg_spin[index] * delta) * Basis(before)
		foot.leg_release.append(error)
		foot.leg_release_spin.append((_rotation_vector(predicted_leg * Basis(animated).transposed()) - error) / delta)
	foot.release_weight = foot.weight
	foot.release_time = 0.0
	foot.phase = Phase.RELEASE
	foot.support = null
	foot.reason = reason

func _ground(sole: Vector3, forward: Vector3, foot: Foot) -> Dictionary:
	var space := _body.get_world_3d().direct_space_state
	foot.ray_from = sole + Vector3.UP * settings.ray_up
	foot.ray_to = sole - Vector3.UP * settings.ray_down
	var query := PhysicsRayQueryParameters3D.create(foot.ray_from, foot.ray_to, settings.collision_mask, [_body.get_rid()])
	var center := space.intersect_ray(query)
	if not _walkable(center):
		return {}
	var best := center.duplicate()
	var tangent := forward.slide(Vector3.UP).normalized() * settings.sole_half_length
	# Heel/toe clearance prevents a shoe dipping through the next stair's top face.
	for offset: Vector3 in [-tangent, tangent]:
		query.from = foot.ray_from + offset
		query.to = foot.ray_to + offset
		var sample := space.intersect_ray(query)
		if not _walkable(sample):
			continue
		var normal: Vector3 = sample.normal
		var plane_y: float = sample.position.y - (normal.x * (sole.x - sample.position.x) + normal.z * (sole.z - sample.position.z)) / normal.y
		if plane_y > best.position.y:
			best = sample.duplicate()
			best.position = Vector3(sole.x, plane_y, sole.z)
	best.position = Vector3(sole.x, best.position.y, sole.z)
	return best

func _walkable(hit: Dictionary) -> bool:
	return not hit.is_empty() and (hit.normal as Vector3).dot(Vector3.UP) >= cos(deg_to_rad(settings.max_ground_angle)) and hit.collider is Node3D

func _surface_basis(animated_forward: Vector3, normal: Vector3) -> Basis:
	var forward := animated_forward.slide(Vector3.UP).normalized()
	if forward.length_squared() < 0.1:
		forward = _skeleton.global_basis.z.slide(Vector3.UP).normalized()
	var flat := Basis(Vector3.UP.cross(forward), Vector3.UP, forward)
	var local_normal := flat.inverse() * normal
	var pitch := clampf(atan2(local_normal.z, local_normal.y), -deg_to_rad(settings.max_pitch), deg_to_rad(settings.max_pitch))
	var roll := clampf(atan2(-local_normal.x, local_normal.y), -deg_to_rad(settings.max_roll), deg_to_rad(settings.max_roll))
	return (flat * Basis.from_euler(Vector3(pitch, 0.0, roll))).orthonormalized()

func _apply_pelvis(delta: float) -> void:
	var required := 0.0
	for foot in _feet:
		if foot.weight < 0.05:
			continue
		var hip := _bone_world(foot.hip).origin
		var offset := foot.goal.origin - hip
		var horizontal_sq := offset.x * offset.x + offset.z * offset.z
		var reach := foot.length * 0.985
		# Solve the reachable vertical interval, rather than copying the feet's height difference.
		if offset.y < 0.0 and horizontal_sq < reach * reach:
			var drop := foot.goal.origin.y + sqrt(reach * reach - horizontal_sq) - hip.y
			required = minf(required, minf(0.0, drop) * foot.weight)
	_pelvis_drop = move_toward(_pelvis_drop, maxf(required, -settings.max_pelvis_drop), settings.pelvis_speed * delta)
	var pose := _skeleton.get_bone_pose_position(_pelvis)
	pose += _skeleton.global_basis.inverse() * (Vector3.UP * _pelvis_drop)
	_skeleton.set_bone_pose_position(_pelvis, pose)

func _drive_leg(foot: Foot, delta: float) -> void:
	var hip := _bone_world(foot.hip).origin
	var knee := _bone_world(foot.knee).origin
	var ankle := foot.animated.origin + Vector3.UP * _pelvis_drop
	var axis := (ankle - hip).normalized()
	var forward := _skeleton.global_basis.z.slide(axis).normalized()
	if forward.length_squared() < 0.01:
		forward = _skeleton.global_basis.x.slide(axis).normalized()
	var bend := (knee - hip).slide(axis)
	if bend.length() > 0.025 and bend.dot(forward) > 0.0:
		forward = (bend.normalized() + forward * 0.3).normalized()
	foot.pole.global_position = hip + forward * 0.8 + axis * 0.25
	var target := foot.goal
	if foot.phase in [Phase.SWING, Phase.APPROACH]:
		target.origin.y += _pelvis_drop * (1.0 - foot.weight)
	elif foot.phase == Phase.RELEASE:
		# The incoming residual already contains the old pelvis compensation.
		# Introduce the CURRENT drop with zero endpoint slopes, not last tick's drop.
		target.origin.y += _pelvis_drop * smoothstep(0.0, 1.0, foot.release_time)
	var displacement := target.origin - hip
	var reach := foot.length * 0.998
	if foot.weight > 0.0 and displacement.length() > reach:
		target.origin = hip + displacement.normalized() * reach
		foot.reach_limited = true
	foot.resolved_velocity = (target.origin - foot.resolved.origin) / delta if foot.output_sampled else Vector3.ZERO
	foot.resolved_spin = _rotation_vector(target.basis.orthonormalized() * foot.resolved.basis.orthonormalized().transposed()) / delta if foot.output_sampled else Vector3.ZERO
	foot.previous_animated = foot.animated
	foot.output_sampled = true
	foot.resolved = target
	foot.target.global_transform = target
	# Contact/Stance keep full IK. During Release, do not solve the nearly straight
	# chain again: a smooth ankle path can still snap the knee at the reach limit.
	# Decay the LAST DISPLAYED joint correction instead, preserving its velocity.
	foot.ik.influence = 1.0 if foot.phase != Phase.RELEASE and foot.weight > 0.0001 else 0.0
	foot.leg_animated = [_skeleton.get_bone_pose_rotation(foot.hip), _skeleton.get_bone_pose_rotation(foot.knee)]
	if foot.phase == Phase.RELEASE:
		var u := foot.release_time
		# Quintic residuals have zero endpoint accelerations as well as zero final
		# offset/velocity; this avoids a sharp late catch-up in the joint chain.
		var residual := 1.0 - u * u * u * (10.0 + u * (-15.0 + 6.0 * u))
		var tangent := u * (1.0 - u) * (1.0 - u) * (1.0 - u) * (1.0 + 3.0 * u) / settings.release_speed
		for index in 2:
			var correction := _rotation_basis(foot.leg_release[index] * residual + foot.leg_release_spin[index] * tangent).get_rotation_quaternion()
			_skeleton.set_bone_pose_rotation(foot.hip if index == 0 else foot.knee, correction * foot.leg_animated[index])

func _rotation_basis(vector: Vector3) -> Basis:
	var angle := vector.length()
	return Basis(vector / angle, angle) if angle > 0.0 else Basis.IDENTITY

func _rotation_vector(basis: Basis) -> Vector3:
	var rotation := basis.get_rotation_quaternion()
	if rotation.w < 0.0: rotation = -rotation
	var axis := Vector3(rotation.x, rotation.y, rotation.z)
	# atan2 stays accurate for small corrections where acos(w) rounds to zero.
	return axis.normalized() * (2.0 * atan2(axis.length(), rotation.w))

func apply_foot_rotations(delta: float) -> void:
	for foot in _feet:
		if not foot.sampled:
			continue
		var pose := _skeleton.get_bone_global_pose(foot.ankle)
		var desired := foot.goal.basis.orthonormalized()
		pose.basis = _skeleton.global_basis.inverse() * desired
		_skeleton.set_bone_global_pose(foot.ankle, pose)
		var current: Array[Quaternion] = [_skeleton.get_bone_pose_rotation(foot.hip), _skeleton.get_bone_pose_rotation(foot.knee)]
		for index in 2:
			foot.leg_spin[index] = _rotation_vector(Basis(current[index] * foot.leg_previous[index].inverse())) / delta if foot.leg_previous.size() == 2 and delta > 0.0 else Vector3.ZERO
		foot.leg_previous = current

func _bone_world(bone: int) -> Transform3D:
	return _skeleton.global_transform * _skeleton.get_bone_global_pose(bone)

func get_debug_state() -> Dictionary:
	var result := {"enabled": enabled, "pelvis_drop": _pelvis_drop, "feet": []}
	for foot in _feet:
		result.feet.append({
			"side": foot.label, "phase": PHASE_NAMES[foot.phase], "weight": foot.weight,
			"contact": foot.contact, "distance_weight": foot.distance_weight,
			"contact_velocity": foot.transition.velocity() if foot.phase == Phase.CONTACT else Vector3.ZERO,
			"lock": foot.lock_world, "target": foot.goal, "animated": foot.animated,
			"normal": foot.hit.get("normal", Vector3.UP), "has_ground": not foot.hit.is_empty(),
			"lock_error": foot.lock_error, "reach_limited": foot.reach_limited, "reason": foot.reason,
		})
	return result

func _update_debug() -> void:
	_debug_instance.visible = draw_debug
	_debug_mesh.clear_surfaces()
	if not draw_debug or _feet.is_empty():
		return
	_debug_mesh.surface_begin(Mesh.PRIMITIVE_LINES, _debug_material)
	for foot in _feet:
		var color: Color = [Color.GRAY, Color.YELLOW, Color.ORANGE, Color.GREEN, Color.MAGENTA][foot.phase]
		_line(foot.ray_from, foot.ray_to, Color(0.5, 0.5, 0.5))
		_cross(foot.animated * settings.sole_offset, 0.045, Color.DODGER_BLUE)
		_cross(foot.goal * settings.sole_offset, 0.065, color)
		if not foot.hit.is_empty():
			_line(foot.hit.position, foot.hit.position + foot.hit.normal * 0.25, Color.CYAN)
		var hip := _bone_world(foot.hip).origin
		var knee := _bone_world(foot.knee).origin
		var ankle := _bone_world(foot.ankle).origin
		_line(hip, knee, color)
		_line(knee, ankle, color)
		_line(ankle, foot.target.global_position, Color.RED if foot.reach_limited else color)
	_debug_mesh.surface_end()

func _line(a: Vector3, b: Vector3, color: Color) -> void:
	_debug_mesh.surface_set_color(color)
	_debug_mesh.surface_add_vertex(a)
	_debug_mesh.surface_set_color(color)
	_debug_mesh.surface_add_vertex(b)

func _cross(point: Vector3, size: float, color: Color) -> void:
	_line(point - Vector3.RIGHT * size, point + Vector3.RIGHT * size, color)
	_line(point - Vector3.UP * size, point + Vector3.UP * size, color)
	_line(point - Vector3.BACK * size, point + Vector3.BACK * size, color)
