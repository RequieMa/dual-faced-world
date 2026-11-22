extends SceneTree
## PR1 验收：机位切换必须改变实际画面，HUD 必须显示当前画面/冷却/烧毁。
## 运行：godot --headless --path . --script tests/test_game_root_camera_view.gd
##
## 先写测试（红）再实现；断言数守卫防止运行时错误造成「假绿」。

const SCENE_PATH := "res://scenes/game_root.tscn"
const EXPECTED_CHECKS := 27

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
	if packed == null:
		_check("game_root.tscn 可加载", false)
		_report()
		return
	_game_root = packed.instantiate()
	_game_root.auto_tick = false
	root.add_child(_game_root)

	var overview := _game_root.get_node_or_null("World/OverviewCamera") as Camera3D
	_check("总览相机 OverviewCamera 存在", overview != null)
	_check("启动时总览相机 current", overview != null and overview.current)

	var views: Array[Camera3D] = []
	for camera_id in ["C1", "C2", "C3", "C4"]:
		var camera := _game_root.get_node_or_null("World/Cameras/%s" % camera_id) as Camera3D
		views.append(camera)
		_check("机位 %s 有实际 Camera3D" % camera_id, camera != null)
	_check("启动时四个机位都不是 current",
		views.all(func(camera): return camera != null and not camera.current))

	if not _game_root.has_method("get_camera_view_state"):
		_check("提供 get_camera_view_state()", false)
		_report()
		return
	_check("提供 get_camera_view_state()", true)
	_check("初始画面为总览",
		String(_game_root.get_camera_view_state().get("view", "")) == "",
		str(_game_root.get_camera_view_state()))

	_check("按 1 进入 C1", _game_root.handle_action("game_camera_1"))
	var c1 := _game_root.get_node("World/Cameras/C1") as Camera3D
	_check("C1 画面 current", c1 != null and c1.current)
	_check("get_camera_view_state 返回 C1",
		String(_game_root.get_camera_view_state().get("view", "")) == "C1",
		str(_game_root.get_camera_view_state()))

	_check("按 2 进入 C2", _game_root.handle_action("game_camera_2"))
	var c2 := _game_root.get_node("World/Cameras/C2") as Camera3D
	_check("C2 current 且 C1 退出", c2 != null and c2.current and not c1.current)
	_check("离开机位回到总览",
		_game_root.handle_action("game_camera_off") and overview != null and overview.current)

	var status := _game_root.get_node_or_null("UI/CameraStatus") as Label
	_check("HUD 有 CameraStatus", status != null)
	_check("HUD 标明总览/机位状态",
		status != null and status.text.contains("总览"), "" if status == null else status.text)

	# 进入 C3 再离开 → C3 冷却；HUD 应显示冷却。
	_game_root.handle_action("game_camera_3")
	_game_root.handle_action("game_camera_off")
	status = _game_root.get_node_or_null("UI/CameraStatus") as Label
	_check("HUD 显示 C3 冷却",
		status != null and status.text.contains("C3") and status.text.contains("冷却"),
		"" if status == null else status.text)

	# C4 停留到过载烧毁：画面必须回总览，HUD 显示烧毁。
	_check("进入 C4", _game_root.handle_action("game_camera_4"))
	_game_root.tick(8.0)
	var c4 := _game_root.get_node("World/Cameras/C4") as Camera3D
	status = _game_root.get_node_or_null("UI/CameraStatus") as Label
	_check("C4 烧毁后画面回总览",
		overview != null and overview.current and c4 != null and not c4.current)
	_check("HUD 显示 C4 烧毁", status != null and status.text.contains("C4 烧毁"),
		"" if status == null else status.text)
	_check("烧毁后 get_camera_view_state 为空",
		String(_game_root.get_camera_view_state().get("view", "")) == "",
		str(_game_root.get_camera_view_state()))

	_check("未知机位不能切画面", not _game_root.switch_camera("C9"))
	_check("未知机位尝试后仍是总览", overview != null and overview.current)

	_game_root.reset_for_loop(0.0)
	status = _game_root.get_node_or_null("UI/CameraStatus") as Label
	_check("循环复位后回到总览", overview != null and overview.current)
	_check("循环复位后烧毁记录保留",
		status != null and status.text.contains("C4 烧毁"),
		"" if status == null else status.text)

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
		print("CAMERA_VIEW_TEST_PASS (%d checks)" % _checks)
		quit(0)
	else:
		printerr("CAMERA_VIEW_TEST_FAIL (%d/%d failed)" % [_failures.size(), _checks])
		for failure in _failures:
			printerr("  - ", failure)
		quit(1)
