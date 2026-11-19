extends "res://scripts/monitor_grid.gd"
## integrated_sim：二面世界的集成 simulation。
##
## - 第一阶段（Issue #3）：只读回放 —— 复用 MonitorGrid（基类 transition）、
##   TapeResource / TapeArchive、TimeManager、ClueManager；每帧
##   TapeSampler.sample(tape, playback_time) → SimWorld.apply_state()；
##   ReplayEventDispatcher 决定何时把事件登记成 archive 线索（(last, now] 窗口）。
## - 第二阶段（Issue #6）：实时推进 —— present_time 从 45 开始走，LiveRuntime 按同一
##   EventTimeline 采样并叠加 live 覆盖后 apply_state()；放大视图里可拖拽
##   Key_01 / Switch_01（回放模式禁止）；实时新事件登记为 source="live" 线索。
##
## 两阶段共用同一套接口：apply_state 是唯一状态写入口，
## ClueManager.register_clue(t, type, actor, target, cause, source) 签名不变。

const SimTimeline = preload("res://scripts/sim/sim_timeline.gd")
const TapeSampler = preload("res://scripts/sim/tape_sampler.gd")
const ReplayControllerScript = preload("res://scripts/sim/replay_controller.gd")
const ReplayEventDispatcherScript = preload("res://scripts/sim/replay_event_dispatcher.gd")
const LiveRuntimeScript = preload("res://scripts/sim/live_runtime.gd")
const TapeResourceScript = preload("res://scripts/tapes/tape_resource.gd")

## 实时/回放的分界时刻：录像带只覆盖 [0,45)，45 之后才是「现在」。
const LIVE_START_TIME := 45.0
## 实时时钟流速（1x = 真实时间）。
const LIVE_TIME_SCALE := 1.0
## 拖拽拾取半径（世界单位，按射线到道具中心的距离判定）。
const PICK_RADIUS := 1.2
const PICKABLE_PROPS: Array[String] = ["Key_01", "Switch_01"]
const MAP_DRAG_LIMIT := 9.5
## 4 路监控 = 地图四角俯视，目标都是地图中心；机位抬高到越过边界墙，
## 否则近端墙体会挡住半个画面。
const CELL_CAMERA_TARGETS: Array[Vector3] = [
	Vector3(0.0, 0.8, 0.0),
	Vector3(0.0, 0.8, 0.0),
	Vector3(0.0, 0.8, 0.0),
	Vector3(0.0, 0.8, 0.0),
]
const CELL_CAMERA_OFFSETS: Array[Vector3] = [
	Vector3(-15.0, 19.0, -15.0),
	Vector3(15.0, 19.0, -15.0),
	Vector3(-15.0, 19.0, 15.0),
	Vector3(15.0, 19.0, 15.0),
]
const SPEEDS: Array[float] = [0.5, 1.0, 2.0]

enum Mode { LIVE, REPLAY }

var timeline: Dictionary = {}
var mode: Mode = Mode.LIVE
var tapes: Array = []

var _replay: Node = null
var _dispatcher: Node = null
var _live_runtime: Node = null
var _time_manager: Node = null
var _clue_manager: Node = null
var _tape_archive: Node = null
var _active_tape_id := ""
var _syncing_scrub := false
## 拖拽状态
var _dragging := false
var _drag_prop_name := ""
var _drag_message := ""
var _drag_message_until_msec := 0

@onready var _sim_world: Node3D = $World/SimWorld
@onready var _clue_board = $Chrome/ClueBoard
@onready var _tape_buttons: HBoxContainer = $Chrome/TopBar/VBox/TransportRow/TapeButtons
@onready var _speed_buttons: HBoxContainer = $Chrome/TopBar/VBox/TransportRow/SpeedButtons
@onready var _play_pause_button: Button = $Chrome/TopBar/VBox/TransportRow/PlayPauseButton
@onready var _playback_label: Label = $Chrome/TopBar/VBox/HeaderRow/PlaybackLabel
@onready var _mode_button: Button = $Chrome/TopBar/VBox/HeaderRow/ModeButton
@onready var _time_label: Label = $Chrome/TopBar/VBox/HeaderRow/TimeLabel
@onready var _scrub: HSlider = $Chrome/TopBar/VBox/ScrubRow/ScrubBar
@onready var _scrub_label: Label = $Chrome/TopBar/VBox/ScrubRow/ScrubLabel


func _ready() -> void:
	_time_manager = get_node_or_null("/root/TimeManager")
	_clue_manager = get_node_or_null("/root/ClueManager")
	_tape_archive = get_node_or_null("/root/TapeArchive")

	timeline = SimTimeline.build()
	_build_tapes()

	cell_targets = CELL_CAMERA_TARGETS
	cell_offsets = CELL_CAMERA_OFFSETS
	chrome_root = $Chrome
	super._ready()

	_setup_replay()
	_setup_live()
	_setup_ui()
	if _clue_board != null:
		_clue_board.setup(_clue_manager)
	_boot_live()


# --- 启动 ---------------------------------------------------------------------

## 第二阶段：实时视图从 t=45 开始推进（第一阶段是冻结在 45 的静帧）。
## 注意：present_time / speed 是全局 autoload TimeManager 的状态，本场景按「谁在实时
## 谁负责驱动」的约定独占使用它（回放时冻结、实时 1x 推进）。
func _boot_live() -> void:
	mode = Mode.LIVE
	_active_tape_id = ""
	if _time_manager != null:
		_time_manager.present_time = LIVE_START_TIME
		_time_manager.speed = LIVE_TIME_SCALE
	_apply_live_frame(LIVE_START_TIME)
	_refresh_ui()


func _build_tapes() -> void:
	for entry in timeline.get("tapes", []):
		var tape = TapeResourceScript.new()
		tape.tape_id = String(entry["tape_id"])
		tape.label = String(entry["label"])
		tape.time_start = float(entry["time_start"])
		tape.time_end = float(entry["time_end"])
		tape.known_to_player = true
		# 带内相对事件：给 TapeResource / TimeManager 的档案接口用；
		# integrated_sim 的回放采样走全局 EventTimeline（TapeSampler），不消费这份副本。
		for event in timeline.get("events", []):
			var at := float((event as Dictionary)["t"])
			if at > tape.time_start and at <= tape.time_end:
				tape.event_timeline.append({
					"t": at - tape.time_start,
					"event": "%s %s" % [String(event["type"]), String(event["target"])],
				})
		tapes.append(tape)
		if _tape_archive != null:
			_tape_archive.register_tape(tape)


func _setup_replay() -> void:
	_replay = ReplayControllerScript.new()
	_replay.name = "ReplayController"
	add_child(_replay)
	_dispatcher = ReplayEventDispatcherScript.new()
	_dispatcher.name = "ReplayEventDispatcher"
	add_child(_dispatcher)

	_replay.ticked.connect(_on_replay_ticked)
	_replay.seeked.connect(_on_replay_seeked)
	_replay.state_changed.connect(_refresh_ui)
	_dispatcher.event_dispatched.connect(_on_event_dispatched)


func _setup_live() -> void:
	_live_runtime = LiveRuntimeScript.new()
	_live_runtime.name = "LiveRuntime"
	add_child(_live_runtime)
	_live_runtime.setup(timeline, _sim_world, _clue_manager)


## 实时每帧：先按 same EventTimeline 采样 + live 覆盖算出状态并交给 apply_state，
## 再跑交互判定（判定结果写进 live 覆盖，下一帧生效）。
func _apply_live_frame(now: float) -> void:
	if _live_runtime != null:
		_live_runtime.step(now)
		_apply_state(_live_runtime.compose(now))
	else:
		_apply_state(SimTimeline.state_at(timeline, now))


func _process(_delta: float) -> void:
	if mode != Mode.LIVE or _live_runtime == null:
		return
	var now := float(_time_manager.present_time) if _time_manager != null else LIVE_START_TIME
	var duration := float(timeline.get("duration", SimTimeline.DURATION))
	if now >= duration:
		# 时间线走完就停在末帧，避免 present_time 跑出快照范围。
		now = duration
		if _time_manager != null:
			_time_manager.speed = 0.0
	_apply_live_frame(now)
	_refresh_clock()


func _setup_ui() -> void:
	for tape in tapes:
		var button := Button.new()
		button.name = "Tape_%s" % String(tape.tape_id)
		button.text = "%s · %s" % [String(tape.tape_id), String(tape.label)]
		button.pressed.connect(_on_tape_pressed.bind(String(tape.tape_id)))
		_tape_buttons.add_child(button)

	for value in SPEEDS:
		var button := Button.new()
		button.name = "Speed_%s" % value
		button.text = "%sx" % value
		button.pressed.connect(_on_speed_pressed.bind(value))
		_speed_buttons.add_child(button)

	_play_pause_button.pressed.connect(_on_play_pause_pressed)
	_mode_button.pressed.connect(_on_mode_pressed)
	_scrub.step = 0.1
	_scrub.min_value = 0.0
	_scrub.max_value = LIVE_START_TIME
	_syncing_scrub = true
	_scrub.value = 0.0
	_syncing_scrub = false
	_scrub.value_changed.connect(_on_scrub_changed)


# --- 回放 ---------------------------------------------------------------------

func open_tape(tape_id: String) -> void:
	var tape = _find_tape(tape_id)
	if tape == null:
		push_warning("没有这盘带: %s" % tape_id)
		return
	mode = Mode.REPLAY
	_active_tape_id = tape_id
	# 回放期间冻结实时时钟：否则「切回实时」时 present_time 已经跑到别处。
	if _time_manager != null:
		_time_manager.speed = 0.0
	_replay.open_tape(tape)
	_dispatcher.reset(timeline, float(tape.time_start))
	_sync_scrub_range(tape)
	_apply_state(TapeSampler.sample(timeline, tape, _replay.playback_time))
	_refresh_ui()


func play() -> void:
	if mode != Mode.REPLAY or _replay == null or _replay.tape == null:
		return
	if _replay.playback_time >= float(_replay.tape.time_end) - 0.001:
		_replay.seek(float(_replay.tape.time_start))
	_replay.set_paused(false)
	_refresh_ui()


func pause() -> void:
	if _replay == null:
		return
	_replay.set_paused(true)
	_refresh_ui()


func set_speed(value: float) -> void:
	if _replay == null:
		return
	_replay.set_speed(value)
	_refresh_ui()


func seek(value: float) -> void:
	if mode != Mode.REPLAY or _replay == null:
		return
	_replay.seek(value)
	_refresh_ui()


## 返回实时视图：先按 present_time 完整 apply_state 一次（含 live 覆盖），避免从回放画面跳变。
## 回放里被拖过/改写过的道具，也在这里被 live 状态覆盖回来。
func enter_live() -> void:
	mode = Mode.LIVE
	_active_tape_id = ""
	if _replay != null:
		_replay.close()
	if _time_manager != null:
		_time_manager.speed = LIVE_TIME_SCALE
	var now := float(_time_manager.present_time) if _time_manager != null else LIVE_START_TIME
	_apply_live_frame(now)
	_refresh_ui()


# --- 道具拖拽（只有实时模式 + 放大视图可拖） -----------------------------------

## 程序入口也用于 eval/测试：回放模式下返回 false 且不改变任何状态。
func drag_prop_to(prop_name: String, ground_pos: Vector3) -> bool:
	if mode != Mode.LIVE or _live_runtime == null:
		_set_drag_message("回放中不可拖拽道具")
		return false
	if not _live_runtime.drag_prop(prop_name, ground_pos):
		return false
	var now := float(_time_manager.present_time) if _time_manager != null else LIVE_START_TIME
	_apply_state(_live_runtime.compose(now))
	_set_drag_message("拖拽 %s → %.1f, %.1f" % [prop_name, ground_pos.x, ground_pos.z])
	return true


func _gui_input(event: InputEvent) -> void:
	super._gui_input(event)

	var motion := event as InputEventMouseMotion
	if motion != null and _dragging:
		if _live_runtime != null:
			drag_prop_to(_drag_prop_name, _ground_point(motion.position))
		accept_event()
		return

	var button := event as InputEventMouseButton
	if button == null or button.button_index != MOUSE_BUTTON_LEFT:
		return

	if not button.pressed:
		if _dragging:
			_dragging = false
			_drag_prop_name = ""
			accept_event()
		return

	if state != FocusState.FOCUSED:
		return
	var picked := _pick_prop_at(button.position)
	if picked.is_empty():
		return
	if mode != Mode.LIVE:
		# 回放里允许玩家尝试，但明确拒绝：道具位置不变。
		_set_drag_message("回放中不可拖拽道具")
		accept_event()
		return
	_dragging = true
	_drag_prop_name = picked
	accept_event()


## 屏幕坐标 → 放大视图相机的射线（ZoomViewport 与窗口同尺寸，1:1 映射）。
func _ray_for_screen(screen_pos: Vector2) -> Dictionary:
	var window_size := get_viewport().get_visible_rect().size
	var zoom_size := Vector2(_zoom_viewport.size)
	var viewport_pos := Vector2(screen_pos.x / maxf(window_size.x, 1.0) * zoom_size.x,
		screen_pos.y / maxf(window_size.y, 1.0) * zoom_size.y)
	return {
		"origin": _zoom_camera.project_ray_origin(viewport_pos),
		"normal": _zoom_camera.project_ray_normal(viewport_pos),
	}


## 射线拾取：取射线到道具中心距离最近且在半径内的那个。
func _pick_prop_at(screen_pos: Vector2) -> String:
	if _sim_world == null or _zoom_camera == null:
		return ""
	var ray := _ray_for_screen(screen_pos)
	var origin: Vector3 = ray["origin"]
	var direction: Vector3 = ray["normal"]
	var best := ""
	var best_distance := INF
	for prop_name in PICKABLE_PROPS:
		var node: Node3D = _sim_world.get_prop_node(prop_name)
		if node == null:
			continue
		var center := node.global_position
		var along := (center - origin).dot(direction)
		if along <= 0.05:
			continue
		var closest := origin + direction * along
		if closest.distance_to(center) <= PICK_RADIUS and along < best_distance:
			best = prop_name
			best_distance = along
	return best


## 射线与地面（y=0）交点，并夹在地图范围内。
func _ground_point(screen_pos: Vector2) -> Vector3:
	var ray := _ray_for_screen(screen_pos)
	var origin: Vector3 = ray["origin"]
	var direction: Vector3 = ray["normal"]
	if absf(direction.y) < 0.0001:
		return Vector3.ZERO
	var distance := -origin.y / direction.y
	if distance <= 0.0:
		return Vector3.ZERO
	var point := origin + direction * distance
	return Vector3(clampf(point.x, -MAP_DRAG_LIMIT, MAP_DRAG_LIMIT), 0.0,
		clampf(point.z, -MAP_DRAG_LIMIT, MAP_DRAG_LIMIT))


func _on_tape_pressed(tape_id: String) -> void:
	open_tape(tape_id)


func _on_play_pause_pressed() -> void:
	if _replay == null:
		return
	if _replay.paused:
		play()
	else:
		pause()


func _on_speed_pressed(value: float) -> void:
	set_speed(value)


func _on_mode_pressed() -> void:
	if mode == Mode.REPLAY:
		enter_live()
	else:
		open_tape(String(tapes[0].tape_id) if not tapes.is_empty() else "TAPE-01")


func _on_scrub_changed(value: float) -> void:
	if _syncing_scrub or mode != Mode.REPLAY or _replay == null:
		return
	seek(value)


func _sync_scrub_range(tape) -> void:
	_syncing_scrub = true
	_scrub.min_value = float(tape.time_start)
	_scrub.max_value = float(tape.time_end)
	_scrub.value = clampf(float(tape.time_start), _scrub.min_value, _scrub.max_value)
	_syncing_scrub = false


# --- 回放 → 状态 / 事件 --------------------------------------------------------

func _on_replay_ticked(_previous: float, current: float) -> void:
	_dispatcher.advance(current)
	_apply_state(TapeSampler.sample(timeline, _replay.tape, current))
	_refresh_ui()


func _on_replay_seeked(_previous: float, current: float, forward: bool) -> void:
	# 向前 seek 只重建状态不补播事件；向后 seek 让窗口起点一起回退。
	_dispatcher.seek(current, forward)
	_apply_state(TapeSampler.sample(timeline, _replay.tape, current))
	_refresh_ui()


func _on_event_dispatched(entry: Dictionary) -> void:
	if _clue_manager == null:
		return
	_clue_manager.register_clue(
		float(entry.get("t", 0.0)),
		String(entry.get("type", "")),
		String(entry.get("actor", "")),
		String(entry.get("target", "")),
		String(entry.get("cause", "")),
		"archive"
	)


func _apply_state(state: Dictionary) -> void:
	if _sim_world != null:
		_sim_world.apply_state(state)


# --- UI ----------------------------------------------------------------------

func _refresh_ui() -> void:
	if _time_label == null:
		return
	var present := float(_time_manager.present_time) if _time_manager != null else LIVE_START_TIME
	if mode == Mode.LIVE:
		_mode_button.text = "回放"
		_play_pause_button.disabled = true
		_play_pause_button.text = "播放"
		_scrub.editable = false
		_scrub_label.text = "—"
		# 回到实时后进度条不再代表上一盘带，恢复成实时时间轴 0–45。
		_scrub.min_value = 0.0
		_scrub.max_value = LIVE_START_TIME
		_syncing_scrub = true
		_scrub.value = clampf(present, _scrub.min_value, _scrub.max_value)
		_syncing_scrub = false
		_refresh_clock()
	else:
		_mode_button.text = "返回实时"
		_time_label.text = "回放 %05.1fs" % _replay.playback_time
		_play_pause_button.disabled = false
		_play_pause_button.text = "播放" if _replay.paused else "暂停"
		_scrub.editable = true
		_syncing_scrub = true
		_scrub.value = clampf(_replay.playback_time, _scrub.min_value, _scrub.max_value)
		_syncing_scrub = false
		_playback_label.text = "%s · %s · %.1fx" % [
			_active_tape_id,
			"暂停" if _replay.paused else "播放中",
			_replay.speed,
		]
		_scrub_label.text = "%.1fs / %.0fs" % [
			_replay.playback_time,
			float(_replay.tape.time_end) if _replay.tape != null else LIVE_START_TIME,
		]
		if not _drag_message.is_empty() and Time.get_ticks_msec() < _drag_message_until_msec:
			_playback_label.text = _drag_message


# --- 实时 UI ------------------------------------------------------------------

## 实时时钟标签 + 操作提示（拖拽被拒绝时临时显示原因）。
func _refresh_clock() -> void:
	if _time_label == null:
		return
	var now := float(_time_manager.present_time) if _time_manager != null else LIVE_START_TIME
	_time_label.text = "实时 %05.1fs" % now
	if _playback_label != null:
		_playback_label.text = _live_hint_text()


func _live_hint_text() -> String:
	if not _drag_message.is_empty() and Time.get_ticks_msec() < _drag_message_until_msec:
		return _drag_message
	return "实时推进中 · 可拖拽道具"


func _set_drag_message(text: String) -> void:
	_drag_message = text
	_drag_message_until_msec = Time.get_ticks_msec() + 2500


# --- 运行时查询（godot-bridge eval 验证用） ------------------------------------

func get_sim_snapshot() -> Dictionary:
	var sim: Dictionary = _sim_world.get_state_snapshot() if _sim_world != null else {"agents": {}, "props": {}, "apply_count": 0}
	return {
		"mode": "LIVE" if mode == Mode.LIVE else "REPLAY",
		"focus_state": get_state_name(),
		"present_time": float(_time_manager.present_time) if _time_manager != null else -1.0,
		"clock_speed": float(_time_manager.speed) if _time_manager != null else -1.0,
		"playback_time": _replay.playback_time if _replay != null else 0.0,
		"paused": _replay.paused if _replay != null else true,
		"speed": _replay.speed if _replay != null else 1.0,
		"tape_id": _active_tape_id,
		"agents": sim["agents"],
		"props": sim["props"],
		"apply_count": sim["apply_count"],
		"clue_count": _clue_manager.timeline_clue_count() if _clue_manager != null else 0,
		"live_clue_count": _count_live_clues(),
		"clues": _clue_manager.get_timeline_clues() if _clue_manager != null else [],
		"live": _live_runtime.get_state() if _live_runtime != null else {},
		"drag_message": _live_hint_text(),
	}


## 按 source 统计 live 线索（timeline_clue_count 是按 type 统计的，不能混用）。
func _count_live_clues() -> int:
	if _clue_manager == null:
		return 0
	var total := 0
	for clue in _clue_manager.get_timeline_clues():
		if String((clue as Dictionary).get("source", "")) == "live":
			total += 1
	return total


func get_tape_list() -> Array:
	var result: Array = []
	for tape in tapes:
		result.append({"tape_id": String(tape.tape_id), "label": String(tape.label),
			"time_start": float(tape.time_start), "time_end": float(tape.time_end)})
	return result


func get_clue_board_snapshot() -> Dictionary:
	return {
		"rows": _clue_board.get_row_count() if _clue_board != null else 0,
		"clues": _clue_manager.get_timeline_clues() if _clue_manager != null else [],
	}


func _find_tape(tape_id: String):
	for tape in tapes:
		if String(tape.tape_id) == tape_id:
			return tape
	return null
