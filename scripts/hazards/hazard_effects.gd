extends Node
## W5 过载危险效果（Issue #15）：摄像头过载后放出强光 / 短路 / 起火。
##
## 契约：trigger(kind, position)（flash / short / fire）、tick(delta)；
## 信号 hazard_started(kind, pos)、hazard_ended(kind, pos)。
##
## 设计：
## - 危险是「限时区域」：持续 duration 秒，期间在 radius 内阻挡敌人；
## - 到点在 tick 里结束并发 hazard_ended；没有自动恢复以外的隐藏状态；
## - 与 W1 只通过信号耦合：bind_overload_source() 订阅宿主传入对象的
##   overload_started(camera_id)，再用位置查询回调把机位 id 解析成坐标。
##   W1 的 overload_started 只带 camera_id，所以位置必须由宿主提供；
## - 配置错误按 W0 §0 写 last_errors + 发 definition_error，不抛错、不 push_warning；
## - 不新增 autoload，不用 _process。

const KIND_FLASH := "flash"
const KIND_SHORT := "short"
const KIND_FIRE := "fire"

## 默认值：既能挡住一次巡逻，又不会永久封锁房间。策划要调时走 configure()。
const DEFAULT_RULES := {
	KIND_FLASH: {"duration": 1.5, "radius": 3.0, "blocking": true},
	KIND_SHORT: {"duration": 3.0, "radius": 2.0, "blocking": true},
	KIND_FIRE: {"duration": 5.0, "radius": 2.5, "blocking": true},
}
const TIME_EPSILON := 0.000001

signal hazard_started(kind: String, position: Vector3)
signal hazard_ended(kind: String, position: Vector3)
signal definition_error(message: String)

## 配置错误（W0 §0）；configure 成功时清空。
var last_errors: Array[String] = []

## kind -> { "duration": float, "radius": float, "blocking": bool }
var _rules: Dictionary = DEFAULT_RULES.duplicate(true)
## 进行中的危险，按触发顺序保存：{ id, kind, position, remain, duration, radius, blocking }
var _active: Array[Dictionary] = []
var _next_id := 1

## W1 接线：overload_started → 位置查询 → trigger()。
var _overload_source: Object = null
var _overload_position_lookup: Callable
var _overload_kind := KIND_SHORT


## 触发一次危险。未知 kind 返回 false + push_warning（运行时非法调用，非配置错误）。
func trigger(kind: String, position: Vector3) -> bool:
	if not _rules.has(kind):
		push_warning("HazardEffects.trigger: 未知危险类型 %s" % kind)
		return false
	var rule: Dictionary = _rules[kind]
	var hazard := {
		"id": "%s#%d" % [kind, _next_id],
		"kind": kind,
		"position": position,
		"remain": float(rule["duration"]),
		"duration": float(rule["duration"]),
		"radius": float(rule["radius"]),
		"blocking": bool(rule["blocking"]),
	}
	_next_id += 1
	_active.append(hazard)
	hazard_started.emit(kind, position)
	return true


## 推进危险计时。到点的危险先改状态再发 hazard_ended，回调里查到的是一致的快照。
func tick(delta: float) -> void:
	if delta <= 0.0 or _active.is_empty():
		return
	var still_active: Array[Dictionary] = []
	var ended: Array[Dictionary] = []
	for entry in _active:
		var remain := float(entry["remain"]) - delta
		if remain <= TIME_EPSILON:
			ended.append(entry)
		else:
			entry["remain"] = remain
			still_active.append(entry)
	_active = still_active
	for entry in ended:
		var kind := String(entry["kind"])
		var position: Vector3 = entry["position"]
		hazard_ended.emit(kind, position)


## 该点是否被任意进行中的危险区域挡住（半径边界视为区域内）。
func is_blocking(position: Vector3) -> bool:
	for entry in _active:
		if not bool(entry["blocking"]):
			continue
		var center: Vector3 = entry["position"]
		if position.distance_to(center) <= float(entry["radius"]) + TIME_EPSILON:
			return true
	return false


## 该点上的危险 id 列表（EnemyPatrol.blocked_by_hazard 用；空 = 未被挡）。
func blocking_hazards_at(position: Vector3) -> Array[String]:
	var ids: Array[String] = []
	for entry in _active:
		if not bool(entry["blocking"]):
			continue
		var center: Vector3 = entry["position"]
		if position.distance_to(center) <= float(entry["radius"]) + TIME_EPSILON:
			ids.append(String(entry["id"]))
	return ids


## 清空进行中的危险（循环复位/新一局 demo 用）；不补发 hazard_ended，
## 宿主在复位后统一刷新 HUD/敌人状态。
func reset() -> void:
	_active.clear()


## 进行中的危险快照（含剩余时间），供宿主做特效/调试。
func get_active_hazards() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for entry in _active:
		result.append(entry.duplicate(true))
	return result


## 运行状态 + 当前规则。测试/UI 用，不暴露内部引用。
func get_state() -> Dictionary:
	return {
		"active": get_active_hazards(),
		"kinds": _rules.duplicate(true),
		"overload_kind": _overload_kind if _overload_source != null else "",
	}


## 覆盖式规则配置。形状：{ kind: {duration, radius, blocking} }，也接受 { "kinds": {...} }。
## 只改给出的字段；非法字段写 last_errors + 发 definition_error，保留上一个合法值。
func configure(config: Dictionary) -> void:
	last_errors.clear()
	var rules_value: Variant = config
	# 支持 { kind: {...} } 与 { "kinds": { kind: {...} } }；带 "kinds" 时顶层其它键忽略。
	if config.has("kinds"):
		rules_value = config["kinds"]
		if not rules_value is Dictionary:
			_report_error("HazardEffects.configure: kinds 必须是对象")
			return
	for raw_kind in (rules_value as Dictionary).keys():
		var kind := String(raw_kind)
		if not _rules.has(kind):
			_report_error("HazardEffects.configure: 未知危险类型 %s" % kind)
			continue
		var entry_value: Variant = (rules_value as Dictionary)[raw_kind]
		if not entry_value is Dictionary:
			_report_error("HazardEffects.configure: %s 的规则必须是对象" % kind)
			continue
		_apply_rule(kind, entry_value)


## 订阅 W1（或测试假会话）的 overload_started。
## position_lookup(camera_id) 必须返回 Vector3；返回 null/其它类型时该次过载不产生危险。
func bind_overload_source(source: Object, position_lookup: Callable,
		kind: String = KIND_SHORT) -> bool:
	if source == null or not source.has_signal("overload_started"):
		push_warning("HazardEffects.bind_overload_source: 对象没有 overload_started 信号")
		return false
	if not position_lookup.is_valid():
		push_warning("HazardEffects.bind_overload_source: position_lookup 无效")
		return false
	if not _rules.has(kind):
		push_warning("HazardEffects.bind_overload_source: 未知危险类型 %s" % kind)
		return false
	unbind_overload_source()
	_overload_source = source
	_overload_position_lookup = position_lookup
	_overload_kind = kind
	source.connect("overload_started", _on_overload_started)
	return true


func unbind_overload_source() -> void:
	if _overload_source != null and is_instance_valid(_overload_source):
		if _overload_source.is_connected("overload_started", _on_overload_started):
			_overload_source.disconnect("overload_started", _on_overload_started)
	_overload_source = null
	_overload_position_lookup = Callable()
	_overload_kind = KIND_SHORT


# --- 内部 ---------------------------------------------------------------------

func _on_overload_started(camera_id: String) -> void:
	if not _overload_position_lookup.is_valid():
		return
	var position_value: Variant = _overload_position_lookup.call(camera_id)
	if position_value is Vector3:
		trigger(_overload_kind, position_value)
	else:
		push_warning("HazardEffects: 机位 %s 没有可用位置，未触发危险" % camera_id)


func _apply_rule(kind: String, rule: Dictionary) -> void:
	for key in ["duration", "radius"]:
		if not rule.has(key):
			continue
		var value: Variant = rule[key]
		if typeof(value) != TYPE_FLOAT and typeof(value) != TYPE_INT:
			_report_error("HazardEffects.configure: %s.%s 必须是数字" % [kind, key])
			continue
		var number := float(value)
		if not is_finite(number):
			_report_error("HazardEffects.configure: %s.%s 必须是有限数" % [kind, key])
			continue
		if number < 0.0:
			_report_error("HazardEffects.configure: %s.%s 不能为负" % [kind, key])
			continue
		_rules[kind][key] = number
	if rule.has("blocking"):
		var blocking_value: Variant = rule["blocking"]
		if typeof(blocking_value) != TYPE_BOOL:
			_report_error("HazardEffects.configure: %s.blocking 必须是布尔值" % kind)
		else:
			_rules[kind]["blocking"] = bool(blocking_value)


func _report_error(message: String) -> void:
	last_errors.append(message)
	definition_error.emit(message)
