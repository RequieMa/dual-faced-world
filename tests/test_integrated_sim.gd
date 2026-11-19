extends SceneTree
## integrated_sim Phase 1 的行为测试（headless）。
## 运行：godot --headless --path . --script tests/test_integrated_sim.gd
## 退出码 0 = 全绿，1 = 有用例失败。
##
## 覆盖：EventTimeline 生成/确定性、TapeSampler 采样、ClueManager 新签名与去重、
## ReplayController 时钟驱动、ReplayEventDispatcher 的事件窗口语义、SimWorld.apply_state、
## 以及 integrated_sim 场景启动契约（present_time == 45.0、3 盘带、4 路监控）。

const TIMELINE_SCRIPT := "res://scripts/sim/sim_timeline.gd"
const SAMPLER_SCRIPT := "res://scripts/sim/tape_sampler.gd"
const CONTROLLER_SCRIPT := "res://scripts/sim/replay_controller.gd"
const DISPATCHER_SCRIPT := "res://scripts/sim/replay_event_dispatcher.gd"
const WORLD_SCRIPT := "res://scripts/sim/sim_world.gd"
const SCENE_PATH := "res://scenes/integrated_sim.tscn"

var _failures: Array[String] = []
var _checks: int = 0
var _node_tests_done := false


func _initialize() -> void:
	# --script 模式下 root 还没进入 ready 状态，节点类用例要留到第一帧。
	_test_files_exist()
	_test_timeline()
	_test_sampler()
	_test_clue_manager()
	_test_replay_controller()
	_test_replay_dispatcher()


func _process(_delta: float) -> bool:
	if _node_tests_done:
		return false
	_node_tests_done = true
	_run_node_tests()
	return false


func _run_node_tests() -> void:
	_test_sim_world_apply_state()
	_test_scene_boot()
	await _test_monitor_grid_demo_regression()
	_report()


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


func _check_near(label: String, actual: float, expected: float, tolerance: float = 0.001) -> void:
	_check(label, absf(actual - expected) <= tolerance, "actual=%s expected=%s" % [actual, expected])


func _report() -> void:
	print("----")
	if _failures.is_empty():
		print("INTEGRATED_SIM_TEST_PASS (%d checks)" % _checks)
		quit(0)
	else:
		printerr("INTEGRATED_SIM_TEST_FAIL (%d/%d failed)" % [_failures.size(), _checks])
		for failure in _failures:
			printerr("  - ", failure)
		quit(1)


func _load_script(path: String):
	if not ResourceLoader.exists(path):
		return null
	return load(path)


# --- 用例 ---------------------------------------------------------------------

func _test_files_exist() -> void:
	for path in [TIMELINE_SCRIPT, SAMPLER_SCRIPT, CONTROLLER_SCRIPT, DISPATCHER_SCRIPT, WORLD_SCRIPT, SCENE_PATH]:
		_check("存在 %s" % path, ResourceLoader.exists(path))


func _test_timeline() -> void:
	var mod = _load_script(TIMELINE_SCRIPT)
	if mod == null:
		_check("sim_timeline.gd 可加载", false)
		return
	var timeline: Dictionary = mod.build()
	var snapshots: Array = timeline.get("snapshots", [])
	_check("快照 901 帧（0–90s，10Hz）", snapshots.size() == 901, "got %d" % snapshots.size())
	if snapshots.size() >= 2:
		_check_near("首帧 t=0", float(snapshots[0]["t"]), 0.0)
		_check_near("末帧 t=90", float(snapshots[snapshots.size() - 1]["t"]), 90.0)

	var events: Array = timeline.get("events", [])
	var consumed: Array = []
	var planned: Array = []
	for entry in events:
		if bool((entry as Dictionary).get("planned", false)):
			planned.append(entry)
		else:
			consumed.append(entry)
	_check("事件 7 条（4 已消费 + 3 计划）", events.size() == 7 and consumed.size() == 4 and planned.size() == 3,
		"all=%d consumed=%d planned=%d" % [events.size(), consumed.size(), planned.size()])

	var pickup: Dictionary = _find_event(consumed, 12.0)
	_check("t=12 pickup Key_01 by Agent_A", String(pickup.get("type", "")) == "pickup"
		and String(pickup.get("actor", "")) == "Agent_A" and String(pickup.get("target", "")) == "Key_01",
		str(pickup))
	var unlock: Dictionary = _find_event(consumed, 28.0)
	_check("t=28 unlock Door_01 指向 pickup 线索", String(unlock.get("cause", "")) == "pickup_Key_01_12.0", str(unlock))
	var pass_event: Dictionary = _find_event(consumed, 35.0)
	_check("t=35 pass Door_01 指向 unlock 线索", String(pass_event.get("cause", "")) == "unlock_Door_01_28.0", str(pass_event))
	var planned_event: Dictionary = _find_event(planned, 52.0)
	_check("t=52 计划事件（第二阶段消费）标记 planned", bool(planned_event.get("planned", false)) and String(planned_event.get("target", "")) == "Door_02")

	# 道具状态在事件点切换
	var before_pickup: Dictionary = mod.state_at(timeline, 11.9)
	var after_pickup: Dictionary = mod.state_at(timeline, 12.05)
	_check("t=11.9 Key_01 在地面", String(before_pickup["props"]["Key_01"]["state"]) == "ground", str(before_pickup["props"]["Key_01"]))
	_check("t=12.05 Key_01 被 Agent_A 持有", String(after_pickup["props"]["Key_01"]["holder"]) == "Agent_A"
		and String(after_pickup["props"]["Key_01"]["state"]) == "carried", str(after_pickup["props"]["Key_01"]))
	var key_offset: float = (after_pickup["props"]["Key_01"]["pos"] as Vector3).distance_to(after_pickup["agents"]["Agent_A"])
	_check("携带中的 Key_01 贴着 Agent_A", key_offset < 1.2, "offset=%s" % key_offset)

	_check("t=19.9 Switch_01 为 off", String(mod.state_at(timeline, 19.9)["props"]["Switch_01"]["state"]) == "off")
	_check("t=20.0 Switch_01 为 on", String(mod.state_at(timeline, 20.0)["props"]["Switch_01"]["state"]) == "on")
	_check("t=27.9 Door_01 为 locked", String(mod.state_at(timeline, 27.9)["props"]["Door_01"]["state"]) == "locked")
	_check("t=28.0 Door_01 为 unlocked", String(mod.state_at(timeline, 28.0)["props"]["Door_01"]["state"]) == "unlocked")
	_check("Door_02 在档案时间线中保持 locked（计划事件不消费）",
		String(mod.state_at(timeline, 60.0)["props"]["Door_02"]["state"]) == "locked")

	# 确定性：同一函数调用两次得到同一份快照
	var again: Dictionary = mod.build()
	var digest_a := JSON.stringify(timeline["snapshots"])
	var digest_b := JSON.stringify(again["snapshots"])
	_check("EventTimeline 可重复生成（确定性）", digest_a == digest_b and not digest_a.is_empty())

	# 3 盘带覆盖 [0,45)
	var tapes: Array = timeline.get("tapes", [])
	_check("3 盘带覆盖 0–45s", tapes.size() == 3
		and is_equal_approx(float(tapes[0]["time_start"]), 0.0)
		and is_equal_approx(float(tapes[0]["time_end"]), 15.0)
		and is_equal_approx(float(tapes[2]["time_start"]), 30.0)
		and is_equal_approx(float(tapes[2]["time_end"]), 45.0), str(tapes))
	_check("带标签只显示起止时间后两位",
		String(tapes[0]["label"]).contains("00-15") and String(tapes[1]["label"]).contains("15-30")
		and String(tapes[2]["label"]).contains("30-45"), str([tapes[0]["label"], tapes[1]["label"], tapes[2]["label"]]))


func _find_event(events: Array, at: float) -> Dictionary:
	for entry in events:
		if is_equal_approx(float((entry as Dictionary).get("t", -1.0)), at):
			return entry as Dictionary
	return {}


func _make_tapes(timeline: Dictionary) -> Array:
	var tape_script = load("res://scripts/tapes/tape_resource.gd")
	var tapes: Array = []
	for entry in timeline.get("tapes", []):
		var tape = tape_script.new()
		tape.tape_id = String(entry["tape_id"])
		tape.label = String(entry["label"])
		tape.time_start = float(entry["time_start"])
		tape.time_end = float(entry["time_end"])
		tape.known_to_player = true
		for event in timeline.get("events", []):
			var at := float(event["t"])
			if at > tape.time_start and at <= tape.time_end:
				tape.event_timeline.append({"t": at - tape.time_start, "event": "%s %s" % [event["type"], event["target"]]})
		tapes.append(tape)
	return tapes


func _test_sampler() -> void:
	var mod = _load_script(TIMELINE_SCRIPT)
	var sampler = _load_script(SAMPLER_SCRIPT)
	if mod == null or sampler == null:
		_check("tape_sampler.gd 可加载", false)
		return
	var timeline: Dictionary = mod.build()
	var tapes := _make_tapes(timeline)

	var clamped: Dictionary = sampler.sample(timeline, tapes[1], 5.0)
	_check_near("TAPE-02 采样早于带首时钳到 15.0", float(clamped["sampled_time"]), 15.0)

	var mid: Dictionary = sampler.sample(timeline, tapes[0], 7.55)
	_check_near("采样时间 = playback_time", float(mid["sampled_time"]), 7.55)
	var lo: Dictionary = mod.state_at(timeline, 7.5)
	var hi: Dictionary = mod.state_at(timeline, 7.6)
	var expected_mid: Vector3 = (lo["agents"]["Agent_A"] as Vector3).lerp(hi["agents"]["Agent_A"], 0.5)
	var actual_mid: Vector3 = mid["agents"]["Agent_A"]
	_check("采样在 10Hz 快照之间线性插值", actual_mid.distance_to(expected_mid) < 0.02,
		"actual=%s expected=%s" % [actual_mid, expected_mid])

	var end_state: Dictionary = sampler.sample(timeline, tapes[2], 999.0)
	_check_near("TAPE-03 采样晚于带尾时钳到 45.0", float(end_state["sampled_time"]), 45.0)
	_check("采样结果带完整道具状态", end_state["props"].has("Door_01") and end_state["props"]["Door_01"].has("state"))


func _test_clue_manager() -> void:
	var manager = root.get_node_or_null("ClueManager")
	_check("ClueManager autoload 存在", manager != null)
	if manager == null:
		return
	manager.clear()
	manager.clear_timeline_clues()

	var first: String = manager.register_clue(12.0, "pickup", "Agent_A", "Key_01", "", "archive")
	_check("register_clue 返回线索 id", first == "pickup_Key_01_12.0", first)
	_check("时间线线索计数 1", manager.timeline_clue_count() == 1)

	var duplicate: String = manager.register_clue(12.0, "pickup", "Agent_A", "Key_01", "whatever", "live")
	_check("去重键 (t,type,actor,target) 命中时返回空串", duplicate.is_empty() and manager.timeline_clue_count() == 1)

	var unlock_id: String = manager.register_clue(28.0, "unlock", "Agent_A", "Door_01", first, "archive")
	_check("cause 可引用已有线索 id", unlock_id == "unlock_Door_01_28.0")
	var stored: Dictionary = manager.get_timeline_clue(unlock_id)
	_check("线索记录保留 cause/source/actor/target",
		String(stored.get("cause", "")) == first and String(stored.get("source", "")) == "archive"
		and String(stored.get("actor", "")) == "Agent_A" and String(stored.get("target", "")) == "Door_01", str(stored))

	var ordered: Array = manager.get_timeline_clues()
	_check("线索按时间升序返回", ordered.size() == 2 and float(ordered[0]["t"]) <= float(ordered[1]["t"]))
	_check("按类型计数", manager.timeline_clue_count("pickup") == 1 and manager.timeline_clue_count("unlock") == 1)
	_check("可按类型+目标取最新线索", String(manager.find_latest_timeline_clue("pickup", "Key_01").get("id", "")) == first)

	# 旧「标志」接口仍然可用（demo_clues 用）
	manager.register_flag("door_code_A")
	_check("register_flag 兼容旧标志语义", manager.has_clue("door_code_A"))
	manager.clear()
	manager.clear_timeline_clues()


func _test_replay_controller() -> void:
	var mod = _load_script(TIMELINE_SCRIPT)
	var controller_script = _load_script(CONTROLLER_SCRIPT)
	if mod == null or controller_script == null:
		_check("replay_controller.gd 可加载", false)
		return
	var controller = controller_script.new()
	var tapes := _make_tapes(mod.build())

	controller.open_tape(tapes[0])
	_check("打开 TAPE-01 后停在带首且默认暂停", is_equal_approx(controller.playback_time, 0.0) and controller.paused)
	controller.advance(1.0)
	_check_near("暂停时时钟不推进", controller.playback_time, 0.0)

	controller.set_paused(false)
	controller.advance(1.0)
	_check_near("1x 播放 1s → +1s", controller.playback_time, 1.0)
	controller.set_speed(2.0)
	controller.advance(1.0)
	_check_near("2x 播放 1s → +2s", controller.playback_time, 3.0)
	controller.set_speed(0.5)
	controller.advance(1.0)
	_check_near("0.5x 播放 1s → +0.5s", controller.playback_time, 3.5)

	var seek_result: Dictionary = controller.seek(12.5)
	_check_near("seek 到 12.5", controller.playback_time, 12.5)
	_check("向前 seek 标记", bool(seek_result.get("forward", false)))
	var backward: Dictionary = controller.seek(5.0)
	_check("向后 seek 标记", not bool(backward.get("forward", true)))

	controller.set_speed(10.0)
	controller.set_paused(false)
	controller.advance(10.0)
	_check_near("播放不越过带尾", controller.playback_time, 15.0)
	_check("到带尾自动暂停", controller.paused)
	controller.free()


func _test_replay_dispatcher() -> void:
	var mod = _load_script(TIMELINE_SCRIPT)
	var dispatcher_script = _load_script(DISPATCHER_SCRIPT)
	if mod == null or dispatcher_script == null:
		_check("replay_event_dispatcher.gd 可加载", false)
		return
	var timeline: Dictionary = mod.build()
	var dispatcher = dispatcher_script.new()
	var registered: Array = []
	dispatcher.event_dispatched.connect(func(entry: Dictionary) -> void: registered.append(entry))

	dispatcher.reset(timeline, 0.0)
	dispatcher.advance(11.9)
	_check("事件时间尚未落入窗口时不触发", registered.is_empty())
	dispatcher.advance(12.6)
	_check("越过 12.0 触发 pickup", registered.size() == 1 and String(registered[0]["type"]) == "pickup", str(registered))
	dispatcher.advance(13.0)
	_check("只触发一次（窗口不重叠）", registered.size() == 1)

	dispatcher.seek(19.8, true)
	_check("向前 seek 不播事件", registered.size() == 1)
	dispatcher.advance(20.2)
	_check("向前 seek 后继续播放仍触发窗口内事件", registered.size() == 2 and String(registered[1]["type"]) == "switch",
		str(registered))

	dispatcher.seek(5.0, false)
	dispatcher.advance(12.5)
	_check("向后 seek 重置起点后再次越过事件点会重播（去重交给 ClueManager）",
		registered.size() == 3 and String(registered[2]["type"]) == "pickup", str(registered))

	_check("计划事件（t>45）不派发", _count_type(registered, "unlock") == 0, str(registered))
	dispatcher.free()


func _count_type(entries: Array, type_name: String) -> int:
	var total := 0
	for entry in entries:
		if String((entry as Dictionary).get("type", "")) == type_name:
			total += 1
	return total


func _test_sim_world_apply_state() -> void:
	var mod = _load_script(TIMELINE_SCRIPT)
	var world_script = _load_script(WORLD_SCRIPT)
	if mod == null or world_script == null:
		_check("sim_world.gd 可加载", false)
		return
	var timeline: Dictionary = mod.build()
	var state: Dictionary = mod.state_at(timeline, 28.05)
	var world = world_script.new()
	root.add_child(world)
	world.apply_state(state)

	var snapshot: Dictionary = world.get_state_snapshot()
	_check("SimWorld 生成 3 个 agent", (snapshot["agents"] as Dictionary).size() == 3, str(snapshot["agents"].keys()))
	_check("SimWorld 生成 4 个道具", (snapshot["props"] as Dictionary).size() == 4, str(snapshot["props"].keys()))
	var agent_ok: bool = (snapshot["agents"]["Agent_A"] as Vector3).distance_to(state["agents"]["Agent_A"]) < 0.001
	_check("apply_state 写入 agent 位置", agent_ok)
	_check("apply_state 写入 Door_01 状态", String(snapshot["props"]["Door_01"]["state"]) == "unlocked", str(snapshot["props"]["Door_01"]))
	_check("apply_state 写入 Switch_01 状态", String(snapshot["props"]["Switch_01"]["state"]) == "on", str(snapshot["props"]["Switch_01"]))
	_check("apply_state 计数（回放路径唯一入口可观测）", int(snapshot["apply_count"]) == 1, str(snapshot["apply_count"]))

	var door_node: Node3D = world.get_node_or_null("Props/Door_01")
	_check("道具节点按名字可寻址（供拖拽拾取）", door_node != null)
	var agent_node: Node3D = world.get_node_or_null("Agents/Agent_A")
	_check("agent 节点按名字可寻址", agent_node != null)
	if door_node != null:
		_check("节点位置与状态一致", door_node.position.distance_to((state["props"]["Door_01"]["pos"] as Vector3)) < 0.001)
	world.queue_free()


func _test_scene_boot() -> void:
	if not ResourceLoader.exists(SCENE_PATH):
		_check("integrated_sim.tscn 存在", false)
		return
	var packed := load(SCENE_PATH) as PackedScene
	var instance := packed.instantiate() if packed != null else null
	_check("integrated_sim.tscn 可实例化", instance != null)
	if instance == null:
		return
	root.add_child(instance)
	# --script 模式下 autoload 的全局标识符不可编译期解析，测试里按节点取。
	var time_manager := root.get_node_or_null("TimeManager")
	var tape_archive := root.get_node_or_null("TapeArchive")
	_check("TimeManager autoload 存在", time_manager != null)
	_check("启动时 present_time == 45.0", time_manager != null and is_equal_approx(float(time_manager.present_time), 45.0),
		"present_time=%s" % (time_manager.present_time if time_manager != null else "n/a"))
	_check("实时时钟以 1x 推进（第二阶段起为实时推进，不再是冻结画面）",
		time_manager != null and float(time_manager.speed) > 0.0,
		"speed=%s" % (time_manager.speed if time_manager != null else "n/a"))
	_check("3 盘带进入 TapeArchive", tape_archive != null and tape_archive.get_tapes().size() >= 3,
		"count=%d" % (tape_archive.get_tapes().size() if tape_archive != null else -1))
	_check("监控网格 4 路 SubViewport", instance.get_node("MonitorGrid").get_child_count() == 4)
	for index in range(1, 5):
		var camera := instance.get_node("MonitorGrid/Cell_%02d/SubViewport/Camera3D" % index) as Camera3D
		_check("Cell_%02d 有 current Camera3D" % index, camera != null and camera.current)
		if camera == null:
			continue
		_check("Cell_%02d 机位在地图四角（不在原点）" % index, camera.global_position.length() > 10.0,
			str(camera.global_position))
		var forward := -camera.global_transform.basis.z
		var to_target := (Vector3(0.0, 0.8, 0.0) - camera.global_position).normalized()
		_check("Cell_%02d 朝向地图中心" % index, forward.dot(to_target) > 0.9,
			"dot=%.2f" % forward.dot(to_target))
	var boot: Dictionary = instance.get_sim_snapshot()
	_check("启动模式为 LIVE", String(boot.get("mode", "")) == "LIVE", str(boot.get("mode", "")))
	_check("启动时道具来自 t=45 的冻结状态", String(boot["props"]["Door_01"]["state"]) == "unlocked", str(boot["props"]))
	_check_near("启动时 playback_time 为 0（未播放）", float(boot.get("playback_time", -1.0)), 0.0)
	instance.queue_free()


## monitor_grid_demo 的行为回归：重构出基类后，放大/返回状态机必须与原来一致。
func _test_monitor_grid_demo_regression() -> void:
	if not ResourceLoader.exists("res://scenes/monitor_grid_demo.tscn"):
		_check("monitor_grid_demo.tscn 存在", false)
		return
	var packed := load("res://scenes/monitor_grid_demo.tscn") as PackedScene
	var demo := packed.instantiate() if packed != null else null
	_check("monitor_grid_demo.tscn 可实例化", demo != null)
	if demo == null:
		return
	root.add_child(demo)
	_check("demo 初始为 GRID", demo.get_state_name() == "GRID", demo.get_state_name())
	demo._enter_focus(1)
	await create_timer(0.7).timeout
	_check("demo 放大后进入 FOCUSED", demo.get_state_name() == "FOCUSED", demo.get_state_name())
	_check("demo 放大时 transition layer 可见", bool(demo.get_focus_snapshot()["transition_layer_visible"]))
	demo._leave_focus()
	await create_timer(0.7).timeout
	_check("demo 返回后回到 GRID", demo.get_state_name() == "GRID", demo.get_state_name())
	_check("demo 返回后 grid alpha 恢复 1", is_equal_approx(float(demo.get_focus_snapshot()["grid_alpha"]), 1.0))
	demo.queue_free()
