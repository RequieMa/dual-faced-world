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
const ConfigLoaderScript := preload("res://scripts/config/config_loader.gd")

const SURVEILLANCE_PATH := "res://resources/data/surveillance.json"
const DIALOGUES_PATH := "res://resources/data/dialogues.json"
const LEVEL_PATH := "res://resources/data/levels/theater.json"
const LEVEL_SCHEMA_PATH := "res://resources/data/schema/level.schema.json"
const WORLD_NODE := "World"
const CAMERA_VIEWS_NODE := "World/Cameras"
const OVERVIEW_CAMERA_NODE := "World/OverviewCamera"

## 每个机位的画面朝向（位置在场景里，朝向由运行时 look_at 统一算，避免手算欧拉角）。
const CAMERA_LOOK_TARGETS := {
	"C1": Vector3(-2.5, 1.0, 0.0),
	"C2": Vector3(2.5, 1.0, 0.0),
	"C3": Vector3(0.0, 1.0, 0.0),
	"C4": Vector3(0.0, 1.0, -4.0),
}

## 关卡没加载出来时的兜底机位（与 surveillance.json 对齐）。
const DEFAULT_CAMERAS: Array[String] = ["C1", "C2", "C3", "C4"]

## 玩法层输入：运行时用 InputMap.add_action 注册，**不写 project.godot**；
## 节点退出场景树时清理自己注册的动作（沿用 W8 的做法）。
const INPUT_ACTIONS := {
	"game_camera_1": KEY_1,
	"game_camera_2": KEY_2,
	"game_camera_3": KEY_3,
	"game_camera_4": KEY_4,
	"game_camera_off": KEY_0,
	"game_hint_follow": KEY_F,
	"game_hint_wait": KEY_G,
	"game_hint_open": KEY_O,
	"game_indicator": KEY_I,
	"game_door": KEY_H,
	"game_cycle_npc": KEY_TAB,
	"game_dialogue": KEY_SPACE,
	"game_tape": KEY_T,
	"game_tape_next": KEY_RIGHT,
	"game_tape_prev": KEY_LEFT,
	"game_tape_forward": KEY_UP,
	"game_tape_back": KEY_DOWN,
	"game_close": KEY_ESCAPE,
	"game_restart": KEY_R,
}

const HINT_TEXTS := {
	"game_hint_follow": "跟我来",
	"game_hint_wait": "等待",
	"game_hint_open": "开门",
}

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

## 机位画面：id -> Scene 里的 Camera3D；空 id 表示总览。
var _camera_views: Dictionary = {}
var _overview_camera: Camera3D = null
var _camera_view_id: String = ""

## 由 World 子树注册进来的目标，按能力分类，便于循环复位。
var _npcs: Dictionary = {}
var _lights: Dictionary = {}
var _doors: Dictionary = {}
var _initial_npc_states: Dictionary = {}
var _initial_light_states: Dictionary = {}
var _initial_door_states: Dictionary = {}

var _round_active: bool = false

## 关卡数据（resources/data/levels/*.json）。
var _level: Dictionary = {}
var _level_cameras: Array[String] = []
## 关卡机位与 surveillance.json 的差集（装配期警告，见契约 §1）。
var _camera_mismatches: Array[String] = []

## 输入：按 World 扫描顺序收集的 NPC，Tab 循环当前提示对象。
var _npc_ids: Array[String] = []
var _npc_index: int = 0
var _registered_actions: Array[String] = []

## 录像带检查（读取 TapeArchive autoload；没有也不影响其它系统）。
var _tape_archive: Node = null
var _tape_panel: CanvasLayer = null
var _tape_label: Label = null
var _tape_open: bool = false
var _tape_index: int = 0
var _tape_time: float = 0.0
const TAPE_SEEK_STEP := 10.0

## 可玩 demo（序章）：数据驱动的轮次目标，剧情以后重设计也不影响这套骨架。
const DEMO_ROUNDS := 3
const DEMO_ROUND_TIME := 60.0
const DEMO_ROUND_SCORE := 100
const DEMO_BURN_PENALTY := 30
const DEMO_TARGET_NPC := "npc_imaginary"

var _demo_round: int = 0
var _demo_score: int = 0
var _demo_time_left: float = 0.0
var _demo_phase: String = "idle"
var _demo_message: String = ""
var _demo_round_burned: Array[String] = []
var _demo_hud: CanvasLayer = null
var _demo_label: Label = null


func _ready() -> void:
	_build_systems()
	_load_data()
	_load_level()
	_bind_camera_views()
	_bind_world()
	_collect_npc_ids()
	_setup_tape_archive()
	register_input_actions()
	_capture_world_initial_state()
	_refresh_hud()
	set_process(auto_tick)
	if auto_tick:
		start_demo()


func _exit_tree() -> void:
	unregister_input_actions()


func _process(delta: float) -> void:
	if auto_tick:
		# 切窗/卡顿会产生 5s+ 的 delta；限步避免一帧把摄像头直接烧掉。
		tick(minf(delta, 0.1))


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	if dispatch_key_event(event as InputEventKey):
		get_viewport().set_input_as_handled()


## 按键分发（InputMap 是唯一来源）：测试直接调用它，避免依赖真实输入循环。
## 面板打开时只响应录像带相关按键与重试，避免后台误切机位/发提示。
func dispatch_key_event(event: InputEventKey) -> bool:
	if not event.pressed or event.echo:
		return false
	for action in INPUT_ACTIONS:
		if _tape_open and not (String(action).begins_with("game_tape") or action == "game_close" or action == "game_restart"):
			continue
		if event.is_action_pressed(action):
			return handle_action(action)
	return false


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
	_camera_session.burned.connect(_on_camera_burned)
	_camera_session.cooldown_changed.connect(_on_camera_cooldown)
	_guide_bus.hint_sent.connect(_on_hint_sent)
	_loop_manager.round_started.connect(_on_loop_round_started)
	_loop_manager.round_ended.connect(_on_loop_round_ended)
	_dialogue_controller.error_occurred.connect(_on_dialogue_error)


## 把场景里的 C1–C4 Camera3D 接成真正的画面；缺失时退化为总览，不中止启动。
func _bind_camera_views() -> void:
	_overview_camera = get_node_or_null(OVERVIEW_CAMERA_NODE) as Camera3D
	_camera_views.clear()
	var rig := get_node_or_null(CAMERA_VIEWS_NODE)
	if rig == null:
		push_warning("GameRoot: 场景缺少 %s，机位切换只更新状态" % CAMERA_VIEWS_NODE)
	else:
		for child in rig.get_children():
			if not child is Camera3D:
				continue
			var camera := child as Camera3D
			var camera_id := String(camera.name)
			camera.current = false
			_camera_views[camera_id] = camera
			var target: Variant = CAMERA_LOOK_TARGETS.get(camera_id)
			if target is Vector3:
				camera.look_at(target, Vector3.UP)
	if _overview_camera != null:
		_overview_camera.current = true
	_camera_view_id = ""


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
	_wire_npc_doors()


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


## O 提示的 OPEN_DOOR 状态需要 NPC 知道要开哪扇门；门在 NPC 之后才扫描到，
## 所以统一在 World 扫描完成后接线。没有门时保持现状（NPC 只走完路线）。
func _wire_npc_doors() -> void:
	var door = _doors.get("door_a")
	if door == null or not is_instance_valid(door):
		return
	for target_id in _npcs:
		var npc = _npcs[target_id]
		if is_instance_valid(npc) and npc.has_method("set_door_target"):
			npc.set_door_target(door)


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
	# 记逻辑状态：NPC 的 to_dict / 灯的开关 / 门的开合；门用 from_dict 复位。
	for target_id in _npcs:
		if is_instance_valid(_npcs[target_id]):
			_initial_npc_states[target_id] = _npcs[target_id].to_dict()
	for target_id in _lights:
		if is_instance_valid(_lights[target_id]):
			_initial_light_states[target_id] = bool(_lights[target_id].is_on())
	for target_id in _doors:
		if is_instance_valid(_doors[target_id]):
			_initial_door_states[target_id] = bool(_doors[target_id].is_open())


# --- 关卡数据 -------------------------------------------------------------------

func _load_level() -> void:
	load_level(LEVEL_PATH)


## 加载关卡并做机位交叉校验（可注入路径，便于测试 fallback 与差集告警）。
## 契约：level.cameras 只描述摆放，surveillance.json 是计时权威来源；不一致以 surveillance 为准。
func load_level(path: String) -> bool:
	var loader = ConfigLoaderScript.new()
	var data: Dictionary = loader.load_json(path, LEVEL_SCHEMA_PATH)
	_camera_mismatches.clear()
	if data.is_empty():
		_fail("level 配置加载失败: %s" % _join_errors(loader.last_errors))
		_level = {"id": "", "name": "", "rooms": [], "cameras": []}
		_level_cameras.assign(DEFAULT_CAMERAS)
		_refresh_hud()
		return false
	_level = data
	_level_cameras.clear()
	for entry in _level.get("cameras", []):
		if entry is Dictionary and not String(entry.get("id", "")).is_empty():
			_level_cameras.append(String(entry["id"]))
	if _level_cameras.is_empty():
		_level_cameras.assign(DEFAULT_CAMERAS)
		push_warning("GameRoot: level 没有配置机位，使用默认机位 %s" % str(DEFAULT_CAMERAS))
	_cross_check_cameras()
	_refresh_hud()
	return true


## 双向差集：level 多配 / 少配 surveillance 机位都记录到 _camera_mismatches 并 push_warning。
func _cross_check_cameras() -> void:
	var known: Dictionary = _camera_config.get_cameras()
	if known.is_empty():
		return
	for camera_id in _level_cameras:
		if not known.has(camera_id):
			_camera_mismatches.append("level 机位 %s 未在 surveillance.json 中配置" % camera_id)
	for camera_id in known:
		if not _level_cameras.has(String(camera_id)):
			_camera_mismatches.append("surveillance 机位 %s 未在关卡中配置" % camera_id)
	for mismatch in _camera_mismatches:
		push_warning("GameRoot: " + mismatch)


func _collect_npc_ids() -> void:
	_npc_ids.clear()
	var ids: Array = _npcs.keys()
	ids.sort()
	for target_id in ids:
		_npc_ids.append(String(target_id))
	_npc_index = 0


func _current_npc_id() -> String:
	if _npc_ids.is_empty():
		return ""
	return _npc_ids[clampi(_npc_index, 0, _npc_ids.size() - 1)]


# --- 输入（运行时注册，不改 project.godot） ----------------------------------------

func register_input_actions() -> void:
	for action in INPUT_ACTIONS:
		if InputMap.has_action(action):
			# 宿主动作：存在即接管，不登记所有权；若它还没绑任何键，补一个本模块的键，
			# 否则 is_action_pressed() 永远为 false。
			if InputMap.action_get_events(action).is_empty():
				var existing_event := InputEventKey.new()
				existing_event.physical_keycode = INPUT_ACTIONS[action]
				InputMap.action_add_event(action, existing_event)
			continue
		InputMap.add_action(action)
		var input_event := InputEventKey.new()
		input_event.physical_keycode = INPUT_ACTIONS[action]
		InputMap.action_add_event(action, input_event)
		_registered_actions.append(action)


func unregister_input_actions() -> void:
	for action in _registered_actions:
		if InputMap.has_action(action):
			InputMap.erase_action(action)
	_registered_actions.clear()


## 给测试 / 宿主用的动作入口：不经过 InputEvent，行为与按键一致。
func handle_action(action: String) -> bool:
	match action:
		"game_camera_1", "game_camera_2", "game_camera_3", "game_camera_4":
			return _action_switch_camera(action)
		"game_camera_off":
			leave_camera()
			_refresh_hud()
			return true
		"game_hint_follow", "game_hint_wait", "game_hint_open":
			return _action_send_hint(action)
		"game_indicator":
			return _action_toggle_indicator()
		"game_door":
			return _action_open_door()
		"game_cycle_npc":
			return _action_cycle_npc()
		"game_dialogue":
			return _action_advance_dialogue()
		"game_tape":
			_toggle_tape_panel()
			return true
		"game_tape_next":
			return _action_tape_move(1)
		"game_tape_prev":
			return _action_tape_move(-1)
		"game_tape_forward":
			return _action_tape_seek(TAPE_SEEK_STEP)
		"game_tape_back":
			return _action_tape_seek(-TAPE_SEEK_STEP)
		"game_close":
			return _action_close()
		"game_restart":
			_demo_retry()
			return true
		_:
			return false


func _action_switch_camera(action: String) -> bool:
	var index := action.substr(action.length() - 1).to_int() - 1
	if index < 0 or index >= _level_cameras.size():
		return false
	var ok := switch_camera(_level_cameras[index])
	_refresh_hud()
	return ok


func _action_send_hint(action: String) -> bool:
	var target := _current_npc_id()
	if target.is_empty():
		return false
	var ok := send_hint(target, String(HINT_TEXTS.get(action, "")))
	_refresh_hud()
	return ok


func _action_toggle_indicator() -> bool:
	if _lights.is_empty():
		return false
	var target_id := _first_target_id(_lights, "light_a")
	var current := bool(_lights[target_id].call("is_on"))
	var ok := set_indicator(target_id, not current)
	_refresh_hud()
	return ok


func _action_open_door() -> bool:
	if _doors.is_empty():
		return false
	return open_door(_first_target_id(_doors, "door_a"))


## 优先用关卡的固定 id；找不到才回落到扫描顺序（避免加一盏灯就切错目标）。
func _first_target_id(targets: Dictionary, preferred: String) -> String:
	if targets.has(preferred):
		return preferred
	return String(targets.keys()[0])


func _action_cycle_npc() -> bool:
	if _npc_ids.size() <= 1:
		return false
	_npc_index = (_npc_index + 1) % _npc_ids.size()
	_refresh_hud()
	return true


func _action_advance_dialogue() -> bool:
	if not _dialogue_controller.is_active():
		return false
	_dialogue_controller.advance()
	_refresh_hud()
	return true


func _action_close() -> bool:
	if _tape_open:
		_close_tape()
		return true
	if not String(_camera_session.get_state().get("current", "")).is_empty():
		leave_camera()
		_refresh_hud()
		return true
	return false


# --- 录像带检查 -----------------------------------------------------------------

func _setup_tape_archive() -> void:
	_tape_archive = get_node_or_null("/root/TapeArchive")


func _known_tapes() -> Array:
	if _tape_archive == null or not _tape_archive.has_method("get_known_tapes"):
		return []
	# 懒加载：只有真正需要磁带列表时才碰全局 autoload 的默认库。
	if _tape_archive.has_method("get_tapes") and _tape_archive.has_method("load_default_library"):
		if _tape_archive.get_tapes().is_empty():
			_tape_archive.load_default_library()
	return _tape_archive.get_known_tapes()


func _toggle_tape_panel() -> void:
	if _tape_open:
		_close_tape()
		return
	_tape_open = true
	_tape_index = 0
	_tape_time = 0.0
	_ensure_tape_panel()
	if _tape_panel != null:
		_tape_panel.visible = true
	_refresh_tape()


func _close_tape() -> void:
	_tape_open = false
	if _tape_panel != null:
		_tape_panel.visible = false
	_refresh_hud()


func _action_tape_move(direction: int) -> bool:
	if not _tape_open:
		return false
	var tapes := _known_tapes()
	if tapes.size() < 2:
		return false
	_tape_index = posmod(_tape_index + direction, tapes.size())
	_tape_time = 0.0
	_refresh_tape()
	return true


func _action_tape_seek(delta: float) -> bool:
	if not _tape_open:
		return false
	var tapes := _known_tapes()
	if tapes.is_empty():
		return false
	var tape = tapes[clampi(_tape_index, 0, tapes.size() - 1)]
	_tape_time = clampf(_tape_time + delta, 0.0, float(tape.duration()))
	_refresh_tape()
	return true


func _ensure_tape_panel() -> void:
	if _tape_panel != null:
		return
	_tape_panel = CanvasLayer.new()
	_tape_panel.name = "TapePanel"
	add_child(_tape_panel)
	var background := ColorRect.new()
	background.color = Color(0.04, 0.05, 0.07, 0.92)
	background.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	background.offset_top = -280.0
	_tape_panel.add_child(background)
	_tape_label = Label.new()
	_tape_label.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	_tape_label.offset_top = -264.0
	_tape_label.offset_left = 28.0
	_tape_label.offset_right = -28.0
	_tape_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	_tape_label.add_theme_font_size_override("font_size", 18)
	_tape_panel.add_child(_tape_label)
	_tape_panel.visible = false


func _refresh_tape() -> void:
	if _tape_label != null:
		_tape_label.text = "\n".join(_tape_lines())


func _tape_lines() -> Array[String]:
	var lines: Array[String] = []
	lines.append("录像带检查  ｜  T 关闭 · ← → 切带 · ↑ ↓ 快进/快退")
	var tapes := _known_tapes()
	if tapes.is_empty():
		lines.append("")
		lines.append("（还没有已发现的录像带）")
		return lines
	var index := clampi(_tape_index, 0, tapes.size() - 1)
	var tape = tapes[index]
	lines.append("")
	lines.append("第 %d/%d 盘：%s" % [index + 1, tapes.size(), tape.display_name()])
	lines.append("时长 %s  ｜  当前 %s" % [
		tape.format_seconds(tape.duration()), tape.format_seconds(_tape_time)])
	var events: Array = tape.events_between(-1.0, _tape_time)
	lines.append("")
	if events.is_empty():
		lines.append("（这一刻还没有事件）")
	else:
		for entry in events:
			lines.append("· %s  %s" % [
				tape.format_seconds(float(entry.get("t", 0.0))), String(entry.get("event", ""))])
	var clues := _clues_up_to(tape)
	if not clues.is_empty():
		lines.append("")
		lines.append("线索：")
		for clue in clues:
			lines.append("· " + String(clue))
	return lines


## ClueManager 的 timeline 线索（绝对时间）落在 [带首, 带首 + 当前相对时间]。
func _clues_up_to(tape) -> Array[String]:
	var result: Array[String] = []
	var clues = get_node_or_null("/root/ClueManager")
	if clues == null:
		return result
	var limit := float(tape.time_start) + _tape_time
	for clue in clues.get_timeline_clues():
		if not clue is Dictionary:
			continue
		# 实时（live）线索不属于录像带回放，跳过。
		if String(clue.get("source", "")) == "live":
			continue
		var at := float(clue.get("t", -1.0))
		if at < float(tape.time_start) or at > limit:
			continue
		result.append("%s  %s: %s → %s" % [
			tape.format_seconds(at - float(tape.time_start)),
			String(clue.get("type", "")),
			String(clue.get("actor", "")),
			String(clue.get("target", "")),
		])
	return result


func get_tape_state() -> Dictionary:
	var tapes := _known_tapes()
	var tape_id := ""
	var duration := 0.0
	var time := 0.0
	var index := _tape_index
	if not tapes.is_empty():
		index = clampi(_tape_index, 0, tapes.size() - 1)
		var tape = tapes[index]
		tape_id = String(tape.tape_id)
		duration = float(tape.duration())
		time = _tape_time
	return {
		"open": _tape_open,
		"index": index,
		"known_count": tapes.size(),
		"tape_id": tape_id,
		"time": time,
		"duration": duration,
	}


# --- 可玩 demo（序章） -----------------------------------------------------------

## 3 轮目标：每轮限时把朋友（npc_imaginary）引导到门口。
## 到达 = NPC 的 waypoint_index 走完 route 并进入 WAIT；超时 = 本轮失败，按 R 重试。
## 分数 = 每轮 100 + 剩余秒数，烧毁摄像头每台 -30（永久烧毁，符合 M16）。
func start_demo() -> void:
	if not _npcs.has(DEMO_TARGET_NPC):
		_fail("demo 目标 NPC %s 不存在" % DEMO_TARGET_NPC)
	if _tape_open:
		_close_tape()
	# R 通关重玩 = 新开一局：分数、轮次、烧毁机位、当前画面一起清空。
	# 同一局内的 restart_round 仍保留烧毁（M16），两者语义不同。
	if is_instance_valid(_camera_session):
		_camera_session.reset()
		_set_camera_view("")
	_demo_round = 1
	_demo_score = 0
	_demo_phase = "playing"
	_begin_demo_round(true)


func is_demo_active() -> bool:
	return _demo_phase == "playing"


func get_demo_state() -> Dictionary:
	return {
		"phase": _demo_phase,
		"round": _demo_round,
		"rounds": DEMO_ROUNDS,
		"time_left": _demo_time_left,
		"score": _demo_score,
		"message": _demo_message,
		"burned": _burned_cameras(),
	}


func _begin_demo_round(discover_tape: bool = true) -> void:
	_demo_time_left = DEMO_ROUND_TIME
	_demo_round_burned = _burned_cameras()
	_demo_message = "第 %d/%d 轮：按 F 让朋友跟上，带他到门口" % [_demo_round, DEMO_ROUNDS]
	if _loop_manager.get_round_index() == 0:
		start_round()
		reset_for_loop(0.0)
	else:
		restart_round(0.0)
	if discover_tape:
		_discover_next_tape()
	_ensure_demo_hud()
	_refresh_demo_hud()


func _update_demo(delta: float) -> void:
	if _demo_phase != "playing":
		return
	_demo_time_left = maxf(0.0, _demo_time_left - delta)
	_apply_burn_penalty()
	if _demo_target_arrived():
		_complete_demo_round()
	elif _demo_time_left <= 0.0:
		_demo_fail("超时")
	_refresh_demo_hud()


func _demo_target_arrived() -> bool:
	var npc = _npcs.get(DEMO_TARGET_NPC)
	if npc == null or not is_instance_valid(npc):
		return false
	var npc_state: Dictionary = npc.get_state()
	return String(npc_state.get("state", "")) == "WAIT" \
		and int(npc_state.get("route_size", 0)) > 0 \
		and int(npc_state.get("waypoint_index", 0)) >= int(npc_state.get("route_size", 0))


func _apply_burn_penalty() -> void:
	for camera_id in _burned_cameras():
		if _demo_round_burned.has(camera_id):
			continue
		_demo_round_burned.append(camera_id)
		_demo_score -= DEMO_BURN_PENALTY
		_demo_message = "摄像头 %s 过载烧毁，扣 %d 分" % [camera_id, DEMO_BURN_PENALTY]


func _complete_demo_round() -> void:
	_demo_score += DEMO_ROUND_SCORE + int(ceil(_demo_time_left))
	if _round_active:
		end_round({"outcome": "won"})
	if _demo_round >= DEMO_ROUNDS:
		_demo_phase = "won"
		_demo_message = "演示通关 · 得分 %d（按 R 重玩）" % _demo_score
	else:
		_demo_round += 1
		_begin_demo_round()


func _demo_fail(reason: String) -> void:
	_demo_phase = "lost"
	_demo_message = "本轮失败：%s（按 R 重试）" % reason
	if _round_active:
		end_round({"outcome": "timeout"})


func _demo_retry() -> void:
	if _demo_phase == "lost":
		# 失败后计时仍在跑（tick 继续推进摄像头），重试前把这段烧毁补扣。
		_apply_burn_penalty()
		_demo_phase = "playing"
		if _tape_open:
			_close_tape()
		_begin_demo_round(false)  # 重试不额外解锁磁带
	elif _demo_phase == "won":
		start_demo()


func _burned_cameras() -> Array[String]:
	var burned: Array[String] = []
	if not is_instance_valid(_camera_session):
		return burned
	for camera_id in _camera_session.get_state().get("burned", []):
		burned.append(String(camera_id))
	return burned


func _discover_next_tape() -> void:
	var archive = get_node_or_null("/root/TapeArchive")
	if archive == null or not archive.has_method("get_tapes"):
		return
	if archive.has_method("load_default_library") and archive.get_tapes().is_empty():
		archive.load_default_library()
	for tape in archive.get_tapes():
		if not bool(tape.known_to_player):
			archive.discover(String(tape.tape_id))
			return


func _ensure_demo_hud() -> void:
	if _demo_hud != null:
		return
	_demo_hud = CanvasLayer.new()
	_demo_hud.name = "DemoHud"
	add_child(_demo_hud)
	_demo_label = Label.new()
	_demo_label.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_demo_label.offset_left = -460.0
	_demo_label.offset_top = 20.0
	_demo_label.offset_right = -24.0
	_demo_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_demo_label.add_theme_font_size_override("font_size", 18)
	_demo_hud.add_child(_demo_label)


func _refresh_demo_hud() -> void:
	if _demo_label == null:
		return
	if _demo_phase == "playing":
		_demo_label.text = "第 %d/%d 轮 ｜ 剩余 %ds ｜ 得分 %d\n%s" % [
			_demo_round, DEMO_ROUNDS, int(ceil(_demo_time_left)), _demo_score, _demo_message]
	else:
		_demo_label.text = "第 %d/%d 轮 ｜ 得分 %d\n%s" % [
			_demo_round, DEMO_ROUNDS, _demo_score, _demo_message]


# --- HUD -----------------------------------------------------------------------

func _refresh_hud() -> void:
	var hint_label := get_node_or_null("UI/Hint") as Label
	if hint_label == null:
		return
	var current := ""
	if is_instance_valid(_camera_session):
		current = String(_camera_session.get_state().get("current", ""))
	var camera_text := current if not current.is_empty() else "—"
	var level_name := String(_level.get("name", ""))
	if level_name.is_empty():
		level_name = "（关卡未加载）"
	var npc := _current_npc_id()
	hint_label.text = "关卡：%s ｜ 机位：%s ｜ 提示对象：%s（Tab 切换）\n1–4 机位 · 0 离开 · F 跟随 · G 等待 · O 开门 · I 灯 · H 门 · Space 对话 · T 录像带" % [
		level_name, camera_text, npc if not npc.is_empty() else "—"]
	var camera_status := get_node_or_null("UI/CameraStatus") as Label
	if camera_status != null:
		camera_status.text = _camera_status_text()


## HUD 的机位状态：当前画面 + 每台机位的烧毁/冷却/使用中。所有数值来自 CameraSession。
func _camera_status_text() -> String:
	if not is_instance_valid(_camera_session):
		return "画面：—"
	var camera_state: Dictionary = _camera_session.get_state()
	var current := String(camera_state.get("current", ""))
	var burned: Array = camera_state.get("burned", [])
	var cooldowns: Dictionary = camera_state.get("cooldowns", {})
	var parts: Array[String] = []
	for raw_id in _level_cameras:
		var camera_id := String(raw_id)
		if burned.has(camera_id):
			parts.append("%s 烧毁" % camera_id)
		elif cooldowns.has(camera_id):
			parts.append("%s 冷却 %.1fs" % [camera_id, float(cooldowns[camera_id])])
		elif current == camera_id:
			parts.append("%s 使用中 %.1fs" % [camera_id, float(camera_state.get("remain", 0.0))])
		else:
			parts.append(camera_id)
	var view_text := "总览" if _camera_view_id.is_empty() else _camera_view_id
	return "画面：%s ｜ %s" % [view_text, " · ".join(parts)]


func get_level_state() -> Dictionary:
	return {
		"id": String(_level.get("id", "")),
		"name": String(_level.get("name", "")),
		"room_count": (_level.get("rooms", []) as Array).size(),
		"cameras": _level_cameras.duplicate(),
		"camera_mismatches": _camera_mismatches.duplicate(),
		"hint_target": _current_npc_id(),
	}


# --- 时钟 ---------------------------------------------------------------------

## 宿主每帧调用：推进摄像头停留 / 冷却与场景里可 tick 的引导目标。
func tick(delta: float) -> void:
	if delta <= 0.0 or not is_finite(delta):
		return
	# 录像带检查面板是暂停界面：打开时世界时间、机位停留、敌人巡逻全部冻结。
	if _tape_open:
		return
	if is_instance_valid(_camera_session):
		_camera_session.tick(delta)
	for target_id in _npcs:
		var npc = _npcs[target_id]
		if is_instance_valid(npc) and npc.has_method("tick"):
			npc.tick(delta)
	_update_demo(delta)
	# 当前机位的停留倒计时需要连续刷新，否则 HUD 只在切换/烧毁时更新。
	if is_instance_valid(_camera_session) \
			and not String(_camera_session.get_state().get("current", "")).is_empty():
		_refresh_hud()


# --- 摄像头（W1） ---------------------------------------------------------------

func switch_camera(camera_id: String) -> bool:
	if not is_instance_valid(_camera_session):
		return false
	var ok := bool(_camera_session.enter(camera_id))
	if ok:
		_set_camera_view(camera_id)
	_refresh_hud()
	return ok


func leave_camera() -> void:
	if not is_instance_valid(_camera_session):
		return
	var current := String(_camera_session.get_state().get("current", ""))
	if not current.is_empty():
		_camera_session.leave(current)
		_set_camera_view("")
		_refresh_hud()


## 画面切换：找不到对应 Camera3D 时回总览，不让逻辑状态和画面脱节。
func _set_camera_view(camera_id: String) -> void:
	var target: Camera3D = null
	if not camera_id.is_empty() and _camera_views.has(camera_id):
		target = _camera_views[camera_id] as Camera3D
		_camera_view_id = camera_id
	else:
		_camera_view_id = ""
		target = _overview_camera
	if target != null:
		target.current = true


func _on_camera_burned(camera_id: String) -> void:
	if _camera_view_id == camera_id:
		_set_camera_view("")
	_refresh_hud()


func _on_camera_cooldown(_camera_id: String, _remain: float) -> void:
	_refresh_hud()


func get_camera_view_state() -> Dictionary:
	var view_ids: Array[String] = []
	for camera_id in _camera_views:
		view_ids.append(String(camera_id))
	view_ids.sort()
	return {
		"view": _camera_view_id,
		"overview": _camera_view_id.is_empty(),
		"views": view_ids,
	}


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
		_set_camera_view("")
	for target_id in _npcs:
		var npc = _npcs[target_id]
		if is_instance_valid(npc) and _initial_npc_states.has(target_id):
			npc.from_dict((_initial_npc_states[target_id] as Dictionary).duplicate(true))
	for target_id in _lights:
		var light = _lights[target_id]
		if is_instance_valid(light) and _initial_light_states.has(target_id):
			light.set_on(bool(_initial_light_states[target_id]))
	for target_id in _doors:
		var door = _doors[target_id]
		if is_instance_valid(door) and _initial_door_states.has(target_id):
			door.from_dict({"open": bool(_initial_door_states[target_id])})
	_refresh_hud()


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
		"camera_view": get_camera_view_state(),
		"guide": _guide_bus.get_state() if is_instance_valid(_guide_bus) else {},
		"loop": {
			"round": _loop_manager.get_round_index() if is_instance_valid(_loop_manager) else 0,
			"history": _loop_manager.get_history() if is_instance_valid(_loop_manager) else [],
		},
		"dialogue": _dialogue_controller.get_state() if is_instance_valid(_dialogue_controller) else {},
		"style": _style_controller.get_state() if is_instance_valid(_style_controller) else {},
		"round_active": _round_active,
		"level": get_level_state(),
		"tape": get_tape_state(),
		"input_actions": _registered_actions.duplicate(),
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
