class_name DraggableNumber
extends SpinBox

# Number scrubbing leaves normal SpinBox bounds, arrows and text parsing intact.
# The cursor stays visible, so dragging UI cannot capture the gameplay camera.
var _armed: bool = false
var _editing: bool = false
var _distance: float = 0.0
var _drag_value: float = 0.0

func _ready() -> void:
	var edit := get_line_edit()
	edit.editable = false
	edit.mouse_filter = Control.MOUSE_FILTER_STOP
	edit.mouse_default_cursor_shape = Control.CURSOR_HSIZE
	edit.gui_input.connect(_number_input)
	edit.text_submitted.connect(func(_text: String): _finish_edit.call_deferred())
	edit.focus_exited.connect(_finish_edit)
	tooltip_text = "左右拖动数值；Shift 精细调节；双击输入，Enter 或移开焦点确认。改值立即重置雾场。"
	edit.tooltip_text = tooltip_text

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_armed = false

func _number_input(event: InputEvent) -> void:
	var edit := get_line_edit()
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed and event.double_click:
			_armed = false
			_editing = true
			edit.editable = true
			edit.mouse_default_cursor_shape = Control.CURSOR_IBEAM
			edit.grab_focus()
			edit.select_all.call_deferred()
			edit.accept_event()
		elif not _editing:
			_armed = event.pressed
			_distance = 0.0
			_drag_value = value
			if event.pressed:
				edit.grab_focus()
			edit.accept_event()
	elif event is InputEventMouseMotion and _armed and not _editing:
		if not event.button_mask & MOUSE_BUTTON_MASK_LEFT:
			_armed = false
			return
		_distance += absf(event.relative.x)
		_drag_value += event.relative.x * step * (0.1 if event.shift_pressed else 1.0)
		_drag_value = clampf(_drag_value, min_value, max_value)
		if _distance >= 3.0:
			value = _drag_value
		edit.accept_event()

func _finish_edit() -> void:
	if not _editing:
		return
	_editing = false
	apply()
	var edit := get_line_edit()
	edit.editable = false
	edit.deselect()
	edit.mouse_default_cursor_shape = Control.CURSOR_HSIZE
