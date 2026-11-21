extends SceneTree
## W8 亲身段落（M14）+ 终章动作段（M15，二段跳）的自动化测试。
## 运行：godot --headless --path . --script tests/test_player_controller.gd
## 退出码 0 = 全绿，1 = 有用例失败。
##
## 只 new() 本模块，不依赖 autoload、不依赖物理帧；输入动作在运行时注册，
## 每个用例结束时清理，避免污染其它套件。

const PLAYER_CONTROLLER := "res://scripts/player/player_controller.gd"
const JUMP_SECTION := "res://scripts/player/jump_section.gd"

## 运行时注册的输入动作名（必须与实现里的常量一致）。
const ACTION_NAMES := [
	"player_move_forward",
	"player_move_back",
	"player_move_left",
	"player_move_right",
	"player_jump",
]

const EPS := 0.001
const TICK := 0.05

var _failures: Array[String] = []
var _checks: int = 0


func _initialize() -> void:
	_cleanup_player_actions()
	_check("存在 scripts/player/jump_section.gd", ResourceLoader.exists(JUMP_SECTION))
	_check("存在 scripts/player/player_controller.gd", ResourceLoader.exists(PLAYER_CONTROLLER))
	if not ResourceLoader.exists(JUMP_SECTION) or not ResourceLoader.exists(PLAYER_CONTROLLER):
		_report()
		return

	_test_jump_section_defaults_and_limits()
	_test_jump_section_relock_after_landing()
	_test_player_defaults_and_move()
	_test_player_turning()
	_test_jump_and_land()
	_test_double_jump()
	_test_jump_hold_edge()
	_test_jump_signals()
	_test_landed_signal_position()
	_test_reset()
	_test_input_shapes()
	_test_action_section_toggle()
	_test_jump_action_disabled_by_default()
	_test_whole_section_toggle()
	_test_setup_validation()
	_test_input_actions()
	_test_attach_body()

	_cleanup_player_actions()
	_report()


# --- 断言与工具 ---------------------------------------------------------------

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
		print("PLAYER_CONTROLLER_TEST_PASS (%d checks)" % _checks)
		quit(0)
	else:
		printerr("PLAYER_CONTROLLER_TEST_FAIL (%d/%d failed)" % [_failures.size(), _checks])
		for failure in _failures:
			printerr("  - ", failure)
		quit(1)


func _vec_approx(actual: Vector3, expected: Vector3) -> bool:
	return abs(actual.x - expected.x) < EPS \
		and abs(actual.y - expected.y) < EPS \
		and abs(actual.z - expected.z) < EPS


func _new_jump_section() -> RefCounted:
	return load(JUMP_SECTION).new()


## 测试用控制器：默认把「跳跃动作段」打开（W8 组件在玩法层默认关闭，见设计决定）。
## 要验证类默认值的用例请用 _new_raw_controller()。
func _new_controller(config: Dictionary = {}) -> Node:
	var merged := {"action_enabled": true}
	merged.merge(config, true)
	return _new_raw_controller(merged)


func _new_raw_controller(config: Dictionary = {}) -> Node:
	var controller: Node = load(PLAYER_CONTROLLER).new()
	controller.setup(config)
	return controller


func _dispose(controller: Node) -> void:
	if controller == null:
		return
	controller.unregister_input_actions()
	controller.free()


func _cleanup_player_actions() -> void:
	for action in ACTION_NAMES:
		if InputMap.has_action(action):
			InputMap.erase_action(action)


func _tick_until_grounded(controller: Node, max_ticks: int = 400) -> Dictionary:
	var ticks := 0
	while not bool(controller.get_state()["grounded"]) and ticks < max_ticks:
		controller.tick(TICK, {})
		ticks += 1
	return controller.get_state()


# --- JumpSection ---------------------------------------------------------------

func _test_jump_section_defaults_and_limits() -> void:
	var section: RefCounted = _new_jump_section()
	_check("JumpSection：默认二段跳", section.get_max_jumps() == 2)
	_check("JumpSection：初始两跳可用", section.get_jumps_left() == 2 and section.get_jumps_used() == 0)
	_check("JumpSection：初始处于落地状态", section.is_grounded())

	_check("JumpSection：第一次跳成功", section.try_jump() == true)
	_check("JumpSection：第一次跳消耗一次", section.get_jumps_used() == 1 and section.get_jumps_left() == 1)
	_check("JumpSection：起跳后离地", not section.is_grounded())
	_check("JumpSection：空中第二次跳成功", section.try_jump() == true)
	_check("JumpSection：第二次跳用尽", section.get_jumps_used() == 2 and section.get_jumps_left() == 0)
	_check("JumpSection：第三次被拒绝", section.try_jump() == false)
	_check("JumpSection：拒绝后计数不变", section.get_jumps_used() == 2 and section.get_jumps_left() == 0)

	_check("JumpSection：可配置为三段跳", section.set_max_jumps(3) == true)
	section.on_landed()
	_check("JumpSection：落地重置为三跳", section.get_jumps_used() == 0 and section.get_jumps_left() == 3)
	section.try_jump()
	section.try_jump()
	section.try_jump()
	_check("JumpSection：三段跳内第三次成功", section.get_jumps_used() == 3)
	_check("JumpSection：三段跳的第四次被拒绝", section.try_jump() == false)

	_check("JumpSection：拒绝 0 段跳", section.set_max_jumps(0) == false)
	_check("JumpSection：拒绝负数", section.set_max_jumps(-2) == false)
	_check("JumpSection：拒绝过大的次数", section.set_max_jumps(99) == false)
	_check("JumpSection：非法设置不改变上限", section.get_max_jumps() == 3)
	_check("JumpSection：可以调回 1 段跳", section.set_max_jumps(1) == true)
	section.on_landed()
	_check("JumpSection：落地后只剩一次", section.get_jumps_left() == 1)


func _test_jump_section_relock_after_landing() -> void:
	var section: RefCounted = _new_jump_section()
	section.try_jump()
	section.try_jump()
	_check("JumpSection：落地前不可再跳", section.try_jump() == false)
	section.on_landed()
	_check("JumpSection：落地后恢复两跳", section.get_jumps_left() == 2 and section.is_grounded())
	_check("JumpSection：落地后可再次起跳", section.try_jump() == true)
	section.on_landed()
	section.on_landed()
	_check("JumpSection：重复落地是幂等的", section.get_jumps_left() == 2 and section.is_grounded())


# --- PlayerController：移动 / 转向 --------------------------------------------

func _test_player_defaults_and_move() -> void:
	var controller := _new_controller()
	var state: Dictionary = controller.get_state()
	_check("PlayerController：默认状态 idle", state["state"] == "idle")
	_check("PlayerController：默认落地", state["grounded"] == true)
	_check("PlayerController：默认最大两跳", state["max_jumps"] == 2 and state["jumps_left"] == 2)
	_check("PlayerController：默认位置在地面原点", _vec_approx(state["position"], Vector3.ZERO))
	_check("PlayerController：默认朝向 0", abs(float(state["yaw"])) < EPS)

	for i in range(5):
		controller.tick(0.1, {"move": Vector2(0, -1)})
	state = controller.get_state()
	_check("PlayerController：前进时状态 moving", state["state"] == "moving")
	_check("PlayerController：前进沿 -Z", abs(float(state["position"].z) + 1.5) < 0.01)
	_check("PlayerController：前进不偏移 X", abs(float(state["position"].x)) < EPS)
	_check("PlayerController：朝北时 yaw 为 0", abs(float(state["yaw"])) < EPS)

	var before: Vector3 = state["position"]
	controller.tick(0.1, {})
	state = controller.get_state()
	_check("PlayerController：松开输入回到 idle", state["state"] == "idle")
	_check("PlayerController：松开输入不继续位移", _vec_approx(state["position"], before))
	_check("PlayerController：松开输入水平速度归零", abs(float(state["velocity"].x)) < EPS and abs(float(state["velocity"].z)) < EPS)

	controller.tick(0.0, {"move": Vector2(1, 0)})
	controller.tick(-0.5, {"move": Vector2(1, 0)})
	_check("PlayerController：非正 delta 不推进", _vec_approx(controller.get_state()["position"], before))
	_dispose(controller)


func _test_player_turning() -> void:
	var controller := _new_controller()
	controller.tick(0.1, {"move": Vector2(1, 0)})
	var one_tick_yaw := float(controller.get_state()["yaw"])
	_check("转向：单帧转角受 turn_speed * delta 限制", abs(abs(one_tick_yaw) - 0.8) < 0.001)

	for i in range(9):
		controller.tick(0.1, {"move": Vector2(1, 0)})
	var state: Dictionary = controller.get_state()
	_check("转向：朝东时 yaw 收敛到 -PI/2", abs(float(state["yaw"]) + PI / 2.0) < 0.01)
	_check("转向：朝东时沿 +X 移动", float(state["position"].x) > 1.0)
	_check("转向：朝东时 Z 不漂移", abs(float(state["position"].z)) < EPS)

	for i in range(10):
		controller.tick(0.1, {"move": Vector2(0, -1)})
	state = controller.get_state()
	_check("转向：从东折向北时 yaw 回到 0", abs(float(state["yaw"])) < 0.01)
	_check("转向：折向时不会绕远路（连续 tick 内完成）", float(state["position"].z) < -1.0)

	var slow := _new_controller({"turn_speed": 2.0})
	slow.tick(0.1, {"move": Vector2(1, 0)})
	_check("转向：配置的 turn_speed 生效", abs(abs(float(slow.get_state()["yaw"])) - 0.2) < 0.001)
	_dispose(slow)
	_dispose(controller)


# --- PlayerController：跳跃 / 落地 --------------------------------------------

func _test_jump_and_land() -> void:
	var controller := _new_controller()
	var landed_positions: Array = []
	controller.landed.connect(func(position: Vector3) -> void: landed_positions.append(position))

	controller.tick(TICK, {"jump": true})
	var state: Dictionary = controller.get_state()
	_check("跳跃：第一次跳后进入 airborne", state["state"] == "airborne" and state["grounded"] == false)
	_check("跳跃：第一次跳消耗一次", state["jumps_used"] == 1 and state["jumps_left"] == 1)
	_check("跳跃：起跳瞬间垂直速度为上升", float(state["velocity"].y) > 0.0)
	controller.tick(TICK, {"jump": false})

	state = _tick_until_grounded(controller)
	_check("落地：最终回到地面", state["grounded"] == true and abs(float(state["position"].y)) < EPS)
	_check("落地：落地那一帧状态是 landing", state["state"] == "landing")
	_check("落地：跳跃预算重置", state["jumps_used"] == 0 and state["jumps_left"] == 2)
	_check("落地：landed 信号只发一次", landed_positions.size() == 1)

	controller.tick(TICK, {})
	_check("落地：landing 是过渡态，下一帧回 idle", controller.get_state()["state"] == "idle")
	_check("落地：落地后可以再跳", _press_jump(controller) and controller.get_state()["state"] == "airborne")
	_dispose(controller)


func _test_double_jump() -> void:
	var controller := _new_controller()

	controller.tick(TICK, {"jump": true})
	var first: Dictionary = controller.get_state()
	_check("二段跳：第一跳成功", first["jumps_used"] == 1 and first["jumps_left"] == 1)
	_check("二段跳：第一跳后在空中", first["grounded"] == false)

	controller.tick(TICK, {"jump": false})
	var mid: Dictionary = controller.get_state()
	_check("二段跳：松开跳跃键后仍在空中", mid["grounded"] == false)
	var vy_before_second: float = float(mid["velocity"].y)

	controller.tick(TICK, {"jump": true})
	var second: Dictionary = controller.get_state()
	_check("二段跳：空中第二次跳成功", second["jumps_used"] == 2 and second["jumps_left"] == 0)
	_check("二段跳：第二次跳重新给上升速度", float(second["velocity"].y) >= vy_before_second)
	_check("二段跳：第二次跳后仍在空中", second["grounded"] == false)

	controller.tick(TICK, {"jump": false})
	var vy_before_third: float = float(controller.get_state()["velocity"].y)
	controller.tick(TICK, {"jump": true})
	var third: Dictionary = controller.get_state()
	_check("二段跳：第三次被拒绝", third["jumps_used"] == 2 and third["jumps_left"] == 0)
	_check("二段跳：拒绝后不再获得上升速度", float(third["velocity"].y) < vy_before_third)
	_check("二段跳：三次尝试后仍在空中", third["grounded"] == false)

	var landed: Dictionary = _tick_until_grounded(controller)
	_check("二段跳：落地后恢复两次机会", landed["jumps_used"] == 0 and landed["jumps_left"] == 2)
	_dispose(controller)


## 按住跳跃键跨帧只应消耗一次；松开再按才算下一次。
func _test_jump_hold_edge() -> void:
	var controller := _new_controller()
	controller.tick(TICK, {"jump": true})
	_check("按住：第一帧消耗一次", int(controller.get_state()["jumps_used"]) == 1)
	for i in range(5):
		controller.tick(TICK, {"jump": true})
	var state: Dictionary = controller.get_state()
	_check("按住跳跃键跨帧只触发一次", int(state["jumps_used"]) == 1)
	_check("按住期间保持空中", state["grounded"] == false)

	controller.tick(TICK, {"jump": false})
	controller.tick(TICK, {"jump": true})
	_check("松开再按触发第二跳", int(controller.get_state()["jumps_used"]) == 2)
	for i in range(3):
		controller.tick(TICK, {"jump": true})
	_check("预算用尽后按住不再触发", int(controller.get_state()["jumps_used"]) == 2)
	_dispose(controller)


func _test_jump_signals() -> void:
	var controller := _new_controller()
	var jumps: Array = []
	var rejections: Array = []
	controller.jumped.connect(func(used: int, left: int) -> void: jumps.append([used, left]))
	controller.jump_rejected.connect(func(left: int) -> void: rejections.append(left))

	controller.tick(TICK, {"jump": true})
	controller.tick(TICK, {"jump": false})
	controller.tick(TICK, {"jump": true})
	controller.tick(TICK, {"jump": false})
	controller.tick(TICK, {"jump": true})
	_check("信号：jumped 发两次且参数正确", jumps.size() == 2 and jumps[0] == [1, 1] and jumps[1] == [2, 0])
	_check("信号：jump_rejected 发一次且剩余 0", rejections.size() == 1 and int(rejections[0]) == 0)
	_dispose(controller)


func _test_landed_signal_position() -> void:
	var controller := _new_controller()
	var positions: Array = []
	controller.landed.connect(func(position: Vector3) -> void: positions.append(position))

	controller.tick(TICK, {"jump": true})
	controller.tick(TICK, {"jump": false, "move": Vector2(0, -1)})
	var guard := 0
	while not bool(controller.get_state()["grounded"]) and guard < 400:
		controller.tick(TICK, {"move": Vector2(0, -1)})
		guard += 1
	var state: Dictionary = controller.get_state()
	_check("落地信号：只发一次", positions.size() == 1)
	_check("落地信号：位置等于同帧最终位置", positions.size() == 1 and _vec_approx(positions[0], state["position"]))
	_check("落地信号：同帧水平位移已计入", positions.size() == 1 and float(positions[0].z) < -0.5)
	_dispose(controller)


func _test_reset() -> void:
	var controller := _new_controller()
	controller.tick(0.1, {"jump": true})
	controller.tick(0.1, {"move": Vector2(1, 0)})
	controller.reset()
	var state: Dictionary = controller.get_state()
	_check("reset：回到出生点", _vec_approx(state["position"], Vector3.ZERO))
	_check("reset：清空速度与朝向", _vec_approx(state["velocity"], Vector3.ZERO) and abs(float(state["yaw"])) < EPS)
	_check("reset：恢复落地与跳跃预算", state["grounded"] == true and state["jumps_used"] == 0 and state["jumps_left"] == 2)
	_check("reset：状态回到 idle", state["state"] == "idle")
	_dispose(controller)


## 兼容 Vector3 的 move 与 int 的 jump（宿主可能从其它输入层转过来）。
func _test_input_shapes() -> void:
	var controller := _new_controller()
	controller.tick(0.1, {"move": Vector3(0.0, 0.0, -1.0)})
	var state: Dictionary = controller.get_state()
	_check("输入：Vector3 move 取 x/z", state["state"] == "moving" and float(state["position"].z) < -0.2)

	controller.tick(0.1, {"jump": 1})
	_check("输入：jump 接受 int 1", int(controller.get_state()["jumps_used"]) == 1)
	controller.tick(0.1, {"jump": 0})
	controller.tick(0.1, {"jump": 1})
	_check("输入：int 0/1 也按上升沿计数", int(controller.get_state()["jumps_used"]) == 2)
	_dispose(controller)


func _press_jump(controller: Node) -> bool:
	controller.tick(TICK, {"jump": false})
	var before: int = int(controller.get_state()["jumps_used"])
	controller.tick(TICK, {"jump": true})
	var after: int = int(controller.get_state()["jumps_used"])
	controller.tick(TICK, {"jump": false})
	return after == before + 1


# --- 可开关 -------------------------------------------------------------------

func _test_action_section_toggle() -> void:
	var controller := _new_controller({"action_enabled": false})
	controller.tick(0.1, {"jump": true})
	var state: Dictionary = controller.get_state()
	_check("动作段关闭：跳跃被拒绝", state["grounded"] == true and state["state"] == "idle")
	_check("动作段关闭：不消耗跳跃预算", state["jumps_used"] == 0 and state["jumps_left"] == 2)
	_check("动作段关闭：不会离地", abs(float(state["position"].y)) < EPS)

	controller.tick(0.1, {"jump": false})
	controller.tick(0.1, {"move": Vector2(0, -1)})
	_check("动作段关闭：移动仍然可用", controller.get_state()["state"] == "moving")

	controller.set_action_enabled(true)
	controller.tick(0.1, {"jump": true})
	_check("运行时打开动作段后可以跳", int(controller.get_state()["jumps_used"]) == 1)
	_dispose(controller)


## 设计决定（2026-11-21，#20）：终章的二段跳动作段不保留。
## 组件本身作为可选项保留，但 PlayerController 默认关闭跳跃动作段。
func _test_jump_action_disabled_by_default() -> void:
	var controller := _new_raw_controller()
	var state: Dictionary = controller.get_state()
	_check("PlayerController：二段跳动作段默认关闭（M15 不保留）", state["action_enabled"] == false)

	controller.tick(0.1, {"jump": true})
	state = controller.get_state()
	_check("PlayerController：默认跳跃被拒绝",
		state["grounded"] == true and int(state["jumps_used"]) == 0
		and abs(float(state["position"].y)) < EPS, str(state))

	controller.tick(0.1, {"jump": false})
	controller.set_action_enabled(true)
	controller.tick(0.1, {"jump": true})
	_check("PlayerController：显式打开后仍可跳（组件保留为可选项）",
		int(controller.get_state()["jumps_used"]) == 1)
	_dispose(controller)


func _test_whole_section_toggle() -> void:
	var controller := _new_controller({"enabled": false})
	var state: Dictionary = controller.get_state()
	_check("亲身段落关闭：状态为 disabled", state["state"] == "disabled")

	controller.tick(0.5, {"move": Vector2(0, -1), "jump": true})
	state = controller.get_state()
	_check("亲身段落关闭：不移动", _vec_approx(state["position"], Vector3.ZERO))
	_check("亲身段落关闭：不跳跃", state["jumps_used"] == 0 and state["grounded"] == true)
	_check("亲身段落关闭：状态保持 disabled", state["state"] == "disabled")

	controller.set_enabled(true)
	controller.tick(0.1, {"move": Vector2(0, -1)})
	state = controller.get_state()
	_check("运行时打开亲身段落后可以移动", state["state"] == "moving" and float(state["position"].z) < -0.2)
	_dispose(controller)


# --- 配置校验 -----------------------------------------------------------------

func _test_setup_validation() -> void:
	var controller := _new_controller()
	var definition_errors: Array = []
	controller.definition_error.connect(func(message: String) -> void: definition_errors.append(message))

	_check("配置：非法 max_jumps 返回 false", controller.setup({"max_jumps": 0}) == false)
	_check("配置：非法值写入 last_errors", controller.last_errors.size() == 1)
	_check("配置：非法值发 definition_error", definition_errors.size() == 1)
	_check("配置：非法值不应用（上限仍为 2）", controller.get_state()["max_jumps"] == 2)

	_check("配置：非法 move_speed 返回 false", controller.setup({"move_speed": -1.0}) == false)
	_check("配置：非法 move_speed 被记录", controller.last_errors.size() == 1)

	_check("配置：负数 max_jumps 返回 false", controller.setup({"max_jumps": -1}) == false)
	_check("配置：负数 max_jumps 被记录", controller.last_errors.size() == 1)
	_check("配置：非整数 max_jumps 返回 false", controller.setup({"max_jumps": 2.5}) == false)
	_check("配置：非整数 max_jumps 被记录", controller.last_errors.size() == 1)

	_check("配置：合法配置返回 true", controller.setup({"max_jumps": 3, "move_speed": 2.0}) == true)
	_check("配置：合法配置生效", controller.get_state()["max_jumps"] == 3)
	_check("配置：合法配置清空 last_errors", controller.last_errors.is_empty())
	_check("配置：整数值的 float 也可接受", controller.setup({"max_jumps": 4.0}) == true)
	_check("配置：整数值的 float 生效", controller.get_state()["max_jumps"] == 4)
	_dispose(controller)


# --- 输入动作 -----------------------------------------------------------------

func _test_input_actions() -> void:
	_cleanup_player_actions()
	# 模拟一个已经存在的同名动作：本模块不能把它当成自己注册的，清理时也不能删。
	InputMap.add_action("player_move_forward")

	var controller := _new_controller()
	for action in ACTION_NAMES:
		_check("输入：运行时注册 %s" % action, InputMap.has_action(action))
	_check("输入：不改 project.godot 的 input 映射", ProjectSettings.get_setting("input/player_jump", null) == null)

	var has_space := false
	for event in InputMap.action_get_events("player_jump"):
		if event is InputEventKey and (event as InputEventKey).physical_keycode == KEY_SPACE:
			has_space = true
	_check("输入：跳跃动作绑定空格键", has_space)

	controller.unregister_input_actions()
	_check("输入：清理后移除本模块注册的动作", not InputMap.has_action("player_jump") and not InputMap.has_action("player_move_back"))
	_check("输入：清理时不删除预先存在的动作", InputMap.has_action("player_move_forward"))
	InputMap.erase_action("player_move_forward")
	_check("输入：清理输入动作不影响状态机", controller.get_state()["state"] == "idle")
	_dispose(controller)


# --- 可选 CharacterBody3D 挂接 -------------------------------------------------

func _test_attach_body() -> void:
	var controller := _new_controller()
	var body := CharacterBody3D.new()
	controller.attach_body(body)
	controller.tick(0.2, {"move": Vector2(0, -1)})
	var state: Dictionary = controller.get_state()
	_check("挂接：CharacterBody3D 位置与状态机同步", _vec_approx(body.position, state["position"]))
	_check("挂接：CharacterBody3D 朝向与状态机同步", abs(body.rotation.y - float(state["yaw"])) < EPS)

	controller.detach_body()
	var detached_at: Vector3 = body.position
	controller.tick(0.2, {"move": Vector2(1, 0)})
	_check("挂接：detach 后不再同步", _vec_approx(body.position, detached_at))

	body.free()
	_dispose(controller)
