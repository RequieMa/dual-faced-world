extends SceneTree
## 可玩 demo（序章）测试：3 轮目标 / 计时 / 得分 / 失败重试 / 烧毁扣分 / 磁带解锁。
## 运行：godot --headless --path . --script tests/test_prologue_demo.gd
## 退出码 0 = 全绿，1 = 有用例失败。

const SCENE_PATH := "res://scenes/game_root.tscn"
## 全绿时应执行的断言数：运行时错误会中止当前函数，靠数量守恒抓住「假绿」。
const EXPECTED_CHECKS := 40

var _failures: Array[String] = []
var _checks: int = 0
var _started := false


func _initialize() -> void:
	_check("存在 scenes/game_root.tscn", ResourceLoader.exists(SCENE_PATH))


func _process(_delta: float) -> bool:
	if _started:
		return false
	_started = true
	_run_tests()
	return false


func _run_tests() -> void:
	_check("存在 TapeArchive autoload", root.get_node_or_null("TapeArchive") != null)
	_test_full_run()
	_test_timeout_and_retry()
	_test_burn_penalty()
	_report()


# --- 通关流程 ------------------------------------------------------------------

func _test_full_run() -> void:
	var instance := _new_game_root()
	if instance == null:
		_check("game_root 可实例化", false)
		return
	instance.start_demo()
	var state: Dictionary = instance.get_demo_state()
	_check("start_demo 后进入 playing", String(state["phase"]) == "playing", str(state))
	_check("第 1/3 轮", int(state["round"]) == 1 and int(state["rounds"]) == 3, str(state))
	_check("限时 60 秒", is_equal_approx(float(state["time_left"]), 60.0), str(state))
	_check("开局得分为 0", int(state["score"]) == 0, str(state))
	_check("开局自动开始循环第 1 轮", instance.get_loop_manager().get_round_index() == 1)
	_check("有 demo HUD", instance.get_node_or_null("DemoHud") != null)
	var hud_label := instance.get_node_or_null("DemoHud").get_child(0) as Label
	_check("HUD 显示轮次与目标", hud_label != null and hud_label.text.contains("第 1/3 轮")
		and hud_label.text.contains("带他到门口"), "" if hud_label == null else hud_label.text)
	var archive = root.get_node_or_null("TapeArchive")
	if archive != null:
		_check("开局解锁第一盘磁带", archive.known_count() >= 1, str(archive.known_count()))

	instance.tick(10.0)
	state = instance.get_demo_state()
	_check("tick 推进倒计时", float(state["time_left"]) < 51.0 and float(state["time_left"]) > 49.0,
		str(state))

	_finish_round(instance)
	state = instance.get_demo_state()
	_check("把朋友带到门口后进入第 2 轮", int(state["round"]) == 2 and String(state["phase"]) == "playing",
		str(state))
	_check("成功一轮得分 > 100", int(state["score"]) > 100, str(state))
	_check("循环轮次跟随 demo 轮次", instance.get_loop_manager().get_round_index() == 2,
		str(instance.get_loop_manager().get_round_index()))
	var npc_after_round: Dictionary = instance.get_state()["guide"]["npcs"]["npc_imaginary"]
	_check("第 2 轮开始时 NPC 已复位",
		String(npc_after_round["state"]) == "IDLE" and int(npc_after_round["waypoint_index"]) == 0,
		str(npc_after_round))

	_finish_round(instance)
	_finish_round(instance)
	state = instance.get_demo_state()
	_check("完成 3 轮后通关", String(state["phase"]) == "won", str(state))
	_check("通关得分 >= 300", int(state["score"]) >= 300, str(state))
	_check("通关文案含「通关」", String(state["message"]).contains("通关"), str(state["message"]))
	if archive != null:
		_check("三轮后已解锁多盘磁带", archive.known_count() >= 2, str(archive.known_count()))

	# 通关后按 R 重玩
	var score_before := int(state["score"])
	instance.handle_action("game_restart")
	state = instance.get_demo_state()
	_check("通关后 R 重玩回到第 1 轮", String(state["phase"]) == "playing" and int(state["round"]) == 1,
		str(state))
	_check("重玩清空得分", int(state["score"]) == 0 and score_before >= 300, str(state))
	instance.free()


func _finish_round(instance) -> void:
	var before_round := int(instance.get_demo_state()["round"])
	instance.handle_action("game_hint_follow")
	for i in range(40):
		instance.tick(0.5)
		var state: Dictionary = instance.get_demo_state()
		if String(state["phase"]) != "playing" or int(state["round"]) != before_round:
			return


# --- 超时与重试 ----------------------------------------------------------------

func _test_timeout_and_retry() -> void:
	var instance := _new_game_root()
	if instance == null:
		_check("第二个实例可实例化", false)
		return
	instance.start_demo()
	var start_score := int(instance.get_demo_state()["score"])
	var archive = root.get_node_or_null("TapeArchive")
	var known_before := 0
	if archive != null:
		known_before = archive.known_count()
	instance.tick(61.0)
	var state: Dictionary = instance.get_demo_state()
	_check("超时后本轮失败", String(state["phase"]) == "lost", str(state))
	_check("失败文案含「超时」", String(state["message"]).contains("超时"), str(state["message"]))
	_check("超时不加得分", int(state["score"]) == start_score, str(state))
	_check("失败时 demo 不是 active", instance.is_demo_active() == false)
	var history: Array = instance.get_loop_manager().get_history()
	_check("超时写入轮次结果 outcome=timeout",
		not history.is_empty() and String(history[-1].get("outcome", "")) == "timeout", str(history))

	instance.handle_action("game_restart")
	state = instance.get_demo_state()
	_check("R 重试回到同一轮", String(state["phase"]) == "playing" and int(state["round"]) == 1,
		str(state))
	_check("重试后倒计时重置", is_equal_approx(float(state["time_left"]), 60.0), str(state))
	_check("重试重置 NPC 状态",
		String(instance.get_state()["guide"]["npcs"]["npc_imaginary"]["state"]) == "IDLE",
		str(instance.get_state()["guide"]["npcs"]["npc_imaginary"]))
	if archive != null:
		_check("重试不额外解锁磁带", archive.known_count() == known_before,
			"%d -> %d" % [known_before, archive.known_count()])
	instance.free()


# --- 烧毁扣分 ------------------------------------------------------------------

func _test_burn_penalty() -> void:
	var instance := _new_game_root()
	if instance == null:
		_check("第三个实例可实例化", false)
		return
	instance.start_demo()
	_check("进入 C1", instance.handle_action("game_camera_1"))
	instance.tick(7.0)
	var state: Dictionary = instance.get_demo_state()
	_check("C1 过载烧毁", instance.get_camera_session().is_burned("C1"),
		str(instance.get_camera_session().get_state()))
	_check("烧毁扣 30 分", int(state["score"]) == -30, str(state))
	_check("烧毁有提示文案", String(state["message"]).contains("烧毁"), str(state["message"]))
	instance.tick(1.0)
	_check("同一台机位不重复扣分", int(instance.get_demo_state()["score"]) == -30,
		str(instance.get_demo_state()))
	instance.tick(60.0)
	var timeout_state: Dictionary = instance.get_demo_state()
	_check("超时前烧毁的机位已结算",
		String(timeout_state["phase"]) == "lost" and int(timeout_state["score"]) == -30,
		str(timeout_state))
	# 失败阶段计时仍在跑：再烧一台，重试时应补扣。
	_check("失败后仍可切机位", instance.handle_action("game_camera_2"))
	instance.tick(7.0)
	_check("失败阶段的烧毁暂不扣分", int(instance.get_demo_state()["score"]) == -30,
		str(instance.get_demo_state()))
	instance.handle_action("game_restart")
	_check("重试时补扣失败阶段烧毁的机位", int(instance.get_demo_state()["score"]) == -60,
		str(instance.get_demo_state()))
	instance.tick(1.0)
	_check("重试后不再次扣分", int(instance.get_demo_state()["score"]) == -60,
		str(instance.get_demo_state()))
	instance.free()


# --- 工具 ---------------------------------------------------------------------

func _new_game_root() -> Node:
	var packed := ResourceLoader.load(SCENE_PATH) as PackedScene
	if packed == null:
		return null
	var instance := packed.instantiate()
	if instance == null:
		return null
	instance.auto_tick = false
	root.add_child(instance)
	return instance


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
	if _failures.is_empty() and _checks != EXPECTED_CHECKS:
		_failures.append("断言数守卫：期望 %d，实际 %d（用例被跳过或运行时错误）" % [EXPECTED_CHECKS, _checks])
	print("----")
	if _failures.is_empty():
		print("PROLOGUE_DEMO_TEST_PASS (%d checks)" % _checks)
		quit(0)
	else:
		printerr("PROLOGUE_DEMO_TEST_FAIL (%d/%d failed)" % [_failures.size(), _checks])
		for failure in _failures:
			printerr("  - ", failure)
		quit(1)
