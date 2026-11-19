extends SceneTree
## integrated_sim Phase 2（实时推进 / 道具拖拽 / live 因果链）的行为测试。
## 运行：godot --headless --path . --script tests/test_integrated_sim_live.gd
## 退出码 0 = 全绿，1 = 有用例失败。

const TIMELINE_SCRIPT := "res://scripts/sim/sim_timeline.gd"
const LIVE_SCRIPT := "res://scripts/sim/live_runtime.gd"
const WORLD_SCRIPT := "res://scripts/sim/sim_world.gd"
const SCENE_PATH := "res://scenes/integrated_sim.tscn"

var _failures: Array[String] = []
var _checks: int = 0
var _node_tests_done := false


func _initialize() -> void:
	_check("存在 res://scripts/sim/live_runtime.gd", ResourceLoader.exists(LIVE_SCRIPT))


func _process(_delta: float) -> bool:
	if _node_tests_done:
		return true
	_node_tests_done = true
	_test_live_rules()
	_test_scene_live_and_drag()
	_report()
	return true


# --- 断言 ---------------------------------------------------------------------

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
		print("INTEGRATED_SIM_LIVE_TEST_PASS (%d checks)" % _checks)
		quit(0)
	else:
		printerr("INTEGRATED_SIM_LIVE_TEST_FAIL (%d/%d failed)" % [_failures.size(), _checks])
		for failure in _failures:
			printerr("  - ", failure)
		quit(1)


func _clue_manager() -> Node:
	return root.get_node_or_null("ClueManager")


func _make_live(timeline: Dictionary):
	var world_script = load(WORLD_SCRIPT)
	var live_script = load(LIVE_SCRIPT)
	if world_script == null or live_script == null:
		return null
	var world = world_script.new()
	root.add_child(world)
	var live = live_script.new()
	root.add_child(live)
	live.setup(timeline, world, _clue_manager())
	return {"world": world, "live": live}


# --- 用例 ---------------------------------------------------------------------

func _test_live_rules() -> void:
	var timeline_script = load(TIMELINE_SCRIPT)
	var live_script = load(LIVE_SCRIPT)
	if timeline_script == null or live_script == null:
		_check("live_runtime.gd 可加载", false)
		return
	var timeline: Dictionary = timeline_script.build()
	var bundle = _make_live(timeline)
	if bundle == null:
		_check("SimWorld / LiveRuntime 可实例化", false)
		return
	var world: Node3D = bundle["world"]
	var live = bundle["live"]
	var manager := _clue_manager()
	manager.clear_timeline_clues()

	# 起点：t=45，Key_01 由 Agent_A 携带（档案 pickup 的延续）
	var state_45: Dictionary = live.compose(45.0)
	_check("t=45 Key_01 仍由 Agent_A 携带",
		String(state_45["props"]["Key_01"]["holder"]) == "Agent_A", str(state_45["props"]["Key_01"]))
	_check("live 起点内室门 Door_02 为 locked", String(state_45["props"]["Door_02"]["state"]) == "locked")

	# Agent_A 在 45.0 时已贴到 Door_02 的交互半径内 → 实时 unlock，cause 指向 archive pickup
	var first: Array = live.step(45.0)
	_check("实时首帧登记 1 条 live 线索", first.size() == 1, str(first))
	var clue: Dictionary = manager.find_latest_timeline_clue("unlock", "Door_02")
	_check("live unlock 的 source=live", String(clue.get("source", "")) == "live", str(clue))
	_check("live unlock 的 actor=Agent_A", String(clue.get("actor", "")) == "Agent_A", str(clue))
	_check("live unlock 的 cause 指向 archive pickup", String(clue.get("cause", "")) == "pickup_Key_01_12.0", str(clue))
	_check("live unlock 让 Door_02 变为 unlocked", String(live.compose(45.0)["props"]["Door_02"]["state"]) == "unlocked")

	# 状态已变 → 下一帧不会再登记同一条线索
	var second: Array = live.step(45.05)
	_check("同一交互不会每帧重复登记", second.is_empty(), str(second))
	_check("live 线索计数仍为 1", manager.timeline_clue_count("unlock") == 1)

	# 拖拽：把 Key_01 拖到地面（清掉持有者）
	_check("拖拽 Key_01 成功", live.drag_prop("Key_01", Vector3(0.0, 0.0, -7.0)))
	var dragged: Dictionary = live.compose(45.0)["props"]["Key_01"]
	_check("拖拽后 Key_01 落在地面目标点", (dragged["pos"] as Vector3).distance_to(Vector3(0.0, 0.4, -7.0)) < 0.01, str(dragged))
	_check("拖拽后 Key_01 无持有者", String(dragged["holder"]).is_empty() and String(dragged["state"]) == "ground")

	# Agent_C 沿路径经过 (0,-7) 附近时拾取 → live pickup
	var before_pickup: int = manager.timeline_clue_count()
	var pickup_result: Array = live.step(48.6)
	_check("Agent_C 经过时登记 live pickup", pickup_result.size() == 1, str(pickup_result))
	var pickup_clue: Dictionary = manager.find_latest_timeline_clue("pickup", "Key_01", "live")
	_check("live pickup 的 actor=Agent_C 且 source=live",
		String(pickup_clue.get("actor", "")) == "Agent_C" and String(pickup_clue.get("source", "")) == "live", str(pickup_clue))
	_check("live pickup 后 Key_01 跟随 Agent_C",
		String(live.compose(48.6)["props"]["Key_01"]["holder"]) == "Agent_C"
		and (live.compose(48.6)["props"]["Key_01"]["pos"] as Vector3).distance_to(live.compose(48.6)["agents"]["Agent_C"]) < 1.2)
	var repeated: Array = live.step(48.65)
	_check("live pickup 不重复登记", repeated.is_empty() and manager.timeline_clue_count() == before_pickup + 1,
		"count=%d" % manager.timeline_clue_count())

	# 未满足条件的道具不会误触发：Switch_01 在 45s 已是 on
	var switch_clues: Array = []
	for entry in manager.get_timeline_clues():
		if String(entry["type"]) == "switch" and String(entry["source"]) == "live":
			switch_clues.append(entry)
	_check("Switch_01 已为 on 时不产生 live switch 事件", switch_clues.is_empty(), str(switch_clues))

	# apply_state 仍是唯一入口：实时状态能写进节点
	world.apply_state(live.compose(48.6))
	var node_snapshot: Dictionary = world.get_state_snapshot()
	_check("实时状态经 apply_state 写入节点",
		(node_snapshot["props"]["Key_01"]["pos"] as Vector3).distance_to(Vector3(0.0, 0.0, -7.0)) < 0.01
		or String(node_snapshot["props"]["Key_01"]["holder"]) == "Agent_C", str(node_snapshot["props"]["Key_01"]))

	world.queue_free()
	live.queue_free()
	manager.clear_timeline_clues()


func _test_scene_live_and_drag() -> void:
	if not ResourceLoader.exists(SCENE_PATH):
		_check("integrated_sim.tscn 存在", false)
		return
	var packed := load(SCENE_PATH) as PackedScene
	var scene := packed.instantiate() if packed != null else null
	_check("integrated_sim.tscn 可实例化", scene != null)
	if scene == null:
		return
	root.add_child(scene)
	var manager := _clue_manager()
	manager.clear_timeline_clues()

	var time_manager := root.get_node_or_null("TimeManager")
	_check("实时时钟以 1x 推进（不再是冻结画面）",
		time_manager != null and float(time_manager.speed) > 0.0,
		"speed=%s" % (time_manager.speed if time_manager != null else "n/a"))
	_check("启动时 present_time 从 45.0 起", time_manager != null and float(time_manager.present_time) >= 45.0,
		"present_time=%s" % (time_manager.present_time if time_manager != null else "n/a"))

	var snapshot: Dictionary = scene.get_sim_snapshot()
	_check("启动模式为 LIVE", String(snapshot["mode"]) == "LIVE")

	# 实时模式下可以拖拽
	var dragged: bool = scene.drag_prop_to("Key_01", Vector3(0.0, 0.0, -7.0))
	_check("LIVE 模式允许拖拽 Key_01", dragged)
	_check("拖拽后节点位置更新", (scene.get_sim_snapshot()["props"]["Key_01"]["pos"] as Vector3).distance_to(Vector3(0.0, 0.4, -7.0)) < 0.01)
	_check("拖拽产生 live 线索之外无副作用（线索计数不因拖拽增长）", manager.timeline_clue_count("pickup") <= 1,
		"pickup=%d" % manager.timeline_clue_count("pickup"))

	# 回放模式禁止拖拽：位置不变、返回 false
	scene.open_tape("TAPE-01")
	var before: Vector3 = scene.get_sim_snapshot()["props"]["Key_01"]["pos"]
	var rejected: bool = scene.drag_prop_to("Key_01", Vector3(8.0, 0.0, 8.0))
	var after: Vector3 = scene.get_sim_snapshot()["props"]["Key_01"]["pos"]
	_check("REPLAY 模式拒绝拖拽（返回 false）", not rejected)
	_check("REPLAY 模式拖拽不改变道具位置", before.distance_to(after) < 0.001, "before=%s after=%s" % [before, after])

	# 向前 seek 过事件点：不再补播事件，线索计数不变
	var pickup_before: int = manager.timeline_clue_count("pickup")
	var unlock_before: int = manager.timeline_clue_count("unlock")
	scene.seek(29.0)
	_check("回放中向前 seek 过事件点不改变线索计数（去重）",
		manager.timeline_clue_count("pickup") == pickup_before and manager.timeline_clue_count("unlock") == unlock_before,
		"pickup %d->%d unlock %d->%d" % [pickup_before, manager.timeline_clue_count("pickup"), unlock_before, manager.timeline_clue_count("unlock")])

	# 回放里拖过的道具视觉位置，切回实时后被 live 状态覆盖
	scene.enter_live()
	var live_key: Dictionary = scene.get_sim_snapshot()["props"]["Key_01"]
	_check("切回实时后道具由 live 状态覆盖", not String(live_key.get("holder", "")).is_empty() or
		(live_key["pos"] as Vector3).distance_to(Vector3(0.0, 0.4, -7.0)) < 0.01, str(live_key))

	scene.queue_free()
	manager.clear_timeline_clues()
