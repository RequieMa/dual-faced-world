extends Node
## LiveRuntime：实时推进 + 道具拖拽 + live 因果链（第二阶段）。
##
## 实时与回放共用同一条 EventTimeline：每帧 `compose(present_time)` 取基准状态，
## 再叠加 live 覆盖（拖拽位置、已被实时改写的道具状态），最后交给 SimWorld.apply_state()。
## `step()` 负责在 agent 到达交互点时判定 pickup / switch / unlock，并把新事件
## 登记成 source="live" 的线索；cause 引用产生该能力的 pickup 线索（可能来自 archive）。
##
## 第一阶段契约不变：不改 EventTimeline 生成器、不改 apply_state 入口、不改 register_clue 签名。

const SimTimeline = preload("res://scripts/sim/sim_timeline.gd")

## 交互半径（只在 XZ 平面上比较：agent 高度与道具高度不同，y 不参与）
const PICKUP_RADIUS := 1.5
const SWITCH_RADIUS := 1.6
const DOOR_RADIUS := 2.0
## 可拖拽的道具（门不参与拖拽）
const DRAGGABLE_PROPS: Array[String] = ["Key_01", "Switch_01"]
## 道具被拖到地面后的高度（保持原来的视觉高度）
const DRAG_HEIGHT := {"Key_01": 0.4, "Switch_01": 0.55}
## 携带时相对 agent 的偏移（与 EventTimeline 保持一致）
const CARRY_OFFSET := Vector3(0.45, 0.25, 0.0)

var _timeline: Dictionary = {}
var _sim_world: Node3D = null
var _clue_manager: Node = null
## 道具覆盖：prop -> {pos: Vector3, state: String, holder: String}
var _overrides: Dictionary = {}
## 本运行时登记过的 live 线索 id（按登记顺序）
var _live_clue_ids: Array[String] = []
var _last_time := 0.0
## 拖拽挂起：拖拽期间玩家正在改世界，不做交互判定。
## 否则每帧都会把「临时无持有者 + 临时位置」当成 agent 到达交互点，
## 登记出幻影 live 线索（实测每 0.1s 一条）。
var _dragging := false


func setup(timeline: Dictionary, sim_world: Node3D, clue_manager: Node) -> void:
	_timeline = timeline
	_sim_world = sim_world
	_clue_manager = clue_manager


## 拖拽开始/结束时由 UI 调用：拖拽期间暂停交互判定。
func set_dragging(value: bool) -> void:
	_dragging = value


func is_dragging() -> bool:
	return _dragging


## 基准时间线状态 + live 覆盖（不写节点）。
func compose(at: float) -> Dictionary:
	var state: Dictionary = SimTimeline.state_at(_timeline, at)
	for prop_name in _overrides.keys():
		var override: Dictionary = _overrides[prop_name]
		var base: Dictionary = state["props"].get(prop_name, {})
		state["props"][prop_name] = {
			"pos": override.get("pos", base.get("pos", Vector3.ZERO)),
			"state": override.get("state", base.get("state", "")),
			"holder": override.get("holder", base.get("holder", "")),
		}
	return state


## 推进一帧的交互判定；返回本次新登记的 live 线索 id。
## 拖拽进行中只更新「被携带道具跟随持有者」，不判定任何交互（见 _dragging 注释）。
func step(at: float) -> Array:
	_last_time = at
	var new_ids: Array = []
	if _timeline.is_empty() or _sim_world == null or _clue_manager == null:
		return new_ids
	var state: Dictionary = compose(at)
	if not (state.get("props", {}) as Dictionary).has("Key_01"):
		return new_ids

	# 被携带的道具每帧跟着持有者走（拖拽期间也要维护，避免其它道具停在旧位置）
	for prop_name in _overrides.keys():
		var override: Dictionary = _overrides[prop_name]
		var holder := String(override.get("holder", ""))
		if holder.is_empty() or not (state["agents"] as Dictionary).has(holder):
			continue
		override["pos"] = (state["agents"][holder] as Vector3) + CARRY_OFFSET
		override["state"] = "carried"

	if _dragging:
		return new_ids

	var agents: Array = (state["agents"] as Dictionary).keys()

	# 1) Key_01：无人持有且 agent 进入拾取半径
	var key: Dictionary = state["props"]["Key_01"]
	if String(key["holder"]).is_empty():
		for agent_name in agents:
			if _xz_distance(state["agents"][agent_name], key["pos"]) <= PICKUP_RADIUS:
				var pickup_id := _register(at, "pickup", String(agent_name), "Key_01", "")
				if not pickup_id.is_empty():
					_overrides["Key_01"] = {
						"pos": (state["agents"][agent_name] as Vector3) + CARRY_OFFSET,
						"state": "carried",
						"holder": String(agent_name),
					}
					new_ids.append(pickup_id)
				break

	# 2) Switch_01：只在 off 时被 agent 打开（45s 时它已是 on，不会误触发）
	var switch_prop: Dictionary = state["props"]["Switch_01"]
	if String(switch_prop["state"]) == "off":
		for agent_name in agents:
			if _xz_distance(state["agents"][agent_name], switch_prop["pos"]) <= SWITCH_RADIUS:
				var previous_switch: Dictionary = _clue_manager.find_latest_timeline_clue("switch", "Switch_01")
				var switch_id := _register(at, "switch", String(agent_name), "Switch_01",
					String(previous_switch.get("id", "")))
				if not switch_id.is_empty():
					_overrides["Switch_01"] = {
						"pos": switch_prop["pos"],
						"state": "on",
						"holder": "",
					}
					new_ids.append(switch_id)
				break

	# 3) 门：持有钥匙的 agent 到达锁着的门 → live unlock，cause 指向 pickup（可能来自 archive）
	var key_holder := String((state["props"]["Key_01"] as Dictionary)["holder"])
	if not key_holder.is_empty():
		for door_name in ["Door_01", "Door_02"]:
			var door: Dictionary = state["props"][door_name]
			if String(door["state"]) != "locked":
				continue
			if _xz_distance(state["agents"][key_holder], door["pos"]) > DOOR_RADIUS:
				continue
			var pickup_clue: Dictionary = _clue_manager.find_latest_timeline_clue("pickup", "Key_01")
			var cause := String(pickup_clue.get("id", ""))
			if cause.is_empty():
				# 玩家还没看过档案：直接引用时间线上的 archive pickup 事件 id。
				# 这条 archive 线索被回放到时才会出现在线索板上，箭头也就那时才画得出来。
				cause = SimTimeline.clue_id(SimTimeline.PICKUP_EVENT_T, "pickup", "Key_01")
			var unlock_id := _register(at, "unlock", key_holder, door_name, cause)
			if not unlock_id.is_empty():
				_overrides[door_name] = {"pos": door["pos"], "state": "unlocked", "holder": ""}
				new_ids.append(unlock_id)
	return new_ids


## 把可拖拽道具放到地面某点（清掉持有者，让 agent 可以重新拾取）。
func drag_prop(prop_name: String, ground_pos: Vector3) -> bool:
	if not DRAGGABLE_PROPS.has(prop_name):
		return false
	var height := float(DRAG_HEIGHT.get(prop_name, 0.4))
	_overrides[prop_name] = {
		"pos": Vector3(ground_pos.x, height, ground_pos.z),
		"state": "ground" if prop_name == "Key_01" else String(compose(_last_time)["props"][prop_name]["state"]),
		"holder": "",
	}
	return true


func get_state() -> Dictionary:
	return {
		"overrides": _overrides.duplicate(true),
		"live_clue_ids": _live_clue_ids.duplicate(),
		"last_time": _last_time,
		"dragging": _dragging,
	}


# --- 内部 ---------------------------------------------------------------------

func _register(at: float, type_name: String, actor: String, target: String, cause: String) -> String:
	if _clue_manager == null:
		return ""
	var clue_id: String = _clue_manager.register_clue(at, type_name, actor, target, cause, "live")
	if not clue_id.is_empty():
		_live_clue_ids.append(clue_id)
	return clue_id


func _xz_distance(a: Vector3, b: Vector3) -> float:
	# 只比平面距离：agent 在 y=0.6~0.8，道具在 y=0.4~1.2，直接比 3D 距离会虚假地放大半径。
	return Vector2(a.x - b.x, a.z - b.z).length()
