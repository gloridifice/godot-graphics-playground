@tool
extends RefCounted
## Main-thread live lights, independent of the static geometry snapshot.
## Keep hidden and zero-energy candidates so they can contribute when enabled.

const MAX_LIGHTS := 8
const BUFFER_BYTES := MAX_LIGHTS * 32 # two vec4s per light

var _source: Node
var _proxy: Node3D
var _origin: Vector3
var _candidates: Array[Light3D] = []

func _init(source: Node, proxy: Node3D, origin: Vector3) -> void:
	_source = source
	_proxy = proxy
	_origin = origin
	var pending: Array[Node] = [source]
	while not pending.is_empty():
		var node: Node = pending.pop_back()
		_track(node)
		pending.append_array(node.get_children())
	# Node enter/exit also covers reparenting. The connections die with this list.
	var tree := source.get_tree()
	tree.node_added.connect(_track)
	tree.node_removed.connect(_untrack)

func _track(node: Node) -> void:
	if (node is DirectionalLight3D or node is OmniLight3D) and is_instance_valid(_source):
		if node == _source or _source.is_ancestor_of(node):
			_candidates.append(node as Light3D)

func _untrack(node: Node) -> void:
	if node is Light3D:
		_candidates.erase(node)

func _participates(node: Node, proxy: Node3D) -> bool:
	while node:
		if node == proxy or node is Viewport or node.is_in_group(&"split_rc_ignore"):
			return false
		if node is Node3D and not node.is_visible_in_tree():
			return false
		if node == _source:
			return true
		node = node.get_parent()
	return false

func pack() -> PackedVector4Array:
	var data := PackedVector4Array()
	if not is_instance_valid(_source) or not _source.is_inside_tree():
		return data
	var proxy := _proxy if is_instance_valid(_proxy) else null
	for light in _candidates:
		if light.light_negative or not _participates(light, proxy):
			continue
		var energy := light.light_color.srgb_to_linear() * light.light_energy * light.light_indirect_energy
		if energy.r + energy.g + energy.b <= 0.0:
			continue
		var v: Vector3
		var radius := 0.0
		var attenuation := 0.0
		if light is OmniLight3D:
			radius = light.omni_range
			if radius <= 0.0:
				continue
			v = light.global_position - _origin
			attenuation = light.omni_attenuation
		else:
			v = light.global_basis.z.normalized()
		data.append(Vector4(v.x, v.y, v.z, radius)) # w=0 for directional lights
		data.append(Vector4(energy.r, energy.g, energy.b, attenuation))
		if data.size() == MAX_LIGHTS * 2:
			break
	return data
