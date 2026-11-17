extends Control
## Read-only runtime view. The cloud is a labelled 2D slice, not the 22D search metric.

@export var character_path: NodePath
const DESIGN := Vector2(420, 550)
const INK := Color("e6eef6")
const MUTED := Color("8b9eaf")
const CYAN := Color("57daca")
const AMBER := Color("ffcb78")
const GRID := Color("283b4b")
const PLOT := Rect2(34, 126, 352, 188)
const DOT_SIDES := 12
var _character: MotionCharacter
var _database: MotionDatabase
var _points := PackedVector2Array()
# Immutable projected geometry: one background batch and one selected-clip batch.
var _cloud_mesh: ArrayMesh
var _highlight_meshes: Array[ArrayMesh] = []
var _box_styles: Dictionary[String, StyleBoxFlat] = {}
var _minimum := Vector2.ZERO
var _maximum := Vector2.ONE
var _state: Dictionary = {}
var _trail := PackedVector2Array()
var _last_mode: StringName
var _font: Font

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_character = get_node_or_null(character_path) as MotionCharacter
	_font = ThemeDB.fallback_font
	if _character == null:
		push_warning("Motion Matching view requires a MotionCharacter.")
		set_process(false)

func _process(_delta: float) -> void:
	if not is_instance_valid(_character):
		set_process(false)
		return
	var matcher := _character.motion_matching
	if matcher.database != _database:
		_database = matcher.database
		_project_database()
	_state = matcher.get_debug_state()
	if _last_mode != _state.state:
		_trail.clear()
	_last_mode = _state.state
	if _state.pose_available and _state.state in [&"Grounded", &"Crouch"]:
		var point: Vector2 = _state.pose_current
		if _trail.is_empty() or _trail[-1].distance_to(point) > 0.002:
			_trail.append(point)
			if _trail.size() > 24: _trail.remove_at(0)
	queue_redraw()

func _project_database() -> void:
	_points.clear()
	_cloud_mesh = null
	_highlight_meshes.clear()
	_minimum = Vector2.ZERO
	_maximum = Vector2.ONE
	if _database == null: return
	var groups: Array[PackedVector2Array] = []
	_minimum = Vector2(INF, INF)
	_maximum = Vector2(-INF, -INF)
	for clip in _database.clips.size():
		var group := PackedVector2Array()
		for frame in _database.counts[clip]:
			var row := (_database.starts[clip] + frame) * MotionDatabase.WIDTH
			var point := Vector2(_database.features[row + 2], _database.features[row + 5])
			_points.append(point)
			group.append(point)
			_minimum = _minimum.min(point)
			_maximum = _maximum.max(point)
		groups.append(group)
	if _points.is_empty():
		_minimum = Vector2.ZERO
		_maximum = Vector2.ONE
		return
	var padding := (_maximum - _minimum).max(Vector2(0.1, 0.1)) * 0.12
	_minimum -= padding
	_maximum += padding
	# Build once per database, never once per frame or match change. Native draw_mesh
	# reuses these buffers; changing the primary clip only selects another batch.
	_cloud_mesh = _point_mesh(_points, 1.7, Color(0.35, 0.46, 0.59, 0.30))
	for group in groups:
		_highlight_meshes.append(_point_mesh(group, 2.3, Color(0.34, 0.85, 0.79, 0.55)))

func _point_mesh(points: PackedVector2Array, radius: float, color: Color) -> ArrayMesh:
	if points.is_empty(): return null
	var vertices := PackedVector2Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var transparent := color
	transparent.a = 0.0
	for point in points:
		var center := _plot(point)
		var first := vertices.size()
		vertices.append(center)
		colors.append(color)
		# A transparent outer ring provides soft edges without per-dot AA commands
		# or runtime polygon triangulation. Parent UI scaling also scales this mesh.
		for side in DOT_SIDES:
			var direction := Vector2.from_angle(TAU * side / DOT_SIDES)
			vertices.append(center + direction * (radius - 0.5))
			vertices.append(center + direction * (radius + 0.5))
			colors.append(color)
			colors.append(transparent)
		for side in DOT_SIDES:
			var inner := first + 1 + side * 2
			var next := first + 1 + (side + 1) % DOT_SIDES * 2
			indices.append_array(PackedInt32Array([first, inner, next, inner, inner + 1, next, next, inner + 1, next + 1]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh

func _plot(point: Vector2) -> Vector2:
	var uv := (point - _minimum) / (_maximum - _minimum)
	return PLOT.position + Vector2(uv.x, 1.0 - uv.y) * PLOT.size

func _text(position: Vector2, value: String, font_size: int = 14, color: Color = INK) -> void:
	draw_string(_font, position, value, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)

func _box(rect: Rect2, color: Color, radius: int = 12, border: Color = Color.TRANSPARENT) -> void:
	var key := "%s/%d/%s" % [color.to_html(), radius, border.to_html()]
	var style := _box_styles.get(key) as StyleBoxFlat
	if style == null:
		style = StyleBoxFlat.new()
		style.bg_color = color
		style.set_corner_radius_all(radius)
		style.border_color = border
		style.set_border_width_all(1 if border.a > 0.0 else 0)
		_box_styles[key] = style
	draw_style_box(style, rect)

func _draw() -> void:
	if _font == null: return
	draw_set_transform(Vector2.ZERO, 0.0, size / DESIGN)
	_box(Rect2(Vector2.ZERO, DESIGN), Color(0.035, 0.055, 0.078, 0.96), 16, GRID)
	_text(Vector2(22, 26), "ANIMATION / LIVE", 11, MUTED)
	_text(Vector2(22, 55), "Motion Matching", 25)
	if _state.is_empty() or _database == null:
		_text(Vector2(22, 90), "Waiting for animation samples...", 14, MUTED)
		return
	var grounded: bool = _state.state == &"Grounded"
	var climbing: bool = _state.state == &"Climb"
	var matching: bool = _state.state in [&"Grounded", &"Crouch"]
	var mode := "CLIMB" if climbing else ("CROUCH" if _state.state == &"Crouch" else ("LIVE" if grounded else "NATIVE"))
	_box(Rect2(326, 25, 72, 25), Color("193d3b") if matching else GRID, 6)
	_text(Vector2(336, 43), mode, 11, CYAN if matching else MUTED)
	var clip: String = _state.clip if matching else str(_state.state)
	_text(Vector2(22, 82), "%s  /  %.2f s" % [clip, _state.time] if matching else clip + (" / procedural constraints" if climbing else " / native animation"), 16, CYAN)
	_text(Vector2(22, 107), "%d sampled frames / 22D search" % _points.size(), 12, MUTED)
	_draw_cloud(matching)
	var run: float = _state.run_blend if grounded else 0.0
	var side: float = _state.walk.direction_blend if grounded else 0.0
	_text(Vector2(22, 368), "LIVE MIX / CHANNEL CONTRIBUTION", 11, MUTED)
	if grounded:
		var channels: Array = [_state.walk.longitudinal, _state.walk.lateral, _state.run.longitudinal, _state.run.lateral]
		var weights := [(1.0 - run) * (1.0 - side), (1.0 - run) * side, run * (1.0 - side), run * side]
		for index in 4:
			_channel_row(391 + index * 24, ["Walk Z", "Walk X", "Run Z", "Run X"][index], channels[index].clip, weights[index])
	elif matching:
		_channel_row(391, "Crouch", _state.clip, 1.0)
		_text(Vector2(22, 429), "Single crouch retrieval channel", 13, MUTED)
	else:
		_text(Vector2(22, 402), "Ground search and pose decay bypassed", 14, MUTED)
		_text(Vector2(22, 429), "Surface palms > body constraints > arm IK" if climbing else "Driven by vertical velocity + floor contact", 13, MUTED)
	var matcher := _character.motion_matching
	var smoothing := matching and matcher.pose_smoothing_enabled and matcher.pose_half_life > 0.0
	_text(Vector2(22, 497), "DECAY  %s" % ("ON / %.3f s half-life" % matcher.pose_half_life if smoothing else "BYPASS"), 12, AMBER if smoothing else MUTED)
	_text(Vector2(22, 520), "grip > body collision > shoulders + sway > arm IK" if climbing else "pose + trajectory  >  search  >  blend  >  decay  >  IK", 12, MUTED)
	_text(Vector2(22, 539), "cost %.2f  /  rate x%.2f" % [_state.cost, _state.rate] if matching else ("ESC: detach; regrab resets only on landing" if climbing else "Native airborne playback; no stale ground markers"), 11, MUTED)

func _draw_cloud(matching: bool) -> void:
	_box(PLOT.grow(8), Color("0b1520"), 8)
	for step in 5:
		var x := PLOT.position.x + PLOT.size.x * step / 4.0
		var y := PLOT.position.y + PLOT.size.y * step / 4.0
		draw_line(Vector2(x, PLOT.position.y), Vector2(x, PLOT.end.y), GRID, 1.0)
		draw_line(Vector2(PLOT.position.x, y), Vector2(PLOT.end.x, y), GRID, 1.0)
	var primary := _database.clips.find(_state.clip) if matching else -1
	if _cloud_mesh != null: draw_mesh(_cloud_mesh, null)
	if primary >= 0 and primary < _highlight_meshes.size() and _highlight_meshes[primary] != null:
		draw_mesh(_highlight_meshes[primary], null)
	if matching and _state.pose_available:
		for index in range(1, _trail.size()):
			draw_line(_plot(_trail[index - 1]), _plot(_trail[index]), Color(1.0, 0.8, 0.47, float(index) / _trail.size() * 0.5), 1.5, true)
		var target := _plot(_state.pose_target)
		var current := _plot(_state.pose_current)
		draw_line(current, target, Color(0.8, 0.88, 0.92, 0.7), 1.0, true)
		draw_circle(target, 8, CYAN, false, 2.0, true)
		draw_circle(current, 5, AMBER, true, -1, true)
	# Fixed legend remains readable when p and P coincide or approach plot edges.
	_text(Vector2(34, 335), "L foot z: %.2f ... %.2f m / R foot z: vertical" % [_minimum.x, _maximum.x], 10, MUTED)
	draw_circle(Vector2(40, 351), 4, CYAN, false, 1.5, true)
	_text(Vector2(50, 355), "P target", 11, CYAN)
	draw_circle(Vector2(134, 351), 3, AMBER)
	_text(Vector2(144, 355), "p tracked", 11, AMBER)
	_text(Vector2(267, 355), "2D pose slice", 11, MUTED)

func _channel_row(y: float, axis: String, clip: String, weight: float) -> void:
	var color := CYAN if weight > 0.001 else MUTED
	_text(Vector2(22, y), axis, 12, color)
	_text(Vector2(83, y), clip, 12, color)
	var bar := Rect2(230, y - 10, 117, 5)
	_box(bar, GRID, 2)
	if weight > 0.001: _box(Rect2(bar.position, Vector2(bar.size.x * weight, bar.size.y)), CYAN, 2)
	_text(Vector2(360, y), "%3.0f%%" % (weight * 100.0), 12, color)
