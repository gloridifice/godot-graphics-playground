extends SceneTree
## Exercise the shipped gather / deposit / merge kernels on controlled rays. A
## rendered average cannot distinguish a missing direction from a valid black one,
## or two full deposits from two complementary ones in a uniform lighting field.
const ShaderFile := preload("../shaders/cascades.glsl")
var _owned: Array[RID] = []
var _failures := 0

func _initialize() -> void:
	if not RenderingServer.get_rendering_device():
		push_error("interval_bins_test requires a real RenderingDevice")
		quit(2)
		return
	root.unfocusable = true
	RenderingServer.call_on_render_thread(_run)

func _zeros(size: int) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(size)
	return bytes

func _run() -> void:
	var rd := RenderingServer.get_rendering_device()
	var params := _zeros(240)
	# World origin lies one quarter of the way through the log-distance fade.
	params.encode_float(112, pow(2.0,0.65+0.35*0.25)) # camera translation x
	for c in 4:
		params.encode_u32(128+c*4,8) # one 8-way bucket per level
		params.encode_u32(144+c*4,c*8)
		params.encode_u32(160+c*4,[0,64,320,1344][c])
		params.encode_float(176+c*4,1.0)
		params.encode_u32(192+c*4,[3,1,1,1][c]) # three one-pixel tiles, frame 1
	var incoming := PackedVector4Array([
		Vector4(0,0,0,0.1), Vector4(0,0,0,8),  # C0 direction 1: black opaque hit
		Vector4(0,0,0,9.0), Vector4(0,0,0,16), # C0 direction 2: crossed interval
		Vector4(0,0,0,0.1), Vector4(3,0,0,24), # C0 direction 3: emissive hit
	])
	var bins := _zeros(5440*64)
	for b in range(64,320): # all C1 directions share the same known red background
		bins.encode_float(b*64+48,2.0)
		bins.encode_float(b*64+60,1.0)
	var ids: Array[RID] = [rd.uniform_buffer_create(240,params)]
	for data: PackedByteArray in [_zeros(32*16),_zeros(64),_zeros(32*4),bins,incoming.to_byte_array(),_zeros(64),_zeros(64),_zeros(64),_zeros(64)]:
		ids.append(rd.storage_buffer_create(data.size(),data))
	_owned.append_array(ids)
	var fmt := RDTextureFormat.new()
	fmt.width = 1
	fmt.height = 1
	fmt.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	var sampler := rd.sampler_create(RDSamplerState.new())
	_owned.append(sampler)
	for i in 5:
		var texture := rd.texture_create(fmt,RDTextureView.new())
		ids.append(texture)
		_owned.append(texture)
	var uniforms: Array[RDUniform] = []
	for i in ids.size():
		var u := RDUniform.new()
		u.binding = i
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		if i == 0: u.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
		elif i == 10 or i == 11 or i == 13:
			u.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
			u.add_id(sampler)
		elif i == 12 or i == 14: u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		u.add_id(ids[i])
		uniforms.append(u)
	var shader := rd.shader_create_from_spirv(ShaderFile.get_spirv())
	var pipeline := rd.compute_pipeline_create(shader)
	var bindings := rd.uniform_set_create(uniforms,shader,0)
	for stage in [2,3,4,5]: # gather two C0 slots, allocate parents, split rays, merge C0
		var list := rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(list,pipeline)
		rd.compute_list_bind_uniform_set(list,bindings,0)
		rd.compute_list_set_push_constant(list,PackedInt32Array([stage,0,0,0]).to_byte_array(),16)
		rd.compute_list_dispatch(list,2 if stage == 5 else 1,1,1)
		rd.compute_list_end()
	var slots := rd.buffer_get_data(ids[1],0,8*16)
	var result := rd.buffer_get_data(ids[4],0,64*64)
	var levels := 0
	for id in 8:
		var key := slots.decode_u32(id*16)
		if key == 0: continue
		var level := (key-1)>>27
		levels |= 1<<level
		var expected_mass := 0.84375 if level == 0 else 0.15625 # complementary smoothstep weights
		for d in 4:
			var offset := (id*8+d)*64
			var red := result.decode_float(offset+48)
			var weight := result.decode_float(offset+60)
			var expected_red: float = [0.0,0.0,2.0,3.0][d]
			var expected_weight := 0.0 if d == 0 else expected_mass
			var label: String = ["unsampled","blocked","transmitted","emissive"][d]
			_check(absf(red-expected_red) < 0.01 and absf(weight-expected_weight) < 0.005,
				"LOD %d %s: red=%.3f weight=%.3f (expected %.3f / %.3f)" % [level,label,red,weight,expected_red,expected_weight])
	_check(levels == 3,"both overlapping LODs contributed")
	for rid: RID in [bindings,pipeline,shader]: rd.free_rid(rid)
	for rid in _owned: rd.free_rid(rid)
	print("Split RC directional bins: %d failure(s)" % _failures)
	quit.call_deferred(1 if _failures else 0)

func _check(ok: bool, message: String) -> void:
	if ok: print("PASS: ",message)
	else:
		_failures += 1
		push_error(message)
