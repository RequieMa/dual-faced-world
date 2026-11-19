extends "res://scripts/monitor_grid.gd"
## integrated_sim：二面世界的集成 simulation（第一阶段 = 只读回放）。
##
## - 复用 MonitorGrid（基类 transition）、TapeResource / TapeArchive、TimeManager、ClueManager；
## - 每帧 TapeSampler.sample(tape, playback_time) → SimWorld.apply_state()；
## - ReplayEventDispatcher 决定何时把事件登记成 archive 线索（(last, now] 窗口）；
## - 实时视图冻结在 t1=45：present_time=45、TimeManager.speed=0，不推进时钟；
## - 道具在回放中可见、状态正确，但不可拖拽（拖拽是第二阶段）。

const SimTimeline = preload("res://scripts/sim/sim_timeline.gd")
const TapeSampler = preload("res://scripts/sim/tape_sampler.gd")
const ReplayControllerScript = preload("res://scripts/sim/replay_controller.gd")
const ReplayEventDispatcherScript = preload("res://scripts/sim/replay_event_dispatcher.gd")
const TapeResourceScript = preload("res://scripts/tapes/tape_resource.gd")

## 实时/回放的分界时刻：录像带只覆盖 [0,45)，45 之后才是「现在」。
const LIVE_START_TIME := 45.0
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
var _time_manager: Node = null
var _clue_manager: Node = null
var _tape_archive: Node = null
var _active_tape_id := ""
var _syncing_scrub := false

@onready var _sim_world: Node3D = $World/SimWorld
@onready var _clue_board = $Chrome/ClueBoard
@onready var _tape_buttons: HBoxContainer = $Chrome/TopBar/VBox/TransportRow/TapeButtons
@onready var _speed_buttons: HBoxContainer = $Chrome/TopBar/VBox/TransportRow/SpeedButtons
@onready var _play_pause_button: Button = $Chrome/TopBar/VBox/TransportRow/PlayPauseButton
@onready var _playback_label: Label = $Chrome/TopBar/VBox/TransportRow/PlaybackLabel
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
	_setup_ui()
	if _clue_board != null:
		_clue_board.setup(_clue_manager)
	_boot_live()


# --- 启动 ---------------------------------------------------------------------

## 第一阶段：实时视图是 t1=45 的冻结画面（不推进时钟）。
func _boot_live() -> void:
	mode = Mode.LIVE
	_active_tape_id = ""
	if _time_manager != null:
		_time_manager.present_time = LIVE_START_TIME
		_time_manager.speed = 0.0
	_apply_state(SimTimeline.state_at(timeline, LIVE_START_TIME))
	_refresh_ui()


func _build_tapes() -> void:
	for entry in timeline.get("tapes", []):
		var tape = TapeResourceScript.new()
		tape.tape_id = String(entry["tape_id"])
		tape.label = String(entry["label"])
		tape.time_start = float(entry["time_start"])
		tape.time_end = float(entry["time_end"])
		tape.known_to_player = true
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


## 返回实时视图：先按 present_time 完整 apply_state 一次，避免从回放画面跳变。
func enter_live() -> void:
	mode = Mode.LIVE
	_active_tape_id = ""
	if _replay != null:
		_replay.close()
	_apply_realtime_state()
	_refresh_ui()


func _apply_realtime_state() -> void:
	var now := float(_time_manager.present_time) if _time_manager != null else LIVE_START_TIME
	_apply_state(SimTimeline.state_at(timeline, now))


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
	_replay.seek(value)


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
		_time_label.text = "实时 %05.1fs（冻结）" % present
		_play_pause_button.disabled = true
		_play_pause_button.text = "播放"
		_playback_label.text = "实时画面：t=45 冻结"
		_scrub.editable = false
		_scrub_label.text = "—"
		_syncing_scrub = true
		_scrub.value = clampf(present, _scrub.min_value, _scrub.max_value)
		_syncing_scrub = false
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
		"clues": _clue_manager.get_timeline_clues() if _clue_manager != null else [],
	}


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
