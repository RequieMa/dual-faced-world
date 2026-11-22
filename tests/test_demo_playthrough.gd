extends SceneTree
## P0 可玩性回归：巡逻只抓“正在移动的朋友”，玩家先过载机位再按 F 能真实通关；
## 不能出现“第 2 轮开局 2 秒必输、但摄像头过载要 6 秒”的死局。
## 运行：godot --headless --path . --script tests/test_demo_playthrough.gd

const SCENE_PATH := "res://scenes/game_root.tscn"
const EXPECTED_CHECKS := 17

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
	var packed := ResourceLoader.load(SCENE_PATH) as PackedScene
	var game := packed.instantiate()
	game.auto_tick = false
	root.add_child(game)
	game.start_demo()

	# 第 1 轮：拾取 → 开门 → 跟随，正常过。
	_check("第 1 轮拾取", game.handle_action("game_pickup"))
	_check("第 1 轮开门", game.handle_action("game_door"))
	_check("第 1 轮 F", game.handle_action("game_hint_follow"))
	game.tick(4.0)
	_check("进入第 2 轮", int(game.get_demo_state()["round"]) == 2,
		str(game.get_demo_state()))

	# 关键：朋友站着不动时，巡逻不能抓；否则玩家没有 6 秒过载窗口。
	game.tick(5.0)
	var idle_state: Dictionary = game.get_demo_state()
	_check("朋友不动时巡逻不判负", String(idle_state["phase"]) == "playing", str(idle_state))
	if String(idle_state["phase"]) != "playing":
		game.free()
		_report()
		return

	# 真实策略：先过载 C1（6s）制造闪光，再开门/F；闪光期间巡逻被挡。
	game.switch_camera("C1")
	game.tick(6.5)
	_check("C1 过载烧毁", game.get_camera_session().is_burned("C1"),
		str(game.get_camera_session().get_state()))
	_check("过载产生闪光", game.get_hazard_effects().get_active_hazards().size() > 0,
		str(game.get_hazard_effects().get_state()))
	_check("闪光覆盖当前巡逻位置",
		game.get_hazard_effects().is_blocking(game.get_guard().get_position()),
		str(game.get_guard().get_state()))
	_check("第 2 轮开门", game.handle_action("game_door"))
	_check("第 2 轮 F", game.handle_action("game_hint_follow"))
	game.tick(4.0)
	var round3: Dictionary = game.get_demo_state()
	_check("进入第 3 轮", int(round3["round"]) == 3, str(round3))
	if int(round3["round"]) != 3:
		game.free()
		_report()
		return

	# 第 3 轮换 C2 过载；闪光范围覆盖巡逻线，仍能过。
	game.switch_camera("C2")
	game.tick(5.5)
	_check("C2 过载烧毁", game.get_camera_session().is_burned("C2"),
		str(game.get_camera_session().get_state()))
	_check("第 3 轮开门", game.handle_action("game_door"))
	_check("第 3 轮 F", game.handle_action("game_hint_follow"))
	game.tick(4.0)
	_check("真实策略三轮通关", String(game.get_demo_state()["phase"]) == "won",
		str(game.get_demo_state()))
	_check("通关时朋友仍在移动或已到门口",
		String(game.get_state()["guide"]["npcs"]["npc_imaginary"]["state"]) in ["WAIT", "FOLLOW"],
		str(game.get_state()["guide"]["npcs"]["npc_imaginary"]))

	game.free()
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
		print("DEMO_PLAYTHROUGH_TEST_PASS (%d checks)" % _checks)
		quit(0)
	else:
		printerr("DEMO_PLAYTHROUGH_TEST_FAIL (%d/%d failed)" % [_failures.size(), _checks])
		for failure in _failures:
			printerr("  - ", failure)
		quit(1)
