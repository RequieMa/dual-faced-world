extends SceneTree
## 飞鼠行为回归：尺寸、巡游、叼取/放下、火焰恐慌。

const SQUIRREL_SCRIPT := "res://scripts/room_demo/flying_squirrel.gd"
const MAIN_SCENE := "res://scenes/main.tscn"

var _failures: Array[String] = []
var _checks := 0
var _started := false


func _initialize() -> void:
	_check("飞鼠脚本存在", ResourceLoader.exists(SQUIRREL_SCRIPT))


func _process(_delta: float) -> bool:
	if _started:
		return false
	_started = true
	_run_tests()
	_report()
	return false


func _run_tests() -> void:
	var squirrel_script = load(SQUIRREL_SCRIPT)
	_check("飞鼠尺寸与线索 primitive 一致", is_equal_approx(float(squirrel_script.SIZE), 0.34),
		str(squirrel_script.SIZE))

	var squirrel = squirrel_script.new()
	root.add_child(squirrel)
	var empty_items: Array[Node3D] = []
	squirrel.setup(Vector3(-4, 0, -4), Vector3(4, 2.6, 4), 7, empty_items)
	_check("飞鼠初始在巡游/滑翔/爬墙状态",
		String(squirrel.get_state()["state"]) in ["wander", "glide", "climb"],
		str(squirrel.get_state()))
	var start: Vector3 = squirrel.global_position
	for i in 12:
		squirrel.tick(0.1)
	_check("飞鼠会移动", squirrel.global_position.distance_to(start) > 0.05,
		str(squirrel.global_position))

	var item := Node3D.new()
	item.name = "CarryTest"
	root.add_child(item)
	item.global_position = squirrel.global_position
	var items: Array[Node3D] = [item]
	squirrel.carryables = items
	squirrel.tick(0.1)
	_check("飞鼠碰到道具会叼起", bool(squirrel.get_state()["carrying"]))
	var dropped: Array[Vector3] = []
	squirrel.item_dropped.connect(func(_node: Node3D, pos: Vector3): dropped.append(pos))
	squirrel.carryables.clear()
	for i in 80:
		squirrel.tick(0.1)
	_check("飞鼠会叼到别处放下", not bool(squirrel.get_state()["carrying"]), str(squirrel.get_state()))
	_check("放下时发出位置信号", not dropped.is_empty(), str(dropped))

	squirrel.global_position = Vector3.ZERO
	var fires: Array[Vector3] = [Vector3(1.2, 0, 0)]
	squirrel.set_fire_sources(fires)
	squirrel.tick(0.2)
	_check("靠近火焰会恐慌", squirrel.is_panicking())
	_check("恐慌时远离火焰", squirrel.global_position.x < 0.0, str(squirrel.global_position))

	var demo = (load(MAIN_SCENE) as PackedScene).instantiate()
	root.add_child(demo)
	_check("场景中有 2 只飞鼠", demo.squirrels.size() == 2, str(demo.squirrels.size()))
	demo.queue_free()
	squirrel.queue_free()
	item.queue_free()


func _check(label: String, condition: bool, detail: String = "") -> void:
	_checks += 1
	if condition:
		print("PASS  ", label)
	else:
		var message := label
		if not detail.is_empty():
			message += "  [" + detail + "]"
		_failures.append(message)
		printerr("FAIL  ", message)


func _report() -> void:
	print("----")
	if _failures.is_empty():
		print("ROOM_SQUIRREL_TEST_PASS (%d checks)" % _checks)
		quit(0)
	else:
		printerr("ROOM_SQUIRREL_TEST_FAIL (%d/%d failed)" % [_failures.size(), _checks])
		for failure in _failures:
			printerr("  - ", failure)
		quit(1)
