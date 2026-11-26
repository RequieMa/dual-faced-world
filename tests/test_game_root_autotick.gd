extends SceneTree
## PR3 验收：真实 `_process` + auto_tick 时间轴（不手动 tick）。
## 用 Engine.time_scale 加速，但仍是引擎逐帧推进；覆盖倒计时、机位烧毁回总览、拾取/开门/过关。

const SCENE_PATH := "res://scenes/game_root.tscn"
const EXPECTED_CHECKS := 12

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
	Engine.time_scale = 20.0
	Engine.max_fps = 60
	var packed := ResourceLoader.load(SCENE_PATH) as PackedScene
	var game_root := packed.instantiate()
	root.add_child(game_root)
	await process_frame
	_check("game_root.tscn 可实例化并装配", game_root != null)
	if game_root == null:
		_finish()
		return

	var initial: Dictionary = game_root.get_demo_state()
	_check("auto_tick 启动即第 1 轮",
		String(initial["phase"]) == "playing" and int(initial["round"]) == 1, str(initial))
	_check("初始倒计时为 60s", is_equal_approx(float(initial["time_left"]), 60.0), str(initial))

	var time_before := float(game_root.get_demo_state()["time_left"])
	await _wait_until(func() -> bool:
		return float(game_root.get_demo_state()["time_left"]) < time_before - 0.5, 2000)
	_check("真实 _process 推进倒计时",
		float(game_root.get_demo_state()["time_left"]) < time_before - 0.5,
		str(game_root.get_demo_state()))

	_check("真实输入切到 C1", game_root.handle_action("game_camera_1"))
	await _wait_until(func() -> bool:
		return game_root.get_camera_session().is_burned("C1"), 3000)
	_check("真实时间轴下 C1 会烧毁", game_root.get_camera_session().is_burned("C1"),
		str(game_root.get_camera_session().get_state()))
	_check("烧毁后画面回总览",
		String(game_root.get_camera_view_state().get("view", "")) == "",
		str(game_root.get_camera_view_state()))

	_check("真实输入按 E 拾取", game_root.handle_action("game_pickup"))
	_check("真实输入按 H 开门", game_root.handle_action("game_door"))
	_check("真实输入按 F 引导", game_root.handle_action("game_hint_follow"))
	await _wait_until(func() -> bool:
		return int(game_root.get_demo_state()["round"]) >= 2, 4000)
	_check("真实时间轴推进到第 2 轮",
		int(game_root.get_demo_state()["round"]) >= 2, str(game_root.get_demo_state()))

	game_root.free()
	_finish()


func _wait_until(predicate: Callable, timeout_ms: int) -> void:
	var started := Time.get_ticks_msec()
	while Time.get_ticks_msec() - started < timeout_ms:
		if bool(predicate.call()):
			return
		await process_frame


func _finish() -> void:
	Engine.time_scale = 1.0
	Engine.max_fps = 0
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
		print("AUTOTICK_E2E_TEST_PASS (%d checks)" % _checks)
		quit(0)
	else:
		printerr("AUTOTICK_E2E_TEST_FAIL (%d/%d failed)" % [_failures.size(), _checks])
		for failure in _failures:
			printerr("  - ", failure)
		quit(1)
