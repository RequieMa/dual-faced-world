extends Node3D
## W12 集成装配根节点：把 W1–W8 的系统 new 出来并接线（契约 §3 / §10）。
##
## 设计约束：
## - 不新增 autoload：所有系统都由本节点持有，测试可以直接实例化场景驱动；
## - 配置走各模块自己的加载入口（surveillance.json / dialogues.json 经 ConfigLoader）；
## - 计时统一由宿主 `tick(delta)` 驱动，headless 测试用固定步长复现；
## - 场景里的 World 子树只放内容（NPC / 灯 / 门 / 扬声器），本脚本按鸭子类型
##   (`get_target_id`) 注册到 GuideBus，不改别人的场景或脚本；
## - `reset_for_loop()` 只复位「本轮内可变」的状态：摄像头焦点/冷却、NPC、灯。
##   按 M16 未拍板前的契约默认，烧毁的机位保持烧毁；
##   GuideableDoor 没有 close() 接口，门的开合状态不参与循环复位的（见 docs）。
##
## 对外 API 是给宿主 / 端到端 smoke 用的最小面；各系统内部契约仍以
## docs/MECHANICS_CONTRACTS.md 为权威。

signal camera_overloaded(camera_id: String)
signal hint_sent(target_id: String, text: String)
signal round_started(round_index: int)
signal round_ended(round_index: int, summary: Dictionary)
signal definition_error(message: String)

const CameraSessionScript := preload("res://scripts/camera/camera_session.gd")
const CameraConfigScript := preload("res://scripts/camera/camera_config.gd")
const GuideBusScript := preload("res://scripts/guide/guide_bus.gd")
const LoopManagerScript := preload("res://scripts/loop/loop_manager.gd")
const DialogueControllerScript := preload("res://scripts/dialogue/dialogue_controller.gd")
const StyleControllerScript := preload("res://scripts/render/style_controller.gd")

const SURVEILLANCE_PATH := "res://resources/data/surveillance.json"
const DIALOGUES_PATH := "res://resources/data/dialogues.json"
const WORLD_NODE := "World"

## 真实游玩时由 `_process` 推进计时；headless 测试关掉它，改用固定步长 tick()。
@export var auto_tick: bool = true

## 装配期的配置/数据错误（不抛错；同时发 definition_error）。
var last_errors: Array[String] = []

var _camera_config = CameraConfigScript.new()
var _camera_session: Node
var _guide_bus: Node
var _loop_manager: Node
var _dialogue_controller: Control
var _style_controller: Node

## 由 World 子树注册进来的目标，按能力分类，便于循环复位。
var _npcs: Dictionary = {}
var _lights: Dictionary = {}
var _doors: Dictionary = {}
var _initial_npc_states: Dictionary = {}
var _initial_light_states: Dictionary = {}

var _round_active: bool = false


func _ready() -> void:
	_build_systems()
	_load_data()
	_bind_world()
	_capture_world_initial_state()
	set_process(auto_tick)


func _process(delta: float) -> void:
	if auto_tick:
		# 切窗/卡顿会产生 5s+ 的 delta；限步避免一帧把摄像头直接烧掉。
		tick(minf(delta, 0.1))


# --- 装配 ---------------------------------------------------------------------

func _build_systems() -> void:
	_camera_session = CameraSessionScript.new()
	_camera_session.name = "CameraSession"
	add_child(_camera_session)

	_guide_bus = GuideBusScript.new()
	_guide_bus.name = "GuideBus"
	add_child(_guide_bus)

	_loop_manager = LoopManagerScript.new()
	_loop_manager.name = "LoopManager"
	add_child(_loop_manager)

	_dialogue_controller = DialogueControllerScript.new()
	_dialogue_controller.name = "DialogueController"
	add_child(_dialogue_controller)

	_style_controller = StyleControllerScript.new()
	_style_controller.name = "StyleController"
	add_child(_style_controller)

	_camera_session.overload_started.connect(_on_camera_overload)
	_guide_bus.hint_sent.connect(_on_hint_sent)
	_loop_manager.round_started.connect(_on_loop_round_started)
	_loop_manager.round_ended.connect(_on_loop_round_ended)
	_dialogue_controller.error_occurred.connect(_on_dialogue_error)


func _load_data() -> void:
	if not _camera_config.load_into(_camera_session, SURVEILLANCE_PATH):
		_fail("surveillance 配置加载失败: %s" % _join_errors(_camera_config.last_errors))
	# 对话加载失败已经由 DialogueController.error_occurred -> _on_dialogue_error -> _fail
	# 记录一次，这里不再重复追加。
	_dialogue_controller.load_defs(DIALOGUES_PATH)


func _bind_world() -> void:
	var world := get_node_or_null(WORLD_NODE)
	if world == null:
		_fail("GameRoot: 场景缺少 %s 节点，引导目标未注册" % WORLD_NODE)
		return
	_scan_world(world)


## 按鸭子类型扫描：get_target_id() 的节点注册到 GuideBus；
## 带 play_hint()+on_bus_hint() 的扬声器订阅 hint_sent。
func _scan_world(node: Node) -> void:
	if node.has_method("get_target_id"):
		var target_id := String(node.call("get_target_id"))
		if not target_id.is_empty() and _guide_bus.register_target(target_id, node):
			if node.has_method("on_hint"):
				_npcs[target_id] = node
				var raw_group: Variant = node.get("group")
				_tag_style_group(node, raw_group if raw_group is String else "")
			elif node.has_method("is_on"):
				_lights[target_id] = node
			elif node.has_method("is_open"):
				_doors[target_id] = node
	if node.has_method("play_hint") and node.has_method("on_bus_hint"):
		var callback := Callable(node, "on_bus_hint")
		if not _guide_bus.hint_sent.is_connected(callback):
			_guide_bus.hint_sent.connect(callback)
	for child in node.get_children():
		_scan_world(child)


## 把 NPC 的网格挂到 StyleController 消费的组（real / imaginary）。
## 网格是 GuideableNpc 在 _ready 里代码生成的，场景文件无法直接打组；
## 这里在 World 绑定阶段补齐，否则 W4 的 apply_style 只会翻开关、套不到任何节点。
func _tag_style_group(node: Node, group: String) -> void:
	var canonical := group.strip_edges().to_lower()
	if canonical != "real" and canonical != "imaginary":
		return
	_add_group_recursive(node, canonical)


func _add_group_recursive(node: Node, group: String) -> void:
	# 只标网格，不把 Label3D 也套上空间 shader。
	if node is MeshInstance3D and not node.is_in_group(group):
		node.add_to_group(group)
	for child in node.get_children():
		_add_group_recursive(child, group)


func _capture_world_initial_state() -> void:
	# 只记逻辑状态（NPC 的 to_dict / 灯的开关）；门没有 close()，见文件头。
	for target_id in _npcs:
		if is_instance_valid(_npcs[target_id]):
			_initial_npc_states[target_id] = _npcs[target_id].to_dict()
	for target_id in _lights:
		if is_instance_valid(_lights[target_id]):
			_initial_light_states[target_id] = bool(_lights[target_id].is_on())


# --- 时钟 ---------------------------------------------------------------------

## 宿主每帧调用：推进摄像头停留 / 冷却与场景里可 tick 的引导目标。
func tick(delta: float) -> void:
	if delta <= 0.0 or not is_finite(delta):
		return
	if is_instance_valid(_camera_session):
		_camera_session.tick(delta)
	for target_id in _npcs:
		var npc = _npcs[target_id]
		if is_instance_valid(npc) and npc.has_method("tick"):
			npc.tick(delta)


# --- 摄像头（W1） ---------------------------------------------------------------

func switch_camera(camera_id: String) -> bool:
	if not is_instance_valid(_camera_session):
		return false
	return bool(_camera_session.enter(camera_id))


func leave_camera() -> void:
	if not is_instance_valid(_camera_session):
		return
	var current := String(_camera_session.get_state().get("current", ""))
	if not current.is_empty():
		_camera_session.leave(current)


# --- 引导（W2） -----------------------------------------------------------------

func send_hint(target_id: String, text: String) -> bool:
	return bool(_guide_bus.send_hint(target_id, text))


func set_indicator(target_id: String, on: bool) -> bool:
	return bool(_guide_bus.set_indicator(target_id, on))


func open_door(target_id: String) -> bool:
	return bool(_guide_bus.open_door(target_id))


# --- 对话 / 画风（W3 / W4） ---------------------------------------------------------

func start_dialogue(dialogue_id: String, group_override: String = "") -> bool:
	return bool(_dialogue_controller.start(dialogue_id, group_override))


func apply_style(group: String, enabled: bool) -> bool:
	return bool(_style_controller.apply_style(group, enabled))


# --- 循环（W6） -----------------------------------------------------------------

## 开始新一轮（首轮从 1 开始）。
func start_round() -> void:
	_loop_manager.start_round()


## 结束当前轮；没有进行中的轮次时返回 false。
func end_round(summary: Dictionary = {}) -> bool:
	if not _round_active:
		push_warning("GameRoot.end_round: 当前没有进行中的轮次")
		return false
	_loop_manager.end_round(summary)
	return true


## 循环重开：结束当前轮（若有）→ 世界复位 → 开始新一轮。
func restart_round(time: float = 0.0) -> bool:
	if _round_active:
		_loop_manager.end_round({"outcome": "rewind"})
	_loop_manager.rewind_to(time, [self])
	_loop_manager.start_round()
	return true


## LoopManager 参与者协议：复位本轮内可变的世界状态。
## 烧毁机位按 M16 默认保持烧毁，因此只清空焦点/冷却，不从存档里恢复。
func reset_for_loop(_time: float) -> void:
	if is_instance_valid(_camera_session):
		var camera_data: Dictionary = _camera_session.to_dict()
		camera_data["current"] = ""
		camera_data["remain"] = 0.0
		camera_data["cooldowns"] = {}
		_camera_session.from_dict(camera_data)
	for target_id in _npcs:
		var npc = _npcs[target_id]
		if is_instance_valid(npc) and _initial_npc_states.has(target_id):
			npc.from_dict((_initial_npc_states[target_id] as Dictionary).duplicate(true))
	for target_id in _lights:
		var light = _lights[target_id]
		if is_instance_valid(light) and _initial_light_states.has(target_id):
			light.set_on(bool(_initial_light_states[target_id]))


# --- 状态 / 访问器 ---------------------------------------------------------------

func get_camera_session() -> Node:
	return _camera_session


func get_guide_bus() -> Node:
	return _guide_bus


func get_loop_manager() -> Node:
	return _loop_manager


func get_dialogue_controller() -> Control:
	return _dialogue_controller


func get_style_controller() -> Node:
	return _style_controller


func is_round_active() -> bool:
	return _round_active


func get_state() -> Dictionary:
	return {
		"camera": _camera_session.get_state() if is_instance_valid(_camera_session) else {},
		"guide": _guide_bus.get_state() if is_instance_valid(_guide_bus) else {},
		"loop": {
			"round": _loop_manager.get_round_index() if is_instance_valid(_loop_manager) else 0,
			"history": _loop_manager.get_history() if is_instance_valid(_loop_manager) else [],
		},
		"dialogue": _dialogue_controller.get_state() if is_instance_valid(_dialogue_controller) else {},
		"style": _style_controller.get_state() if is_instance_valid(_style_controller) else {},
		"round_active": _round_active,
		"last_errors": last_errors.duplicate(),
	}


# --- 内部 ---------------------------------------------------------------------

func _on_camera_overload(camera_id: String) -> void:
	camera_overloaded.emit(camera_id)


func _on_hint_sent(target_id: String, text: String) -> void:
	hint_sent.emit(target_id, text)


func _on_loop_round_started(round_index: int) -> void:
	_round_active = true
	round_started.emit(round_index)


func _on_loop_round_ended(round_index: int, summary: Dictionary) -> void:
	_round_active = false
	round_ended.emit(round_index, summary)


func _on_dialogue_error(message: String) -> void:
	_fail(message)


func _fail(message: String) -> void:
	last_errors.append(message)
	definition_error.emit(message)


func _join_errors(errors: Array) -> String:
	if errors.is_empty():
		return "未知错误"
	return "; ".join(errors)
