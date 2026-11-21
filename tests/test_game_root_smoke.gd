extends SceneTree
## W12 端到端 smoke：加载 game_root → 切摄像头 → 过载 → 发 hint → 开一轮/结束一轮 → exit 0。
## 运行：godot --headless --path . --script tests/test_game_root_smoke.gd
## 退出码 0 = 全绿，1 = 有用例失败。
##
## 按 Issue #19 的验收标准，本文件先于实现写（红），实现后转绿。
## 只实例化 game_root 场景，不依赖 autoload / 真实帧率；过载计时用固定 tick 推进。
##
## 覆盖：场景/脚本存在、主入口切到 game_root、系统装配与接线（W1/W2/W3/W4/W6）、
## 摄像头切换与过载烧毁、引导 hint / 指示灯 / 门、一轮起止与循环重开、
## 重开后的世界复位（烧毁机位按 M16 默认保持）、聚合 get_state。

const SCENE_PATH := "res://scenes/game_root.tscn"
const SCRIPT_PATH := "res://scripts/game_root.gd"
const MAIN_SCENE := "res://scenes/main.tscn"

const REQUIRED_METHODS: Array[String] = [
	"switch_camera", "leave_camera", "send_hint", "set_indicator", "open_door",
	"start_dialogue", "apply_style", "start_round", "end_round", "restart_round",
	"tick", "reset_for_loop", "get_state",
	"get_camera_session", "get_guide_bus", "get_loop_manager",
	"get_dialogue_controller", "get_style_controller",
]
const REQUIRED_SIGNALS: Array[String] = [
	"camera_overloaded", "hint_sent", "round_started", "round_ended", "definition_error",
]
## 全绿时应执行的断言数：运行时错误会中止当前用例，靠数量守恒抓住「假绿」。
const EXPECTED_CHECKS := 87

var _failures: Array[String] = []
var _checks: int = 0
var _started := false

var _game_root: Node = null
var _events: Array = []


func _initialize() -> void:
	_check("存在 scenes/game_root.tscn", ResourceLoader.exists(SCENE_PATH))
	_check("存在 scripts/game_root.gd", ResourceLoader.exists(SCRIPT_PATH))
	_check("主入口 scenes/main.tscn 装配 GameRoot", _main_scene_has_game_root())


func _process(_delta: float) -> bool:
	if _started:
		return false
	_started = true
	_run_tests()
	return false


func _run_tests() -> void:
	if not ResourceLoader.exists(SCENE_PATH) or not ResourceLoader.exists(SCRIPT_PATH):
		_report()
		return

	var packed := ResourceLoader.load(SCENE_PATH) as PackedScene
	_check("game_root.tscn 可作为 PackedScene 加载", packed != null)
	if packed == null:
		_report()
		return

	var instance := packed.instantiate()
	_check("game_root 可实例化", instance != null)
	if instance == null:
		_report()
		return

	_check("根节点挂载 game_root.gd", _script_path(instance) == SCRIPT_PATH)
	_check("GameRoot 实现契约方法", _has_required_methods(instance))
	_check("GameRoot 声明契约信号", _has_required_signals(instance))
	if not _has_required_methods(instance):
		instance.free()
		_report()
		return

	# 关掉自动 tick：headless 测试用固定步长复现过载，不依赖真实帧率。
	if "auto_tick" in instance:
		instance.auto_tick = false
	# 在入树前接线，才能捕获 _ready 里装配/加载失败的 definition_error。
	instance.definition_error.connect(func(message): _events.append(["definition_error", message]))
	_game_root = instance
	root.add_child(_game_root)

	_test_assembly()
	_test_camera_switch_and_overload()
	_test_guide()
	_test_rounds()
	_test_dialogue()
	_test_style()
	_test_state()
	_test_main_entry()

	_game_root.queue_free()
	_report()


# --- 装配 ---------------------------------------------------------------------

func _test_assembly() -> void:
	_check("CameraSession 已装配", _game_root.get_camera_session() != null)
	_check("GuideBus 已装配", _game_root.get_guide_bus() != null)
	_check("LoopManager 已装配", _game_root.get_loop_manager() != null)
	_check("DialogueController 已装配", _game_root.get_dialogue_controller() != null)
	_check("StyleController 已装配", _game_root.get_style_controller() != null)

	var bus = _game_root.get_guide_bus()
	var targets: Array = bus.get_targets() if bus != null else []
	_check("场景目标已注册到 GuideBus", targets.size() == 4, str(targets))
	_check("注册了可引导 NPC npc_real", targets.has("npc_real"), str(targets))
	_check("注册了指示灯 light_a", targets.has("light_a"), str(targets))
	_check("注册了门 door_a", targets.has("door_a"), str(targets))

	# 装配失败（配置/对话定义坏掉）时应该走 definition_error，而不是静默。
	_check("装配期没有 definition_error", _count_events("definition_error") == 0, str(_events))
	_check("surveillance 配置加载成功", _game_root.last_errors.is_empty(), str(_game_root.last_errors))


# --- 摄像头 -------------------------------------------------------------------

func _test_camera_switch_and_overload() -> void:
	var session = _game_root.get_camera_session()
	_game_root.camera_overloaded.connect(func(camera_id): _events.append(["camera_overloaded", camera_id]))

	_check("切换到 C1", _game_root.switch_camera("C1"))
	_check("当前机位是 C1", session.get_state()["current"] == "C1", str(session.get_state()))
	_check("未知机位被拒绝", not _game_root.switch_camera("C_NOPE"))
	_check("拒绝后仍停在 C1", session.get_state()["current"] == "C1", str(session.get_state()))

	_check("切到 C2", _game_root.switch_camera("C2"))
	_check("当前机位是 C2", session.get_state()["current"] == "C2", str(session.get_state()))
	_check("冷却中切回 C1 失败", not _game_root.switch_camera("C1"))

	# 用远大于 dwell 的固定步长推进到过载，避免把测试绑死在 surveillance.json 的具体数值上。
	_game_root.tick(30.0)
	var state: Dictionary = session.get_state()
	_check("过载后离开当前机位", state["current"] == "", str(state))
	_check("过载计数 +1", int(state["overload_count"]) == 1, str(state))
	_check("C2 被烧毁", session.is_burned("C2"), str(state))
	_check("广播一次 camera_overloaded", _count_events("camera_overloaded") == 1, str(_events))
	_check("过载事件带机位 id", String(_event_value("camera_overloaded")) == "C2", str(_events))
	_check("烧毁机位不能再次进入", not _game_root.switch_camera("C2"))

	# 切走时 C1 进入冷却；tick 推进足够久后冷却结束，可再进。
	_game_root.tick(30.0)
	_check("冷却结束后可重新进入 C1", _game_root.switch_camera("C1"))
	_game_root.leave_camera()
	_check("leave 后没有当前机位", session.get_state()["current"] == "", str(session.get_state()))


# --- 引导 ---------------------------------------------------------------------

func _test_guide() -> void:
	var bus = _game_root.get_guide_bus()
	var npc = _game_root.find_child("NpcReal", true, false)
	_game_root.hint_sent.connect(func(target_id, text): _events.append(["hint_sent", target_id, text]))

	_check("发送 follow 提示", _game_root.send_hint("npc_real", "follow"))
	_check("hint_sent 广播一次", _count_events("hint_sent") == 1, str(_events))
	var hint_event: Array = _event("hint_sent")
	_check("hint 事件带目标与文本",
		hint_event.size() > 2 and String(hint_event[1]) == "npc_real" and String(hint_event[2]) == "follow",
		str(hint_event))
	var speaker = _game_root.find_child("Speaker", true, false)
	_check("扬声器收到 hint", speaker != null and int(speaker.get_state()["play_count"]) == 1,
		"" if speaker == null else str(speaker.get_state()))
	_check("NPC 进入 FOLLOW", npc != null and String(npc.get_state()["state"]) == "FOLLOW",
		"" if npc == null else str(npc.get_state()))
	_check("未知目标发送 hint 返回 false", not _game_root.send_hint("npc_nope", "follow"))
	_check("空提示返回 false", not _game_root.send_hint("npc_real", "  "))

	_check("打开指示灯", _game_root.set_indicator("light_a", true))
	var light = _game_root.find_child("Indicator", true, false)
	_check("指示灯状态为 on", light != null and bool(light.is_on()))

	_check("打开门", _game_root.open_door("door_a"))
	var door = _game_root.find_child("Door", true, false)
	_check("门状态为 open", door != null and bool(door.is_open()))
	_check("重复开门幂等", _game_root.open_door("door_a"))
	_check("bus 目标数稳定", bus.get_targets().size() == 4, str(bus.get_targets()))


# --- 循环 ---------------------------------------------------------------------

func _test_rounds() -> void:
	var loop = _game_root.get_loop_manager()
	_game_root.round_started.connect(func(index): _events.append(["round_started", index]))
	_game_root.round_ended.connect(func(index, summary): _events.append(["round_ended", index, summary]))

	_check("未开轮时 end_round 返回 false", not _game_root.end_round({"outcome": "stray"}))

	_game_root.start_round()
	_check("首轮轮次为 1", loop.get_round_index() == 1, str(loop.get_round_index()))
	_check("round_started 广播", _count_events("round_started") == 1, str(_events))

	_check("结束一轮", _game_root.end_round({"outcome": "caught", "clues": 1, "solved": 0}))
	_check("history 记录一轮", loop.get_history().size() == 1, str(loop.get_history()))
	_check("summary 被规范化", _event_value("round_ended")["round"] == 1, str(_events))
	_check("round_ended 广播", _count_events("round_ended") == 1, str(_events))
	# 已经结束的一轮不能重复结束。
	_check("重复 end_round 返回 false", not _game_root.end_round({"outcome": "again"}))

	# 再开一轮后循环重开：结束当前轮 → 世界复位 → 开始新一轮。
	_game_root.start_round()
	_check("第二轮轮次为 2", loop.get_round_index() == 2, str(loop.get_round_index()))
	_check("restart_round 成功", _game_root.restart_round(0.0))
	_check("重开后轮次为 3", loop.get_round_index() == 3, str(loop.get_round_index()))
	_check("history 记录两轮", loop.get_history().size() == 2, str(loop.get_history()))

	var camera_state: Dictionary = _game_root.get_camera_session().get_state()
	_check("重开清空当前机位", camera_state["current"] == "", str(camera_state))
	# M16 已拍板（#20）：烧毁的机位永久不恢复。
	_check("重开保留烧毁机位（M16 已决定）", _game_root.get_camera_session().is_burned("C2"), str(camera_state))

	var npc = _game_root.find_child("NpcReal", true, false)
	_check("重开复位 NPC 状态", npc != null and String(npc.get_state()["state"]) == "IDLE",
		"" if npc == null else str(npc.get_state()))
	var light = _game_root.find_child("Indicator", true, false)
	_check("重开复位指示灯", light != null and not bool(light.is_on()))


# --- 对话 ---------------------------------------------------------------------

func _test_dialogue() -> void:
	var dialogue = _game_root.get_dialogue_controller()
	_check("开始 stranger_greeting", _game_root.start_dialogue("stranger_greeting"))
	_check("对话 active", dialogue.is_active())
	var state: Dictionary = dialogue.get_state()
	_check("对话 group 归一化为 real", String(state["group"]) == "real", str(state))
	_check("对话有 2 行", int(state["total"]) == 2, str(state))
	dialogue.advance()
	dialogue.advance()
	_check("对话播完停止", not dialogue.is_active(), str(dialogue.get_state()))
	_check("未知对话 id 返回 false", not _game_root.start_dialogue("dialogue_nope"))


# --- 画风 ---------------------------------------------------------------------

func _test_style() -> void:
	var style = _game_root.get_style_controller()
	_check("开启 real 画风", _game_root.apply_style("real", true))
	_check("real 画风已启用", bool(style.get_state()["styles"]["real"]["enabled"]))
	_check("real 画风覆盖到场景网格", int(style.get_state()["styles"]["real"]["applied_nodes"]) >= 1,
		str(style.get_state()))
	_check("未知画风被拒绝", not _game_root.apply_style("pencil", true))
	_check("关闭 real 画风", _game_root.apply_style("real", false))
	_check("real 画风已关闭", not bool(style.get_state()["styles"]["real"]["enabled"]))
	_check("关闭后不再覆盖网格", int(style.get_state()["styles"]["real"]["applied_nodes"]) == 0,
		str(style.get_state()))


# --- 聚合状态 -----------------------------------------------------------------

func _test_state() -> void:
	var state: Dictionary = _game_root.get_state()
	for key in ["camera", "guide", "loop", "dialogue", "style", "round_active"]:
		_check("get_state 含 %s" % key, state.has(key), str(state.keys()))
	_check("get_state.round_active 为 true", bool(state["round_active"]))


# --- 主入口链路 ---------------------------------------------------------------

func _test_main_entry() -> void:
	# 结构断言之外，把 main.tscn 真正入树跑一次 _ready，确认入口链路可用。
	var packed := ResourceLoader.load(MAIN_SCENE) as PackedScene
	_check("主入口 PackedScene 可加载", packed != null)
	if packed == null:
		return
	var instance := packed.instantiate()
	var entry_root := instance.get_node_or_null("GameRoot")
	_check("主入口含 GameRoot 子节点", entry_root != null)
	if entry_root == null:
		instance.free()
		return
	entry_root.auto_tick = false
	root.add_child(instance)
	_check("主入口 GameRoot 入树后装配系统", entry_root.get_camera_session() != null)
	_check("主入口 GameRoot 可切摄像头", entry_root.switch_camera("C1"))
	instance.queue_free()


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
	if _checks != EXPECTED_CHECKS:
		var count_message := "断言数不符：实际 %d，期望 %d（有用例被运行时错误中止？）" % [_checks, EXPECTED_CHECKS]
		_failures.append(count_message)
		printerr("FAIL  ", count_message)
	if _failures.is_empty():
		print("GAME_ROOT_SMOKE_PASS (%d checks)" % _checks)
		quit(0)
	else:
		printerr("GAME_ROOT_SMOKE_FAIL (%d/%d failed)" % [_failures.size(), _checks])
		for failure in _failures:
			printerr("  - ", failure)
		quit(1)


func _main_scene_has_game_root() -> bool:
	if not ResourceLoader.exists(MAIN_SCENE):
		return false
	var packed := ResourceLoader.load(MAIN_SCENE) as PackedScene
	if packed == null:
		return false
	var instance := packed.instantiate()
	if instance == null:
		return false
	var game_root := instance.get_node_or_null("GameRoot")
	var ok := game_root != null and _script_path(game_root) == SCRIPT_PATH
	instance.free()
	return ok


func _script_path(node: Node) -> String:
	var script := node.get_script() as Script
	return "" if script == null else script.resource_path


func _has_required_methods(node: Node) -> bool:
	for method_name in REQUIRED_METHODS:
		if not node.has_method(method_name):
			return false
	return true


func _has_required_signals(node: Node) -> bool:
	var names: Array = []
	for signal_info in node.get_signal_list():
		names.append(String(signal_info["name"]))
	for signal_name in REQUIRED_SIGNALS:
		if not names.has(signal_name):
			return false
	return true


func _count_events(event_name: String) -> int:
	var count := 0
	for event in _events:
		if String(event[0]) == event_name:
			count += 1
	return count


func _event(event_name: String) -> Array:
	for event in _events:
		if String(event[0]) == event_name:
			return event
	return []


func _event_value(event_name: String) -> Variant:
	for event in _events:
		if String(event[0]) == event_name:
			return event[2] if event.size() > 2 else event[1]
	return null
