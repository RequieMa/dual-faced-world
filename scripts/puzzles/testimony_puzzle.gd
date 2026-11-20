extends "res://scripts/puzzles/puzzle_base.gd"
## 证词推理：读四条证词，选出与现场矛盾的那一条（叙事型解谜）。

const TESTIMONIES := [
	{"id": "甲", "text": "我一直在一楼大厅，整晚没上过二楼。"},
	{"id": "乙", "text": "九点左右，我听见二楼传来玻璃碎裂的声音。"},
	{"id": "丙", "text": "九点我在二楼走廊，什么声音都没听见。"},
	{"id": "丁", "text": "九点我在一楼厨房，正和甲说了几句话。"},
]
const CONTRADICTION := "丙"
const REASON := "丙说自己在二楼走廊却什么都没听见 —— 而走廊尽头那扇窗正是在九点被打破的。"

var selected := ""

var _choice_buttons: Dictionary = {}


func build_body() -> void:
	body_box.add_child(make_label("现场：二楼走廊尽头的窗在九点被打破，碎玻璃落在走廊地毯上。", 14))
	body_box.add_child(HSeparator.new())
	for testimony in TESTIMONIES:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		var button := make_button("就是他", select.bind(String(testimony["id"])), 80)
		row.add_child(button)
		row.add_child(make_label("%s：%s" % [String(testimony["id"]), String(testimony["text"])], 15))
		body_box.add_child(row)
		_choice_buttons[String(testimony["id"])] = button


func reset() -> void:
	selected = ""
	super.reset()


# --- 交互 API -----------------------------------------------------------------

func select(id: String) -> bool:
	if is_solved or not _has_id(id):
		return false
	selected = id
	if id == CONTRADICTION:
		return succeed("说中了：%s。%s" % [id, REASON])
	fail("%s 的证词解释得通，和现场并不冲突。" % id)
	return false


func get_selected() -> String:
	return selected


func get_state() -> Dictionary:
	var state := super.get_state()
	state["selected"] = selected
	state["solution"] = CONTRADICTION
	return state


# --- 内部 ---------------------------------------------------------------------

func _has_id(id: String) -> bool:
	for testimony in TESTIMONIES:
		if String(testimony["id"]) == id:
			return true
	return false
