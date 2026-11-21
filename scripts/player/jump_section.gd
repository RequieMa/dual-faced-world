extends RefCounted
## 跳跃预算状态机（W8 / M15「终章动作段落」的可开关实现）。
##
## 只负责「还能跳几次」这一件事，不接触物理：PlayerController 负责重力与落地判定，
## 落地后调用 on_landed() 重置预算。这样 headless 测试不需要物理帧。
##
## 契约（Issue #18）：set_max_jumps(n)、try_jump()、on_landed()；
## 默认二段跳，越界（不在 MIN_JUMPS..MAX_JUMPS）拒绝并保持原值。

signal jumped(jumps_used: int, jumps_left: int)
signal jump_rejected(jumps_left: int)
signal landed()

const DEFAULT_MAX_JUMPS := 2
const MIN_JUMPS := 1
const MAX_JUMPS := 8

var _max_jumps: int = DEFAULT_MAX_JUMPS
var _jumps_used: int = 0
var _grounded: bool = true


## 次数是否在上限允许范围内（供宿主/配置层复用，避免重复硬编码边界）。
static func is_valid_max_jumps(count: int) -> bool:
	return count >= MIN_JUMPS and count <= MAX_JUMPS


## 设置跳跃次数上限。越界返回 false，不修改当前值。
func set_max_jumps(count: int) -> bool:
	if not is_valid_max_jumps(count):
		push_warning("JumpSection: 跳跃次数必须在 %d..%d 之间，收到 %d" % [MIN_JUMPS, MAX_JUMPS, count])
		return false
	_max_jumps = count
	if _jumps_used > _max_jumps:
		_jumps_used = _max_jumps
	return true


func get_max_jumps() -> int:
	return _max_jumps


## 尝试消耗一次跳跃预算。成功返回 true；预算用尽返回 false（状态不变）。
func try_jump() -> bool:
	if _jumps_used >= _max_jumps:
		jump_rejected.emit(get_jumps_left())
		return false
	_jumps_used += 1
	_grounded = false
	jumped.emit(_jumps_used, get_jumps_left())
	return true


## 落地：重置预算。重复调用是幂等的，只有从空中落地时才发 landed。
func on_landed() -> void:
	var was_airborne := not _grounded
	_jumps_used = 0
	_grounded = true
	if was_airborne:
		landed.emit()


func is_grounded() -> bool:
	return _grounded


func get_jumps_used() -> int:
	return _jumps_used


func get_jumps_left() -> int:
	return _max_jumps - _jumps_used


## 回到初始状态（不改变上限）。
func reset() -> void:
	_jumps_used = 0
	_grounded = true


func get_state() -> Dictionary:
	return {
		"max_jumps": _max_jumps,
		"jumps_used": _jumps_used,
		"jumps_left": get_jumps_left(),
		"grounded": _grounded,
	}
