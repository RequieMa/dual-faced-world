extends "res://scripts/puzzles/puzzle_base.gd"
## 数字密码锁：从线索里的两个数字拼出 4 位密码（40 + 12 → 4012）。

const DEFAULT_CODE := "4012"

var expected_code := DEFAULT_CODE
var entry := ""

var _entry_label: Label = null


func build_body() -> void:
	body_box.add_child(make_label("保险箱面板：4 位数字", 15))
	_entry_label = make_label(_display_entry(), 38, Color(0.95, 0.97, 1.0))
	body_box.add_child(_entry_label)

	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 6)
	body_box.add_child(grid)
	for digit in ["1", "2", "3", "4", "5", "6", "7", "8", "9"]:
		grid.add_child(make_button(digit, _on_digit_pressed.bind(digit), 64))
	grid.add_child(make_button("清除", clear_input, 64))
	grid.add_child(make_button("0", _on_digit_pressed.bind("0"), 64))
	grid.add_child(make_button("确认", submit_code, 64))


func reset() -> void:
	expected_code = DEFAULT_CODE
	entry = ""
	super.reset()


# --- 交互 API（UI 与测试共用） ------------------------------------------------

func press_digit(digit: String) -> void:
	if is_solved or digit.length() != 1 or not digit.is_valid_int():
		return
	if entry.length() >= expected_code.length():
		return
	entry += digit
	_refresh_entry()


func clear_input() -> void:
	entry = ""
	_refresh_entry()


func submit_code() -> bool:
	if is_solved:
		return false
	if entry == expected_code:
		return succeed("密码正确，保险箱「咔」地弹开了。")
	fail("门锁发出两下短促的蜂鸣：密码错误。")
	entry = ""
	_refresh_entry()
	return false


func configure(code: String) -> void:
	expected_code = code
	entry = ""
	_refresh_entry()


func get_entry() -> String:
	return entry


func get_state() -> Dictionary:
	var state := super.get_state()
	state["entry"] = entry
	state["expected"] = expected_code
	return state


# --- 内部 ---------------------------------------------------------------------

func _on_digit_pressed(digit: String) -> void:
	press_digit(digit)


func _display_entry() -> String:
	var padded := entry
	while padded.length() < expected_code.length():
		padded += "-"
	return padded


func _refresh_entry() -> void:
	if _entry_label != null:
		_entry_label.text = _display_entry()
