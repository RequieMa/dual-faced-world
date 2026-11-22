extends Node
## 摄像头会话状态机（W1）：停留计时 → 过载 → 烧毁；离开 → 冷却。
##
## 设计约束（docs/MECHANICS_CONTRACTS.md §1）：
## - 不使用 `_process`：宿主每帧调用 `tick(delta)`，固定步长可在 headless 下复现；
## - 所有时长来自 `configure()`，代码里的 6.0 / 4.0 只是「配置缺省时」的兜底值；
## - 过载结束的默认策略是永久烧毁（M16 拍板前不改契约）；
## - 不做画面：监控墙 / 相机仍由现有 MonitorGrid 负责。
##
## 状态不变量：`current` 非空时该机位一定已配置、未烧毁、且不在冷却中；
## `burned` 与 `cooldowns` 互斥；`remain` 只在 `current` 非空时有意义。
##
## 信号只表达「状态变化」：enter() 因冷却 / 烧毁 / 未知机位被拒绝时
## 不改变状态，也不补发信号（避免宿主在回调里重试 enter 造成递归）。

const DEFAULT_DWELL := 6.0
const DEFAULT_COOLDOWN := 4.0
## 固定步长累计会留下 1e-17 量级的浮点残差；到点判定要给一点余量。
const TIME_EPSILON := 0.000001

signal overload_started(camera_id: String)
signal overload_finished(camera_id: String)
signal burned(camera_id: String)
signal cooldown_changed(camera_id: String, remain: float)

## 机位 id -> { "dwell": float, "cooldown": float }
var _cameras: Dictionary = {}
var _current: String = ""
var _remain: float = 0.0
## 机位 id -> 剩余冷却秒数（> 0 才存在）。
var _cooldowns: Dictionary = {}
## 永久失效的机位 id（顺序稳定，便于存档 diff）。
var _burned: Array = []
var _overload_count: int = 0


## 覆盖式配置。调用后运行时状态重置为初始值（存档请随后 from_dict）。
## 重配不广播信号：宿主需要重新读取 get_state() 刷新冷却 / 烧毁 UI。
## config 形状：{ "cameras": { "C1": {"dwell": 6.0, "cooldown": 4.0}, ... } }
func configure(config: Dictionary) -> void:
	_cameras.clear()
	_current = ""
	_remain = 0.0
	_cooldowns.clear()
	_burned.clear()
	_overload_count = 0

	var cameras: Variant = config.get("cameras")
	if not cameras is Dictionary:
		push_warning("CameraSession.configure: 缺少 cameras 字典，未配置任何机位")
		return
	for raw_id in (cameras as Dictionary).keys():
		var camera_id := String(raw_id)
		var entry: Variant = (cameras as Dictionary)[raw_id]
		if not entry is Dictionary:
			push_warning("CameraSession.configure: 机位 %s 的配置不是对象，已忽略" % camera_id)
			continue
		var timing: Dictionary = entry
		_cameras[camera_id] = {
			"dwell": _read_duration(timing, "dwell", DEFAULT_DWELL, camera_id),
			"cooldown": _read_duration(timing, "cooldown", DEFAULT_COOLDOWN, camera_id),
		}


## 进入某机位。冷却中 / 已烧毁 / 未配置返回 false，且不改变当前机位。
## 从另一个机位直接切过来时，旧机位按 leave 规则进入冷却。
func enter(camera_id: String) -> bool:
	if not _cameras.has(camera_id):
		push_warning("CameraSession.enter: 未配置的机位 %s" % camera_id)
		return false
	if is_burned(camera_id):
		push_warning("CameraSession.enter: 机位 %s 已烧毁" % camera_id)
		return false
	if _cooldowns.has(camera_id):
		# 拒绝不改状态：不补发 cooldown_changed。若在回调里重试 enter()，
		# 「不变也发」会无限递归；冷却剩余量由 tick() 的变化广播。
		return false
	if _current == camera_id:
		return true
	if not _current.is_empty():
		leave(_current)
	_current = camera_id
	_remain = float((_cameras[camera_id] as Dictionary)["dwell"])
	return true


## 离开当前机位并开始冷却；未进入该机位时无副作用。
func leave(camera_id: String) -> void:
	if _current != camera_id:
		return
	_current = ""
	_remain = 0.0
	var cooldown := float((_cameras[camera_id] as Dictionary)["cooldown"])
	if cooldown > 0.0:
		_cooldowns[camera_id] = cooldown
		cooldown_changed.emit(camera_id, cooldown)


## 推进停留 / 冷却计时。由宿主每帧调用（不要用 _process），负值忽略。
func tick(delta: float) -> void:
	if delta <= 0.0:
		return

	if not _current.is_empty():
		_remain -= delta
		if _remain <= TIME_EPSILON:
			_overload(_current)

	if _cooldowns.is_empty():
		return
	# keys() 返回副本，回调里即使改状态也不会破坏遍历。
	for raw_id in _cooldowns.keys():
		var camera_id := String(raw_id)
		var remain := float(_cooldowns[raw_id]) - delta
		if remain <= TIME_EPSILON:
			_cooldowns.erase(raw_id)
			cooldown_changed.emit(camera_id, 0.0)
		else:
			_cooldowns[raw_id] = remain
			cooldown_changed.emit(camera_id, remain)


## 清空运行时状态（配置保留）。用于“新开一局 demo”重玩；
## 循环重开（restart_round）不要调用，M16 要求同一次运行内烧毁不恢复。
func reset() -> void:
	_current = ""
	_remain = 0.0
	_cooldowns.clear()
	_burned.clear()
	_overload_count = 0


## 运行时状态快照（W0 §1 契约字段 + Issue #11 要求的 overload_count）。
func get_state() -> Dictionary:
	return {
		"current": _current,
		"remain": _remain,
		"cooldowns": _cooldowns.duplicate(true),
		"burned": _burned.duplicate(),
		"overload_count": _overload_count,
	}


func is_burned(camera_id: String) -> bool:
	return _burned.has(camera_id)


## 存档快照：只含运行时状态，配置仍以 surveillance.json 为权威来源。
func to_dict() -> Dictionary:
	return {
		"current": _current,
		"remain": _remain,
		"cooldowns": _cooldowns.duplicate(true),
		"burned": _burned.duplicate(),
		"overload_count": _overload_count,
	}


## 从存档恢复。先回到默认状态，再逐字段覆盖；缺失字段保持默认值，
## 类型不符的字段忽略并 push_warning（W0 §0），不抛错。
func from_dict(data: Dictionary) -> void:
	_current = ""
	_remain = 0.0
	_cooldowns.clear()
	_burned.clear()
	_overload_count = 0

	if data.has("current"):
		var current_value: Variant = data["current"]
		if typeof(current_value) == TYPE_STRING:
			var current_id := String(current_value)
			if not current_id.is_empty():
				if not _cameras.has(current_id):
					push_warning("CameraSession.from_dict: 未配置的 current=%s，已忽略" % current_id)
				else:
					_current = current_id
		else:
			push_warning("CameraSession.from_dict: current 类型不符，已忽略")

	if data.has("remain"):
		var remain_value: Variant = data["remain"]
		if typeof(remain_value) == TYPE_FLOAT or typeof(remain_value) == TYPE_INT:
			if float(remain_value) < 0.0:
				# 负数视为损坏数据：按「缺失 remain」处理，回满额而不是立刻过载。
				push_warning("CameraSession.from_dict: remain 为负，按缺失处理")
				if not _current.is_empty():
					_remain = float((_cameras[_current] as Dictionary)["dwell"])
			elif not _current.is_empty():
				var dwell := float((_cameras[_current] as Dictionary)["dwell"])
				_remain = float(remain_value)
				if _remain > dwell:
					push_warning("CameraSession.from_dict: remain 超过 dwell，已收敛到 %.1f" % dwell)
					_remain = dwell
			# current 为空时 remain 无意义，保持默认 0。
		else:
			push_warning("CameraSession.from_dict: remain 类型不符，已忽略")
	elif not _current.is_empty():
		# 缺失 remain 但 current 有效：回到该机位的满额停留。
		_remain = float((_cameras[_current] as Dictionary)["dwell"])

	if data.has("cooldowns"):
		var cooldowns_value: Variant = data["cooldowns"]
		if cooldowns_value is Dictionary:
			for raw_id in (cooldowns_value as Dictionary).keys():
				var camera_id := String(raw_id)
				if not _cameras.has(camera_id):
					push_warning("CameraSession.from_dict: 冷却中的未配置机位 %s，已忽略" % camera_id)
					continue
				var cooldown_value: Variant = (cooldowns_value as Dictionary)[raw_id]
				if typeof(cooldown_value) != TYPE_FLOAT and typeof(cooldown_value) != TYPE_INT:
					push_warning("CameraSession.from_dict: %s 的冷却类型不符，已忽略" % camera_id)
					continue
				if float(cooldown_value) <= 0.0:
					push_warning("CameraSession.from_dict: %s 的冷却不是正数，已忽略" % camera_id)
					continue
				var configured_cooldown := float((_cameras[camera_id] as Dictionary)["cooldown"])
				if configured_cooldown <= 0.0:
					push_warning("CameraSession.from_dict: %s 配置的 cooldown 为 0，忽略存档冷却" % camera_id)
					continue
				if float(cooldown_value) > configured_cooldown:
					push_warning("CameraSession.from_dict: %s 的冷却超过配置值，已收敛" % camera_id)
					_cooldowns[camera_id] = configured_cooldown
				else:
					_cooldowns[camera_id] = float(cooldown_value)
		else:
			push_warning("CameraSession.from_dict: cooldowns 类型不符，已忽略")

	if data.has("burned"):
		var burned_value: Variant = data["burned"]
		if burned_value is Array:
			var valid := true
			for raw_id in burned_value:
				if typeof(raw_id) != TYPE_STRING:
					valid = false
					break
			if valid:
				for raw_id in burned_value:
					var camera_id := String(raw_id)
					if not _cameras.has(camera_id):
						push_warning("CameraSession.from_dict: 未配置的烧毁机位 %s，已忽略" % camera_id)
						continue
					if not _burned.has(camera_id):
						_burned.append(camera_id)
			else:
				push_warning("CameraSession.from_dict: burned 含非字符串元素，整个字段已忽略")
		else:
			push_warning("CameraSession.from_dict: burned 类型不符，已忽略")

	if data.has("overload_count"):
		var count := _read_int(data["overload_count"])
		if count >= 0:
			_overload_count = count
		else:
			push_warning("CameraSession.from_dict: overload_count 类型不符，已忽略")

	# 收敛不变量：烧毁机位不能同时是 current 或处于冷却。
	if not _current.is_empty() and _burned.has(_current):
		push_warning("CameraSession.from_dict: current=%s 已烧毁，已清空" % _current)
		_current = ""
		_remain = 0.0
	if not _current.is_empty() and _cooldowns.has(_current):
		push_warning("CameraSession.from_dict: current=%s 与冷却冲突，已移除冷却" % _current)
		_cooldowns.erase(_current)
	for raw_id in _cooldowns.keys():
		if _burned.has(String(raw_id)):
			_cooldowns.erase(raw_id)
	# remain 只在有 current 时有意义；current 被丢弃时一并归零。
	if _current.is_empty():
		_remain = 0.0


# --- 内部 ---------------------------------------------------------------------

func _overload(camera_id: String) -> void:
	# 先落状态再发信号：overload_started 的回调里如果重入 enter()，
	# 看到的必须是「已烧毁」，否则会破坏 current/burned 互斥的不变量。
	_current = ""
	_remain = 0.0
	_overload_count += 1
	if not _burned.has(camera_id):
		_burned.append(camera_id)
	overload_started.emit(camera_id)
	burned.emit(camera_id)
	# 默认策略（M16 拍板前）：过载 = 永久烧毁，所以过载在上一步就结束了。
	overload_finished.emit(camera_id)


func _read_duration(entry: Dictionary, key: String, fallback: float, camera_id: String) -> float:
	if not entry.has(key):
		push_warning("CameraSession.configure: 机位 %s 缺少 %s，使用默认 %.1f"
			% [camera_id, key, fallback])
		return fallback
	var value: Variant = entry[key]
	if typeof(value) != TYPE_FLOAT and typeof(value) != TYPE_INT:
		push_warning("CameraSession.configure: 机位 %s 的 %s 不是数字，使用默认 %.1f"
			% [camera_id, key, fallback])
		return fallback
	if float(value) < 0.0:
		push_warning("CameraSession.configure: 机位 %s 的 %s 为负，使用默认 %.1f"
			% [camera_id, key, fallback])
		return fallback
	return float(value)


func _read_int(value: Variant) -> int:
	if typeof(value) == TYPE_INT:
		return int(value) if int(value) >= 0 else -1
	if typeof(value) == TYPE_FLOAT and is_equal_approx(value, roundf(value)):
		var rounded := int(roundf(value))
		return rounded if rounded >= 0 else -1
	return -1
