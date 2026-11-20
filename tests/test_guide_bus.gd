extends SceneTree
## GuideBus + 三件套（扬声器 / 指示灯 / 门）的自动化测试（W2）。
## 运行：godot --headless --path . --script tests/test_guide_bus.gd
## 退出码 0 = 全绿，1 = 有用例失败。
##
## 只 new() 本模块，不依赖 autoload / 真实帧率 / 渲染；覆盖目标注册、
## hint / 灯 / 门的成功与非法目标分支、幂等重复调用、扬声器播放与状态查询。

const BUS_SCRIPT := "res://scripts/guide/guide_bus.gd"
const NPC_SCRIPT := "res://scripts/guide/guideable_npc.gd"
const SPEAKER_SCRIPT := "res://scripts/guide/speaker_beacon.gd"
const LIGHT_SCRIPT := "res://scripts/guide/indicator_light.gd"
const DOOR_SCRIPT := "res://scripts/guide/guideable_door.gd"

var _failures: Array[String] = []
var _checks := 0
var _started := false


func _initialize() -> void:
	_check("存在 guide_bus.gd", ResourceLoader.exists(BUS_SCRIPT))
	_check("存在 guideable_npc.gd", ResourceLoader.exists(NPC_SCRIPT))
	_check("存在 speaker_beacon.gd", ResourceLoader.exists(SPEAKER_SCRIPT))
	_check("存在 indicator_light.gd", ResourceLoader.exists(LIGHT_SCRIPT))
	_check("存在 guideable_door.gd", ResourceLoader.exists(DOOR_SCRIPT))


func _process(_delta: float) -> bool:
	if _started:
		return false
	_started = true
	_run_tests()
	return false


func _run_tests() -> void:
	_test_register_targets()
	_test_send_hint()
	_test_indicator()
	_test_door()
	_test_speaker()
	_test_bad_inputs()
	_test_get_state()
	_test_demo_scene()
	_report()


# --- 断言 / 工具 -------------------------------------------------------------

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
		print("GUIDE_BUS_TEST_PASS (%d checks)" % _checks)
		quit(0)
	else:
		printerr("GUIDE_BUS_TEST_FAIL (%d/%d failed)" % [_failures.size(), _checks])
		for failure in _failures:
			printerr("  - ", failure)
		quit(1)


func _new_from(path: String):
	var script = load(path)
	if script == null:
		return null
	var node = script.new()
	root.add_child(node)
	return node


func _free_node(node) -> void:
	if node == null:
		return
	if node.get_parent() != null:
		node.get_parent().remove_child(node)
	node.queue_free()


func _new_bus():
	return _new_from(BUS_SCRIPT)


func _new_npc():
	return _new_from(NPC_SCRIPT)


func _new_speaker():
	return _new_from(SPEAKER_SCRIPT)


func _new_light():
	return _new_from(LIGHT_SCRIPT)


func _new_door():
	return _new_from(DOOR_SCRIPT)


# --- 目标注册 -----------------------------------------------------------------

func _test_register_targets() -> void:
	var bus = _new_bus()
	var npc = _new_npc()
	if bus == null or npc == null:
		_free_node(bus)
		_free_node(npc)
		return

	npc.setup("npc_a", "real")
	_check("注册 NPC 返回 true", bus.register_target("npc_a", npc) == true)
	_check("重复 id 注册返回 false", bus.register_target("npc_a", npc) == false)
	_check("空 id 注册返回 false", bus.register_target("", npc) == false)
	_check("null 目标注册返回 false", bus.register_target("null_target", null) == false)
	_check("get_targets 包含已注册 id", bus.get_targets().has("npc_a"))
	_check("重复注册不产生重复条目", bus.get_targets().size() == 1)

	bus.unregister_target("npc_a")
	_check("取消注册后 get_targets 为空", bus.get_targets().is_empty())
	_check("取消注册后 send_hint 返回 false", bus.send_hint("npc_a", "follow") == false)

	# 取消不存在的目标是无害 no-op。
	bus.unregister_target("never_registered")
	_check("取消不存在的目标不崩溃", bus.get_targets().is_empty())

	_free_node(bus)
	_free_node(npc)


# --- send_hint ----------------------------------------------------------------

func _test_send_hint() -> void:
	var bus = _new_bus()
	var npc = _new_npc()
	if bus == null or npc == null:
		_free_node(bus)
		_free_node(npc)
		return

	npc.setup("npc_a", "real")
	npc.set_route([Vector3.ZERO, Vector3(2.0, 0.0, 0.0)])
	bus.register_target("npc_a", npc)

	var hints: Array = []
	bus.hint_sent.connect(func(target_id: String, text: String) -> void:
		hints.append({"id": target_id, "text": text})
	)

	_check("命中 hint 返回 true", bus.send_hint("npc_a", "follow") == true)
	_check("命中 hint 后 NPC 进入 FOLLOW", String(npc.get_state().get("state", "")) == "FOLLOW")
	_check("命中 hint 发一次 hint_sent", hints.size() == 1)
	if hints.size() == 1:
		_check("hint_sent 带正确 target_id", String(hints[0]["id"]) == "npc_a")
		_check("hint_sent 带正确 text", String(hints[0]["text"]) == "follow")

	var before := hints.size()
	_check("未知 hint 返回 false", bus.send_hint("npc_a", "dance") == false)
	_check("未知 hint 不发 hint_sent", hints.size() == before)
	_check("空 hint 返回 false", bus.send_hint("npc_a", "   ") == false)
	_check("不存在目标的 hint 返回 false", bus.send_hint("nobody", "follow") == false)
	_check("不存在目标的 hint 不发信号", hints.size() == before)

	# 目标存在但没有 on_hint（把灯当 NPC）也要安全失败。
	var light = _new_light()
	light.setup("light_a")
	bus.register_target("light_a", light)
	_check("目标无 on_hint 时 send_hint 返回 false", bus.send_hint("light_a", "follow") == false)

	_free_node(light)
	_free_node(bus)
	_free_node(npc)


# --- 指示灯 -------------------------------------------------------------------

func _test_indicator() -> void:
	var bus = _new_bus()
	var light = _new_light()
	var npc = _new_npc()
	if bus == null or light == null or npc == null:
		_free_node(bus)
		_free_node(light)
		_free_node(npc)
		return

	light.setup("light_a")
	npc.setup("npc_not_a_light", "real")
	bus.register_target("light_a", light)
	bus.register_target("npc_not_a_light", npc)

	var events: Array = []
	bus.indicator_changed.connect(func(id: String, on: bool) -> void:
		events.append({"id": id, "on": on})
	)

	_check("开灯返回 true", bus.set_indicator("light_a", true) == true)
	_check("灯状态变为 on", light.is_on() == true)
	_check("开灯发一次 indicator_changed", events.size() == 1)
	if events.size() == 1:
		_check("indicator_changed 带正确 id", String(events[0]["id"]) == "light_a")
		_check("indicator_changed 带 on=true", bool(events[0]["on"]) == true)

	_check("重复开灯仍返回 true", bus.set_indicator("light_a", true) == true)
	_check("重复开灯状态不变", light.is_on() == true)
	_check("重复开灯不重复发信号", events.size() == 1)

	_check("关灯返回 true", bus.set_indicator("light_a", false) == true)
	_check("灯状态变为 off", light.is_on() == false)
	_check("关灯发一次 indicator_changed", events.size() == 2)
	if events.size() == 2:
		_check("关灯信号 on=false", bool(events[1]["on"]) == false)

	_check("重复关灯仍返回 true", bus.set_indicator("light_a", false) == true)
	_check("重复关灯不重复发信号", events.size() == 2)

	_check("不存在的灯返回 false", bus.set_indicator("no_light", true) == false)
	_check("把 NPC 当灯设置返回 false", bus.set_indicator("npc_not_a_light", true) == false)

	_free_node(bus)
	_free_node(light)
	_free_node(npc)


# --- 门 -----------------------------------------------------------------------

func _test_door() -> void:
	var bus = _new_bus()
	var door = _new_door()
	var npc = _new_npc()
	if bus == null or door == null or npc == null:
		_free_node(bus)
		_free_node(door)
		_free_node(npc)
		return

	door.setup("door_a")
	npc.setup("npc_not_a_door", "real")
	bus.register_target("door_a", door)
	bus.register_target("npc_not_a_door", npc)

	var opened: Array = []
	bus.door_opened.connect(func(id: String) -> void:
		opened.append(id)
	)

	_check("开门返回 true", bus.open_door("door_a") == true)
	_check("门状态变为 open", door.is_open() == true)
	_check("开门发一次 door_opened", opened.size() == 1)
	if opened.size() == 1:
		_check("door_opened 带正确 id", String(opened[0]) == "door_a")

	_check("重复开门仍返回 true", bus.open_door("door_a") == true)
	_check("重复开门状态不变", door.is_open() == true)
	_check("重复开门不重复发信号", opened.size() == 1)

	_check("不存在的门返回 false", bus.open_door("no_door") == false)
	_check("不存在的门不发信号", opened.size() == 1)
	_check("把 NPC 当门打开返回 false", bus.open_door("npc_not_a_door") == false)

	_free_node(bus)
	_free_node(door)
	_free_node(npc)


# --- 扬声器 -------------------------------------------------------------------

func _test_speaker() -> void:
	var bus = _new_bus()
	var speaker = _new_speaker()
	var npc = _new_npc()
	if bus == null or speaker == null or npc == null:
		_free_node(bus)
		_free_node(speaker)
		_free_node(npc)
		return

	speaker.setup("speaker_a")
	var played: Array = []
	speaker.hint_played.connect(func(speaker_id: String, text: String) -> void:
		played.append({"id": speaker_id, "text": text})
	)

	_check("扬声器播放 hint 返回 true", speaker.play_hint("follow") == true)
	_check("扬声器记录播放次数", int(speaker.get_state().get("play_count", 0)) == 1)
	_check("扬声器发一次 hint_played", played.size() == 1)
	if played.size() == 1:
		_check("hint_played 带正确 id", String(played[0]["id"]) == "speaker_a")
		_check("hint_played 带正确文本", String(played[0]["text"]) == "follow")

	_check("扬声器空文本返回 false", speaker.play_hint("   ") == false)
	_check("扬声器空文本不计数", int(speaker.get_state().get("play_count", 0)) == 1)

	# bus.hint_sent -> speaker.on_bus_hint 是 demo 里的接线方式，这里显式验证可接。
	bus.hint_sent.connect(speaker.on_bus_hint)
	npc.setup("npc_a", "imaginary")
	npc.set_route([Vector3.ZERO, Vector3(1.0, 0.0, 0.0)])
	bus.register_target("npc_a", npc)
	bus.send_hint("npc_a", "wait")
	_check("bus 的 hint 能驱动扬声器播放", int(speaker.get_state().get("play_count", 0)) == 2)

	_free_node(bus)
	_free_node(speaker)
	_free_node(npc)


# --- 非法输入 ----------------------------------------------------------------

func _test_bad_inputs() -> void:
	var bus = _new_bus()
	if bus == null:
		return

	_check("null 目标不能开灯", bus.set_indicator("", true) == false)
	_check("空 id 不能开门", bus.open_door("") == false)
	_check("空 id 不能 hint", bus.send_hint("", "follow") == false)

	# 注册普通 Node（没有任何目标方法），各动作都应安全失败而不是崩。
	var plain := Node.new()
	root.add_child(plain)
	bus.register_target("plain", plain)
	_check("普通 Node 可注册（注册表不校验能力）", bus.get_targets().has("plain"))
	_check("普通 Node 不能收 hint", bus.send_hint("plain", "follow") == false)
	_check("普通 Node 不能开灯", bus.set_indicator("plain", true) == false)
	_check("普通 Node 不能开门", bus.open_door("plain") == false)
	_free_node(plain)

	_free_node(bus)


# --- get_state ----------------------------------------------------------------

func _test_get_state() -> void:
	var bus = _new_bus()
	var npc = _new_npc()
	var light = _new_light()
	var door = _new_door()
	if bus == null or npc == null or light == null or door == null:
		_free_node(bus)
		_free_node(npc)
		_free_node(light)
		_free_node(door)
		return

	npc.setup("npc_a", "real")
	npc.set_route([Vector3.ZERO, Vector3(2.0, 0.0, 0.0)])
	light.setup("light_a")
	door.setup("door_a")
	bus.register_target("npc_a", npc)
	bus.register_target("light_a", light)
	bus.register_target("door_a", door)

	bus.send_hint("npc_a", "follow")
	bus.set_indicator("light_a", true)
	bus.open_door("door_a")

	var state: Dictionary = bus.get_state()
	var targets: Array = state.get("targets", [])
	_check("get_state 列出全部目标", targets.has("npc_a") and targets.has("light_a") and targets.has("door_a"))
	_check("get_state 记录灯状态", bool((state.get("indicators", {}) as Dictionary).get("light_a", false)) == true)
	_check("get_state 记录门状态", bool((state.get("doors", {}) as Dictionary).get("door_a", false)) == true)
	var npc_state: Dictionary = (state.get("npcs", {}) as Dictionary).get("npc_a", {})
	_check("get_state 记录 NPC 状态机", String(npc_state.get("state", "")) == "FOLLOW")

	_free_node(bus)
	_free_node(npc)
	_free_node(light)
	_free_node(door)


# --- demo 场景 ----------------------------------------------------------------

func _test_demo_scene() -> void:
	var path := "res://scenes/guide_demo.tscn"
	_check("存在 guide_demo.tscn", ResourceLoader.exists(path))
	if not ResourceLoader.exists(path):
		return
	var packed = load(path) as PackedScene
	_check("guide_demo.tscn 可加载为 PackedScene", packed != null)
	if packed == null:
		return
	var demo = packed.instantiate()
	_check("guide_demo.tscn 可实例化", demo != null)
	if demo == null:
		return
	root.add_child(demo)

	var state: Dictionary = demo.get_state()
	var targets: Array = state.get("targets", [])
	_check("demo 自动注册 NPC / 灯 / 门",
		targets.has("npc_real") and targets.has("npc_imaginary")
		and targets.has("light_a") and targets.has("door_a"))
	_check("demo 没有把扬声器误注册成目标", targets.size() == 4)
	_check("demo 初始 npc_real 为 IDLE",
		String(((state.get("npcs", {}) as Dictionary).get("npc_real", {})).get("state", "")) == "IDLE")

	# 直接推进 demo 自己的时间轴（不必等真实帧），验证自动播放确实驱动了三件套。
	demo._process(0.3)
	var after_first: Dictionary = demo.get_state()
	_check("demo 第一拍后 npc_real 进入 FOLLOW",
		String(((after_first.get("npcs", {}) as Dictionary).get("npc_real", {})).get("state", "")) == "FOLLOW")

	demo._process(0.3)
	demo._process(2.5)
	var after_light: Dictionary = demo.get_state()
	_check("demo 自动打开指示灯",
		bool((after_light.get("indicators", {}) as Dictionary).get("light_a", false)) == true)

	demo._process(2.0)
	var after_door: Dictionary = demo.get_state()
	_check("demo 自动打开门",
		bool((after_door.get("doors", {}) as Dictionary).get("door_a", false)) == true)

	# 再让场景自己跑 60 帧：验收要求 headless 下不报错。
	for _index in range(60):
		demo._process(1.0 / 60.0)
	_check("demo 跑 60 帧后仍在场景树里", demo.is_inside_tree())

	_free_node(demo)
