@tool
extends Node3D

# Deterministic procedural scenery; no imported assets or baked editor children.
const SEED := 1947

func _ready() -> void:
	_build_forest()
	if not Engine.is_editor_hint():
		var player := get_node("Player") as PlaygroundPlayer
		var spawn := Vector2(_path_x(14.0), 14.0)
		player.position = Vector3(spawn.x, _height(spawn.x, spawn.y) + 0.94, spawn.y)
		player.reset_physics_interpolation()
		player.jumped.connect(_on_player_jumped)

func _on_player_jumped(feet_position: Vector3) -> void:
	# Every local box receives the same world-space event; no seam at rotated box boundaries.
	for child in get_children():
		if child is HeightfieldFogBox:
			child.disturb_mist(feet_position)

func _height(x: float, z: float) -> float:
	return 0.55 * sin(x * 0.13) * cos(z * 0.17) + 0.3 * sin(z * 0.3) - 0.65 * exp(-(x*x + (z+3.0)*(z+3.0)) / 75.0)

func _path_x(z: float) -> float:
	return 2.5 * sin(z * 0.15)

func _material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.95
	return material

func _mesh(parent: Node3D, shape: Mesh, at: Vector3, material: Material) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.mesh = shape
	instance.material_override = material
	instance.position = at
	parent.add_child(instance)
	return instance

func _build_forest() -> void:
	var landscape := Node3D.new()
	landscape.name = "Landscape"
	add_child(landscape)
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var cells := 64
	var step := 48.0 / cells
	for z in cells:
		for x in cells:
			for corner in [Vector2(0,0), Vector2(1,0), Vector2(0,1), Vector2(1,0), Vector2(1,1), Vector2(0,1)]:
				var px: float = -24.0 + (x + corner.x) * step
				var pz: float = -24.0 + (z + corner.y) * step
				var path := 1.0 - smoothstep(0.8, 1.7, absf(px - _path_x(pz)))
				var variation := 0.5 + 0.5 * sin(px * 0.73 + pz * 0.51)
				var grass := Color(0.17, 0.25, 0.095).lerp(Color(0.27, 0.34, 0.14), variation)
				surface.set_color(grass.lerp(Color(0.36, 0.28, 0.17), path))
				surface.set_normal(Vector3(_height(px-0.05,pz)-_height(px+0.05,pz), 0.1, _height(px,pz-0.05)-_height(px,pz+0.05)).normalized())
				surface.add_vertex(Vector3(px, _height(px,pz), pz))
	var ground_material := _material(Color.WHITE)
	ground_material.vertex_color_use_as_albedo = true
	var terrain_sources := Node3D.new()
	terrain_sources.name = "Terrain"
	landscape.add_child(terrain_sources)
	var ground := _mesh(terrain_sources, surface.commit(), Vector3.ZERO, ground_material)
	ground.name = "Ground"
	ground.create_trimesh_collision()
	_add_boundary(landscape)
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	var bark := _material(Color(0.20, 0.12, 0.065))
	var needles: Array[StandardMaterial3D] = []
	for color in [Color(0.10,0.23,0.13), Color(0.16,0.30,0.15), Color(0.23,0.34,0.16), Color(0.12,0.27,0.22)]:
		needles.append(_material(color))
	var positions: Array[Vector2] = []
	for attempt in 650:
		if positions.size() >= 100:
			break
		var p := Vector2(rng.randf_range(-23,23), rng.randf_range(-23,23))
		if absf(p.x - _path_x(p.y)) < 2.8 or p.length() < 5.0:
			continue
		# Open foreground preserves a clear view of the mist and winding path.
		if p.x > 2.0 and p.y > 6.0 and p.length() < 20.0:
			continue
		var crowded := false
		for other in positions:
			if other.distance_to(p) < 3.1:
				crowded = true
				break
		if crowded:
			continue
		positions.append(p)
		var tree := Node3D.new()
		landscape.add_child(tree)
		tree.position = Vector3(p.x, _height(p.x,p.y), p.y)
		tree.rotation.y = rng.randf_range(0, TAU)
		var height := rng.randf_range(5.0, 9.0)
		var trunk := CylinderMesh.new()
		trunk.top_radius = 0.12
		trunk.bottom_radius = 0.25
		trunk.height = height * 0.8
		trunk.radial_segments = 7
		_mesh(tree, trunk, Vector3(0, trunk.height/2, 0), bark).create_convex_collision()
		for tier in 3:
			var crown := CylinderMesh.new()
			crown.top_radius = 0.0
			crown.bottom_radius = (1.8 - tier * 0.38) * height / 7.0
			crown.height = height * 0.47
			crown.radial_segments = 8
			_mesh(tree, crown, Vector3(0, height * (0.42 + tier * 0.19), 0), needles[rng.randi_range(0,3)])
	var stones: Array[StandardMaterial3D] = [
		_material(Color(0.31,0.34,0.29)), _material(Color(0.40,0.42,0.36)),
		_material(Color(0.25,0.29,0.24)), _material(Color(0.37,0.34,0.28))]
	for i in 90:
		var x := rng.randf_range(-19,19)
		var z := rng.randf_range(-19,19)
		if absf(x-_path_x(z)) < 1.8:
			continue
		var rock := SphereMesh.new()
		rock.radius = rng.randf_range(0.7,1.6) if i < 12 else rng.randf_range(0.12,0.55)
		rock.height = rock.radius * 1.4
		rock.radial_segments = 7
		rock.rings = 3
		var instance := _mesh(terrain_sources, rock, Vector3(x,_height(x,z)+rock.radius*0.2,z), stones[rng.randi_range(0,3)])
		instance.scale = Vector3(rng.randf_range(1.0,1.6),rng.randf_range(0.65,1.1),1.0)
		instance.rotation.y = rng.randf_range(0,TAU)
		instance.create_convex_collision()
	var wood := _material(Color(0.62,0.43,0.22))
	# Hand-placed hero logs frame the clearing; smaller deadwood sits deeper in the forest.
	for placement in [Vector4(-5,4,5.5,0.8), Vector4(7,-3,6.0,-0.7), Vector4(-9,-11,4.5,1.2), Vector4(11,8,3.8,0.3)]:
		var x: float = placement.x
		var z: float = placement.y
		var length: float = placement.z
		var direction := Vector3(sin(placement.w),0,cos(placement.w))
		var a := Vector3(x,0,z) - direction * length * 0.5
		var b := Vector3(x,0,z) + direction * length * 0.5
		a.y = _height(a.x,a.z)
		b.y = _height(b.x,b.z)
		var log_node := Node3D.new()
		landscape.add_child(log_node)
		log_node.position = (a+b)*0.5 + Vector3(0,0.32,0)
		log_node.basis = Basis(Quaternion(Vector3.UP,(b-a).normalized()))
		var trunk := CylinderMesh.new()
		trunk.height = a.distance_to(b)
		trunk.top_radius = 0.28
		trunk.bottom_radius = 0.4
		trunk.radial_segments = 10
		_mesh(log_node,trunk,Vector3.ZERO,bark).create_convex_collision()
		for end in [-1.0,1.0]:
			var cap := CylinderMesh.new()
			cap.height = 0.025
			cap.top_radius = 0.24 if end > 0 else 0.35
			cap.bottom_radius = cap.top_radius
			cap.radial_segments = 10
			_mesh(log_node,cap,Vector3(0,end*(trunk.height*0.5+0.01),0),wood)
		for branch in 2:
			var stub := CylinderMesh.new()
			stub.height = 0.8
			stub.top_radius = 0.05
			stub.bottom_radius = 0.12
			stub.radial_segments = 6
			var stick := _mesh(log_node,stub,Vector3(0.32,branch*1.4-0.7,0),bark)
			stick.rotation.z = -1.0
	# Terrain and rock tops support fog; trees/deadwood are outside the source subtree.

func _add_boundary(parent: Node3D) -> void:
	# Keep the walkable demo inside its finite terrain, without changing fog bounds.
	var boundary := StaticBody3D.new()
	boundary.name = "WorldBoundary"
	parent.add_child(boundary)
	for axis in 2:
		for sign_value in [-1.0, 1.0]:
			var collider := CollisionShape3D.new()
			var shape := BoxShape3D.new()
			shape.size = Vector3(0.5, 8, 49) if axis == 0 else Vector3(49, 8, 0.5)
			collider.shape = shape
			collider.position = Vector3(sign_value * 24.2, 2, 0) if axis == 0 else Vector3(0, 2, sign_value * 24.2)
			boundary.add_child(collider)
