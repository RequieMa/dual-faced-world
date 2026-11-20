extends "res://scripts/puzzles/puzzle_base.gd"
## 钥匙-门：先在世界里拾取物品（其中有一把是错的），再把对的钥匙用到铁门上。

const WORLD_ITEMS := {
	"黄铜钥匙": "挂在门边的钉子上",
	"生锈钥匙": "躺在抽屉里",
	"回形针": "掉在地毯缝里",
}
const TARGET_DOOR := "铁门"

var inventory: Array[String] = []
var taken: Array[String] = []
var door_open := false

var _items_box: VBoxContainer = null
var _inventory_label: Label = null
var _use_row: HBoxContainer = null


func build_body() -> void:
	body_box.add_child(make_label("房间里能拿到的东西：", 15))
	_items_box = VBoxContainer.new()
	_items_box.add_theme_constant_override("separation", 6)
	body_box.add_child(_items_box)

	body_box.add_child(HSeparator.new())
	body_box.add_child(make_label("背包：", 15))
	_inventory_label = make_label("（空）", 15, Color(0.72, 0.86, 1.0))
	body_box.add_child(_inventory_label)

	_use_row = HBoxContainer.new()
	_use_row.add_theme_constant_override("separation", 6)
	body_box.add_child(_use_row)
	_refresh()


func reset() -> void:
	inventory.clear()
	taken.clear()
	door_open = false
	super.reset()


# --- 交互 API -----------------------------------------------------------------

func pickup(item: String) -> bool:
	if is_solved or not WORLD_ITEMS.has(item) or taken.has(item):
		return false
	taken.append(item)
	inventory.append(item)
	set_status("拿到了：%s（%s）" % [item, WORLD_ITEMS[item]], true)
	_refresh()
	return true


func use(item: String, target: String) -> bool:
	if is_solved:
		return false
	if target != TARGET_DOOR:
		fail("「%s」不是能插钥匙的地方。" % target)
		return false
	if not inventory.has(item):
		fail("背包里没有「%s」。" % item)
		return false
	if item == "黄铜钥匙":
		door_open = true
		return succeed("黄铜钥匙转了两圈，铁门开了。")
	if item == "生锈钥匙":
		inventory.erase(item)
		fail("钥匙断在锁芯里 —— 这根本不是这扇门的钥匙。")
		_refresh()
		return false
	fail("「%s」撬不开这扇门。" % item)
	return false


func get_inventory() -> Array:
	return inventory.duplicate()


func get_state() -> Dictionary:
	var state := super.get_state()
	state["inventory"] = inventory.duplicate()
	state["door_open"] = door_open
	return state


# --- 内部 ---------------------------------------------------------------------

func _refresh() -> void:
	if _items_box == null:
		return
	for child in _items_box.get_children():
		_items_box.remove_child(child)
		child.queue_free()
	for item in WORLD_ITEMS.keys():
		if taken.has(item):
			continue
		_items_box.add_child(make_button("拾取：%s" % item, pickup.bind(String(item))))

	_inventory_label.text = "（空）" if inventory.is_empty() else "、".join(inventory)

	for child in _use_row.get_children():
		_use_row.remove_child(child)
		child.queue_free()
	for item in inventory:
		var label: String = "用 %s 开铁门" % item
		_use_row.add_child(make_button(label, use.bind(item, TARGET_DOOR)))
