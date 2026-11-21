extends Node
## W5 敌人巡逻（Issue #15）：按 waypoint 循环移动 + 视锥看向移动方向。
##
## 契约：setup(waypoints, speed) / tick(delta) / sees(target) -> bool；
## 信号 spotted(target_id)、blocked_by_hazard(hazard_id)。
## 视锥形状按 docs/MECHANICS_CONTRACTS.md §8 由 VisionCone 提供（W7 也消费它）。
##
## 与危险效果（W5 HazardEffects）只通过鸭子类型接线：`set_hazard_source()` 接受
## 任意带 `blocking_hazards_at(position) -> Array[String]` 的对象，或直接的 Callable。
## 这样敌人模块不依赖危险模块，W12 可以把两者接起来，测试也能用假危险源。
##
## 约束：不用 `_process`，由宿主每帧 tick(delta)，固定步长可复现；
## 不新增 autoload；目标只认位置数据 + 可选 id，不依赖具体玩家节点类型。

const VisionConeScript := preload("res://scripts/enemy/vision_cone.gd")
const DEFAULT_HALF_ANGLE_DEG := 45.0
const DEFAULT_RANGE_M := 10.0
const TIME_EPSILON := 0.000001
## 重复 waypoint 理论上会让 while 原地打转；折叠后仍留一道保险。
const MAX_STEPS_PER_TICK := 1000
## 危险阻挡的路径采样步长：大 delta 时也不能一步跨进新出现的危险区。
const HAZARD_PROBE_STEP_M := 0.1
const MAX_HAZARD_PROBES := 256

signal spotted(target_id: String)
signal blocked_by_hazard(hazard_id: String)

## 巡逻路径（已折叠连续重复点；首尾重合时去掉尾部，因为循环本身会回到起点）。
var _waypoints: Array[Vector3] = []
var _speed := 0.0
var _position := Vector3.ZERO
var _direction := Vector3.ZERO
## 下一个要到达的 waypoint 下标；运动方向上它总是「前方」。
var _next_index := 0

var _vision_cone: Node
var _half_angle_deg := DEFAULT_HALF_ANGLE_DEG
var _range_m := DEFAULT_RANGE_M

## 危险源：Object（blocking_hazards_at）或 Callable（position -> Array/String）。
var _hazard_source: Variant = null
## 当前仍处于视野内的目标 id（用于 spotted 的边沿触发）。
var _visible_ids: Dictionary = {}
## 上一次 tick 时挡住自己的危险 id（用于 blocked_by_hazard 的边沿触发）。
var _blocked_ids: Array[String] = []


func _init() -> void:
	_vision_cone = VisionConeScript.new()
	add_child(_vision_cone)
	_refresh_cone_setup()


## 设置巡逻路径与速度。非法元素被忽略；没有有效 waypoint 时原地不动。
func setup(waypoints: Array, speed: float) -> void:
	_waypoints.clear()
	for waypoint in waypoints:
		if waypoint is Vector3:
			_append_waypoint(waypoint)
		else:
			push_warning("EnemyPatrol.setup: 非 Vector3 的 waypoint 已忽略")
	# 首尾重合的写法等价于闭环，循环巡逻本身会回到起点，去掉尾部避免双重停留。
	if _waypoints.size() > 1 and _waypoints[0].is_equal_approx(_waypoints[_waypoints.size() - 1]):
		_waypoints.pop_back()

	if _waypoints.is_empty():
		push_warning("EnemyPatrol.setup: 没有有效 waypoint，巡逻原地不动")
		_position = Vector3.ZERO
		_direction = Vector3.ZERO
		_next_index = 0
	else:
		_position = _waypoints[0]
		_next_index = 1 if _waypoints.size() > 1 else 0
		_direction = _initial_direction()

	_speed = speed
	if speed < 0.0:
		push_warning("EnemyPatrol.setup: 速度为负，按 0 处理")
		_speed = 0.0

	_visible_ids.clear()
	_blocked_ids.clear()
	_refresh_cone_setup()


## 推进巡逻。先判定危险阻挡：被挡住时只发信号、不移动（视锥仍照常判定）。
func tick(delta: float) -> void:
	if delta <= 0.0:
		return

	_update_blocking()
	if not _blocked_ids.is_empty():
		return
	if _waypoints.size() <= 1 or _speed <= 0.0:
		return

	var remaining := _speed * delta
	var steps := 0
	while remaining > TIME_EPSILON and steps < MAX_STEPS_PER_TICK:
		steps += 1
		var target := _waypoints[_next_index]
		var offset := target - _position
		var distance := offset.length()
		if distance <= TIME_EPSILON:
			_advance_waypoint()
			continue
		_direction = offset / distance
		var travel := minf(remaining, distance)
		# 先沿本段路径扫危险：不能因为一次 tick 位移很大就穿进危险区。
		var blocker := _first_blocker_on_path(_position, _direction, travel)
		if not blocker.is_empty():
			_position += _direction * float(blocker["distance"])
			_set_blocking_ids(blocker["ids"])
			return
		_position += _direction * travel
		remaining -= travel
		if travel >= distance - TIME_EPSILON:
			_position = target
			_advance_waypoint()
		if remaining <= TIME_EPSILON:
			break


## 目标是否在视锥内。target 支持 Vector3 / {id, position} / 带位置的对象；
## 带 id 的目标进入视野时发一次 spotted（离开后再次进入会重新发）。
func sees(target: Variant) -> bool:
	var point_value: Variant = _target_point(target)
	if not point_value is Vector3:
		push_warning("EnemyPatrol.sees: 目标没有可用的 Vector3 位置，按看不见处理")
		return false
	var seen: bool = _vision_cone.sees(point_value)
	var target_id := _target_id(target)
	if target_id.is_empty():
		return seen
	if seen:
		if not _visible_ids.has(target_id):
			_visible_ids[target_id] = true
			spotted.emit(target_id)
	else:
		_visible_ids.erase(target_id)
	return seen


## 调整视野。视锥仍由本模块持有，W12 不需要自己拼 getter。
func set_vision(half_angle_deg: float, range_m: float) -> void:
	_half_angle_deg = half_angle_deg
	_range_m = range_m
	_refresh_cone_setup()


## 站桩守卫用：显式指定朝向。移动巡逻每个 tick 会按路径重算朝向并覆盖它。
func set_facing(direction: Vector3) -> void:
	if direction.length_squared() <= TIME_EPSILON:
		_direction = Vector3.ZERO
	else:
		_direction = direction.normalized()


## 接线危险源：Object 需提供 blocking_hazards_at(position) -> Array；
## 也接受 Callable(position) -> Array/String（空 = 未被挡）。
## 换源会清空阻挡记录，下一次 tick 按新源重新发 blocked_by_hazard。
func set_hazard_source(source: Variant) -> void:
	_hazard_source = source
	_blocked_ids.clear()


func get_position() -> Vector3:
	return _position


func get_direction() -> Vector3:
	return _direction


## W7 的 StealthModel 需要锥体本身（它只消费 sees(point)）。
func get_vision_cone() -> Node:
	return _vision_cone


func get_state() -> Dictionary:
	return {
		"position": _position,
		"direction": _direction,
		"speed": _speed,
		"next_index": _next_index,
		"waypoint_count": _waypoints.size(),
		"waypoints": _waypoints.duplicate(),
		"vision": _vision_cone.get_debug_state(),
		"blocked_by": _blocked_ids.duplicate(),
		"spotted": _visible_ids.keys(),
	}


# --- 内部 ---------------------------------------------------------------------

func _append_waypoint(point: Vector3) -> void:
	if not _waypoints.is_empty() and _waypoints[_waypoints.size() - 1].is_equal_approx(point):
		return
	_waypoints.append(point)


func _initial_direction() -> Vector3:
	if _waypoints.size() <= 1:
		return Vector3.ZERO
	var offset := _waypoints[1] - _waypoints[0]
	if offset.length_squared() <= TIME_EPSILON:
		return Vector3.ZERO
	return offset.normalized()


func _advance_waypoint() -> void:
	_next_index = (_next_index + 1) % _waypoints.size()


func _refresh_cone_setup() -> void:
	_vision_cone.setup(
		func() -> Vector3: return _position,
		func() -> Vector3: return _direction,
		_half_angle_deg,
		_range_m
	)


func _update_blocking() -> void:
	_set_blocking_ids(_hazard_ids_at(_position))


## 记录当前挡住敌人的危险；同 tick 内重复 id 只算一次，边沿触发不重复发信号。
func _set_blocking_ids(ids: Array) -> void:
	var still_blocked: Array[String] = []
	for raw_id in ids:
		var hazard_id := String(raw_id)
		if still_blocked.has(hazard_id):
			continue
		if not _blocked_ids.has(hazard_id):
			blocked_by_hazard.emit(hazard_id)
		still_blocked.append(hazard_id)
	_blocked_ids = still_blocked


## 沿 origin → origin + direction * distance 采样，返回第一个被危险挡住的位置。
## 大 delta 时按 MAX_HAZARD_PROBES 自适应放大步长，保证采样次数有上限。
func _first_blocker_on_path(origin: Vector3, direction: Vector3, distance: float) -> Dictionary:
	if distance <= TIME_EPSILON:
		return {}
	var step := HAZARD_PROBE_STEP_M
	var probe_count := int(ceil(distance / step))
	if probe_count > MAX_HAZARD_PROBES:
		step = distance / float(MAX_HAZARD_PROBES)
	var travelled := 0.0
	while travelled < distance - TIME_EPSILON:
		travelled = minf(travelled + step, distance)
		var ids := _hazard_ids_at(origin + direction * travelled)
		if not ids.is_empty():
			return {"distance": travelled, "ids": ids}
	return {}


func _hazard_ids_at(position: Vector3) -> Array[String]:
	var ids: Array[String] = []
	if _hazard_source == null:
		return ids
	var raw: Variant = null
	if _hazard_source is Callable:
		var source_callable: Callable = _hazard_source
		if not source_callable.is_valid():
			return ids
		raw = source_callable.call(position)
	elif _hazard_source is Object:
		var source_object: Object = _hazard_source
		if source_object.has_method("blocking_hazards_at"):
			raw = source_object.call("blocking_hazards_at", position)
	if raw is Array:
		for item in raw:
			if typeof(item) == TYPE_STRING and not String(item).is_empty():
				ids.append(String(item))
	elif typeof(raw) == TYPE_STRING and not String(raw).is_empty():
		ids.append(String(raw))
	return ids


## 目标位置解析：Vector3 / Dictionary.position / 带 global_position 或 position 的对象。
func _target_point(target: Variant) -> Variant:
	if target is Vector3:
		return target
	if target is Dictionary:
		var data: Dictionary = target
		if data.has("position") and data["position"] is Vector3:
			return data["position"]
		return null
	if target is Object:
		var object: Object = target
		# 未入树的 Node3D 调 get_global_position() 会报错并返回原点，改用本地 position。
		var inside_tree := true
		if object is Node:
			inside_tree = (object as Node).is_inside_tree()
		if inside_tree:
			if object.has_method("get_global_position"):
				var global_value: Variant = object.call("get_global_position")
				if global_value is Vector3:
					return global_value
			var global_property: Variant = object.get("global_position")
			if global_property is Vector3:
				return global_property
		var property_value: Variant = object.get("position")
		if property_value is Vector3:
			return property_value
	return null


## 目标 id：Dictionary.id 或对象上的 id 属性；没有 id 时只回答可见性、不发 spotted。
func _target_id(target: Variant) -> String:
	var id_value: Variant = null
	if target is Dictionary:
		id_value = (target as Dictionary).get("id")
	elif target is Object:
		id_value = (target as Object).get("id")
	if typeof(id_value) == TYPE_STRING:
		return String(id_value)
	return ""
