extends "res://scripts/puzzles/puzzle_base.gd"
## 开关顺序：按图纸顺序按下 5 个阀门；按错一个全部复位。

const DEFAULT_SEQUENCE: Array[int] = [2, 4, 1, 3, 5]
const LETTERS: Array[String] = ["A", "B", "C", "D", "E"]

var target_sequence: Array[int] = DEFAULT_SEQUENCE.duplicate()
var progress: Array[int] = []

var _progress_label: Label = null
var _valve_buttons: Array[Button] = []


func build_body() -> void:
	body_box.add_child(make_label("5 个阀门（A–E）：", 15))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	body_box.add_child(row)
	_valve_buttons.clear()
	for index in range(LETTERS.size()):
		var button := make_button(LETTERS[index], press.bind(index + 1), 64)
		row.add_child(button)
		_valve_buttons.append(button)

	body_box.add_child(HSeparator.new())
	_progress_label = make_label("已按：—", 16, Color(0.72, 0.86, 1.0))
	body_box.add_child(_progress_label)


func reset() -> void:
	progress.clear()
	super.reset()


# --- 交互 API -----------------------------------------------------------------

## index 从 1 开始（1=A … 5=E）。
func press(index: int) -> bool:
	if is_solved or index < 1 or index > target_sequence.size():
		return false
	var step := progress.size()
	progress.append(index)
	if target_sequence[step] != index:
		progress.clear()
		fail("顺序错了：管道里「嗤」的一声，全部阀门自动复位。")
		_refresh()
		return false
	_refresh()
	if progress.size() == target_sequence.size():
		return succeed("五个阀门依次亮起，水流恢复了。")
	return true


func get_progress() -> Array:
	return progress.duplicate()


func get_solution_letters() -> String:
	var parts: Array[String] = []
	for value in target_sequence:
		parts.append(LETTERS[value - 1])
	return " → ".join(parts)


func get_state() -> Dictionary:
	var state := super.get_state()
	state["progress"] = progress.duplicate()
	state["solution"] = get_solution_letters()
	return state


# --- 内部 ---------------------------------------------------------------------

func _refresh() -> void:
	if _progress_label == null:
		return
	if progress.is_empty():
		_progress_label.text = "已按：—"
	else:
		var parts: Array[String] = []
		for value in progress:
			parts.append(LETTERS[value - 1])
		_progress_label.text = "已按：" + " → ".join(parts)
