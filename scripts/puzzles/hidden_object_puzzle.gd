extends "res://scripts/puzzles/puzzle_base.gd"
## 隐藏物：在 9 个可翻找的位置里找到 5 件目标物；翻空只给反馈，不惩罚。

const SPOTS := [
	{"label": "书架上", "target": "纸条"},
	{"label": "花盆底", "target": "钥匙"},
	{"label": "地毯下", "target": "硬币"},
	{"label": "抽屉里", "target": "纽扣"},
	{"label": "窗帘后", "target": "螺丝刀"},
	{"label": "柜子顶", "target": ""},
	{"label": "水池边", "target": ""},
	{"label": "椅子下", "target": ""},
	{"label": "门缝里", "target": ""},
]

var found: Dictionary = {}
var misses := 0

var _found_label: Label = null


func build_body() -> void:
	body_box.add_child(make_label("翻找房间：找出 5 件物品（翻空会浪费一次机会，但不扣分）。", 14))
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 6)
	body_box.add_child(grid)
	for index in range(SPOTS.size()):
		grid.add_child(make_button(String(SPOTS[index]["label"]), search.bind(index), 130))

	body_box.add_child(HSeparator.new())
	_found_label = make_label("已找到：0 / 5", 15, Color(0.72, 0.86, 1.0))
	body_box.add_child(_found_label)


func reset() -> void:
	found.clear()
	misses = 0
	super.reset()


# --- 交互 API -----------------------------------------------------------------

func search(index: int) -> bool:
	if is_solved or index < 0 or index >= SPOTS.size():
		return false
	var target: String = String(SPOTS[index]["target"])
	var label: String = String(SPOTS[index]["label"])
	if target.is_empty():
		misses += 1
		fail("「%s」什么都没有。" % label)
		return false
	if found.has(target):
		fail("「%s」已经找过了。" % label)
		return false
	found[target] = true
	set_status("在「%s」找到了：%s" % [label, target], true)
	_refresh()
	if found.size() == _target_count():
		return succeed("五件物品全部找到了。")
	return true


func get_found() -> Array:
	return found.keys()


func get_spots() -> Array:
	return SPOTS.duplicate(true)


func get_state() -> Dictionary:
	var state := super.get_state()
	state["found"] = found.keys()
	state["misses"] = misses
	return state


# --- 内部 ---------------------------------------------------------------------

func _target_count() -> int:
	var total := 0
	for spot in SPOTS:
		if not String(spot["target"]).is_empty():
			total += 1
	return total


func _refresh() -> void:
	if _found_label == null:
		return
	_found_label.text = "已找到：%d / %d" % [found.size(), _target_count()]
