extends RefCounted
## EventTimeline：0–90s 一次性预计算的确定性 simulation 时间线。
##
## 不启用物理引擎：所有运动都是 waypoint 线性插值，10Hz 采样，
## 每 0.1s 存一份完整状态快照（所有 agent 位置 + 所有道具位置和状态）。
## 回放与实时都从同一个时间线取状态，因此「同一时刻的画面」只有一份真值。
##
## 事件：t<=45 的事件在快照生成时被消费（道具状态随之改变）；
## t>45 的计划事件只作为数据存在（planned=true），第一阶段不消费，
## 由第二阶段（live）在满足条件时重新判定。

const DURATION := 90.0
const SAMPLE_INTERVAL := 0.1
const TAPE_WINDOW := 15.0
## 录像带只覆盖 [0,45)；45 之后只有实时视图，没有档案。
const TAPE_COVERAGE_END := 45.0

const KEY_START := Vector3(2.5, 0.4, 6.0)
const SWITCH_POS := Vector3(-6.0, 0.55, 6.0)
const DOOR_01_POS := Vector3(0.0, 1.2, -6.0)
const DOOR_02_POS := Vector3(4.0, 1.2, -3.8)

const PICKUP_EVENT_T := 12.0
const SWITCH_EVENT_T := 20.0
const UNLOCK_01_EVENT_T := 28.0

## 每个 agent 的路径关键帧：段内线性插值，关键帧落在交互事件时刻上，
## 保证「事件发生时 actor 就在目标点」。
const AGENT_PATHS := {
	"Agent_A": [
		{"t": 0.0, "p": Vector3(-2.0, 0.6, 7.0)},
		{"t": 12.0, "p": Vector3(2.5, 0.6, 6.0)},
		{"t": 20.0, "p": Vector3(0.0, 0.6, 0.0)},
		{"t": 28.0, "p": Vector3(0.0, 0.6, -5.4)},
		{"t": 38.0, "p": Vector3(-4.0, 0.6, -7.0)},
		{"t": 47.0, "p": Vector3(4.2, 0.6, -3.8)},
		{"t": 56.0, "p": Vector3(8.0, 0.6, -8.0)},
		{"t": 70.0, "p": Vector3(8.0, 0.6, 2.0)},
	],
	"Agent_B": [
		{"t": 0.0, "p": Vector3(5.0, 0.7, -7.0)},
		{"t": 20.0, "p": Vector3(-6.0, 0.7, 6.0)},
		{"t": 32.0, "p": Vector3(2.0, 0.7, 2.0)},
		{"t": 44.0, "p": Vector3(-7.0, 0.7, -2.0)},
		{"t": 52.0, "p": Vector3(0.0, 0.7, -6.5)},
		{"t": 64.0, "p": Vector3(3.0, 0.7, -8.0)},
	],
	"Agent_C": [
		{"t": 0.0, "p": Vector3(-8.0, 0.8, 0.0)},
		{"t": 30.0, "p": Vector3(0.0, 0.8, 2.0)},
		{"t": 35.0, "p": Vector3(0.0, 0.8, -5.4)},
		{"t": 45.0, "p": Vector3(-4.0, 0.8, -8.0)},
		{"t": 53.0, "p": Vector3(4.2, 0.8, -3.8)},
		{"t": 60.0, "p": Vector3(8.0, 0.8, -7.0)},
		{"t": 75.0, "p": Vector3(8.0, 0.8, 5.0)},
	],
}

## cause 用线索 id 引用（格式 type_target_t），形成跨事件/跨来源的因果链。
## planned=true 的事件只存数据：第一阶段不消费，也不派发。
const EVENTS := [
	{"t": 12.0, "type": "pickup", "actor": "Agent_A", "target": "Key_01", "cause": ""},
	{"t": 20.0, "type": "switch", "actor": "Agent_B", "target": "Switch_01", "cause": ""},
	{"t": 28.0, "type": "unlock", "actor": "Agent_A", "target": "Door_01", "cause": "pickup_Key_01_12.0"},
	{"t": 35.0, "type": "pass", "actor": "Agent_C", "target": "Door_01", "cause": "unlock_Door_01_28.0"},
	{"t": 52.0, "type": "unlock", "actor": "Agent_C", "target": "Door_02", "cause": "pickup_Key_01_12.0", "planned": true},
	{"t": 60.0, "type": "switch", "actor": "Agent_B", "target": "Switch_01", "cause": "switch_Switch_01_20.0", "planned": true},
	{"t": 75.0, "type": "pass", "actor": "Agent_A", "target": "Door_01", "cause": "unlock_Door_01_28.0", "planned": true},
]


## 线索 id：同一时刻同一类型同一目标唯一，跨来源（archive/live）共享。
static func clue_id(at: float, type_name: String, target: String) -> String:
	return "%s_%s_%.1f" % [type_name, target, snappedf(at, 0.1)]


## 生成整条时间线（快照 + 事件 + 3 盘录像带）。
static func build() -> Dictionary:
	var snapshots: Array = []
	var steps := int(round(DURATION / SAMPLE_INTERVAL))
	for index in range(steps + 1):
		snapshots.append(_state_at_raw(float(index) * SAMPLE_INTERVAL, true))

	var events: Array = []
	for entry in EVENTS:
		var copy: Dictionary = (entry as Dictionary).duplicate(true)
		copy["planned"] = bool(copy.get("planned", false))
		copy["id"] = clue_id(float(copy["t"]), String(copy["type"]), String(copy["target"]))
		events.append(copy)

	var tapes: Array = []
	var tape_index := 1
	var start := 0.0
	while start < TAPE_COVERAGE_END - 0.001:
		var finish := minf(start + TAPE_WINDOW, TAPE_COVERAGE_END)
		tapes.append({
			"tape_id": "TAPE-%02d" % tape_index,
			"label": "%02d-%02d" % [int(round(start)) % 100, int(round(finish)) % 100],
			"time_start": start,
			"time_end": finish,
			"duration": finish - start,
		})
		start = finish
		tape_index += 1

	return {
		"duration": DURATION,
		"sample_interval": SAMPLE_INTERVAL,
		"snapshots": snapshots,
		"events": events,
		"tapes": tapes,
	}


## 任意时刻的状态：在相邻两份 10Hz 快照之间线性插值位置，
## 状态量（on/off、locked/unlocked、carried/ground）取左端（阶跃语义）。
static func state_at(timeline: Dictionary, at: float) -> Dictionary:
	var snapshots: Array = timeline.get("snapshots", [])
	if snapshots.is_empty():
		return {"t": at, "agents": {}, "props": {}}
	var interval := float(timeline.get("sample_interval", SAMPLE_INTERVAL))
	var duration := float(timeline.get("duration", DURATION))
	var clamped := clampf(at, 0.0, duration)
	var position := clamped / interval
	# +0.0001 抵消 12.0/0.1 = 119.999… 的浮点误差，避免整点落到上一帧。
	var index := int(floor(position + 0.0001))
	if index >= snapshots.size() - 1:
		return _copy_state(snapshots[snapshots.size() - 1], clamped)
	if index < 0:
		return _copy_state(snapshots[0], clamped)

	var ratio := clampf(position - float(index), 0.0, 1.0)
	var low: Dictionary = snapshots[index]
	var high: Dictionary = snapshots[index + 1]

	var agents := {}
	for agent_name in (low["agents"] as Dictionary).keys():
		agents[agent_name] = (low["agents"][agent_name] as Vector3).lerp(high["agents"][agent_name], ratio)

	var props := {}
	for prop_name in (low["props"] as Dictionary).keys():
		var low_prop: Dictionary = low["props"][prop_name]
		var high_prop: Dictionary = high["props"][prop_name]
		props[prop_name] = {
			"pos": (low_prop["pos"] as Vector3).lerp(high_prop["pos"], ratio),
			"state": String(low_prop["state"]),
			"holder": String(low_prop["holder"]),
		}
	return {"t": clamped, "agents": agents, "props": props}


## 取出 (from_time, to_time] 内的事件；默认跳过 planned（第一阶段不消费）。
static func events_between(timeline: Dictionary, from_time: float, to_time: float, include_planned: bool = false) -> Array:
	var result: Array = []
	for entry in timeline.get("events", []):
		if bool((entry as Dictionary).get("planned", false)) and not include_planned:
			continue
		var at := float((entry as Dictionary).get("t", 0.0))
		if at > from_time and at <= to_time:
			result.append(entry)
	return result


# --- 内部 ---------------------------------------------------------------------

static func _copy_state(snapshot: Dictionary, at: float) -> Dictionary:
	var agents := {}
	for agent_name in (snapshot["agents"] as Dictionary).keys():
		agents[agent_name] = snapshot["agents"][agent_name]
	var props := {}
	for prop_name in (snapshot["props"] as Dictionary).keys():
		props[prop_name] = (snapshot["props"][prop_name] as Dictionary).duplicate(true)
	return {"t": at, "agents": agents, "props": props}


static func _state_at_raw(at: float, _generate: bool) -> Dictionary:
	var agents := {}
	for agent_name in AGENT_PATHS.keys():
		agents[agent_name] = _agent_position(String(agent_name), at)

	var key_holder := "Agent_A" if at >= PICKUP_EVENT_T else ""
	var key_pos := KEY_START
	if not key_holder.is_empty():
		# 拿在手里：位置跟着持有者走，仍由 apply_state 统一写入节点。
		key_pos = (agents[key_holder] as Vector3) + Vector3(0.45, 0.25, 0.0)

	var props := {
		"Key_01": {"pos": key_pos, "state": "ground" if key_holder.is_empty() else "carried", "holder": key_holder},
		"Switch_01": {"pos": SWITCH_POS, "state": "on" if at >= SWITCH_EVENT_T else "off", "holder": ""},
		"Door_01": {"pos": DOOR_01_POS, "state": "unlocked" if at >= UNLOCK_01_EVENT_T else "locked", "holder": ""},
		# Door_02 只有 planned 事件（t=52），第一阶段不消费 → 档案里始终 locked。
		"Door_02": {"pos": DOOR_02_POS, "state": "locked", "holder": ""},
	}
	return {"t": at, "agents": agents, "props": props}


static func _agent_position(agent_name: String, at: float) -> Vector3:
	var path: Array = AGENT_PATHS.get(agent_name, [])
	if path.is_empty():
		return Vector3.ZERO
	var first: Dictionary = path[0]
	if at <= float(first["t"]):
		return first["p"]
	for index in range(1, path.size()):
		var current: Dictionary = path[index]
		if at <= float(current["t"]):
			var previous: Dictionary = path[index - 1]
			var span := float(current["t"]) - float(previous["t"])
			var ratio := 0.0 if span <= 0.0 else (at - float(previous["t"])) / span
			return (previous["p"] as Vector3).lerp(current["p"], ratio)
	return path[path.size() - 1]["p"]
