extends Node3D
## GuideableNpc：可被玩家「引导」的 NPC 状态机（W2）。
##
## 契约见 docs/MECHANICS_CONTRACTS.md §2：
##   setup(id, group) / on_hint(text) / tick(delta) / get_state() / to_dict() / from_dict()
##   enum State { IDLE, WAIT, FOLLOW, OPEN_DOOR }
##   signal arrived(npc_id) / needs_hint(npc_id, hint)
##
## 不依赖物理引擎：位置沿 route 里的 waypoint 做线性插值，由宿主每帧调 tick(delta)。
## 提示词用语义命令（follow / wait / open_door，含中文别名），不写死剧情；
## real / imaginary 两组人共用同一个状态机，行为完全一致。
##
## 本流的独占 glob 不含 scripts/person/person_group.gd（W0 契约 §4 的归属文件），
## 因此这里内置一份等价的 normalize_group()：friend -> imaginary、stranger -> real、
## 未知值 -> real + push_warning。等 PersonGroup 落地后由 W12 装配时替换调用即可。

enum State { IDLE, WAIT, FOLLOW, OPEN_DOOR }

signal arrived(npc_id: String)
signal needs_hint(npc_id: String, hint: String)

const GROUP_REAL := "real"
const GROUP_IMAGINARY := "imaginary"

const HINT_FOLLOW := "follow"
const HINT_WAIT := "wait"
const HINT_OPEN_DOOR := "open_door"

const DEFAULT_SPEED := 2.0
## 判定「到达路点」的距离阈值，避免浮点误差导致最后一小步永远走不完。
const ARRIVE_EPSILON := 0.0001

## 提示词 -> 目标状态。键统一按小写比较；未知提示返回 false 并发 needs_hint。
const HINT_ALIASES := {
	"follow": State.FOLLOW,
	"跟我来": State.FOLLOW,
	"过来": State.FOLLOW,
	"wait": State.WAIT,
	"wait_here": State.WAIT,
	"等待": State.WAIT,
	"等一下": State.WAIT,
	"open_door": State.OPEN_DOOR,
	"开门": State.OPEN_DOOR,
}

@export var npc_id: String = ""
@export var group: String = GROUP_REAL
## Array[Vector3]；用无类型 Array 是为了场景文件里直接写 [Vector3(...), ...]。
@export var route: Array = []
@export var speed: float = DEFAULT_SPEED
@export var show_visual: bool = true

var state: State = State.IDLE

var _waypoint_index := 0
var _last_hint := ""
var _arrived_emitted := false
var _door_target: Node = null
var _body: MeshInstance3D = null
var _body_material: StandardMaterial3D = null
var _name_label: Label3D = null


func _ready() -> void:
	_build_visual()
	_refresh_visual()


# --- 公开接口（W0 契约） -------------------------------------------------------

## 设置身份与组别；group 会归一化成 real / imaginary。
func setup(id: String, group_name: String) -> void:
	npc_id = id
	group = normalize_group(group_name)
	state = State.IDLE
	_waypoint_index = 0
	_last_hint = ""
	_arrived_emitted = false
	_refresh_visual()


## GuideBus 自动注册用的统一目标 id。
func get_target_id() -> String:
	return npc_id


## 配置 waypoint 路径（逻辑位置，不是物理刚体）。非法条目跳过并告警。
func set_route(points: Array) -> void:
	route.clear()
	for entry in points:
		if entry is Vector3:
			route.append(entry)
		else:
			push_warning("GuideableNpc: route 里出现非 Vector3 条目，已忽略: %s" % str(entry))


func set_speed(value: float) -> void:
	if value > 0.0 and is_finite(value):
		speed = value
	else:
		push_warning("GuideableNpc: 非法速度 %s，保持 %s" % [str(value), str(speed)])


## OPEN_DOOR 到达终点后要打开的门；不设置也能完成动作（只是没有门可开）。
func set_door_target(node: Node) -> void:
	_door_target = node


## 接受一条引导提示。未知提示 / 没有可走路径时返回 false 并发 needs_hint。
func on_hint(text: String) -> bool:
	var hint := text.strip_edges()
	if hint.is_empty():
		_request_hint()
		return false
	var key := hint.to_lower()
	if not HINT_ALIASES.has(key):
		_request_hint()
		return false

	var target_state: int = HINT_ALIASES[key]
	if target_state == State.FOLLOW:
		if route.is_empty():
			_request_hint()
			return false
		if state != State.FOLLOW:
			_start_moving(State.FOLLOW)
	elif target_state == State.OPEN_DOOR:
		if route.is_empty():
			_request_hint()
			return false
		if state != State.OPEN_DOOR:
			_start_moving(State.OPEN_DOOR)
	else:
		if state != State.WAIT:
			state = State.WAIT
			_arrived_emitted = false

	_last_hint = hint
	return true


## 由宿主每帧调用；只有 FOLLOW / OPEN_DOOR 会移动。
func tick(delta: float) -> void:
	if delta <= 0.0 or not is_finite(delta):
		return
	if state != State.FOLLOW and state != State.OPEN_DOOR:
		return
	if route.is_empty():
		state = State.WAIT
		_waypoint_index = 0
		_request_hint()
		return
	if speed <= 0.0:
		return

	var remaining := speed * delta
	while remaining > 0.0 and _waypoint_index < route.size():
		var target: Vector3 = route[_waypoint_index]
		var offset := target - position
		var distance := offset.length()
		if distance <= ARRIVE_EPSILON:
			position = target
			_waypoint_index += 1
			continue
		var step := minf(remaining, distance)
		position += (offset / distance) * step
		remaining -= step
		if distance - step <= ARRIVE_EPSILON:
			position = target
			_waypoint_index += 1

	if _waypoint_index >= route.size():
		_finish_route()


func get_state() -> Dictionary:
	return {
		"id": npc_id,
		"group": group,
		"state": String(State.keys()[state]),
		"state_value": int(state),
		"position": position,
		"waypoint_index": _waypoint_index,
		"route_size": route.size(),
		"speed": speed,
		"last_hint": _last_hint,
	}


## 供 W6 循环重置 / 存档使用：missing 字段保持当前值，类型不符忽略并告警。
func to_dict() -> Dictionary:
	var route_data: Array = []
	for point in route:
		var value: Vector3 = point
		route_data.append([value.x, value.y, value.z])
	return {
		"id": npc_id,
		"group": group,
		"state": int(state),
		"state_name": String(State.keys()[state]),
		"position": [position.x, position.y, position.z],
		"waypoint_index": _waypoint_index,
		"speed": speed,
		"last_hint": _last_hint,
		"route": route_data,
		"arrived_emitted": _arrived_emitted,
	}


func from_dict(data: Dictionary) -> void:
	if not data is Dictionary:
		push_warning("GuideableNpc: from_dict 需要 Dictionary，已忽略")
		return
	if data.has("id"):
		var id_value = data["id"]
		if id_value is String:
			npc_id = id_value
		else:
			push_warning("GuideableNpc: from_dict 的 id 类型不符，已忽略")
	if data.has("group"):
		var group_value = data["group"]
		if group_value is String:
			group = normalize_group(group_value)
		else:
			push_warning("GuideableNpc: from_dict 的 group 类型不符，已忽略")
	if data.has("state"):
		var state_value = data["state"]
		if (state_value is int or state_value is float) \
				and int(state_value) >= 0 and int(state_value) < State.size():
			state = int(state_value)
		else:
			push_warning("GuideableNpc: from_dict 的 state 非法，已忽略")
	if data.has("position"):
		var position_value = data["position"]
		if _is_number_array(position_value, 3):
			position = Vector3(
				float(position_value[0]),
				float(position_value[1]),
				float(position_value[2]))
		else:
			push_warning("GuideableNpc: from_dict 的 position 非法，已忽略")
	if data.has("route"):
		var route_value = data["route"]
		if route_value is Array:
			_restore_route(route_value)
		else:
			push_warning("GuideableNpc: from_dict 的 route 非法，已忽略")
	if data.has("waypoint_index"):
		var index_value = data["waypoint_index"]
		if (index_value is int or index_value is float) and int(index_value) >= 0:
			_waypoint_index = mini(int(index_value), route.size())
		else:
			push_warning("GuideableNpc: from_dict 的 waypoint_index 非法，已忽略")
	if data.has("speed"):
		var speed_value = data["speed"]
		if (speed_value is int or speed_value is float) and float(speed_value) > 0.0:
			speed = float(speed_value)
		else:
			push_warning("GuideableNpc: from_dict 的 speed 非法，已忽略")
	if data.has("last_hint"):
		var hint_value = data["last_hint"]
		if hint_value is String:
			_last_hint = hint_value
		else:
			push_warning("GuideableNpc: from_dict 的 last_hint 类型不符，已忽略")
	if data.has("arrived_emitted"):
		var arrived_value = data["arrived_emitted"]
		if arrived_value is bool:
			_arrived_emitted = arrived_value
		else:
			push_warning("GuideableNpc: from_dict 的 arrived_emitted 类型不符，已忽略")
	_refresh_visual()


## group 的唯一归一化入口。与 W0 契约 §4 的 PersonGroup.normalize() 语义一致。
static func normalize_group(raw: String) -> String:
	var value := raw.strip_edges().to_lower()
	match value:
		"real", "stranger":
			return GROUP_REAL
		"imaginary", "friend":
			return GROUP_IMAGINARY
		_:
			push_warning("GuideableNpc: 未知 group '%s'，按 real 处理" % raw)
			return GROUP_REAL


# --- 内部 ---------------------------------------------------------------------

## 进入移动状态。若上一次已经走完整条 route，则从头再走；否则沿用当前进度，
## 避免中途改指令（例如 FOLLOW -> OPEN_DOOR）时先倒退回起点。
func _start_moving(new_state: int) -> void:
	state = new_state
	if _waypoint_index >= route.size():
		_waypoint_index = 0
	_arrived_emitted = false


func _request_hint() -> void:
	var suggested := HINT_WAIT if route.is_empty() else HINT_FOLLOW
	needs_hint.emit(npc_id, suggested)


func _finish_route() -> void:
	if state == State.OPEN_DOOR and _door_target != null and _door_target.has_method("open"):
		_door_target.open()
	state = State.WAIT
	if not _arrived_emitted:
		_arrived_emitted = true
		arrived.emit(npc_id)


func _restore_route(values: Array) -> void:
	route.clear()
	for entry in values:
		if entry is Vector3:
			route.append(entry)
		elif _is_number_array(entry, 3):
			route.append(Vector3(float(entry[0]), float(entry[1]), float(entry[2])))
		else:
			push_warning("GuideableNpc: from_dict 的 route 条目非法，已忽略")


func _is_number_array(value: Variant, length: int) -> bool:
	if not value is Array:
		return false
	var values: Array = value
	if values.size() != length:
		return false
	for entry in values:
		if not (entry is int or entry is float):
			return false
	return true


# --- 占位视觉（demo 用；测试与 headless 不依赖渲染） ---------------------------

func _build_visual() -> void:
	if not show_visual or _body != null:
		return
	_body = MeshInstance3D.new()
	var mesh := CapsuleMesh.new()
	mesh.radius = 0.35
	mesh.height = 1.4
	_body.mesh = mesh
	_body_material = StandardMaterial3D.new()
	_body.material_override = _body_material
	add_child(_body)

	_name_label = Label3D.new()
	_name_label.font_size = 32
	_name_label.pixel_size = 0.005
	_name_label.position = Vector3(0.0, 1.15, 0.0)
	_name_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	add_child(_name_label)


func _refresh_visual() -> void:
	if _body_material != null:
		_body_material.albedo_color = _group_color()
	if _name_label != null:
		_name_label.text = npc_id if not npc_id.is_empty() else name


func _group_color() -> Color:
	return Color(0.30, 0.82, 0.45) if group == GROUP_REAL else Color(0.72, 0.48, 0.95)
