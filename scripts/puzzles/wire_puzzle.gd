extends "res://scripts/puzzles/puzzle_base.gd"
## 线路/连线：把左边的彩色线头接到右边正确的端子上（接线错误会弹开并给反馈）。
## 注意：方法名用 connect_wire()，避免覆盖 Object.connect()。

const PAIRS := {"红": "1", "蓝": "2", "绿": "3", "黄": "4"}
const LEFT_ORDER: Array[String] = ["红", "蓝", "绿", "黄"]
const RIGHT_ORDER: Array[String] = ["3", "1", "4", "2"]

var connected: Dictionary = {}
var selected_left := ""

var _left_box: VBoxContainer = null
var _right_box: VBoxContainer = null
var _hint_label: Label = null


func build_body() -> void:
	body_box.add_child(make_label("左边是线头颜色，右边是端子编号（顺序是打乱的）：", 14))
	var columns := HBoxContainer.new()
	columns.add_theme_constant_override("separation", 24)
	body_box.add_child(columns)

	var left_column := VBoxContainer.new()
	left_column.add_theme_constant_override("separation", 6)
	columns.add_child(left_column)
	left_column.add_child(make_label("线头", 14, Color(0.7, 0.8, 0.95)))
	_left_box = VBoxContainer.new()
	_left_box.add_theme_constant_override("separation", 4)
	left_column.add_child(_left_box)

	var right_column := VBoxContainer.new()
	right_column.add_theme_constant_override("separation", 6)
	columns.add_child(right_column)
	right_column.add_child(make_label("端子", 14, Color(0.7, 0.8, 0.95)))
	_right_box = VBoxContainer.new()
	_right_box.add_theme_constant_override("separation", 4)
	right_column.add_child(_right_box)

	body_box.add_child(HSeparator.new())
	_hint_label = make_label("先点一根线头，再点右边的端子。", 14, Color(0.72, 0.86, 1.0))
	body_box.add_child(_hint_label)
	_refresh()


func reset() -> void:
	connected.clear()
	selected_left = ""
	super.reset()


# --- 交互 API -----------------------------------------------------------------

func select_left(color: String) -> bool:
	if is_solved or connected.has(color) or not LEFT_ORDER.has(color):
		return false
	selected_left = color
	_refresh()
	return true


func connect_wire(left: String, right: String) -> bool:
	if is_solved:
		return false
	if not LEFT_ORDER.has(left) or not RIGHT_ORDER.has(right):
		return false
	if connected.has(left):
		fail("这根线头已经接好了。")
		return false
	if PAIRS.get(left, "") == right:
		connected[left] = right
		selected_left = ""
		set_status("接好了：%s → %s" % [left, right], true)
		_refresh()
		if connected.size() == PAIRS.size():
			return succeed("四路线路全部接通，指示灯亮起。")
		return true
	selected_left = ""
	fail("接错了：%s 接到 %s，火花一闪，线路弹开。" % [left, right])
	_refresh()
	return false


func get_connected() -> Dictionary:
	return connected.duplicate()


func get_state() -> Dictionary:
	var state := super.get_state()
	state["connected"] = connected.duplicate()
	state["selected_left"] = selected_left
	return state


# --- 内部 ---------------------------------------------------------------------

func _on_left_pressed(color: String) -> void:
	select_left(color)


func _on_right_pressed(right: String) -> void:
	if selected_left.is_empty():
		fail("先点左边的一根线头。")
		return
	connect_wire(selected_left, right)


func _refresh() -> void:
	if _left_box == null:
		return
	for child in _left_box.get_children():
		_left_box.remove_child(child)
		child.queue_free()
	for color in LEFT_ORDER:
		var done := connected.has(color)
		var prefix := "✓ " if done else ("▶ " if selected_left == color else "● ")
		var button := make_button(prefix + color, _on_left_pressed.bind(color), 110)
		button.disabled = done
		_left_box.add_child(button)

	for child in _right_box.get_children():
		_right_box.remove_child(child)
		child.queue_free()
	var taken: Array = connected.values()
	for right in RIGHT_ORDER:
		var done := taken.has(right)
		var button := make_button("端子 %s" % right, _on_right_pressed.bind(right), 110)
		button.disabled = done
		_right_box.add_child(button)

	if _hint_label != null:
		_hint_label.text = "先点一根线头，再点右边的端子。" if selected_left.is_empty() \
			else "已选中线头：%s —— 点右边的端子接上。" % selected_left
