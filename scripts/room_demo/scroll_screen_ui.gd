extends Control
## 3D 滚动屏里渲染的 UI：显示最近放到屏上的照片 / 组合结果。
## 不做输入；拖放由 room_demo 投影到屏幕的 2D 接收区处理。

signal send_requested

const COLOR_TEXT := Color(0.82, 0.92, 0.92)
const COLOR_MUTED := Color(0.55, 0.68, 0.7)
const COLOR_ACCENT := Color(0.35, 0.9, 0.82)

var _list: VBoxContainer
var _result: Label
var _send: Button


func setup() -> void:
	size = Vector2(640, 270)
	var bg := ColorRect.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.02, 0.06, 0.065, 1.0)
	add_child(bg)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 14)
	add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 6)
	margin.add_child(root)
	root.add_child(_label("滚动屏", 26, COLOR_ACCENT))
	_result = _label("等待照片……", 17, COLOR_TEXT)
	_result.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(_result)
	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", 3)
	root.add_child(_list)
	_send = Button.new()
	_send.text = "发送"
	_send.focus_mode = Control.FOCUS_NONE
	_send.custom_minimum_size = Vector2(0, 32)
	# 实际点击用的是 HUD 面板上的大发送键；这里只保留文本区域，避免重复按钮。
	_send.visible = false
	_send.pressed.connect(func(): send_requested.emit())
	root.add_child(_send)
	var hint := _label("把底部照片拖到这块屏，可放任意张\n点击发送后统一判定组合", 14, COLOR_MUTED)
	root.add_child(hint)


func refresh(photos: Array, screen_photo_ids: Array, result_text: String) -> void:
	if _list == null:
		return
	for child in _list.get_children():
		_list.remove_child(child)
		child.queue_free()
	_result.text = result_text if not result_text.is_empty() else "等待照片……"
	var shown := 0
	for raw in screen_photo_ids:
		var photo_id := String(raw)
		var photo := {}
		for entry in photos:
			if String(entry.get("id", "")) == photo_id:
				photo = entry
				break
		if photo.is_empty():
			continue
		var label := _label("• " + String(photo.get("label", photo_id)), 15, COLOR_TEXT)
		_list.add_child(label)
		shown += 1
	if shown == 0:
		_list.add_child(_label("（还没有照片）", 14, COLOR_MUTED))
	if _send != null:
		_send.disabled = screen_photo_ids.is_empty() or result_text.begins_with("滚动屏冷却中")


func _label(text: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return label
