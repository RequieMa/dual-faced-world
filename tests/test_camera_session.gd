extends SceneTree
## W1 摄像头会话（停留 / 过载 / 冷却 / 烧毁）的自动化测试。
## 运行：godot --headless --path . --script tests/test_camera_session.gd
## 退出码 0 = 全绿，1 = 有用例失败。
##
## 覆盖（对应 Issue #11 验收 + docs/MECHANICS_CONTRACTS.md §1 冻结接口）：
## - 停留未超时 / 超时过载烧毁；信号各一次，烧毁后 enter 失败
## - leave 进入冷却；冷却期间 enter 失败且 cooldown_changed 逐帧递减；冷却结束可再进
## - 数值由 configure 驱动（换 dwell/cooldown 行为随之变化）
## - tick(0.1) 固定步长可复现，不使用 _process
## - get_state / to_dict / from_dict 可序列化，from_dict 对缺失/坏类型健壮
## - CameraConfig 读取 surveillance.json（走 W0 ConfigLoader + schema）

const SESSION_PATH := "res://scripts/camera/camera_session.gd"
const CONFIG_PATH := "res://scripts/camera/camera_config.gd"
const SURVEILLANCE_PATH := "res://resources/data/surveillance.json"
const SURVEILLANCE_SCHEMA := "res://resources/data/schema/surveillance.schema.json"
const TEMP_DIR := "user://camera_session_test"


## 鸭子类型目标：CameraConfig.load_into 不应把 session 限定成 Node。
class FakeSession:
	extends RefCounted

	var config: Dictionary = {}

	func configure(value: Dictionary) -> void:
		config = value

var _failures: Array[String] = []
var _checks: int = 0
var _sessions: Array = []
var _events: Array = []


func _initialize() -> void:
	_check("存在 scripts/camera/camera_session.gd", ResourceLoader.exists(SESSION_PATH))
	_check("存在 scripts/camera/camera_config.gd", ResourceLoader.exists(CONFIG_PATH))
	_check("存在 resources/data/surveillance.json", ResourceLoader.exists(SURVEILLANCE_PATH))
	_check("surveillance schema 存在", ResourceLoader.exists(SURVEILLANCE_SCHEMA))
	if not ResourceLoader.exists(SESSION_PATH) or not ResourceLoader.exists(CONFIG_PATH):
		_report()
		return

	_ensure_temp_dir()
	_test_configure_and_state()
	_test_configure_defaults()
	_test_enter_leave_semantics()
	_test_dwell_progress_and_overload()
	_test_cooldown_timeline()
	_test_zero_cooldown()
	_test_switch_cameras()
	_test_multiple_cooldowns()
	_test_leave_non_current()
	_test_configure_reset()
	_test_config_driven()
	_test_deterministic_tick()
	_test_serialization()
	_test_from_dict_robustness()
	_test_surveillance_config()
	_test_camera_config_failure()
	_cleanup()
	_report()


# --- 断言与工具 ---------------------------------------------------------------

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


func _approx(actual: float, expected: float, tolerance: float = 0.0001) -> bool:
	return absf(actual - expected) <= tolerance


func _dict(value: Variant) -> Dictionary:
	return value if value is Dictionary else {}


func _array(value: Variant) -> Array:
	return value if value is Array else []


func _new_session():
	var script = load(SESSION_PATH)
	if script == null:
		return null
	var session = script.new()
	_sessions.append(session)
	return session


func _new_config():
	var script = load(CONFIG_PATH)
	if script == null:
		return null
	return script.new()


func _configure(session, cameras: Dictionary) -> void:
	session.configure({"cameras": cameras})


func _watch(session) -> void:
	_events.clear()
	session.overload_started.connect(_on_overload_started)
	session.overload_finished.connect(_on_overload_finished)
	session.burned.connect(_on_burned)
	session.cooldown_changed.connect(_on_cooldown_changed)


func _on_overload_started(camera_id: String) -> void:
	_events.append({"name": "overload_started", "camera_id": camera_id})


func _on_overload_finished(camera_id: String) -> void:
	_events.append({"name": "overload_finished", "camera_id": camera_id})


func _on_burned(camera_id: String) -> void:
	_events.append({"name": "burned", "camera_id": camera_id})


func _on_cooldown_changed(camera_id: String, remain: float) -> void:
	_events.append({"name": "cooldown_changed", "camera_id": camera_id, "remain": remain})


func _events_named(name: String) -> Array:
	var matches: Array = []
	for event in _events:
		if event is Dictionary and String((event as Dictionary).get("name", "")) == name:
			matches.append(event)
	return matches


func _event_names() -> Array:
	var names: Array = []
	for event in _events:
		if event is Dictionary:
			names.append(String((event as Dictionary).get("name", "")))
	return names


func _count(name: String) -> int:
	return _events_named(name).size()


func _last_event(name: String) -> Dictionary:
	var matches := _events_named(name)
	if matches.is_empty():
		return {}
	return matches[matches.size() - 1]


func _ensure_temp_dir() -> void:
	var absolute := ProjectSettings.globalize_path(TEMP_DIR)
	if not DirAccess.dir_exists_absolute(absolute):
		DirAccess.make_dir_recursive_absolute(absolute)


func _cleanup() -> void:
	var absolute := ProjectSettings.globalize_path(TEMP_DIR)
	if DirAccess.dir_exists_absolute(absolute):
		for file_name in DirAccess.get_files_at(absolute):
			DirAccess.remove_absolute(absolute + "/" + file_name)
		DirAccess.remove_absolute(absolute)


func _report() -> void:
	for session in _sessions:
		if is_instance_valid(session):
			session.free()
	_sessions.clear()
	print("----")
	if _failures.is_empty():
		print("CAMERA_SESSION_TEST_PASS (%d checks)" % _checks)
		quit(0)
	else:
		printerr("CAMERA_SESSION_TEST_FAIL (%d/%d failed)" % [_failures.size(), _checks])
		for failure in _failures:
			printerr("  - ", failure)
		quit(1)


# --- 用例 ---------------------------------------------------------------------

func _test_configure_and_state() -> void:
	var session = _new_session()
	_check("CameraSession 可实例化", session != null)
	if session == null:
		return
	_check("CameraSession 是 Node", session is Node)
	_check("不使用 _process（由宿主 tick）", not session.has_method("_process"))

	_configure(session, {"C1": {"dwell": 2.0, "cooldown": 1.0}})
	var state := _dict(session.get_state())
	_check("configure 后 current 为空", String(state.get("current", "?")) == "")
	_check("configure 后 remain 为 0", _approx(float(state.get("remain", -1.0)), 0.0))
	_check("configure 后 cooldowns 为空", _dict(state.get("cooldowns")).is_empty())
	_check("configure 后 burned 为空", _array(state.get("burned")).is_empty())
	_check("configure 后 overload_count 为 0", int(state.get("overload_count", -1)) == 0)

	_check("未进入时 is_burned 为 false", not session.is_burned("C1"))
	_check("enter 已知机位成功", session.enter("C1") == true)
	state = _dict(session.get_state())
	_check("enter 后 current 为 C1", String(state.get("current", "")) == "C1")
	_check("enter 后 remain 为 dwell", _approx(float(state.get("remain", -1.0)), 2.0))

	_check("未知机位 enter 失败", session.enter("C9") == false)
	_check("未知机位 is_burned 为 false", not session.is_burned("C9"))


func _test_configure_defaults() -> void:
	var session = _new_session()
	# 缺 cooldown → 默认 4.0；坏类型 → 默认值；非对象条目 → 忽略。
	_configure(session, {
		"C1": {"dwell": 2.0},
		"C2": {"dwell": "fast", "cooldown": -1},
		"C3": "not-a-dictionary",
	})
	_check("缺省 dwell/cooldown 的机位仍可 enter（C1）", session.enter("C1") == true)
	session.leave("C1")
	var cooldowns := _dict(_dict(session.get_state()).get("cooldowns"))
	_check("缺省 cooldown 使用契约默认 4.0", _approx(float(cooldowns.get("C1", -1.0)), 4.0),
		str(cooldowns))

	_check("坏 dwell/cooldown 类型用默认值仍可 enter（C2）", session.enter("C2") == true)
	var remain := float(_dict(session.get_state()).get("remain", -1.0))
	_check("坏 dwell 使用契约默认 6.0", _approx(remain, 6.0), str(remain))
	_check("非对象条目被忽略（C3 enter 失败）", session.enter("C3") == false)

	# 没有 cameras 键也不崩，且没有可进入的机位。
	var empty_session = _new_session()
	empty_session.configure({})
	_check("空 configure 不崩溃", String(_dict(empty_session.get_state()).get("current", "?")) == "")
	_check("空 configure 后 enter 失败", empty_session.enter("C1") == false)

	# 停靠中重复 enter 同一机位不重置停留（防止点两下绕过过载）。
	var repeat_session = _new_session()
	_configure(repeat_session, {"C1": {"dwell": 2.0, "cooldown": 1.0}})
	repeat_session.enter("C1")
	repeat_session.tick(1.0)
	var before := float(_dict(repeat_session.get_state()).get("remain", -1.0))
	_check("重复 enter 同一机位成功", repeat_session.enter("C1") == true)
	var after := float(_dict(repeat_session.get_state()).get("remain", -1.0))
	_check("重复 enter 同一机位不重置 remain", _approx(after, before), "%s vs %s" % [before, after])


func _test_enter_leave_semantics() -> void:
	var session = _new_session()
	_configure(session, {"C1": {"dwell": 2.0, "cooldown": 1.0}})
	_check("leave 未进入的机位无副作用", _do_leave_without_enter(session))
	_check("leave 后仍可 enter", session.enter("C1") == true)


func _do_leave_without_enter(session) -> bool:
	session.leave("C1")
	var state := _dict(session.get_state())
	return String(state.get("current", "?")) == "" and _dict(state.get("cooldowns")).is_empty()


func _test_dwell_progress_and_overload() -> void:
	var session = _new_session()
	_watch(session)
	# overload_started 的回调里重入 enter()：必须已经被拒绝，不能把烧毁机位写回 current。
	var reentered: Array = [false]
	var callback_count: Array = [0]
	session.overload_started.connect(func(camera_id: String) -> void:
		callback_count[0] += 1
		reentered[0] = session.enter(camera_id))
	_configure(session, {"C1": {"dwell": 0.25, "cooldown": 1.0}})
	_check("enter C1", session.enter("C1") == true)

	session.tick(0.1)
	_check("tick 推进 remain（0.25 -> 0.15）",
		_approx(float(_dict(session.get_state()).get("remain", -1.0)), 0.15))
	session.tick(0.1)
	_check("第二个 tick 未过载", _count("overload_started") == 0)
	_check("第二个 tick remain 0.05",
		_approx(float(_dict(session.get_state()).get("remain", -1.0)), 0.05))

	session.tick(0.1)
	_check("超时发 overload_started 一次",
		_count("overload_started") == 1 and String(_last_event("overload_started").get("camera_id", "")) == "C1")
	_check("超时发 burned 一次",
		_count("burned") == 1 and String(_last_event("burned").get("camera_id", "")) == "C1")
	_check("超时发 overload_finished 一次",
		_count("overload_finished") == 1
		and String(_last_event("overload_finished").get("camera_id", "")) == "C1")
	_check("过载信号顺序为 started→burned→finished",
		_event_names() == ["overload_started", "burned", "overload_finished"], str(_event_names()))
	_check("overload_started 回调重入 enter 被拒绝",
		int(callback_count[0]) == 1 and reentered[0] == false)

	var state := _dict(session.get_state())
	_check("过载后 current 清空", String(state.get("current", "?")) == "")
	_check("过载后 remain 归零", _approx(float(state.get("remain", -1.0)), 0.0))
	_check("过载后 overload_count 为 1", int(state.get("overload_count", -1)) == 1)
	_check("过载后 burned 列表含 C1", _array(state.get("burned")).has("C1"))
	_check("过载后 is_burned 为 true", session.is_burned("C1"))
	_check("烧毁机位 enter 失败", session.enter("C1") == false)

	session.tick(5.0)
	_check("烧毁后继续 tick 不重复过载", _count("overload_started") == 1 and _count("burned") == 1)
	_check("烧毁后 overload_count 不再增长", int(_dict(session.get_state()).get("overload_count", -1)) == 1)


func _test_cooldown_timeline() -> void:
	var session = _new_session()
	_watch(session)
	_configure(session, {"C1": {"dwell": 5.0, "cooldown": 0.3}})
	_check("enter C1 用于冷却测试", session.enter("C1") == true)
	session.leave("C1")

	var state := _dict(session.get_state())
	var cooldowns := _dict(state.get("cooldowns"))
	_check("leave 后 current 清空", String(state.get("current", "?")) == "")
	_check("leave 后 cooldown 为配置值 0.3", _approx(float(cooldowns.get("C1", -1.0)), 0.3),
		str(cooldowns))
	_check("leave 时发一次 cooldown_changed", _count("cooldown_changed") == 1)

	_check("冷却期间 enter 返回 false", session.enter("C1") == false)
	_check("冷却期间 enter 不动 current",
		String(_dict(session.get_state()).get("current", "?")) == "")
	_check("冷却期间 enter 不补发 cooldown_changed（值未变）",
		_count("cooldown_changed") == 1)

	session.tick(0.1)
	_check("冷却逐帧递减：0.3 -> 0.2",
		_approx(float(_last_event("cooldown_changed").get("remain", -1.0)), 0.2)
		and _count("cooldown_changed") == 2)
	session.tick(0.1)
	_check("冷却逐帧递减：0.2 -> 0.1",
		_approx(float(_last_event("cooldown_changed").get("remain", -1.0)), 0.1)
		and _count("cooldown_changed") == 3)
	session.tick(0.1)
	_check("冷却结束发 remain=0",
		_approx(float(_last_event("cooldown_changed").get("remain", -1.0)), 0.0)
		and _count("cooldown_changed") == 4)
	_check("冷却结束 cooldowns 清空", _dict(_dict(session.get_state()).get("cooldowns")).is_empty())
	_check("冷却结束可再次 enter", session.enter("C1") == true)
	_check("冷却结束 enter 后 current 为 C1",
		String(_dict(session.get_state()).get("current", "")) == "C1")

	var extra = _new_session()
	_configure(extra, {"C1": {"dwell": 5.0, "cooldown": 0.3}})
	extra.enter("C1")
	extra.leave("C1")
	extra.tick(0.2)
	extra.tick(0.2)
	_check("冷却被大 tick 越过时直接归零",
		_dict(_dict(extra.get_state()).get("cooldowns")).is_empty())


func _test_zero_cooldown() -> void:
	var session = _new_session()
	_watch(session)
	_configure(session, {"C1": {"dwell": 5.0, "cooldown": 0.0}})
	session.enter("C1")
	session.leave("C1")
	_check("cooldown=0 时 leave 不进冷却",
		_dict(_dict(session.get_state()).get("cooldowns")).is_empty())
	_check("cooldown=0 时不发 cooldown_changed", _count("cooldown_changed") == 0)
	_check("cooldown=0 时可立即再 enter", session.enter("C1") == true)


func _test_switch_cameras() -> void:
	var session = _new_session()
	_configure(session, {
		"C1": {"dwell": 5.0, "cooldown": 2.0},
		"C2": {"dwell": 5.0, "cooldown": 2.0},
	})
	session.enter("C1")
	session.tick(1.0)
	_check("直接 enter 另一机位成功", session.enter("C2") == true)
	var state := _dict(session.get_state())
	_check("切换后 current 为 C2", String(state.get("current", "")) == "C2")
	_check("切换后 C2 remain 为满额", _approx(float(state.get("remain", -1.0)), 5.0))
	_check("切换后 C1 进入冷却", _approx(float(_dict(state.get("cooldowns")).get("C1", -1.0)), 2.0))

	_check("切回冷却中的 C1 失败", session.enter("C1") == false)
	_check("失败后 current 仍是 C2", String(_dict(session.get_state()).get("current", "")) == "C2")


func _test_multiple_cooldowns() -> void:
	var session = _new_session()
	var config := {
		"C1": {"dwell": 5.0, "cooldown": 2.0},
		"C2": {"dwell": 5.0, "cooldown": 1.0},
	}
	_configure(session, config)
	session.enter("C1")
	session.leave("C1")
	session.enter("C2")
	session.leave("C2")
	var cooldowns := _dict(_dict(session.get_state()).get("cooldowns"))
	_check("多机位可同时冷却",
		_approx(float(cooldowns.get("C1", -1.0)), 2.0)
		and _approx(float(cooldowns.get("C2", -1.0)), 1.0), str(cooldowns))

	session.tick(0.5)
	cooldowns = _dict(_dict(session.get_state()).get("cooldowns"))
	_check("多机位冷却按各自配置递减",
		_approx(float(cooldowns.get("C1", -1.0)), 1.5)
		and _approx(float(cooldowns.get("C2", -1.0)), 0.5), str(cooldowns))
	session.tick(0.5)
	cooldowns = _dict(_dict(session.get_state()).get("cooldowns"))
	_check("先到期的冷却单独移除",
		cooldowns.has("C1") and not cooldowns.has("C2"), str(cooldowns))


func _test_leave_non_current() -> void:
	var session = _new_session()
	var config := {
		"C1": {"dwell": 5.0, "cooldown": 2.0},
		"C2": {"dwell": 5.0, "cooldown": 2.0},
	}
	_configure(session, config)
	session.enter("C1")
	session.leave("C2")
	var state := _dict(session.get_state())
	_check("leave(非 current) 不改变当前机位", String(state.get("current", "")) == "C1")
	_check("leave(非 current) 不产生冷却", _dict(state.get("cooldowns")).is_empty())
	session.tick(0.1)
	_check("leave(非 current) 后停留计时正常递减",
		_approx(float(_dict(session.get_state()).get("remain", -1.0)), 4.9))


func _test_configure_reset() -> void:
	var session = _new_session()
	_configure(session, {
		"C1": {"dwell": 1.0, "cooldown": 1.0},
		"C2": {"dwell": 5.0, "cooldown": 2.0},
		"C3": {"dwell": 5.0, "cooldown": 2.0},
	})
	session.enter("C1")
	session.tick(1.2)
	_check("重配前 C1 已烧毁", session.is_burned("C1"))
	session.enter("C2")
	session.tick(0.5)
	session.leave("C2")
	session.enter("C3")
	var before := _dict(session.get_state())
	_check("重配前同时存在 current / 冷却 / 烧毁",
		String(before.get("current", "")) == "C3"
		and _dict(before.get("cooldowns")).has("C2")
		and _array(before.get("burned")).has("C1")
		and int(before.get("overload_count", -1)) == 1, str(before))
	_check("重配前 remain 非 0", float(before.get("remain", -1.0)) > 0.0)

	_configure(session, {
		"C1": {"dwell": 3.0, "cooldown": 2.0},
		"C2": {"dwell": 3.0, "cooldown": 2.0},
	})
	var state := _dict(session.get_state())
	_check("configure 重置 current", String(state.get("current", "?")) == "")
	_check("configure 重置 burned", _array(state.get("burned")).is_empty())
	_check("configure 重置 cooldowns", _dict(state.get("cooldowns")).is_empty())
	_check("configure 重置 overload_count", int(state.get("overload_count", -1)) == 0)
	_check("configure 重置 remain", _approx(float(state.get("remain", -1.0)), 0.0))
	_check("configure 重置后烧毁机位可再进入", session.enter("C1") == true)
	_check("configure 的新 dwell 立即生效",
		_approx(float(_dict(session.get_state()).get("remain", -1.0)), 3.0))


func _test_config_driven() -> void:
	var short_visit = _new_session()
	var long_visit = _new_session()
	_configure(short_visit, {"C1": {"dwell": 0.5, "cooldown": 99.0}})
	_configure(long_visit, {"C1": {"dwell": 1.0, "cooldown": 0.01}})
	short_visit.enter("C1")
	long_visit.enter("C1")
	for i in range(5):
		short_visit.tick(0.1)
		long_visit.tick(0.1)
	_check("dwell=0.5 的机位在 0.5s 后烧毁", short_visit.is_burned("C1"))
	_check("dwell=1.0 的机位在 0.5s 时仍在停留", not long_visit.is_burned("C1"))
	_check("dwell=1.0 的机位 remain 约 0.5",
		_approx(float(_dict(long_visit.get_state()).get("remain", -1.0)), 0.5))

	for i in range(5):
		long_visit.tick(0.1)
	_check("dwell=1.0 的机位在 1.0s 后烧毁", long_visit.is_burned("C1"))

	# 同一个 tick 序列、不同 dwell：证明没有写死常量。
	var repeat_short = _new_session()
	_configure(repeat_short, {"C1": {"dwell": 0.5, "cooldown": 99.0}})
	repeat_short.enter("C1")
	for i in range(4):
		repeat_short.tick(0.1)
	_check("dwell=0.5 在 0.4s 时未烧毁", not repeat_short.is_burned("C1"))
	repeat_short.tick(0.1)
	_check("dwell=0.5 在 0.5s 时烧毁", repeat_short.is_burned("C1"))


func _test_deterministic_tick() -> void:
	var first = _new_session()
	var second = _new_session()
	var config := {"C1": {"dwell": 2.0, "cooldown": 1.5}, "C2": {"dwell": 4.0, "cooldown": 1.5}}
	_configure(first, config)
	_configure(second, config)

	var sequence := [0.1, 0.1, 0.1, 0.1, 0.5, 0.2, 0.1]
	for delta in sequence:
		first.tick(delta)
		second.tick(delta)
	_check("同一 tick 序列状态完全一致", str(first.get_state()) == str(second.get_state()),
		"%s vs %s" % [first.get_state(), second.get_state()])

	# enter/leave 序列也必须一致。
	first.enter("C1")
	second.enter("C1")
	first.tick(0.3)
	second.tick(0.3)
	first.leave("C1")
	second.leave("C1")
	for delta in sequence:
		first.tick(delta)
		second.tick(delta)
	_check("enter/leave/tick 混合序列可复现", str(first.get_state()) == str(second.get_state()))


func _test_serialization() -> void:
	var session = _new_session()
	_configure(session, {
		"C1": {"dwell": 2.0, "cooldown": 1.0},
		"C2": {"dwell": 5.0, "cooldown": 1.5},
		"C3": {"dwell": 5.0, "cooldown": 1.5},
	})
	session.enter("C1")
	session.tick(2.5)
	_check("序列化前 C1 已烧毁", session.is_burned("C1"))
	_check("序列化前 enter C2", session.enter("C2") == true)
	session.tick(0.5)

	var snapshot := _dict(session.to_dict())
	_check("to_dict 含 current", String(snapshot.get("current", "?")) == "C2")
	_check("to_dict 含 remain", _approx(float(snapshot.get("remain", -1.0)), 4.5))
	_check("to_dict 含 burned", _array(snapshot.get("burned")).has("C1"))
	_check("to_dict 含 overload_count", int(snapshot.get("overload_count", -1)) == 1)

	# 真序列化：JSON 往返后仍能恢复（W6 存档用）。
	var encoded := JSON.stringify(snapshot)
	var decoded: Variant = JSON.parse_string(encoded)
	_check("to_dict 可 JSON 序列化", decoded is Dictionary, encoded)

	var restored = _new_session()
	_configure(restored, {
		"C1": {"dwell": 2.0, "cooldown": 1.0},
		"C2": {"dwell": 5.0, "cooldown": 1.5},
		"C3": {"dwell": 5.0, "cooldown": 1.5},
	})
	restored.from_dict(decoded)
	var state := _dict(restored.get_state())
	_check("from_dict 恢复 current", String(state.get("current", "?")) == "C2")
	_check("from_dict 恢复 remain", _approx(float(state.get("remain", -1.0)), 4.5))
	_check("from_dict 恢复 burned", _array(state.get("burned")).has("C1"))
	_check("from_dict 恢复 overload_count", int(state.get("overload_count", -1)) == 1)
	_check("from_dict 恢复后 is_burned", restored.is_burned("C1"))
	_check("from_dict 恢复后烧毁机位不可 enter", restored.enter("C1") == false)

	# 冷却中的状态也必须能存。
	var cooling = _new_session()
	_configure(cooling, {"C3": {"dwell": 5.0, "cooldown": 1.5}})
	cooling.enter("C3")
	cooling.leave("C3")
	var cooldown_snapshot := _dict(cooling.to_dict())
	var cooling_restored = _new_session()
	_configure(cooling_restored, {"C3": {"dwell": 5.0, "cooldown": 1.5}})
	cooling_restored.from_dict(JSON.parse_string(JSON.stringify(cooldown_snapshot)))
	_check("from_dict 恢复冷却",
		_approx(float(_dict(_dict(cooling_restored.get_state()).get("cooldowns")).get("C3", -1.0)), 1.5))
	_check("from_dict 恢复冷却后 enter 失败", cooling_restored.enter("C3") == false)


func _test_from_dict_robustness() -> void:
	var session = _new_session()
	_configure(session, {
		"C1": {"dwell": 2.0, "cooldown": 1.0},
		"C2": {"dwell": 2.0, "cooldown": 0.0},
	})
	session.from_dict({})
	var state := _dict(session.get_state())
	_check("from_dict({}) 保持默认状态",
		String(state.get("current", "?")) == "" and int(state.get("overload_count", -1)) == 0)

	session.from_dict({"current": 99, "remain": "x", "cooldowns": "bad", "burned": 5, "overload_count": "many"})
	state = _dict(session.get_state())
	_check("from_dict 坏类型不崩溃且保持默认",
		String(state.get("current", "?")) == ""
		and _array(state.get("burned")).is_empty()
		and int(state.get("overload_count", -1)) == 0)

	session.from_dict({"burned": ["C1", 7]})
	_check("from_dict burned 含坏元素时忽略整个字段",
		_array(_dict(session.get_state()).get("burned")).is_empty())

	session.from_dict({"current": "C1", "burned": ["C1"]})
	state = _dict(session.get_state())
	_check("from_dict 烧毁机位不能同时是 current",
		String(state.get("current", "?")) == "" and _array(state.get("burned")).has("C1"))

	session.from_dict({"overload_count": 2.0})
	_check("from_dict 接受整数值 float 的 overload_count",
		int(_dict(session.get_state()).get("overload_count", -1)) == 2)

	session.from_dict({"current": "NOT_CONFIGURED", "remain": 3.0})
	var orphan_state := _dict(session.get_state())
	_check("from_dict 丢弃无效 current 时 remain 归零",
		String(orphan_state.get("current", "?")) == ""
		and _approx(float(orphan_state.get("remain", -1.0)), 0.0))

	session.from_dict({"current": "C1"})
	_check("from_dict 缺 remain 时回到该机位 dwell",
		_approx(float(_dict(session.get_state()).get("remain", -1.0)), 2.0))

	session.from_dict({"current": "C1", "remain": 100.0})
	_check("from_dict remain 超过 dwell 时收敛",
		_approx(float(_dict(session.get_state()).get("remain", -1.0)), 2.0))

	session.from_dict({"cooldowns": {"C1": 99.0}})
	_check("from_dict cooldown 超过配置值时收敛",
		_approx(float(_dict(_dict(session.get_state()).get("cooldowns")).get("C1", -1.0)), 1.0))

	session.from_dict({"cooldowns": {"C1": 0.0}})
	_check("from_dict 非正 cooldown 被忽略",
		_dict(_dict(session.get_state()).get("cooldowns")).is_empty())

	session.from_dict({"burned": ["C9"]})
	_check("from_dict 未配置的 burned 机位被忽略",
		_array(_dict(session.get_state()).get("burned")).is_empty())

	session.from_dict({"current": "C1", "remain": -1.0})
	_check("from_dict 负 remain 按缺失处理（回满额）",
		_approx(float(_dict(session.get_state()).get("remain", -1.0)), 2.0))

	session.from_dict({"cooldowns": {"C2": 1.0}})
	_check("from_dict 配置 cooldown=0 时忽略存档冷却",
		_dict(_dict(session.get_state()).get("cooldowns")).is_empty())

	session.from_dict({"burned": ["C1"], "cooldowns": {"C1": 0.5}})
	var conflict := _dict(session.get_state())
	_check("from_dict burned 与 cooldown 冲突时移除冷却",
		_array(conflict.get("burned")).has("C1")
		and _dict(conflict.get("cooldowns")).is_empty(), str(conflict))


func _test_surveillance_config() -> void:
	var config = _new_config()
	_check("CameraConfig 可实例化", config != null)
	if config == null:
		return
	var loaded: Dictionary = config.load_config()
	_check("surveillance.json 校验通过", not loaded.is_empty(), str(config.last_errors))
	var cameras := _dict(loaded.get("cameras"))
	_check("surveillance.json 含 C1-C4", cameras.size() >= 4 and cameras.has("C1")
		and cameras.has("C2") and cameras.has("C3") and cameras.has("C4"), str(cameras.keys()))
	var c1 := _dict(cameras.get("C1"))
	var c2 := _dict(cameras.get("C2"))
	_check("C1/C2 有 dwell/cooldown 数值",
		typeof(c1.get("dwell")) in [TYPE_FLOAT, TYPE_INT]
		and typeof(c1.get("cooldown")) in [TYPE_FLOAT, TYPE_INT]
		and typeof(c2.get("dwell")) in [TYPE_FLOAT, TYPE_INT]
		and typeof(c2.get("cooldown")) in [TYPE_FLOAT, TYPE_INT], str(c2))
	_check("C2 的数值不是契约默认值（防止自证）",
		_approx(float(c2.get("dwell", -1.0)), 5.0)
		and _approx(float(c2.get("cooldown", -1.0)), 3.0), str(c2))

	var session = _new_session()
	_check("load_into 配置成功", config.load_into(session))
	_check("load_into 后 enter C2 成功", session.enter("C2") == true)
	var expected_dwell := float(c2.get("dwell", -1.0))
	_check("session 使用 surveillance.json 的 dwell（C2=5.0，非默认 6.0）",
		_approx(float(_dict(session.get_state()).get("remain", -1.0)), expected_dwell)
		and _approx(expected_dwell, 5.0))

	var timing := _dict(config.timing_for("C2"))
	_check("timing_for 返回配置值（C2=5.0/3.0）",
		_approx(float(timing.get("dwell", -1.0)), 5.0)
		and _approx(float(timing.get("cooldown", -1.0)), 3.0), str(timing))
	var fallback := _dict(config.timing_for("NOT_CONFIGURED"))
	_check("timing_for 未配置机位用默认 6.0/4.0",
		_approx(float(fallback.get("dwell", -1.0)), 6.0)
		and _approx(float(fallback.get("cooldown", -1.0)), 4.0), str(fallback))

	var fake = FakeSession.new()
	_check("load_into 接受 RefCounted 鸭子类型", config.load_into(fake))
	_check("鸭子类型收到 cameras 配置",
		_dict(fake.config.get("cameras")).size() >= 4)
	_check("load_into 非对象目标返回 false", config.load_into(42) == false)
	_check("load_into 无 configure 的对象返回 false",
		config.load_into(RefCounted.new()) == false)


func _test_camera_config_failure() -> void:
	var config = _new_config()
	if config == null:
		return
	var bad_path := TEMP_DIR + "/surveillance_bad.json"
	var file := FileAccess.open(bad_path, FileAccess.WRITE)
	file.store_string("{\"cameras\": {\"C1\": {\"dwell\": 6.0}}}")
	file.close()
	var loaded: Dictionary = config.load_config(bad_path)
	_check("缺 cooldown 的配置校验失败返回 {}", loaded.is_empty(), str(loaded))
	_check("失败时 last_errors 非空", not config.last_errors.is_empty())

	var session = _new_session()
	_check("失败时 load_into 返回 false", config.load_into(session, bad_path) == false)

	# 无 schema 时合法空对象 {} 也会被 load_json 判成 {}；必须补一条错误。
	var empty_path := TEMP_DIR + "/empty.json"
	var empty_file := FileAccess.open(empty_path, FileAccess.WRITE)
	empty_file.store_string("{}")
	empty_file.close()
	var empty_loaded: Dictionary = config.load_config(empty_path, "")
	_check("无 schema 的空对象配置返回 {} 且 last_errors 非空",
		empty_loaded.is_empty() and not config.last_errors.is_empty(),
		str(config.last_errors))
