extends Node
## W8 亲身段落（M14）+ 终章动作段落（M15，二段跳）的纯状态机。
##
## 设计约束（Issue #18）：
## - 不依赖物理帧：位置 / 朝向 / 重力都在 tick(delta, input) 里用固定 delta 推进，
##   headless 测试可直接驱动；需要真机演示时可选用 attach_body() 挂一个
##   CharacterBody3D 同步 transform，但测试不依赖它。
## - 输入动作在运行时用 InputMap.add_action 注册，**不写 project.godot**；
##   节点退出场景树时自动清理自己注册的动作。
## - M14 / M15 都可开关：enabled 关闭整个亲身段落，action_enabled 只关闭跳跃动作段。
##   设计决定（2026-11-21，#20）：M15 的二段跳**不保留**，action_enabled 默认 false；
##   组件保留为可选项，显式设置才启用。
## - 配置沿用 W0 约定：错误写 last_errors 并 emit definition_error，不返回半成品。

signal landed(position: Vector3)
signal jumped(jumps_used: int, jumps_left: int)
signal jump_rejected(jumps_left: int)
signal definition_error(message: String)

const JUMP_SECTION_SCRIPT := preload("res://scripts/player/jump_section.gd")

const STATE_DISABLED := "disabled"
const STATE_IDLE := "idle"
const STATE_MOVING := "moving"
const STATE_AIRBORNE := "airborne"
const STATE_LANDING := "landing"

const MOVE_DEADZONE := 0.1

## 运行时注册的输入动作；前缀 player_ 避免和既有动作冲突。
const INPUT_ACTIONS := {
	"player_move_forward": KEY_W,
	"player_move_back": KEY_S,
	"player_move_left": KEY_A,
	"player_move_right": KEY_D,
	"player_jump": KEY_SPACE,
}

var last_errors: Array[String] = []

var _enabled: bool = true
## 设计决定（2026-11-21，#20）：终章的二段跳动作段不保留 → 默认关闭。
## 组件仍保留为可选项：显式 setup({"action_enabled": true}) 才会启用跳跃。
var _action_enabled: bool = false
var _move_speed: float = 3.0
var _turn_speed: float = 8.0
var _gravity: float = 20.0
var _jump_velocity: float = 6.0
var _ground_y: float = 0.0

var _position := Vector3.ZERO
var _velocity := Vector3.ZERO
var _yaw := 0.0
var _state: String = STATE_IDLE
var _airborne := false
var _jump_prev := false

var _body: CharacterBody3D = null
var _added_actions: Array[String] = []
var _jump_section: RefCounted = JUMP_SECTION_SCRIPT.new()


func _exit_tree() -> void:
	unregister_input_actions()


## 应用配置并回到初始姿态。未知字段忽略（向前兼容）；非法值整体拒绝。
func setup(config: Dictionary = {}) -> bool:
	last_errors.clear()
	var candidate := {
		"enabled": _enabled,
		"action_enabled": _action_enabled,
		"move_speed": _move_speed,
		"turn_speed": _turn_speed,
		"gravity": _gravity,
		"jump_velocity": _jump_velocity,
		"ground_y": _ground_y,
	}
	var errors: Array[String] = []

	_validate_bool(config, "enabled", candidate, errors)
	_validate_bool(config, "action_enabled", candidate, errors)
	_validate_positive_number(config, "move_speed", candidate, errors)
	_validate_positive_number(config, "turn_speed", candidate, errors)
	_validate_positive_number(config, "gravity", candidate, errors)
	_validate_positive_number(config, "jump_velocity", candidate, errors)
	_validate_finite_number(config, "ground_y", candidate, errors)

	var jump_count: int = _jump_section.get_max_jumps()
	if config.has("max_jumps"):
		var raw: Variant = config["max_jumps"]
		var parsed := 0
		var parsed_ok := false
		if raw is int:
			parsed = int(raw)
			parsed_ok = true
		elif raw is float and is_equal_approx(float(raw), roundf(float(raw))):
			parsed = int(roundf(float(raw)))
			parsed_ok = true
		else:
			errors.append("max_jumps 必须是整数")
		if parsed_ok:
			if JUMP_SECTION_SCRIPT.is_valid_max_jumps(parsed):
				jump_count = parsed
			else:
				errors.append("max_jumps 超出范围 %d..%d" % [JUMP_SECTION_SCRIPT.MIN_JUMPS, JUMP_SECTION_SCRIPT.MAX_JUMPS])

	if not errors.is_empty():
		last_errors.append_array(errors)
		definition_error.emit("PlayerController 配置无效: %s" % last_errors[0])
		return false

	_enabled = bool(candidate["enabled"])
	_action_enabled = bool(candidate["action_enabled"])
	_move_speed = float(candidate["move_speed"])
	_turn_speed = float(candidate["turn_speed"])
	_gravity = float(candidate["gravity"])
	_jump_velocity = float(candidate["jump_velocity"])
	_ground_y = float(candidate["ground_y"])
	_jump_section.set_max_jumps(jump_count)
	_reset_pose()
	register_input_actions()
	return true


## 推进一帧。input 支持：
## - "move": Vector2（x=+X 东，y=+Z 南）或 Vector3（取 x/z）；
## - "jump": bool，只在按下的上升沿触发一次。
## 宿主应使用固定小步长（例如 1/60）；单帧 delta 大于一次跳跃滞空时间时，
## 起跳和落地会落在同一帧（状态机仍自洽，但手感/动画需要更细的步长）。
func tick(delta: float, input: Dictionary = {}) -> void:
	if delta <= 0.0 or not is_finite(delta):
		return

	if not _enabled:
		_velocity = Vector3.ZERO
		_state = STATE_DISABLED
		return

	# landing 只是落地那一帧的过渡态，下一帧回到 idle/moving。
	if _state == STATE_LANDING:
		_state = STATE_IDLE

	var jump_down := _read_jump(input)
	var jump_pressed := jump_down and not _jump_prev
	_jump_prev = jump_down
	if jump_pressed and _action_enabled:
		if _jump_section.try_jump():
			_velocity.y = _jump_velocity
			_airborne = true
			_state = STATE_AIRBORNE
			jumped.emit(_jump_section.get_jumps_used(), _jump_section.get_jumps_left())
		else:
			jump_rejected.emit(_jump_section.get_jumps_left())

	var move := _read_move(input)
	if move.length() > MOVE_DEADZONE:
		var direction := Vector3(move.x, 0.0, move.y).normalized()
		_turn_toward(atan2(-direction.x, -direction.z), delta)
		_velocity.x = direction.x * _move_speed
		_velocity.z = direction.z * _move_speed
		if not _airborne:
			_state = STATE_MOVING
	else:
		_velocity.x = 0.0
		_velocity.z = 0.0
		if not _airborne:
			_state = STATE_IDLE

	var landed_this_tick := false
	if _airborne:
		_velocity.y -= _gravity * delta
		_position.y += _velocity.y * delta
		if _position.y <= _ground_y and _velocity.y <= 0.0:
			_position.y = _ground_y
			_velocity.y = 0.0
			_airborne = false
			_jump_section.on_landed()
			_state = STATE_LANDING
			landed_this_tick = true
		else:
			_state = STATE_AIRBORNE
	else:
		_position.y = _ground_y

	_position.x += _velocity.x * delta
	_position.z += _velocity.z * delta
	_sync_body()
	# 水平积分之后再发信号，保证监听者拿到的位置与本帧 get_state() 一致。
	if landed_this_tick:
		landed.emit(_position)


func get_state() -> Dictionary:
	return {
		"state": _state,
		"position": _position,
		"velocity": _velocity,
		"yaw": _yaw,
		"grounded": not _airborne,
		"jumps_used": _jump_section.get_jumps_used(),
		"jumps_left": _jump_section.get_jumps_left(),
		"max_jumps": _jump_section.get_max_jumps(),
		"enabled": _enabled,
		"action_enabled": _action_enabled,
	}


## 回到出生点并清空跳跃预算（循环回溯用）。
func reset() -> void:
	_reset_pose()


func set_enabled(value: bool) -> void:
	_enabled = value
	if not _enabled:
		_velocity = Vector3.ZERO
		_state = STATE_DISABLED
	else:
		_state = STATE_AIRBORNE if _airborne else STATE_IDLE


func is_enabled() -> bool:
	return _enabled


func set_action_enabled(value: bool) -> void:
	_action_enabled = value


func is_action_enabled() -> bool:
	return _action_enabled


## 可选：把状态机同步到一个 CharacterBody3D 上做真机演示。
## 只同步 transform，不调用 move_and_slide，也不参与物理计算。
func attach_body(body: CharacterBody3D) -> void:
	_body = body
	_sync_body()


func detach_body() -> void:
	_body = null


## 注册本模块需要的输入动作；已存在的同名动作保持不动，也不计入清理列表。
## 输入动作是进程级全局状态，单进程只应有一个 PlayerController；
## 多实例场景请由宿主统一注册/清理，避免先创建的实例删掉共享动作。
func register_input_actions() -> void:
	for action in INPUT_ACTIONS.keys():
		if InputMap.has_action(action):
			continue
		InputMap.add_action(action, 0.2)
		var event := InputEventKey.new()
		event.physical_keycode = INPUT_ACTIONS[action]
		InputMap.action_add_event(action, event)
		_added_actions.append(action)


## 只清理本模块注册的动作（不会删宿主/其它模块预先存在的动作）。
func unregister_input_actions() -> void:
	for action in _added_actions:
		if InputMap.has_action(action):
			InputMap.erase_action(action)
	_added_actions.clear()


# --- 内部 ---------------------------------------------------------------------

func _reset_pose() -> void:
	_position = Vector3(0.0, _ground_y, 0.0)
	_velocity = Vector3.ZERO
	_yaw = 0.0
	_airborne = false
	_jump_prev = false
	_jump_section.reset()
	_state = STATE_DISABLED if not _enabled else STATE_IDLE
	_sync_body()


func _read_move(input: Dictionary) -> Vector2:
	var value: Variant = input.get("move", Vector2.ZERO)
	var move := Vector2.ZERO
	if value is Vector2:
		move = value
	elif value is Vector3:
		move = Vector2(value.x, value.z)
	if move.length() > 1.0:
		move = move.normalized()
	return move


func _read_jump(input: Dictionary) -> bool:
	var value: Variant = input.get("jump", false)
	if value is bool:
		return value
	if value is int:
		return value != 0
	return false


func _turn_toward(target_yaw: float, delta: float) -> void:
	var difference := wrapf(target_yaw - _yaw, -PI, PI)
	var step := _turn_speed * delta
	_yaw = wrapf(_yaw + clampf(difference, -step, step), -PI, PI)


func _sync_body() -> void:
	if _body == null or not is_instance_valid(_body):
		return
	_body.position = _position
	_body.rotation.y = _yaw


func _validate_bool(config: Dictionary, key: String, candidate: Dictionary, errors: Array[String]) -> void:
	if not config.has(key):
		return
	var value: Variant = config[key]
	if value is bool:
		candidate[key] = value
	else:
		errors.append("%s 必须是 bool" % key)


func _validate_positive_number(config: Dictionary, key: String, candidate: Dictionary, errors: Array[String]) -> void:
	if not config.has(key):
		return
	var value: Variant = config[key]
	if not (value is int or value is float):
		errors.append("%s 必须是数字" % key)
		return
	var number := float(value)
	if not is_finite(number) or number <= 0.0:
		errors.append("%s 必须是大于 0 的有限数字" % key)
		return
	candidate[key] = number


func _validate_finite_number(config: Dictionary, key: String, candidate: Dictionary, errors: Array[String]) -> void:
	if not config.has(key):
		return
	var value: Variant = config[key]
	if not (value is int or value is float):
		errors.append("%s 必须是数字" % key)
		return
	var number := float(value)
	if not is_finite(number):
		errors.append("%s 必须是有限数字" % key)
		return
	candidate[key] = number
