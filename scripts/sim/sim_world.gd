extends Node3D
## SimWorld：20×20 平面地图 + 边界墙 + 3 个 agent + 4 个道具。
##
## apply_state() 是**唯一**的节点状态写入口：回放、实时、拖拽后的画面都必须走它，
## 不允许在别处直接 set position。这样「画面」永远等于「某一份状态快照」，
## 第二阶段切换实时/回放时不会出现位置跳变。

const MAP_HALF := 10.0
const AGENT_NAMES: Array[String] = ["Agent_A", "Agent_B", "Agent_C"]
const PROP_NAMES: Array[String] = ["Key_01", "Switch_01", "Door_01", "Door_02"]

const AGENT_COLORS := {
	"Agent_A": Color(0.92, 0.24, 0.28, 1.0),
	"Agent_B": Color(0.28, 0.85, 0.38, 1.0),
	"Agent_C": Color(0.26, 0.48, 0.95, 1.0),
}
const KEY_COLOR := Color(0.20, 0.90, 1.00, 1.0)
const SWITCH_ON_COLOR := Color(0.98, 0.82, 0.20, 1.0)
const SWITCH_OFF_COLOR := Color(0.42, 0.40, 0.30, 1.0)
const DOOR_LOCKED_COLOR := Color(0.82, 0.26, 0.22, 1.0)
const DOOR_UNLOCKED_COLOR := Color(0.28, 0.82, 0.46, 1.0)
const WALL_COLOR := Color(0.16, 0.19, 0.24, 1.0)

var _agents: Dictionary = {}
var _props: Dictionary = {}
var _prop_materials: Dictionary = {}
var _prop_states: Dictionary = {}
var _prop_holders: Dictionary = {}
var _apply_count: int = 0


func _ready() -> void:
	_build_static()
	_build_agents()
	_build_props()


# --- 唯一状态写入口 -----------------------------------------------------------

func apply_state(state: Dictionary) -> void:
	var agents: Dictionary = state.get("agents", {})
	for agent_name in agents.keys():
		var node: Node3D = _agents.get(String(agent_name))
		if node != null:
			node.position = agents[agent_name]

	var props: Dictionary = state.get("props", {})
	for prop_name in props.keys():
		var key := String(prop_name)
		var data: Dictionary = props[prop_name]
		var node: Node3D = _props.get(key)
		if node == null:
			continue
		node.position = data.get("pos", node.position)
		_prop_states[key] = String(data.get("state", ""))
		_prop_holders[key] = String(data.get("holder", ""))
		_apply_prop_visual(key, node, _prop_states[key])
	_apply_count += 1


## 供 eval/测试读取：节点上的真实状态（不是缓存的时间线数据）。
func get_state_snapshot() -> Dictionary:
	var agents := {}
	for agent_name in _agents.keys():
		agents[agent_name] = (_agents[agent_name] as Node3D).position
	var props := {}
	for prop_name in _props.keys():
		var key := String(prop_name)
		props[key] = {
			"pos": (_props[key] as Node3D).position,
			"state": _prop_states.get(key, ""),
			"holder": _prop_holders.get(key, ""),
		}
	return {"agents": agents, "props": props, "apply_count": _apply_count}


func get_prop_node(prop_name: String) -> Node3D:
	return _props.get(prop_name)


func is_agent_name(agent_name: String) -> bool:
	return _agents.has(agent_name)


func reset_apply_count() -> void:
	_apply_count = 0


# --- 静态几何 ----------------------------------------------------------------

func _build_static() -> void:
	var ground := MeshInstance3D.new()
	ground.name = "Ground"
	var plane := PlaneMesh.new()
	plane.size = Vector2(MAP_HALF * 2.0, MAP_HALF * 2.0)
	var ground_material := ShaderMaterial.new()
	ground_material.shader = load("res://shaders/grid_ground.gdshader")
	plane.material = ground_material
	ground.mesh = plane
	add_child(ground)

	var walls := Node3D.new()
	walls.name = "Walls"
	add_child(walls)
	var wall_material := _make_material(WALL_COLOR)
	# 边界墙（20×20 地图四周）
	_add_box(walls, "Wall_N", Vector3(0.0, 1.0, MAP_HALF), Vector3(MAP_HALF * 2.0, 2.0, 0.4), wall_material)
	_add_box(walls, "Wall_S", Vector3(0.0, 1.0, -MAP_HALF), Vector3(MAP_HALF * 2.0, 2.0, 0.4), wall_material)
	_add_box(walls, "Wall_W", Vector3(-MAP_HALF, 1.0, 0.0), Vector3(0.4, 2.0, MAP_HALF * 2.0), wall_material)
	_add_box(walls, "Wall_E", Vector3(MAP_HALF, 1.0, 0.0), Vector3(0.4, 2.0, MAP_HALF * 2.0), wall_material)
	# 北侧内室：两片墙围出 x∈[4,10] / z∈[-10,-3] 的房间，门洞在 (4, -3.8)。
	_add_box(walls, "RoomWall_X", Vector3(4.0, 1.2, -7.3), Vector3(0.3, 2.4, 5.4), wall_material)
	_add_box(walls, "RoomWall_Z", Vector3(7.0, 1.2, -3.0), Vector3(6.0, 2.4, 0.3), wall_material)


func _build_agents() -> void:
	var container := Node3D.new()
	container.name = "Agents"
	add_child(container)
	for agent_name in AGENT_NAMES:
		var node := MeshInstance3D.new()
		node.name = agent_name
		node.mesh = _make_agent_mesh(agent_name)
		container.add_child(node)
		_agents[agent_name] = node


func _build_props() -> void:
	var container := Node3D.new()
	container.name = "Props"
	add_child(container)
	for prop_name in PROP_NAMES:
		var node := MeshInstance3D.new()
		node.name = prop_name
		var material := _make_material(KEY_COLOR)
		node.mesh = _make_prop_mesh(prop_name, material)
		container.add_child(node)
		_props[prop_name] = node
		_prop_materials[prop_name] = material


func _make_agent_mesh(agent_name: String) -> Mesh:
	var material := _make_material(AGENT_COLORS.get(agent_name, Color.WHITE))
	match agent_name:
		"Agent_B":
			var sphere := SphereMesh.new()
			sphere.radius = 0.6
			sphere.height = 1.2
			sphere.material = material
			return sphere
		"Agent_C":
			var cylinder := CylinderMesh.new()
			cylinder.top_radius = 0.5
			cylinder.bottom_radius = 0.5
			cylinder.height = 1.6
			cylinder.material = material
			return cylinder
		_:
			var box := BoxMesh.new()
			box.size = Vector3(1.1, 1.1, 1.1)
			box.material = material
			return box


func _make_prop_mesh(prop_name: String, material: StandardMaterial3D) -> Mesh:
	match prop_name:
		"Key_01":
			var capsule := CapsuleMesh.new()
			capsule.radius = 0.18
			capsule.height = 0.7
			capsule.material = material
			return capsule
		"Switch_01":
			var box := BoxMesh.new()
			box.size = Vector3(0.7, 1.0, 0.7)
			box.material = material
			return box
		"Door_01":
			var door := BoxMesh.new()
			door.size = Vector3(0.3, 2.2, 3.4)
			door.material = material
			return door
		_:
			var door_02 := BoxMesh.new()
			door_02.size = Vector3(0.3, 2.2, 1.6)
			door_02.material = material
			return door_02


## 道具状态 → 视觉：颜色 + 开合角度。位置只由 apply_state 写入，视觉不偷偷改位置。
func _apply_prop_visual(prop_name: String, node: Node3D, state: String) -> void:
	var material: StandardMaterial3D = _prop_materials.get(prop_name)
	if material == null:
		return
	match prop_name:
		"Switch_01":
			var is_on := state == "on"
			material.albedo_color = SWITCH_ON_COLOR if is_on else SWITCH_OFF_COLOR
			material.emission_enabled = is_on
			material.emission = SWITCH_ON_COLOR
			material.emission_energy_multiplier = 1.4 if is_on else 0.0
		"Door_01", "Door_02":
			var is_open := state == "unlocked"
			material.albedo_color = DOOR_UNLOCKED_COLOR if is_open else DOOR_LOCKED_COLOR
			node.rotation.y = deg_to_rad(78.0) if is_open else 0.0
		_:
			material.albedo_color = KEY_COLOR


func _make_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.metallic = 0.08
	material.roughness = 0.45
	return material


func _add_box(parent: Node3D, node_name: String, at: Vector3, size: Vector3, material: Material) -> void:
	var node := MeshInstance3D.new()
	node.name = node_name
	var box := BoxMesh.new()
	box.size = size
	box.material = material
	node.mesh = box
	node.position = at
	parent.add_child(node)
