extends SceneTree
## W5 过载危险效果 + 盲区失明的自动化测试。
## 运行：godot --headless --path . --script tests/test_hazards.gd
## 退出码 0 = 全绿，1 = 有用例失败。
##
## 覆盖：HazardEffects 的 flash / short / fire 触发与到时结束、
## 范围阻挡与多危险叠加、配置校验（W0 §0 的 last_errors / definition_error）、
## 订阅 W1 `overload_started`（用假会话发信号）后挡住 EnemyPatrol 的联调，
## 以及 BlindZone 的 set_blind / is_visible 与区域↔机位映射。
##
## 按 AGENTS.md §2：本文件先于实现写（红），实现后转绿。

const HAZARD_PATH := "res://scripts/hazards/hazard_effects.gd"
const BLIND_PATH := "res://scripts/hazards/blind_zone.gd"
const ENEMY_PATH := "res://scripts/enemy/enemy_patrol.gd"

var _failures: Array[String] = []
var _checks := 0
var _started := false


## 假 W1 会话：只提供 overload_started 信号，验证 HazardEffects 的订阅接线。
class FakeCameraSession:
	signal overload_started(camera_id: String)

	func overload(camera_id: String) -> void:
		overload_started.emit(camera_id)


func _initialize() -> void:
	_check("存在 scripts/hazards/hazard_effects.gd", ResourceLoader.exists(HAZARD_PATH))
	_check("存在 scripts/hazards/blind_zone.gd", ResourceLoader.exists(BLIND_PATH))


func _process(_delta: float) -> bool:
	if _started:
		return false
	_started = true
	if not ResourceLoader.exists(HAZARD_PATH) or not ResourceLoader.exists(BLIND_PATH):
		_report()
		return false
	_test_trigger_and_end()
	_test_three_kinds()
	_test_radius_boundary()
	_test_unknown_kind()
	_test_configure()
	_test_bind_overload_source()
	_test_overload_blocks_enemy()
	_test_blind_zone_basic()
	_test_blind_zone_mapping()
	_test_blind_zone_no_auto_recovery()
	_report()
	return false


func _make_hazard():
	var hazard = load(HAZARD_PATH).new()
	root.add_child(hazard)
	return hazard


func _make_zone():
	var zone = load(BLIND_PATH).new()
	root.add_child(zone)
	return zone


func _kinds(hazard) -> Dictionary:
	return hazard.get_state().get("kinds", {})


# --- HazardEffects ------------------------------------------------------------

func _test_trigger_and_end() -> void:
	var hazard = _make_hazard()
	var started: Array = []
	var ended: Array = []
	hazard.hazard_started.connect(func(kind: String, position: Vector3) -> void:
		started.append({"kind": kind, "pos": position})
	)
	hazard.hazard_ended.connect(func(kind: String, position: Vector3) -> void:
		ended.append({"kind": kind, "pos": position})
	)

	var point := Vector3(3, 0, 4)
	_check("trigger(flash) 返回 true", hazard.trigger("flash", point))
	_check("触发时发一次 hazard_started",
		started.size() == 1 and String(started[0]["kind"]) == "flash"
		and Vector3(started[0]["pos"]).is_equal_approx(point))
	_check("范围内 is_blocking 为 true", hazard.is_blocking(point))
	_check("范围外 is_blocking 为 false", not hazard.is_blocking(point + Vector3(100, 0, 0)))
	_check("触发后未到时仍在阻挡", hazard.is_blocking(point))

	var duration := float((_kinds(hazard)["flash"] as Dictionary)["duration"])
	_check("flash 默认时长大于 0", duration > 0.0)
	hazard.tick(duration - 0.05)
	_check("未到时长仍阻挡", hazard.is_blocking(point))
	_check("未到时长不发 hazard_ended", ended.is_empty())
	hazard.tick(0.1)
	_check("到时长后解除阻挡", not hazard.is_blocking(point))
	_check("到时长后发一次 hazard_ended",
		ended.size() == 1 and String(ended[0]["kind"]) == "flash"
		and Vector3(ended[0]["pos"]).is_equal_approx(point))
	hazard.tick(10.0)
	_check("结束后继续 tick 不重复发 hazard_ended", ended.size() == 1)
	hazard.free()


func _test_three_kinds() -> void:
	var hazard = _make_hazard()
	var started: Array = []
	var ended: Array = []
	hazard.hazard_started.connect(func(kind: String, _position: Vector3) -> void:
		started.append(kind)
	)
	hazard.hazard_ended.connect(func(kind: String, _position: Vector3) -> void:
		ended.append(kind)
	)
	var point := Vector3.ZERO
	for kind in ["flash", "short", "fire"]:
		_check("trigger(%s) 返回 true" % kind, hazard.trigger(kind, point))
	_check("三种危险各发一次 hazard_started", started.size() == 3)
	var kinds: Dictionary = _kinds(hazard)
	_check("默认规则包含 flash / short / fire",
		kinds.has("flash") and kinds.has("short") and kinds.has("fire"))
	for kind in ["flash", "short", "fire"]:
		_check("%s 默认规则有正时长与正半径" % kind,
			float(kinds[kind]["duration"]) > 0.0 and float(kinds[kind]["radius"]) > 0.0)
	_check("同一点叠加三种危险时返回 3 个 id",
		hazard.blocking_hazards_at(point).size() == 3)
	var ids: Array = hazard.blocking_hazards_at(point)
	_check("叠加危险 id 互不相同", ids.size() == 3 and ids[0] != ids[1] and ids[1] != ids[2])

	var flash_duration := float(kinds["flash"]["duration"])
	hazard.tick(flash_duration + 0.01)
	_check("最短的 flash 先结束", ended.size() == 1 and String(ended[0]) == "flash")
	_check("flash 结束后只剩 short / fire 阻挡",
		hazard.blocking_hazards_at(point).size() == 2)
	hazard.tick(100.0)
	_check("全部到时后不再阻挡", not hazard.is_blocking(point))
	_check("全部到时后共发 3 次 hazard_ended", ended.size() == 3)
	hazard.free()


func _test_radius_boundary() -> void:
	var hazard = _make_hazard()
	hazard.trigger("short", Vector3.ZERO)
	var radius := float((_kinds(hazard)["short"] as Dictionary)["radius"])
	_check("危险中心阻挡", hazard.is_blocking(Vector3.ZERO))
	_check("半径边界阻挡", hazard.is_blocking(Vector3(radius, 0, 0)))
	_check("半径外不阻挡", not hazard.is_blocking(Vector3(radius + 0.01, 0, 0)))
	hazard.free()


func _test_unknown_kind() -> void:
	var hazard = _make_hazard()
	var started: Array = []
	hazard.hazard_started.connect(func(kind: String, _position: Vector3) -> void:
		started.append(kind)
	)
	_check("未知 kind 返回 false", not hazard.trigger("smoke", Vector3.ZERO))
	_check("未知 kind 不发 hazard_started", started.is_empty())
	_check("未知 kind 不产生阻挡", not hazard.is_blocking(Vector3.ZERO))
	hazard.free()


func _test_configure() -> void:
	var hazard = _make_hazard()
	var errors: Array = []
	hazard.definition_error.connect(func(message: String) -> void:
		errors.append(message)
	)

	hazard.configure({"flash": {"duration": 0.5, "radius": 5.0, "blocking": false}})
	var flash_rule: Dictionary = _kinds(hazard)["flash"]
	_check("configure 写入 duration", is_equal_approx(float(flash_rule["duration"]), 0.5))
	_check("configure 写入 radius", is_equal_approx(float(flash_rule["radius"]), 5.0))
	_check("configure 写入 blocking", not bool(flash_rule["blocking"]))
	_check("合法 configure 清空 last_errors", hazard.last_errors.is_empty())

	hazard.trigger("flash", Vector3.ZERO)
	_check("blocking=false 时 is_blocking 为 false", not hazard.is_blocking(Vector3.ZERO))
	var ended: Array = []
	hazard.hazard_ended.connect(func(kind: String, _position: Vector3) -> void:
		ended.append(kind)
	)
	hazard.tick(0.5)
	_check("自定义时长生效（0.5s 后结束）", ended.size() == 1 and String(ended[0]) == "flash")

	hazard.configure({"flash": {"duration": -1.0}})
	_check("非法 duration 写 last_errors", hazard.last_errors.size() == 1)
	_check("非法 duration 发 definition_error", errors.size() == 1)
	_check("非法 duration 保留上一个合法值",
		is_equal_approx(float((_kinds(hazard)["flash"] as Dictionary)["duration"]), 0.5))

	hazard.configure({"smoke": {"duration": 1.0}})
	_check("未知 kind 的配置写 last_errors", hazard.last_errors.size() == 1)
	_check("未知 kind 的配置发 definition_error", errors.size() == 2)

	# W0 §0 从严：NaN/INF 会写出「永远不会结束」的危险，必须拒绝。
	hazard.configure({"flash": {"duration": NAN, "radius": INF}})
	_check("非有限数 duration/radius 各写一条 last_errors", hazard.last_errors.size() == 2)
	_check("非有限数 duration/radius 各发一次 definition_error", errors.size() == 4)
	_check("非有限值不覆盖已生效的 duration/radius",
		is_equal_approx(float((_kinds(hazard)["flash"] as Dictionary)["duration"]), 0.5)
		and is_equal_approx(float((_kinds(hazard)["flash"] as Dictionary)["radius"]), 5.0))

	hazard.configure({"flash": {"duration": 1.0}})
	_check("合法 configure 再次清空 last_errors", hazard.last_errors.is_empty())
	hazard.free()


func _test_bind_overload_source() -> void:
	var hazard = _make_hazard()
	var camera := FakeCameraSession.new()
	var positions := {"C3": Vector3(4, 0, 0)}
	var started: Array = []
	hazard.hazard_started.connect(func(kind: String, position: Vector3) -> void:
		started.append({"kind": kind, "pos": position})
	)

	var lookup := func(camera_id: String) -> Variant:
		return positions.get(camera_id)
	_check("bind_overload_source 成功",
		hazard.bind_overload_source(camera, lookup))
	camera.overload("C3")
	_check("订阅 overload_started 后触发 short 危险",
		started.size() == 1 and String(started[0]["kind"]) == "short"
		and Vector3(started[0]["pos"]).is_equal_approx(Vector3(4, 0, 0)))
	_check("危险出现在机位位置", hazard.is_blocking(Vector3(4, 0, 0)))

	camera.overload("未知机位")
	_check("机位位置查询失败时不触发危险", started.size() == 1)

	hazard.unbind_overload_source()
	camera.overload("C3")
	_check("解绑后不再触发危险", started.size() == 1)

	var no_signal_lookup := func(_camera_id: String) -> Variant:
		return Vector3.ZERO
	_check("没有 overload_started 信号的对象绑定失败",
		not hazard.bind_overload_source(RefCounted.new(), no_signal_lookup))
	hazard.free()


func _test_overload_blocks_enemy() -> void:
	# 验收：订阅 W1 overload_started（假信号）→ 危险出现 → 敌人被挡住 → 危险结束 → 恢复巡逻。
	var hazard = _make_hazard()
	var camera := FakeCameraSession.new()
	var patrol = load(ENEMY_PATH).new()
	root.add_child(patrol)
	patrol.setup([Vector3(0, 0, 0), Vector3(20, 0, 0)], 2.0)
	patrol.set_hazard_source(hazard)

	var blocked: Array = []
	patrol.blocked_by_hazard.connect(func(hazard_id: String) -> void:
		blocked.append(hazard_id)
	)
	var positions := {"C3": Vector3(4, 0, 0)}
	var lookup := func(camera_id: String) -> Variant:
		return positions.get(camera_id)
	hazard.bind_overload_source(camera, lookup)

	var short_rule: Dictionary = _kinds(hazard)["short"]
	var radius := float(short_rule["radius"])
	var boundary := 4.0 - radius

	patrol.tick(0.5)
	_check("过载前敌人正常推进到 x=1", patrol.get_position().is_equal_approx(Vector3(1, 0, 0)))
	camera.overload("C3")
	patrol.tick(2.0)
	_check("危险出现在前进路径时停在边界附近",
		absf(patrol.get_position().x - boundary) <= 0.11)
	_check("敌人被挡时发 blocked_by_hazard", blocked.size() == 1)
	_check("blocked_by_hazard 带危险 id", not String(blocked[0]).is_empty())

	var short_duration := float(short_rule["duration"])
	var blocked_x: float = patrol.get_position().x
	hazard.tick(short_duration + 0.1)
	patrol.tick(0.5)
	_check("危险结束后敌人恢复巡逻", patrol.get_position().x > blocked_x + 0.5 - 0.01)
	patrol.free()
	hazard.free()


# --- BlindZone ----------------------------------------------------------------

func _test_blind_zone_basic() -> void:
	var zone = _make_zone()
	_check("默认机位可见", zone.is_visible("C1"))
	zone.set_blind("C1", true)
	_check("set_blind 后 is_visible 为 false", not zone.is_visible("C1"))
	zone.set_blind("C1", true)
	_check("重复 set_blind(true) 保持不可见", not zone.is_visible("C1"))
	zone.set_blind("C1", false)
	_check("set_blind(false) 后恢复可见", zone.is_visible("C1"))
	_check("未登记机位默认可见", zone.is_visible("C99"))
	var state: Dictionary = zone.get_state()
	_check("get_state 含 blind_areas / camera_areas",
		state.has("blind_areas") and state.has("camera_areas"))
	zone.free()


func _test_blind_zone_mapping() -> void:
	var zone = _make_zone()
	_check("register_camera 返回 true", zone.register_camera("C1", "lobby"))
	zone.register_camera("C2", "lobby")
	zone.register_camera("C3", "stage")
	zone.set_blind("lobby", true)
	_check("区域盲化后同区域的 C1/C2 不可见",
		not zone.is_visible("C1") and not zone.is_visible("C2"))
	_check("其它区域机位 C3 仍可见", zone.is_visible("C3"))
	_check("is_area_blind 报告区域状态", zone.is_area_blind("lobby"))
	zone.set_blind("lobby", false)
	_check("区域恢复后同区域机位可见",
		zone.is_visible("C1") and zone.is_visible("C2"))

	zone.register_camera("C3", "lobby")
	zone.set_blind("stage", true)
	_check("机位改挂区域后不再受原区域影响", zone.is_visible("C3"))
	zone.set_blind("lobby", true)
	_check("机位改挂区域后受新区域影响", not zone.is_visible("C3"))
	zone.free()


func _test_blind_zone_no_auto_recovery() -> void:
	# M16 未拍板：默认只认显式 set_blind，不会自己恢复。
	var zone = _make_zone()
	zone.register_camera("C7", "side_gate")
	zone.set_blind("side_gate", true)
	_check("盲区持续生效（多次查询仍不可见）", not zone.is_visible("C7"))
	var first: Dictionary = zone.get_state()
	var second: Dictionary = zone.get_state()
	_check("get_state 不改变盲区状态",
		not zone.is_visible("C7")
		and first["blind_areas"] == second["blind_areas"])
	zone.set_blind("side_gate", false)
	_check("只有显式解除后才恢复可见", zone.is_visible("C7"))
	zone.free()


# --- 断言与汇总 ---------------------------------------------------------------

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
		print("HAZARDS_TEST_PASS (%d checks)" % _checks)
		quit(0)
	else:
		printerr("HAZARDS_TEST_FAIL (%d/%d failed)" % [_failures.size(), _checks])
		for failure in _failures:
			printerr("  - ", failure)
		quit(1)
