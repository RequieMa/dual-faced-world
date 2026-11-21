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
	"game_tape_back", "game_close", "game_restart",
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

	# 键位分发：InputMap 是唯一来源（event.is_action_pressed）
	_check("按键 2 经 dispatch_key_event 切到 C2",
		_dispatch(KEY_2) and String(_game_root.get_state()["camera"]["current"]) == String(cameras[1]),
		str(_game_root.get_state()["camera"]))
	_check("按键 3 切到 C3",
		_dispatch(KEY_3) and String(_game_root.get_state()["camera"]["current"]) == String(cameras[2]))
	_check("按键 4 切到 C4",
		_dispatch(KEY_4) and String(_game_root.get_state()["camera"]["current"]) == String(cameras[3]))
	var camera_before_echo := String(_game_root.get_state()["camera"]["current"])
	_check("echo 按键被忽略", _dispatch(KEY_1, true) == false
		and String(_game_root.get_state()["camera"]["current"]) == camera_before_echo)
	_check("未注册的按键不分发", _dispatch(KEY_K) == false)
	_check("未知动作返回 false", _game_root.handle_action("game_unknown") == false)
	_check("动作 camera_off 再次离开", _game_root.handle_action("game_camera_off"))

	# 提示：默认目标是按 id 排序后的第一个 NPC
	var target_id := String(_game_root.get_level_state().get("hint_target", ""))
	_check("默认提示目标是 npc_imaginary（排序后第一个）", target_id == "npc_imaginary", target_id)
	_check("动作 hint_follow 成功", _game_root.handle_action("game_hint_follow"))
	var guide: Dictionary = _game_root.get_state()["guide"]
	var hinted_npc: Dictionary = guide["npcs"].get(target_id, {})
	_check("提示后目标进入 FOLLOW", String(hinted_npc.get("state", "")) == "FOLLOW", str(hinted_npc))
	_check("提示词被记录", String(hinted_npc.get("last_hint", "")) == "跟我来", str(hinted_npc))
	_check("动作 hint_wait 成功", _game_root.handle_action("game_hint_wait"))
	_check("hint_wait 文案为「等待」",
		String(_game_root.get_state()["guide"]["npcs"].get(target_id, {}).get("last_hint", "")) == "等待")
	_check("动作 hint_open 成功", _game_root.handle_action("game_hint_open"))
	_check("hint_open 文案为「开门」",
		String(_game_root.get_state()["guide"]["npcs"].get(target_id, {}).get("last_hint", "")) == "开门")
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

	# 录像带检查（先发现全部默认带，才能验证切带与绕回）
	var archive = root.get_node_or_null("TapeArchive")
	if archive != null:
		archive.load_default_library()
		for tape in archive.get_tapes():
			archive.discover(String(tape.tape_id))
	_check("面板未打开时 tape_next 返回 false", _game_root.handle_action("game_tape_next") == false)
	_check("动作 tape 打开面板", _game_root.handle_action("game_tape"))
	var tape_state: Dictionary = _game_root.get_tape_state()
	_check("录像带面板已打开", bool(tape_state.get("open", false)), str(tape_state))
	_check("面板有 3 盘已发现的带", int(tape_state.get("known_count", 0)) == 3, str(tape_state))
	var first_index := int(tape_state.get("index", 0))
	_check("动作 tape_next 切带", _game_root.handle_action("game_tape_next"))
	var after_next: Dictionary = _game_root.get_tape_state()
	_check("切带后索引 +1", int(after_next.get("index", 0)) == first_index + 1, str(after_next))
	_check("动作 tape_prev 切回", _game_root.handle_action("game_tape_prev"))
	_check("切回后索引复原", int(_game_root.get_tape_state().get("index", 0)) == first_index)
	_check("tape_prev 从第一盘绕回最后一盘",
		_game_root.handle_action("game_tape_prev")
		and int(_game_root.get_tape_state().get("index", 0)) == 2,
		str(_game_root.get_tape_state()))
	_check("tape_next 从最后一盘绕回第一盘",
		_game_root.handle_action("game_tape_next")
		and int(_game_root.get_tape_state().get("index", 0)) == 0,
		str(_game_root.get_tape_state()))
	_check("动作 tape_forward 快进", _game_root.handle_action("game_tape_forward"))
	var seeked: Dictionary = _game_root.get_tape_state()
	_check("快进后时间增加", float(seeked.get("time", 0.0)) > 0.0, str(seeked))
	_check("动作 tape_back 回退", _game_root.handle_action("game_tape_back"))
	_check("回退后时间归零", is_equal_approx(float(_game_root.get_tape_state().get("time", 0.0)), 0.0),
		str(_game_root.get_tape_state()))
	_check("面板打开时按键 1 被忽略", _dispatch(KEY_1) == false
		and String(_game_root.get_state()["camera"]["current"]) == "")
	_check("动作 tape 再按关闭面板", _game_root.handle_action("game_tape"))
	_check("面板已关闭", _game_root.get_tape_state().get("open", false) == false)
	_check("没有机位时 close 返回 false", _game_root.handle_action("game_close") == false)
	# 前面切过的机位都在冷却里；推进 10 秒让冷却结束，才能验证 close 离开机位。
	_game_root.tick(10.0)
	_check("切到 C1 后 close 离开机位", _game_root.handle_action("game_camera_1")
		and _game_root.handle_action("game_close")
		and String(_game_root.get_state()["camera"]["current"]) == "",
		str(_game_root.get_state()["camera"]))

	# 关卡机位与 surveillance.json 的交叉校验
	var bad_path := "user://bad_level.json"
	var handle := FileAccess.open(bad_path, FileAccess.WRITE)
	handle.store_string("{\"id\": \"bad\", \"rooms\": [{\"id\": \"r\", \"name\": \"r\"}], \"cameras\": [{\"id\": \"C9\", \"room\": \"r\"}]}")
	handle.close()
	_check("加载含未知机位的关卡返回 true", _game_root.load_level(bad_path))
	var bad_mismatches: Array = _game_root.get_level_state().get("camera_mismatches", [])
	_check("交叉校验记录未知机位 C9", bad_mismatches.size() >= 1, str(bad_mismatches))
	_check("重新加载 theater 后差集清空",
		_game_root.load_level(LEVEL_PATH)
		and (_game_root.get_level_state().get("camera_mismatches", []) as Array).is_empty(),
		str(_game_root.get_level_state().get("camera_mismatches", [])))

	# 面板关闭后普通按键仍然生效
	_check("面板关闭后按键 2 仍可切机位",
		_dispatch(KEY_2) and String(_game_root.get_state()["camera"]["current"]) == String(cameras[1]),
		str(_game_root.get_state()["camera"]))
	_check("Esc 在机位打开时离开",
		_dispatch(KEY_ESCAPE) and String(_game_root.get_state()["camera"]["current"]) == "",
		str(_game_root.get_state()["camera"]))

	# 卸载清理
	_game_root.unregister_input_actions()
	for action in INPUT_ACTIONS:
		_check("卸载后动作被清理: " + action, not InputMap.has_action(action))

	# 预置同名动作：GameRoot 不应该删掉不属于自己的动作
	InputMap.add_action("game_hint_follow")
	var preset_event := InputEventKey.new()
	preset_event.physical_keycode = KEY_Y
	InputMap.action_add_event("game_hint_follow", preset_event)
	var second := (ResourceLoader.load(SCENE_PATH) as PackedScene).instantiate()
	second.auto_tick = false
	root.add_child(second)
	_check("预置同名动作保留", InputMap.has_action("game_hint_follow"))
	_check("预置动作不计入 GameRoot 注册列表",
		not (second.get_state().get("input_actions", []) as Array).has("game_hint_follow"),
		str(second.get_state().get("input_actions", [])))
	second.free()
	_check("第二个 GameRoot 退出后预置动作仍在", InputMap.has_action("game_hint_follow"))
	InputMap.erase_action("game_hint_follow")

	_game_root.queue_free()
	_game_root = null


# --- 断言 ---------------------------------------------------------------------

func _dispatch(physical: Key, echo: bool = false) -> bool:
	var input_event := InputEventKey.new()
	input_event.physical_keycode = physical
	input_event.pressed = true
	input_event.echo = echo
	return bool(_game_root.dispatch_key_event(input_event))


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
