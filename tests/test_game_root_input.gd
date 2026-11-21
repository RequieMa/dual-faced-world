extends SceneTree
## 玩法层输入 + 关卡数据测试（Issue #21 下一步）。
## 运行：godot --headless --path . --script tests/test_game_root_input.gd
## 退出码 0 = 全绿，1 = 有用例失败。
##
## 覆盖：
## - `resources/data/levels/theater.json` 能通过 `level.schema.json` 校验；
## - GameRoot 加载关卡并暴露 `get_level_state()`；
## - 运行时注册输入动作（不改 project.godot），卸载时清理；
## - `handle_action()` 驱动：切机位 / 离开 / 提示 / 灯 / 门 / 对话推进 / 录像带面板；
## - 录像带面板：开关、切带、快进快退、内容随 TapeArchive 变化。

const SCENE_PATH := "res://scenes/game_root.tscn"
const LEVEL_PATH := "res://resources/data/levels/theater.json"
const SCHEMA_PATH := "res://resources/data/schema/level.schema.json"
const CONFIG_LOADER := "res://scripts/config/config_loader.gd"

const INPUT_ACTIONS: Array[String] = [
	"game_camera_1", "game_camera_2", "game_camera_3", "game_camera_4",
	"game_camera_off", "game_hint_follow", "game_hint_wait", "game_hint_open",
	"game_indicator", "game_door", "game_cycle_npc", "game_dialogue",
	"game_tape", "game_tape_next", "game_tape_prev", "game_tape_forward",
	"game_tape_back", "game_close",
]

var _failures: Array[String] = []
var _checks: int = 0
var _started := false
var _game_root: Node = null


func _initialize() -> void:
	_check("存在 scenes/game_root.tscn", ResourceLoader.exists(SCENE_PATH))
	_check("存在关卡数据 resources/data/levels/theater.json", ResourceLoader.exists(LEVEL_PATH))
	_check("存在 level.schema.json", ResourceLoader.exists(SCHEMA_PATH))


func _process(_delta: float) -> bool:
	if _started:
		return false
	_started = true
	_run_tests()
	return false


func _run_tests() -> void:
	if not ResourceLoader.exists(SCENE_PATH):
		_report()
		return
	_test_level_data()
	_test_scene_input()
	_report()


# --- 关卡数据 ------------------------------------------------------------------

func _test_level_data() -> void:
	var loader = load(CONFIG_LOADER).new()
	var data: Dictionary = loader.load_json(LEVEL_PATH, SCHEMA_PATH)
	_check("关卡数据通过 schema 校验", not data.is_empty() and loader.last_errors.is_empty(),
		str(loader.last_errors))
	_check("关卡 id 为 theater", String(data.get("id", "")) == "theater", str(data.get("id", "")))
	_check("关卡有名称", not String(data.get("name", "")).is_empty())
	_check("关卡至少有 9 个房间", (data.get("rooms", []) as Array).size() >= 9)
	_check("关卡有 4 个热键机位", (data.get("cameras", []) as Array).size() == 4,
		str((data.get("cameras", []) as Array).size()))
	var first_room: Dictionary = (data.get("rooms", []) as Array)[0] if (data.get("rooms", []) as Array).size() > 0 else {}
	_check("房间带 id/name", first_room.has("id") and first_room.has("name"), str(first_room))


# --- 场景输入 ------------------------------------------------------------------

func _test_scene_input() -> void:
	var packed := ResourceLoader.load(SCENE_PATH) as PackedScene
	if packed == null:
		_check("game_root.tscn 可加载", false)
		return
	var instance := packed.instantiate()
	if instance == null:
		_check("game_root 可实例化", false)
		return
	if not instance.has_method("handle_action") or not instance.has_method("get_level_state"):
		_check("GameRoot 实现 handle_action / get_level_state", false)
		instance.free()
		return
	instance.auto_tick = false
	_game_root = instance
	root.add_child(_game_root)

	# 关卡已装配
	var level: Dictionary = _game_root.get_level_state()
	_check("GameRoot 加载了关卡 id", String(level.get("id", "")) == "theater", str(level))
	_check("GameRoot 暴露房间数", int(level.get("room_count", 0)) >= 9, str(level))
	var cameras: Array = level.get("cameras", [])
	_check("GameRoot 暴露 4 个机位", cameras.size() == 4, str(cameras))

	# 输入动作已注册（运行时，不写 project.godot）
	for action in INPUT_ACTIONS:
		_check("输入动作已注册: " + action, InputMap.has_action(action))

	# 切机位：动作 1 -> 关卡第 1 个机位
	_check("动作 camera_1 成功", _game_root.handle_action("game_camera_1"))
	var state: Dictionary = _game_root.get_state()
	_check("动作 camera_1 切到 C1", String(state["camera"]["current"]) == String(cameras[0]), str(state["camera"]))
	_check("动作 camera_off 离开机位", _game_root.handle_action("game_camera_off"))
	state = _game_root.get_state()
	_check("离开后 current 为空", String(state["camera"]["current"]) == "", str(state["camera"]))

	# 提示：默认目标是按 id 排序后的第一个 NPC
	var target_id := String(_game_root.get_level_state().get("hint_target", ""))
	_check("默认提示目标是 npc_imaginary（排序后第一个）", target_id == "npc_imaginary", target_id)
	_check("动作 hint_follow 成功", _game_root.handle_action("game_hint_follow"))
	var guide: Dictionary = _game_root.get_state()["guide"]
	var hinted_npc: Dictionary = guide["npcs"].get(target_id, {})
	_check("提示后目标进入 FOLLOW", String(hinted_npc.get("state", "")) == "FOLLOW", str(hinted_npc))
	_check("提示词被记录", String(hinted_npc.get("last_hint", "")) == "跟我来", str(hinted_npc))
	_check("动作 cycle_npc 切换目标", _game_root.handle_action("game_cycle_npc"))
	_check("切换后目标变化", String(_game_root.get_level_state().get("hint_target", "")) != target_id)

	# 灯 / 门
	_check("动作 indicator 切换灯", _game_root.handle_action("game_indicator"))
	var guide_after: Dictionary = _game_root.get_state()["guide"]
	_check("灯已打开", bool(guide_after["indicators"].get("light_a", false)), str(guide_after["indicators"]))
	_check("动作 indicator 再切换关闭", _game_root.handle_action("game_indicator"))
	_check("动作 door 开门", _game_root.handle_action("game_door"))
	_check("门已打开", bool(_game_root.get_state()["guide"]["doors"].get("door_a", false)))

	# 对话推进
	_check("没有对话时 dialogue 动作为 false", _game_root.handle_action("game_dialogue") == false)
	_check("开启对话", _game_root.start_dialogue("stranger_greeting"))
	_check("对话中 dialogue 动作推进一行", _game_root.handle_action("game_dialogue"))
	_check("对话推进到第 2 行", int(_game_root.get_state()["dialogue"]["index"]) == 1,
		str(_game_root.get_state()["dialogue"]))

	# 录像带检查
	var archive = root.get_node_or_null("TapeArchive")
	if archive != null:
		archive.load_default_library()
		var tapes: Array = archive.get_tapes()
		if tapes.size() > 0:
			archive.discover(String(tapes[0].tape_id))
	_check("动作 tape 打开面板", _game_root.handle_action("game_tape"))
	var tape_state: Dictionary = _game_root.get_tape_state()
	_check("录像带面板已打开", bool(tape_state.get("open", false)), str(tape_state))
	_check("面板有已发现的带", int(tape_state.get("known_count", 0)) >= 1, str(tape_state))
	var first_index := int(tape_state.get("index", 0))
	if int(tape_state.get("known_count", 0)) >= 2:
		_check("动作 tape_next 切带", _game_root.handle_action("game_tape_next"))
		var after_next: Dictionary = _game_root.get_tape_state()
		_check("切带后索引变化", int(after_next.get("index", 0)) != first_index, str(after_next))
		_check("动作 tape_prev 切回", _game_root.handle_action("game_tape_prev"))
	_check("动作 tape_forward 快进", _game_root.handle_action("game_tape_forward"))
	var seeked: Dictionary = _game_root.get_tape_state()
	_check("快进后时间增加", float(seeked.get("time", 0.0)) > 0.0, str(seeked))
	_check("动作 tape_back 回退", _game_root.handle_action("game_tape_back"))
	_check("回退后时间归零", is_equal_approx(float(_game_root.get_tape_state().get("time", 0.0)), 0.0),
		str(_game_root.get_tape_state()))
	_check("动作 tape 再按关闭面板", _game_root.handle_action("game_tape"))
	_check("面板已关闭", _game_root.get_tape_state().get("open", false) == false)

	# 卸载清理
	_game_root.unregister_input_actions()
	for action in INPUT_ACTIONS:
		_check("卸载后动作被清理: " + action, not InputMap.has_action(action))

	_game_root.queue_free()
	_game_root = null


# --- 断言 ---------------------------------------------------------------------

func _check(label: String, condition: bool, detail: String = "") -> void:
	_checks += 1
	if condition:
		print("PASS  ", label)
	else:
		var message := label
		if not detail.is_empty():
			message += "  [" + detail + "]"
		_failures.append(message)
		printerr("FAIL  ", message)


func _report() -> void:
	print("----")
	if _failures.is_empty():
		print("GAME_ROOT_INPUT_TEST_PASS (%d checks)" % _checks)
		quit(0)
	else:
		printerr("GAME_ROOT_INPUT_TEST_FAIL (%d/%d failed)" % [_failures.size(), _checks])
		for failure in _failures:
			printerr("  - ", failure)
		quit(1)
