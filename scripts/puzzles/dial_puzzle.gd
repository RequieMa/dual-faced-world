extends "res://scripts/puzzles/puzzle_base.gd"
## 转盘/拨轮：把三个拨轮旋到线索给出的刻度（保险箱式）。

const DIAL_COUNT := 3
const DEFAULT_TARGET: Array[int] = [3, 7, 1]

var target: Array[int] = DEFAULT_TARGET.duplicate()
var values: Array[int] = [0, 0, 0]

var _value_labels: Array[Label] = []


func build_body() -> void:
	# 每次重建都从空列表开始：否则重复 reset() 会把已释放的 Label 留在表里，
	# _refresh() 写到 underfreed 对象上（实测 size 累积成 6/9、数值不再更新）。
	_value_labels.clear()
	body_box.add_child(make_label("三个拨轮（0–9），按线索停到正确刻度：", 14))
	for index in range(DIAL_COUNT):
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		var caption := make_label("拨轮 %d" % (index + 1), 16)
		caption.autowrap_mode = TextServer.AUTOWRAP_OFF
		caption.custom_minimum_size = Vector2(72, 0)
		row.add_child(caption)
		row.add_child(make_button("◀", _on_rotate_pressed.bind(index, -1), 44))
		var value_label := make_label("0", 30, Color(0.95, 0.97, 1.0))
		value_label.custom_minimum_size = Vector2(44, 0)
		row.add_child(value_label)
		_value_labels.append(value_label)
		row.add_child(make_button("▶", _on_rotate_pressed.bind(index, 1), 44))
		body_box.add_child(row)
	body_box.add_child(make_label("提示：门牌号 3 · 7 · 1，从左到右对应拨轮 1–3。", 13, Color(0.68, 0.76, 0.9)))
	_refresh()


func reset() -> void:
	target = DEFAULT_TARGET.duplicate()
	values = []
	for index in range(DIAL_COUNT):
		values.append(0)
	super.reset()


# --- 交互 API -----------------------------------------------------------------

func rotate(index: int, delta: int) -> bool:
	if is_solved or index < 0 or index >= DIAL_COUNT or delta == 0:
		return false
	values[index] = posmod(values[index] + delta, 10)
	_refresh()
	if values == target:
		return succeed("三个拨轮停在 %d-%d-%d，锁舌缩了回去。" % [target[0], target[1], target[2]])
	return true


func get_values() -> Array:
	return values.duplicate()


func get_state() -> Dictionary:
	var state := super.get_state()
	state["values"] = values.duplicate()
	state["target"] = target.duplicate()
	return state


# --- 内部 ---------------------------------------------------------------------

func _on_rotate_pressed(index: int, delta: int) -> void:
	rotate(index, delta)


func _refresh() -> void:
	for index in range(_value_labels.size()):
		if index < values.size():
			_value_labels[index].text = str(values[index])
