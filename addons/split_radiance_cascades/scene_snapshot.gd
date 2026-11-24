@tool
extends RefCounted
## Main-thread static geometry snapshot. BVH nodes are depth-first, with an escape
## index so GPU traversal needs neither recursion nor a fixed-depth per-ray stack.

const MAX_TRIANGLES := 65536

class Face:
	var a: Vector3
	var ab: Vector3
	var ac: Vector3
	var center: Vector3
	var bounds: AABB
	var material: int

# Receivers always follow visible geometry, not the optional tracing proxy.
# Keep them indexed: a detailed model must not expand to three vertices per face.
class ReceiverBatch:
	var traced := false # Material also used by a ray-hit surface (including hidden proxies).
	var positions := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	var tint := Vector4.ONE
	var metal_weights := Vector4.ZERO
	var texture: Texture2D
	var metal_texture: Texture2D
	var texture_rid: RID
	var metal_rid: RID
	var filter := BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	var repeat := true

var receivers: Array[ReceiverBatch] = [] # indexed like materials (one batch per material)
var origin := Vector3.ZERO
var nodes := PackedVector4Array() # min.xyz / escape, max.xyz / (first triangle << 3 | leaf count)
var triangles := PackedVector4Array() # a / material, ab, ac
var materials := PackedVector4Array() # linear diffuse reflectance, emitted radiance
# Hardware trace surfaces stay in mesh-local space. A BLAS is shared even if
# two instances use different material overrides; the TLAS instance selects it.
class TraceSurface:
	var vertices: PackedVector3Array
	var indices: PackedInt32Array

class TraceInstance:
	var surface: int
	var material: int
	var transform: Transform3D

var hardware := false
var surfaces: Array[TraceSurface] = []
var instances: Array[TraceInstance] = []
var _surface_ids := {}
var _faces: Array[Face] = []
var _material_ids := {}

func build(root: Node, proxy: Node3D = null, use_hardware := false) -> bool:
	hardware = use_hardware
	if root is Node3D:
		origin = (root as Node3D).global_position
	if proxy and not _collect(proxy, true, false):
		return false
	if not _collect(root, proxy == null, true, proxy):
		return false
	if _faces.is_empty() and instances.is_empty():
		push_warning("Split RC: no supported opaque trace geometry under %s." % (proxy if proxy else root).get_path())
		return false
	if not hardware:
		_build_node(_faces)
	_faces.clear()
	_surface_ids.clear()
	_material_ids.clear()
	return true

func _collect(root: Node, trace: bool, receive: bool, exclude: Node = null) -> bool:
	var pending: Array[Node] = [root]
	while not pending.is_empty():
		var node: Node = pending.pop_back()
		if node == exclude or node is Viewport or node.is_in_group(&"split_rc_ignore"):
			continue
		if node is Node3D:
			# A proxy root may be hidden; still respect hidden descendants.
			if (receive and not node.is_visible_in_tree()) or (not receive and node != root and not node.visible):
				continue
		if node is MeshInstance3D:
			if not _add_mesh(node, trace, receive):
				push_warning("Split RC: trace triangle budget exceeded (%d); snapshot rejected." % MAX_TRIANGLES)
				return false
		pending.append_array(node.get_children())
	return true

func _add_mesh(instance: MeshInstance3D, trace: bool, receive: bool) -> bool:
	var mesh := instance.mesh
	if not (mesh is ArrayMesh or mesh is PrimitiveMesh) or instance.skin != null or instance.layers == 0:
		return true
	var xf := instance.global_transform
	xf.origin -= origin
	for surface in mesh.get_surface_count():
		if mesh is ArrayMesh and (mesh as ArrayMesh).surface_get_primitive_type(surface) != Mesh.PRIMITIVE_TRIANGLES:
			continue
		var mat := instance.get_active_material(surface)
		if mat != null and (not mat is BaseMaterial3D or (mat as BaseMaterial3D).transparency != BaseMaterial3D.TRANSPARENCY_DISABLED):
			continue
		var arrays := mesh.surface_get_arrays(surface)
		if arrays.is_empty() or arrays[Mesh.ARRAY_BONES] != null:
			continue
		var local: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		if indices.is_empty():
			indices.resize(local.size())
			for j in indices.size(): indices[j] = j
		if indices.size() < 3: continue
		var material := _material_id(mat)
		if trace: receivers[material].traced = true
		if trace and hardware:
			var key := [mesh.get_rid(), surface]
			if not _surface_ids.has(key):
				var geometry := TraceSurface.new()
				geometry.vertices = local
				geometry.indices = indices
				_surface_ids[key] = surfaces.size()
				surfaces.append(geometry)
			var inst := TraceInstance.new()
			inst.surface = _surface_ids[key]
			inst.material = material
			inst.transform = xf
			instances.append(inst)
			if not receive: continue
		var vertices := xf * local
		if trace and not hardware and not _add_faces(vertices, indices, material):
			return false
		if receive:
			var batch := receivers[material]
			var offset := batch.positions.size()
			if offset:
				if hardware and trace: indices = indices.duplicate() # BLAS indices remain local.
				for j in indices.size(): indices[j] += offset
			batch.indices.append_array(indices)
			batch.positions.append_array(vertices)
			var uv := PackedVector2Array()
			if (batch.texture or batch.metal_texture) and arrays[Mesh.ARRAY_TEX_UV] != null:
				uv = arrays[Mesh.ARRAY_TEX_UV]
				var base := mat as BaseMaterial3D
				var scale := Vector2(base.uv1_scale.x, base.uv1_scale.y)
				var shift := Vector2(base.uv1_offset.x, base.uv1_offset.y)
				if scale != Vector2.ONE or shift != Vector2.ZERO:
					for j in uv.size(): uv[j] = uv[j] * scale + shift
			else:
				uv.resize(vertices.size())
			batch.uvs.append_array(uv)
	return true

func _add_faces(vertices: PackedVector3Array, indices: PackedInt32Array, material: int) -> bool:
	for i in range(0, indices.size() - 2, 3):
		var a := vertices[indices[i]]
		var b := vertices[indices[i+1]]
		var c := vertices[indices[i+2]]
		if (b - a).cross(c - a).length_squared() < 1e-16:
			continue
		if _faces.size() >= MAX_TRIANGLES:
			return false
		var face := Face.new()
		face.a = a
		face.ab = b - a
		face.ac = c - a
		face.center = (a + b + c) / 3.0
		face.bounds = AABB(a,Vector3.ZERO).expand(a+face.ab).expand(a+face.ac)
		face.material = material
		_faces.append(face)
	return true

func _material_id(mat: BaseMaterial3D) -> int:
	var key := mat.get_instance_id() if mat else 0
	if _material_ids.has(key):
		return _material_ids[key]
	var index := materials.size() >> 1
	var diffuse := Color.WHITE
	var emission := Color.BLACK
	var batch := ReceiverBatch.new()
	receivers.append(batch)
	if mat:
		# Triplanar/custom mapping is not an ordinary UV1 albedo map.
		batch.texture = mat.albedo_texture if not mat.uv1_triplanar else null
		batch.filter = mat.texture_filter
		batch.repeat = mat.texture_repeat
		if batch.texture:
			batch.texture_rid = batch.texture.get_rid()
		var albedo := mat.albedo_color.srgb_to_linear()
		diffuse = albedo * (1.0 - mat.metallic)
		batch.tint = Vector4(diffuse.r, diffuse.g, diffuse.b, 1.0)
		# glTF uses a factor of 1 with a (usually mostly black) metallic map;
		# treating the factor alone as metal would turn even stone receivers black.
		if mat.metallic > 0.0 and mat.metallic_texture and not mat.uv1_triplanar:
			batch.tint = Vector4(albedo.r, albedo.g, albedo.b, 1.0)
			batch.metal_texture = mat.metallic_texture
			batch.metal_rid = batch.metal_texture.get_rid()
			if mat.metallic_texture_channel == BaseMaterial3D.TEXTURE_CHANNEL_GRAYSCALE:
				batch.metal_weights = Vector4(1.0/3.0, 1.0/3.0, 1.0/3.0, 0) * mat.metallic
			else:
				batch.metal_weights[mat.metallic_texture_channel] = mat.metallic
		if mat.emission_enabled:
			emission = mat.emission.srgb_to_linear() * mat.emission_energy_multiplier
	materials.append(Vector4(diffuse.r, diffuse.g, diffuse.b, 0))
	materials.append(Vector4(emission.r, emission.g, emission.b, 0))
	_material_ids[key] = index
	return index

func _build_node(faces: Array[Face]) -> void:
	var index := nodes.size()
	nodes.resize(index + 2)
	var bounds := faces[0].bounds
	var centers := AABB(faces[0].center,Vector3.ZERO)
	for f in faces:
		bounds = bounds.merge(f.bounds)
		centers = centers.expand(f.center)
	var first := 0
	var count := 0
	if faces.size() <= 4:
		first = triangles.size() / 3
		count = faces.size()
		for f in faces:
			triangles.append(Vector4(f.a.x, f.a.y, f.a.z, f.material))
			triangles.append(Vector4(f.ab.x, f.ab.y, f.ab.z, 0))
			triangles.append(Vector4(f.ac.x, f.ac.y, f.ac.z, 0))
	else:
		var axis := centers.size.max_axis_index()
		faces.sort_custom(func(a: Face, b: Face) -> bool: return a.center[axis] < b.center[axis])
		var split := _split_index(faces)
		_build_node(faces.slice(0, split))
		_build_node(faces.slice(split))
	var low := bounds.position
	var high := bounds.end
	nodes[index] = Vector4(low.x, low.y, low.z, nodes.size() >> 1)
	nodes[index + 1] = Vector4(high.x, high.y, high.z, (first << 3) | count)

# Compare seven splits on the widest centroid axis. Area times primitive count
# estimates traversal work; equal-sized groups bound recursion even with coincident centers.
func _split_index(faces: Array[Face]) -> int:
	var size := faces.size()
	if size < 16: return size >> 1
	var groups: Array[AABB] = []
	for i in 8:
		var start := size*i/8
		var bounds := faces[start].bounds
		for j in range(start+1,size*(i+1)/8): bounds = bounds.merge(faces[j].bounds)
		groups.append(bounds)
	var right := groups.duplicate()
	for i in range(6,0,-1): right[i] = right[i].merge(right[i+1])
	var left := groups[0]
	var best_cost := INF
	var split := size >> 1
	for i in range(1,8):
		var n := size*i/8
		var cost := n*_half_area(left) + (size-n)*_half_area(right[i])
		if cost < best_cost:
			best_cost = cost
			split = n
		left = left.merge(groups[i])
	return split

func _half_area(box: AABB) -> float:
	var s := box.size
	return s.x*s.y + s.y*s.z + s.z*s.x
