extends "res://scripts/puzzles/puzzle_base.gd"
## 物品组合：把两件东西合成新道具，再用它解决环境里的问题。
## 顺带演示「错误组合有反馈、合成物进入背包」。

const RECIPES := [
	{"a": "镜片", "b": "镜筒", "result": "望远镜"},
]
const START_ITEMS: Array[String] = ["镜片", "镜筒", "纸条"]
const GOAL_TARGET := "窗台"

var inventory: Array[String] = []
var selected: Array[String] = []

var _inventory_box: VBoxContainer = null
var _selected_label: Label = null
var _combine_button: Button = null
var _goal_button: Button = null


func setup(id: String, title: String, hint: String) -> void:
	inventory.assign(START_ITEMS.duplicate())
	super.setup(id, title, hint)


func build_body() -> void:
	body_box.add_child(make_label("背包（点选两件相同的…不对，是两件不同的东西再合成）：", 14))
	_inventory_box = VBoxContainer.new()
	_inventory_box.add_theme_constant_override("separation", 4)
	body_box.add_child(_inventory_box)

	_selected_label = make_label("已选中：—", 14, Color(0.72, 0.86, 1.0))
	body_box.add_child(_selected_label)

	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 8)
	body_box.add_child(actions)
	_combine_button = make_button("合成选中两件", _on_combine_pressed)
	actions.add_child(_combine_button)
	_goal_button = make_button("用望远镜观察窗台", _on_goal_pressed)
	actions.add_child(_goal_button)
	_refresh()


func reset() -> void:
	inventory.assign(START_ITEMS.duplicate())
	selected.clear()
	super.reset()


# --- 交互 API -----------------------------------------------------------------

func combine(a: String, b: String) -> bool:
	if is_solved:
		return false
	if not inventory.has(a) or not inventory.has(b):
		fail("背包里没有这两件东西。")
		return false
	if a == b:
		fail("同一件东西拼不出新东西。")
		return false
	for recipe in RECIPES:
		var matches: bool = (String(recipe["a"]) == a and String(recipe["b"]) == b) \
			or (String(recipe["a"]) == b and String(recipe["b"]) == a)
		if matches:
			inventory.erase(a)
			inventory.erase(b)
			inventory.append(String(recipe["result"]))
			selected.clear()
			set_status("合成成功：%s + %s → %s" % [a, b, recipe["result"]], true)
			_refresh()
			return true
	fail("「%s」和「%s」拼不到一起。" % [a, b])
	selected.clear()
	_refresh()
	return false


func use(item: String, target: String) -> bool:
	if is_solved:
		return false
	if target != GOAL_TARGET:
		fail("「%s」在这里派不上用场。" % target)
		return false
	if item != "望远镜" or not inventory.has("望远镜"):
		fail("看不了那么远，得先有能用的东西。")
		return false
	return succeed("透过望远镜，你看清了对面楼里的门牌号 —— 那才是下一步的线索。")


func get_inventory() -> Array:
	return inventory.duplicate()


func get_state() -> Dictionary:
	var state := super.get_state()
	state["inventory"] = inventory.duplicate()
	state["selected"] = selected.duplicate()
	return state


# --- 内部 ---------------------------------------------------------------------

func _on_combine_pressed() -> void:
	if selected.size() != 2:
		fail("先选中两件东西（点背包里的条目）。")
		return
	combine(selected[0], selected[1])


func _on_goal_pressed() -> void:
	use("望远镜", GOAL_TARGET)


func _on_item_pressed(item: String) -> void:
	if selected.has(item):
		selected.erase(item)
	else:
		if selected.size() >= 2:
			selected.pop_front()
		selected.append(item)
	_refresh()


func _refresh() -> void:
	if _inventory_box == null:
		return
	for child in _inventory_box.get_children():
		_inventory_box.remove_child(child)
		child.queue_free()
	for item in inventory:
		var prefix := "[x] " if selected.has(item) else "[ ] "
		_inventory_box.add_child(make_button(prefix + item, _on_item_pressed.bind(item)))

	_selected_label.text = "已选中：—" if selected.is_empty() else "已选中：" + "、".join(selected)
	_combine_button.disabled = selected.size() != 2
	_goal_button.disabled = not inventory.has("望远镜")
