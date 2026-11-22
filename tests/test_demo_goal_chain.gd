extends SceneTree
## PR3 验收：磁带→线索→开门→引导→过载→敌人/危险→到门口，以及自动 tick 外的目标链规则。
## 运行：godot --headless --path . --script tests/test_demo_goal_chain.gd

const SCENE_PATH := "res://scenes/game_root.tscn"
const EXPECTED_CHECKS := 36

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
	_reset_globals()

	# 1) 正常三轮：磁带/线索/门/HUD/敌人轮次全部串起来。
	var game := _new_game()
	game.start_demo()
	_check("第 1 轮目标先拾取磁带", String(game.get_demo_state()["objective"]).contains("E"),
		str(game.get_demo_state()))
	_check("门初始关闭", not bool(game.get_demo_state()["door_open"]))
	_check("无线索时 H 被拒绝", not game.handle_action("game_door"))
	_check("H 被拒绝后门仍关闭", not bool(game.get_demo_state()["door_open"]))
	_check("H 被拒绝有门锁提示", String(game.get_demo_state()["message"]).contains("门锁"),
		str(game.get_demo_state()))
	_check("无线索时 O 也被拒绝", not game.handle_action("game_hint_open"))
	_check("E 拾取磁带", game.handle_action("game_pickup"))
	var after_pickup: Dictionary = game.get_demo_state()
	_check("磁带标记为已拾取", bool(after_pickup["tape_collected"]), str(after_pickup))
	_check("门禁线索已登记", bool(after_pickup["clue_found"]), str(after_pickup))
	_check("拾取有加分", int(after_pickup["score"]) >= 20, str(after_pickup))
	_check("拾取后目标转向开门", String(after_pickup["objective"]).contains("H"), str(after_pickup))
	_check("线索后 H 开门", game.handle_action("game_door"))
	_check("门已打开", bool(game.get_demo_state()["door_open"]))
	_check("开门后目标转向 F", String(game.get_demo_state()["objective"]).contains("F"),
		str(game.get_demo_state()))

	_disable_guard(game)
	_check("F 让朋友跟随", game.handle_action("game_hint_follow"))
	game.tick(4.0)
	var round2: Dictionary = game.get_demo_state()
	_check("抵达后进入第 2 轮", String(round2["phase"]) == "playing" and int(round2["round"]) == 2,
		str(round2))
	_check("第 2 轮门复位关闭", not bool(round2["door_open"]), str(round2))
	_check("线索跨轮保留", bool(round2["clue_found"]), str(round2))
	_check("第 2 轮敌人启用", bool(round2["enemy_active"]), str(round2))
	_check("第 2 轮目标先开门", String(round2["objective"]).contains("H"), str(round2))

	_check("第 2 轮 H 开门", game.handle_action("game_door"))
	_disable_guard(game)
	_check("第 2 轮 F 跟随", game.handle_action("game_hint_follow"))
	game.tick(4.0)
	var round3: Dictionary = game.get_demo_state()
	_check("进入第 3 轮", String(round3["phase"]) == "playing" and int(round3["round"]) == 3,
		str(round3))
	_check("第 3 轮敌人仍启用", bool(round3["enemy_active"]), str(round3))
	_check("第 3 轮 H 开门", game.handle_action("game_door"))
	_disable_guard(game)
	_check("第 3 轮 F 跟随", game.handle_action("game_hint_follow"))
	game.tick(4.0)
	_check("三轮后通关", String(game.get_demo_state()["phase"]) == "won",
		str(game.get_demo_state()))
	game.free()

	# 2) 门没开时，NPC 到终点也不能判胜。
	_reset_globals()
	var no_door := _new_game()
	no_door.start_demo()
	no_door.handle_action("game_hint_follow")
	no_door.tick(4.0)
	var waiting: Dictionary = no_door.get_demo_state()
	_check("门没开时不判胜", String(waiting["phase"]) == "playing" and int(waiting["round"]) == 1,
		str(waiting))
	_check("到门口但门锁着有提示", String(waiting["message"]).contains("门"), str(waiting))
	no_door.handle_action("game_pickup")
	no_door.handle_action("game_door")
	no_door.tick(0.1)
	_check("补开门后过关", int(no_door.get_demo_state()["round"]) == 2,
		str(no_door.get_demo_state()))
	no_door.free()

	# 3) 巡逻看见朋友 → 本轮失败。
	_reset_globals()
	var spotted := _new_game()
	spotted.start_demo()
	spotted.handle_action("game_pickup")
	spotted.handle_action("game_door")
	_disable_guard(spotted)
	spotted.handle_action("game_hint_follow")
	spotted.tick(4.0)
	var guard = spotted.get_guard()
	guard.setup([Vector3(4, 0, 0)], 0.0)
	guard.set_facing(Vector3(0, 0, 1))
	spotted.tick(0.1)
	_check("被巡逻发现判负", String(spotted.get_demo_state()["phase"]) == "lost",
		str(spotted.get_demo_state()))
	_check("失败文案含巡逻", String(spotted.get_demo_state()["message"]).contains("巡逻"),
		str(spotted.get_demo_state()))
	spotted.free()

	# 4) 机位过载触发闪光危险，危险覆盖巡逻起点并会到期。
	_reset_globals()
	var hazard_game := _new_game()
	hazard_game.start_demo()
	hazard_game.handle_action("game_pickup")
	hazard_game.handle_action("game_door")
	hazard_game.switch_camera("C1")
	hazard_game.tick(8.0)
	var hazards = hazard_game.get_hazard_effects()
	var guard2 = hazard_game.get_guard()
	_check("过载触发危险", hazards.get_active_hazards().size() > 0,
		str(hazards.get_state()))
	_check("危险覆盖巡逻起点", hazards.is_blocking(guard2.get_position()),
		str(guard2.get_state()))
	hazard_game.tick(9.0)
	_check("危险到期清空", hazards.get_active_hazards().is_empty(), str(hazards.get_state()))
	hazard_game.free()

	_report()


func _new_game() -> Node:
	var packed := ResourceLoader.load(SCENE_PATH) as PackedScene
	var instance := packed.instantiate()
	instance.auto_tick = false
	root.add_child(instance)
	return instance


func _reset_globals() -> void:
	var clues := root.get_node_or_null("ClueManager")
	if clues != null and clues.has_method("clear"):
		clues.clear()
	var archive := root.get_node_or_null("TapeArchive")
	if archive != null and archive.has_method("reset_discovery"):
		archive.reset_discovery()


## 单元测试里把敌人挪到远处、视野归零，专注验证目标链本身。
func _disable_guard(game: Node) -> void:
	var guard = game.get_guard()
	if guard == null:
		return
	guard.setup([Vector3(30, 0, 30)], 0.0)
	guard.set_vision(1.0, 0.1)


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
		print("DEMO_GOAL_CHAIN_TEST_PASS (%d checks)" % _checks)
		quit(0)
	else:
		printerr("DEMO_GOAL_CHAIN_TEST_FAIL (%d/%d failed)" % [_failures.size(), _checks])
		for failure in _failures:
			printerr("  - ", failure)
		quit(1)
