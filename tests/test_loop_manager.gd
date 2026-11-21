extends SceneTree
## W6 循环 / 回溯框架测试（LoopManager + LoopState）。
## 运行：godot --headless --path . --script tests/test_loop_manager.gd
## 退出码 0 = 全绿，1 = 有用例失败。
##
## 覆盖 docs/MECHANICS_CONTRACTS.md §3 与 Issue #16 的验收：
## - start_round 递增轮次并广播；end_round 记录 summary，两轮 summary 可对比；
## - rewind_to 调所有参与者的 reset_for_loop(time)，参与者状态回到该时刻，
##   world_reset 由 rewind_to 广播；
## - reset_for_loop 缺失/参与者非法时 push_warning 并继续，不整体失败；
## - 知识保留：ClueManager 的 timeline clues 在回退/重开时不清空（只读消费）；
## - to_dict/from_dict（含 JSON 往返）恢复轮次与 history，非法数据不崩溃。
##
## 不依赖 autoload，也不依赖真实帧率。

const LOOP_MANAGER := "res://scripts/loop/loop_manager.gd"
const LOOP_STATE := "res://scripts/loop/loop_state.gd"
const CLUE_MANAGER := "res://scripts/clue_manager.gd"

## 契约方法/信号清单：实现被改名或删掉时在开头就失败，而不是少跑断言还 PASS。
const REQUIRED_METHODS: Array[String] = [
	"start_round", "end_round", "rewind_to", "reset_world",
	"get_round_index", "get_history", "to_dict", "from_dict",
]
const REQUIRED_SIGNALS: Array[String] = ["round_started", "round_ended", "world_reset"]
## 全绿时应执行的断言数：运行时错误会中止当前用例，靠数量守恒抓住「假绿」。
const EXPECTED_CHECKS := 48

var _failures: Array[String] = []
var _checks: int = 0


## 假参与者：按时间点保存状态快照，reset_for_loop(time) 回到该时刻。
class FakeParticipant extends RefCounted:
	var snapshots: Dictionary = {0.0: "opening", 10.0: "alert", 20.0: "ending"}
	var state: String = "opening"
	var resets: Array = []
	var order: Array = []

	func reset_for_loop(time: float) -> void:
		order.append("reset")
		resets.append(time)
		state = String(snapshots.get(snappedf(time, 0.1), "missing"))


## 假知识源：不实现 reset_for_loop，模拟 ClueManager 这类只读模块。
class FakeKnowledge extends RefCounted:
	var entries: Array = ["clue_a"]


func _initialize() -> void:
	_check("存在 scripts/loop/loop_manager.gd", ResourceLoader.exists(LOOP_MANAGER))
	_check("存在 scripts/loop/loop_state.gd", ResourceLoader.exists(LOOP_STATE))
	if not ResourceLoader.exists(LOOP_MANAGER) or not ResourceLoader.exists(LOOP_STATE):
		_report()
		return

	var probe = _manager()
	_check("LoopManager 可实例化", probe != null)
	if probe == null:
		_report()
		return
	var missing := _missing_api(probe)
	_check("LoopManager 提供契约方法与信号", missing.is_empty(), str(missing))
	probe.free()
	if not missing.is_empty():
		_report()
		return

	_test_loop_state()
	_test_start_round()
	_test_end_round_history()
	_test_rewind_contract()
	_test_knowledge_kept()
	_test_serialisation()
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


func _report() -> void:
	if _checks != EXPECTED_CHECKS:
		var count_message := "断言数不符：实际 %d，期望 %d（有测试用例被运行时错误中止？）" % [_checks, EXPECTED_CHECKS]
		_failures.append(count_message)
		printerr("FAIL  ", count_message)
	print("----")
	if _failures.is_empty():
		print("LOOP_MANAGER_TEST_PASS (%d checks)" % _checks)
		quit(0)
	else:
		printerr("LOOP_MANAGER_TEST_FAIL (失败 %d 项 / 执行 %d checks)" % [_failures.size(), _checks])
		for failure in _failures:
			printerr("  - ", failure)
		quit(1)


# --- 工具 ---------------------------------------------------------------------

func _manager():
	var script_resource = load(LOOP_MANAGER)
	if script_resource == null or not script_resource.can_instantiate():
		return null
	return script_resource.new()


func _missing_api(instance) -> Array[String]:
	var missing: Array[String] = []
	for method_name in REQUIRED_METHODS:
		if not instance.has_method(method_name):
			missing.append(method_name)
	for signal_name in REQUIRED_SIGNALS:
		if not instance.has_signal(signal_name):
			missing.append("signal:" + signal_name)
	return missing


# --- LoopState ----------------------------------------------------------------

func _test_loop_state() -> void:
	var state = load(LOOP_STATE).new()
	_check("LoopState 初始轮次为 0", state.get_round() == 0)

	state.begin_round(1)
	_check("begin_round 更新轮次", state.get_round() == 1)

	var summary: Dictionary = state.record({"outcome": "caught", "clues": 2})
	_check("record 补齐 round", int(summary.get("round", -1)) == 1, str(summary))
	_check("record 补齐 time/outcome/clues/solved",
		summary.get("time") == 0.0 and summary.get("outcome") == "caught"
		and int(summary.get("clues", -1)) == 2 and int(summary.get("solved", -1)) == 0, str(summary))
	state.record({"outcome": "escaped", "clues": 5, "solved": 3}, 2)

	var history: Array = state.get_history()
	_check("history 按轮次保存两条 summary", history.size() == 2, str(history))
	_check("两轮 summary 可对比（round/clues/outcome 不同）",
		int(history[0]["round"]) == 1 and int(history[1]["round"]) == 2
		and int(history[0]["clues"]) == 2 and int(history[1]["clues"]) == 5
		and String(history[0]["outcome"]) == "caught" and String(history[1]["outcome"]) == "escaped",
		str(history))

	(history[0] as Dictionary)["clues"] = 99
	_check("get_history 返回副本，外部修改不影响内部记录", int(state.get_history()[0]["clues"]) == 2)


# --- LoopManager 轮次 ----------------------------------------------------------

func _test_start_round() -> void:
	var manager = _manager()
	var started: Array = []
	manager.round_started.connect(func(index: int) -> void: started.append(index))

	_check("LoopManager 初始轮次为 0", manager.get_round_index() == 0)
	manager.start_round()
	_check("start_round 使轮次变成 1", manager.get_round_index() == 1)
	manager.start_round()
	_check("再次 start_round 使轮次变成 2", manager.get_round_index() == 2)
	_check("round_started 依次广播 1、2", started == [1, 2], str(started))
	manager.free()


func _test_end_round_history() -> void:
	var manager = _manager()
	var ended: Array = []
	manager.round_ended.connect(func(index: int, summary: Dictionary) -> void:
		ended.append({"round": index, "summary": summary.duplicate(true)}))

	manager.start_round()
	var first: Dictionary = {"outcome": "caught", "time": 120.0, "clues": 2, "solved": 1}
	manager.end_round(first)
	var history: Array = manager.get_history()
	_check("end_round 追加一条 history", history.size() == 1, str(history))
	_check("end_round 记录的 summary 带当前轮次", int(history[0]["round"]) == 1, str(history[0]))
	_check("end_round 保留调用方给的 time/outcome/clues/solved",
		history[0]["time"] == 120.0 and history[0]["outcome"] == "caught"
		and int(history[0]["clues"]) == 2 and int(history[0]["solved"]) == 1, str(history[0]))
	_check("end_round 不改调用方的字典", first.size() == 4 and not first.has("round"), str(first))
	_check("round_ended 广播轮次与 summary",
		ended.size() == 1 and int(ended[0]["round"]) == 1
		and int((ended[0]["summary"] as Dictionary)["clues"]) == 2, str(ended))

	manager.start_round()
	manager.end_round({"outcome": "escaped", "clues": 5, "solved": 3})
	history = manager.get_history()
	_check("第二轮 summary 与第一轮可对比",
		history.size() == 2 and int(history[1]["round"]) == 2
		and int(history[1]["clues"]) == 5 and String(history[1]["outcome"]) == "escaped",
		str(history))
	_check("未提供的 summary 字段补默认值",
		float(history[1]["time"]) == 0.0 and int(history[1]["solved"]) == 3, str(history[1]))

	(history[1] as Dictionary)["clues"] = 99
	_check("history 是副本，外部修改不影响内部记录", int(manager.get_history()[1]["clues"]) == 5)
	manager.free()


# --- 回退 / 重开 ---------------------------------------------------------------

func _test_rewind_contract() -> void:
	var manager = _manager()
	var resets: Array = []
	manager.world_reset.connect(func() -> void: resets.append(1))

	var first := FakeParticipant.new()
	var second := FakeParticipant.new()
	var ok: bool = manager.rewind_to(10.0, [first, second])
	_check("rewind_to 返回 true", ok)
	_check("rewind_to 调每个参与者的 reset_for_loop(time)",
		first.resets == [10.0] and second.resets == [10.0], str([first.resets, second.resets]))
	_check("参与者状态回到该时刻",
		first.state == "alert" and second.state == "alert", str([first.state, second.state]))
	_check("rewind_to 广播一次 world_reset", resets.size() == 1, str(resets.size()))
	_check("rewind_to 不改变轮次", manager.get_round_index() == 0)

	var third := FakeParticipant.new()
	manager.reset_world([third], 20.0)
	_check("reset_world 把参与者重置到指定时刻", third.resets == [20.0] and third.state == "ending",
		str([third.resets, third.state]))
	_check("reset_world 本身不重复广播 world_reset（由 rewind_to 广播）", resets.size() == 1,
		str(resets.size()))

	var knowledge := FakeKnowledge.new()
	var valid := FakeParticipant.new()
	var ok_skip: bool = manager.rewind_to(0.0, [knowledge, valid, null, 42, "not a participant"])
	_check("缺少 reset_for_loop / 非 Object 的参与者被跳过，rewind_to 仍成功", ok_skip,
		str(ok_skip))
	_check("被跳过参与者的状态未被改动", knowledge.entries == ["clue_a"], str(knowledge.entries))
	_check("合法参与者仍然被重置", valid.resets == [0.0] and valid.state == "opening",
		str([valid.resets, valid.state]))
	_check("world_reset 每次 rewind_to 各广播一次", resets.size() == 2, str(resets.size()))

	var sequence: Array = []
	var ordered := FakeParticipant.new()
	ordered.order = sequence
	manager.world_reset.connect(func() -> void: sequence.append("world_reset"))
	manager.rewind_to(10.0, [ordered])
	_check("rewind_to 先把参与者 reset 到该时刻，再广播 world_reset",
		sequence == ["reset", "world_reset"], str(sequence))

	var before_empty: int = resets.size()
	var ok_empty: bool = manager.rewind_to(0.0, [])
	_check("rewind_to 空参与者列表仍成功并广播 world_reset",
		ok_empty and resets.size() == before_empty + 1, str(resets.size()))

	var freed := Node.new()
	freed.free()
	var before_freed: int = resets.size()
	var ok_freed: bool = manager.rewind_to(0.0, [freed])
	# 已知盲区：Godot 无法在进程内断言 stderr；本用例只证明已释放参与者不会中断
	# rewind_to。若实现回退成 `is Object` 会打 SCRIPT ERROR 但仍能通过此断言。
	_check("已释放的参与者不会让 rewind_to 崩溃",
		ok_freed and resets.size() == before_freed + 1, str(ok_freed))

	manager.free()


func _test_knowledge_kept() -> void:
	var manager = _manager()
	var clue_script = load(CLUE_MANAGER)
	if clue_script == null:
		_check("ClueManager 可实例化", false)
		manager.free()
		return

	var clues = clue_script.new()
	var clue_id: String = clues.register_clue(3.0, "pickup", "player", "key")
	var before: Array = clues.get_timeline_clues()
	var world := FakeParticipant.new()

	var ok: bool = manager.rewind_to(0.0, [clues, world])
	_check("回退时 ClueManager 的 timeline clues 不被清空（知识保留）",
		ok and clues.timeline_clue_count() == 1 and clues.has_timeline_clue(clue_id),
		str(clues.get_timeline_clues()))
	_check("时间线线索内容保持不变", clues.get_timeline_clues() == before,
		str(clues.get_timeline_clues()))
	_check("ClueManager 不实现 reset_for_loop（只读消费，不改 clue_manager.gd）",
		not clues.has_method("reset_for_loop"))

	manager.start_round()
	manager.reset_world([clues, world], 0.0)
	_check("回放式重开（start_round + reset_world 到起点）也不清空知识",
		clues.timeline_clue_count() == 1 and clues.has_timeline_clue(clue_id),
		str(clues.get_timeline_clues()))

	clues.free()
	manager.free()


# --- 序列化 -------------------------------------------------------------------

func _test_serialisation() -> void:
	var manager = _manager()
	manager.start_round()
	manager.end_round({"outcome": "caught", "time": 42.5, "clues": 2, "solved": 1})
	manager.start_round()
	manager.end_round({"outcome": "escaped", "time": 88.0, "clues": 5, "solved": 3})

	var data: Dictionary = manager.to_dict()
	_check("to_dict 含 round 与 history",
		int(data.get("round", 0)) == 2 and (data.get("history", []) as Array).size() == 2, str(data))

	var text := JSON.stringify(data)
	var restored = _manager()
	var parsed: Variant = JSON.parse_string(text)
	restored.from_dict(parsed)
	_check("from_dict(JSON 往返) 恢复轮次", restored.get_round_index() == 2,
		str(restored.get_round_index()))
	_check("from_dict(JSON 往返) 恢复 history", restored.get_history() == manager.get_history(),
		str(restored.get_history()))
	restored.start_round()
	_check("from_dict 之后 start_round 接着递增", restored.get_round_index() == 3,
		str(restored.get_round_index()))

	var empty = _manager()
	empty.from_dict({})
	_check("from_dict({}) 保持默认值", empty.get_round_index() == 0 and empty.get_history().is_empty(),
		str(empty.to_dict()))

	var weird = _manager()
	weird.from_dict({"round": "two", "history": "nope"})
	_check("from_dict 类型不符时忽略字段且不崩溃",
		weird.get_round_index() == 0 and weird.get_history().is_empty(), str(weird.to_dict()))

	var mixed = _manager()
	mixed.from_dict({"round": 4, "history": [{"round": 1, "outcome": "a"}, "bad", 3]})
	var mixed_history: Array = mixed.get_history()
	_check("from_dict 跳过非字典的 history 条目",
		mixed.get_round_index() == 4 and mixed_history.size() == 1
		and int(mixed_history[0]["round"]) == 1, str(mixed.to_dict()))
	manager.free()
	restored.free()
	empty.free()
	weird.free()
	mixed.free()
