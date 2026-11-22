extends SceneTree
## PR2 验收：O 提示必须真的开门；门/烧毁在“重开一轮”与“重玩整局”的语义分离；
## 录像带面板暂停计时；lost HUD 不再显示剩余秒数。
## 运行：godot --headless --path . --script tests/test_demo_loop_semantics.gd

const SCENE_PATH := "res://scenes/game_root.tscn"
const EXPECTED_CHECKS := 19

var _failures: Array[String] = []
var _checks: int = 0
var _started := false
var _game_root: Node = null


func _initialize() -> void:
	_check("存在 scenes/game_root.tscn", ResourceLoader.exists(SCENE_PATH))


func _process(_delta: float) -> bool:
	if _started:
		return false
	_started = true
	_run_tests()
	return false


func _run_tests() -> void:
	var packed := ResourceLoader.load(SCENE_PATH) as PackedScene
	_game_root = packed.instantiate()
	_game_root.auto_tick = false
	root.add_child(_game_root)

	# 1) O 提示接线：不启动 demo，避免一轮完成后的 reset 把门又关上。
	_check("默认提示目标是 npc_imaginary",
		String(_game_root.get_level_state().get("hint_target", "")) == "npc_imaginary",
		str(_game_root.get_level_state()))
	# O 开门也受门禁线索约束；本用例只验证 O→门的接线，直接登记线索。
	var clues := root.get_node_or_null("ClueManager")
	if clues != null:
		clues.register_flag("door_code_A")
	_check("O 提示被接受", _game_root.handle_action("game_hint_open"))
	_game_root.tick(4.0)
	var door = _game_root.find_child("Door", true, false)
	_check("O 提示走完路线后门真的打开", door != null and bool(door.is_open()),
		"" if door == null else str(door.get_state()))

	# 2) 重开一轮要关门；烧毁则保留（M16 的“同一次运行内不回滚”）。
	_check("restart_round 成功", _game_root.restart_round(0.0))
	_check("重开一轮后门回到初始关闭", door != null and not bool(door.is_open()),
		"" if door == null else str(door.get_state()))

	# 3) start_demo 是“新开一局”：烧毁和当前画面一起清空，分数归零。
	_game_root.start_demo()
	_game_root.switch_camera("C1")
	_game_root.tick(8.0)
	_check("C1 已烧毁", _game_root.get_camera_session().is_burned("C1"))
	_game_root.start_demo()
	var camera_state: Dictionary = _game_root.get_camera_session().get_state()
	_check("start_demo 清空烧毁机位", not _game_root.get_camera_session().is_burned("C1"),
		str(camera_state))
	_check("start_demo 清空当前画面",
		String(_game_root.get_camera_view_state().get("view", "")) == "",
		str(_game_root.get_camera_view_state()))
	_check("start_demo 分数归零", int(_game_root.get_demo_state()["score"]) == 0,
		str(_game_root.get_demo_state()))
	_check("start_demo 回到第 1 轮",
		String(_game_root.get_demo_state()["phase"]) == "playing"
		and int(_game_root.get_demo_state()["round"]) == 1,
		str(_game_root.get_demo_state()))

	# 4) 录像带面板打开时暂停世界计时（含机位停留），关闭后继续。
	_game_root.switch_camera("C2")
	_check("打开录像带面板", _game_root.handle_action("game_tape"))
	var time_before := float(_game_root.get_demo_state()["time_left"])
	_game_root.tick(10.0)
	_check("面板打开时 demo 计时暂停",
		is_equal_approx(float(_game_root.get_demo_state()["time_left"]), time_before),
		"%s -> %s" % [time_before, _game_root.get_demo_state()])
	_check("面板打开时机位停留也暂停",
		not _game_root.get_camera_session().is_burned("C2"),
		str(_game_root.get_camera_session().get_state()))
	_check("关闭录像带面板", _game_root.handle_action("game_tape"))
	_game_root.tick(1.0)
	_check("关闭面板后计时继续",
		float(_game_root.get_demo_state()["time_left"]) < time_before,
		str(_game_root.get_demo_state()))

	# 5) 失败 HUD 用最终态格式，不再显示“剩余 Ns”。
	_game_root.tick(61.0)
	_check("超时进入 lost", String(_game_root.get_demo_state()["phase"]) == "lost",
		str(_game_root.get_demo_state()))
	var hud := _game_root.get_node_or_null("DemoHud")
	var label := hud.get_child(0) as Label if hud != null and hud.get_child_count() > 0 else null
	_check("lost HUD 不显示剩余秒数", label != null and not label.text.contains("剩余"),
		"" if label == null else label.text)
	_check("lost HUD 显示失败文案", label != null and label.text.contains("失败"),
		"" if label == null else label.text)

	_game_root.free()
	_report()


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
	if _failures.is_empty() and _checks != EXPECTED_CHECKS:
		_failures.append("断言数守卫：期望 %d，实际 %d" % [EXPECTED_CHECKS, _checks])
	print("----")
	if _failures.is_empty():
		print("DEMO_LOOP_SEMANTICS_TEST_PASS (%d checks)" % _checks)
		quit(0)
	else:
		printerr("DEMO_LOOP_SEMANTICS_TEST_FAIL (%d/%d failed)" % [_failures.size(), _checks])
		for failure in _failures:
			printerr("  - ", failure)
		quit(1)
