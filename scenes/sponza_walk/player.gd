extends CharacterBody3D
## Feet are the origin; mouse pitch only moves the head, never the walking plane.
@onready var eyes: Camera3D = $Eyes
@onready var _hand: Node3D = $Eyes/Hold/Model
@onready var _light: OmniLight3D = $Eyes/Hold/Torchlight
var _safe_pose: Transform3D
var _needs_floor := true
var _stride := 0.0

func _ready() -> void:
	# The small hand needs a softer light than the surrounding architecture.
	for part: MeshInstance3D in _hand.find_children("*", "MeshInstance3D", true, false):
		part.layers = 2

func enter(pose: Transform3D, fallback: Transform3D) -> void:
	_safe_pose = fallback
	_place(pose)
	eyes.make_current()

func _place(pose: Transform3D) -> void:
	global_position = pose.origin - Vector3.UP * eyes.position.y
	global_rotation = Vector3(0, pose.basis.get_euler().y, 0)
	eyes.rotation.x = clampf(pose.basis.get_euler().x, -1.4, 1.4)
	velocity = Vector3.ZERO
	reset_physics_interpolation()

func look(pixels: Vector2) -> void:
	rotate_y(-pixels.x * 0.0024)
	eyes.rotation.x = clampf(eyes.rotation.x - pixels.y * 0.0024, -1.4, 1.4)

func toggle_torch() -> void:
	_light.visible = not _light.visible
	$Eyes/Hold/Model/Flame.visible = _light.visible
	$Eyes/Hold/HandFill.visible = _light.visible
	$Eyes/Hold/Model/Wick.set_instance_shader_parameter(&"lit", float(_light.visible))

func walk(axis: Vector2, running: bool, delta: float) -> void:
	if _needs_floor or global_position.y < _safe_pose.origin.y - 12.0:
		if not _needs_floor: _place(_safe_pose)
		_needs_floor = false
		# Entering from the fly camera may mean being several metres off the floor.
		var ray := PhysicsRayQueryParameters3D.create(eyes.global_position, eyes.global_position + Vector3.DOWN * 60.0, collision_mask)
		var hit := get_world_3d().direct_space_state.intersect_ray(ray)
		if hit.is_empty() or Vector3(hit.normal).y < cos(floor_max_angle):
			_place(_safe_pose)
		else:
			global_position = Vector3(hit.position) + Vector3.UP * 0.025
			reset_physics_interpolation()
	var dir := global_basis * Vector3(axis.x, 0.0, axis.y).limit_length()
	var speed := 4.3 if running else 2.4
	velocity.x = dir.x * speed
	velocity.z = dir.z * speed
	if not is_on_floor(): velocity += get_gravity() * delta
	move_and_slide()
	# Animate the held model, not the photometry. Idle flames must not invalidate GI history.
	var travel := Vector2(get_position_delta().x, get_position_delta().z).length() if is_on_floor() else 0.0
	_stride = fmod(_stride + travel * 5.0, TAU)
	var offset := Vector3(sin(_stride) * 0.009, cos(2.0 * _stride) * 0.006, 0.0) if travel > 0.0001 else Vector3.ZERO
	_hand.position = _hand.position.lerp(offset, 1.0 - exp(-12.0 * delta))

## One physics-only trimesh, built on first use and kept when switching cameras.
## The simplified palace is aligned with the visible floor, columns and walls.
static func make_walk_surface(palace: Node3D) -> StaticBody3D:
	var faces := PackedVector3Array()
	var to_local_space := palace.global_transform.affine_inverse()
	for mesh: MeshInstance3D in palace.find_children("*", "MeshInstance3D", true, false):
		if mesh.mesh:
			faces.append_array((to_local_space * mesh.global_transform) * mesh.mesh.get_faces())
	if faces.is_empty(): return null
	var trimesh := ConcavePolygonShape3D.new()
	trimesh.backface_collision = true
	trimesh.set_faces(faces)
	var collision := CollisionShape3D.new()
	collision.shape = trimesh
	var body := StaticBody3D.new()
	body.name = "WalkSurface"
	body.add_child(collision)
	palace.add_child(body)
	return body
