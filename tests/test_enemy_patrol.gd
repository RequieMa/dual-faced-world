extends SceneTree
## W5 敌人巡逻 + 视锥的自动化测试。
## 运行：godot --headless --path . --script tests/test_enemy_patrol.gd
## 退出码 0 = 全绿，1 = 有用例失败。
##
## 覆盖：VisionCone 的锥内/锥外/射程/朝向/遮挡判定（W0 契约 §8），
## EnemyPatrol 的 waypoint 循环推进、可复现性、spotted 边沿信号、
## 危险阻挡（blocked_by_hazard）与视野参数下发。
##
## 按 AGENTS.md §2：本文件先于实现写（红），实现后转绿。

const CONE_PATH := "res://scripts/enemy/vision_cone.gd"
const ENEMY_PATH := "res://scripts/enemy/enemy_patrol.gd"
const ANGLE_EPSILON := 0.001

var _failures: Array[String] = []
var _checks := 0
var _started := false


## 假危险源：只实现 EnemyPatrol 需要的鸭子类型接口，不依赖 HazardEffects 实现。
class FakeHazardSource:
	var active: Array = []
	var origin := Vector3.ZERO
	var radius := 1.0

	func blocking_hazards_at(position: Vector3) -> Array:
		if active.is_empty():
			return []
		if position.distance_to(origin) <= radius + 0.000001:
			return active.duplicate()
		return []


func _initialize() -> void:
	_check("存在 scripts/enemy/vision_cone.gd", ResourceLoader.exists(CONE_PATH))
	_check("存在 scripts/enemy/enemy_patrol.gd", ResourceLoader.exists(ENEMY_PATH))


func _process(_delta: float) -> bool:
	if _started:
		return false
	_started = true
	if not ResourceLoader.exists(CONE_PATH) or not ResourceLoader.exists(ENEMY_PATH):
		_report()
		return false
	# 存在性之外还要确认能解析/实例化：语法错误时 load() 会返回 null，
	# 只查文件存在会静默少跑用例并误报 PASS。
	var cone_script = load(CONE_PATH)
	var enemy_script = load(ENEMY_PATH)
	_check("vision_cone.gd 可加载且可实例化",
		cone_script != null and cone_script.can_instantiate())
	_check("enemy_patrol.gd 可加载且可实例化",
		enemy_script != null and enemy_script.can_instantiate())
	if cone_script == null or enemy_script == null:
		_report()
		return false
	_test_cone_unconfigured()
	_test_cone_geometry()
	_test_cone_orientation_is_live()
	_test_cone_occlusion()
	_test_cone_debug_state()
	_test_patrol_setup_and_tick()
	_test_patrol_loops_waypoints()
	_test_patrol_reproducible()
	_test_patrol_degenerate_inputs()
	_test_patrol_vision()
	_test_patrol_vision_config()
	_test_patrol_spotted_signal()
	_test_patrol_blocked_by_hazard()
	_test_patrol_blocked_with_callable_source()
	_test_patrol_does_not_tunnel_into_hazard()
	_test_patrol_dedupes_hazard_ids()
	_test_patrol_static_guard()
	_test_patrol_node_target()
	_test_patrol_state()
	_report()
	return false


# --- VisionCone ---------------------------------------------------------------

func _test_cone_unconfigured() -> void:
	var cone = load(CONE_PATH).new()
	var debug: Dictionary = cone.get_debug_state()
	_check("未 setup 的锥体看不见任何点", not cone.sees(Vector3(0, 0, 5)))
	_check("未 setup 的锥体报告 configured=false", not bool(debug.get("configured", true)))
	_check("未 setup 的锥体保留默认半角/射程",
		is_equal_approx(float(debug.get("half_angle_deg", -1.0)), 45.0)
		and is_equal_approx(float(debug.get("range_m", -1.0)), 10.0))
	cone.free()


func _test_cone_geometry() -> void:
	var state := {"origin": Vector3.ZERO, "direction": Vector3(0, 0, -1)}
	var cone = load(CONE_PATH).new()
	cone.setup(func(): return state["origin"], func(): return state["direction"], 45.0, 10.0)

	_check("锥内：正前方 5m 可见", cone.sees(Vector3(0, 0, -5)))
	_check("锥外：背后 5m 不可见", not cone.sees(Vector3(0, 0, 5)))
	_check("锥外：偏出 90° 不可见", not cone.sees(Vector3(5, 0, 0)))
	_check("锥外：超出射程 11m 不可见", not cone.sees(Vector3(0, 0, -11)))
	_check("射程边界：恰好 10m 可见", cone.sees(Vector3(0, 0, -10)))
	_check("角度边界：恰好 45° 可见", cone.sees(Vector3(5, 0, -5)))
	_check("角度边界：50° 不可见", not cone.sees(Vector3(6, 0, -5)))
	_check("原点：自身位置可见", cone.sees(Vector3.ZERO))
	cone.free()

	var still := {"origin": Vector3.ZERO, "direction": Vector3.ZERO}
	var zero_cone = load(CONE_PATH).new()
	zero_cone.setup(func(): return still["origin"], func(): return still["direction"], 45.0, 10.0)
	_check("方向为零：原点判定可见", zero_cone.sees(Vector3.ZERO))
	_check("方向为零：非原点判定不可见", not zero_cone.sees(Vector3(0, 0, -5)))
	zero_cone.free()


func _test_cone_orientation_is_live() -> void:
	# 原点/朝向必须每帧从 getter 读，而不是 setup 时快照一份。
	var state := {"origin": Vector3.ZERO, "direction": Vector3(0, 0, -1)}
	var cone = load(CONE_PATH).new()
	cone.setup(func(): return state["origin"], func(): return state["direction"], 45.0, 10.0)
	state["direction"] = Vector3(1, 0, 0)
	_check("朝向更新：新方向 5m 可见", cone.sees(Vector3(5, 0, 0)))
	_check("朝向更新：旧方向不再可见", not cone.sees(Vector3(0, 0, -5)))
	state["origin"] = Vector3(100, 0, 0)
	_check("原点更新：新原点附近可见", cone.sees(Vector3(105, 0, 0)))
	_check("原点更新：旧位置不再可见", not cone.sees(Vector3(0, 0, -5)))
	cone.free()


func _test_cone_occlusion() -> void:
	var cone = load(CONE_PATH).new()
	cone.setup(func(): return Vector3.ZERO, func(): return Vector3(0, 0, -1), 45.0, 10.0)
	# z < -7 视为被墙挡住：纯几何判定，测试不碰物理引擎。
	cone.set_occlusion_check(func(point: Vector3) -> bool: return point.z < -7.0)
	_check("遮挡：锥内未遮挡处可见", cone.sees(Vector3(0, 0, -5)))
	_check("遮挡：锥内被墙挡住不可见", not cone.sees(Vector3(0, 0, -8)))
	_check("遮挡：锥外即使未遮挡也不可见", not cone.sees(Vector3(0, 0, 8)))
	cone.set_occlusion_check(Callable())
	_check("遮挡：清除遮挡回调后恢复可见", cone.sees(Vector3(0, 0, -8)))
	cone.free()


func _test_cone_debug_state() -> void:
	var cone = load(CONE_PATH).new()
	cone.setup(func(): return Vector3(1, 0, 2), func(): return Vector3(0, 0, -1), 30.0, 7.0)
	var debug: Dictionary = cone.get_debug_state()
	_check("debug 报告半角", is_equal_approx(float(debug.get("half_angle_deg", -1.0)), 30.0))
	_check("debug 报告射程", is_equal_approx(float(debug.get("range_m", -1.0)), 7.0))
	_check("debug 报告原点", Vector3(debug.get("origin", Vector3.INF)).is_equal_approx(Vector3(1, 0, 2)))
	_check("debug 报告朝向", Vector3(debug.get("direction", Vector3.INF)).is_equal_approx(Vector3(0, 0, -1)))
	cone.free()


# --- EnemyPatrol --------------------------------------------------------------

func _make_patrol(waypoints: Array, speed: float):
	var patrol = load(ENEMY_PATH).new()
	root.add_child(patrol)
	patrol.setup(waypoints, speed)
	return patrol


func _test_patrol_setup_and_tick() -> void:
	var patrol = _make_patrol([Vector3(0, 0, 0), Vector3(10, 0, 0)], 2.0)
	_check("初始位置在第一个 waypoint", patrol.get_position().is_equal_approx(Vector3.ZERO))
	_check("初始朝向指向下一段", patrol.get_direction().is_equal_approx(Vector3(1, 0, 0)))
	patrol.tick(1.0)
	_check("tick(1) × 2m/s 推进 2m", patrol.get_position().is_equal_approx(Vector3(2, 0, 0)))
	patrol.tick(4.0)
	_check("推进到第二个 waypoint", patrol.get_position().is_equal_approx(Vector3(10, 0, 0)))
	patrol.tick(1.0)
	_check("到点后折返 2m", patrol.get_position().is_equal_approx(Vector3(8, 0, 0)))
	_check("折返后朝向反转", patrol.get_direction().is_equal_approx(Vector3(-1, 0, 0)))
	patrol.tick(-1.0)
	_check("负 delta 被忽略", patrol.get_position().is_equal_approx(Vector3(8, 0, 0)))
	patrol.free()


func _test_patrol_loops_waypoints() -> void:
	var patrol = _make_patrol([
		Vector3(0, 0, 0), Vector3(4, 0, 0), Vector3(4, 0, 4), Vector3(0, 0, 4),
	], 2.0)
	patrol.tick(2.0)
	_check("循环巡逻：到达第 2 点", patrol.get_position().is_equal_approx(Vector3(4, 0, 0)))
	patrol.tick(2.0)
	_check("循环巡逻：到达第 3 点", patrol.get_position().is_equal_approx(Vector3(4, 0, 4)))
	patrol.tick(2.0)
	_check("循环巡逻：到达第 4 点", patrol.get_position().is_equal_approx(Vector3(0, 0, 4)))
	patrol.tick(2.0)
	_check("循环巡逻：回到起点并继续", patrol.get_position().is_equal_approx(Vector3.ZERO))
	patrol.tick(1.0)
	_check("循环巡逻：回到起点后继续下一圈", patrol.get_position().is_equal_approx(Vector3(2, 0, 0)))
	patrol.free()


func _test_patrol_reproducible() -> void:
	var first = _make_patrol([Vector3(0, 0, 0), Vector3(6, 0, 2), Vector3(2, 0, 5)], 1.7)
	var second = _make_patrol([Vector3(0, 0, 0), Vector3(6, 0, 2), Vector3(2, 0, 5)], 1.7)
	for delta in [0.1, 0.25, 1.0, 3.3, 0.05]:
		first.tick(float(delta))
		second.tick(float(delta))
	_check("相同输入序列推进结果一致",
		first.get_position().is_equal_approx(second.get_position()))
	_check("相同输入序列朝向一致",
		first.get_direction().is_equal_approx(second.get_direction()))
	first.free()
	second.free()


func _test_patrol_degenerate_inputs() -> void:
	var single = _make_patrol([Vector3(3, 0, 3)], 2.0)
	single.tick(5.0)
	_check("只有一个 waypoint 时原地不动", single.get_position().is_equal_approx(Vector3(3, 0, 3)))
	single.free()

	var no_speed = _make_patrol([Vector3(0, 0, 0), Vector3(10, 0, 0)], 0.0)
	no_speed.tick(5.0)
	_check("速度 0 时不推进", no_speed.get_position().is_equal_approx(Vector3.ZERO))
	no_speed.free()

	# 连续重复 waypoint 不能让 tick 死循环或吞掉时间。
	var duplicated = _make_patrol([
		Vector3(0, 0, 0), Vector3(0, 0, 0), Vector3(4, 0, 0), Vector3(4, 0, 0),
	], 2.0)
	duplicated.tick(1.0)
	_check("重复 waypoint 被折叠后仍正常推进",
		duplicated.get_position().is_equal_approx(Vector3(2, 0, 0)))
	duplicated.free()

	var empty = _make_patrol([], 2.0)
	empty.tick(1.0)
	_check("空 waypoint 不崩溃、不移动", empty.get_position().is_equal_approx(Vector3.ZERO))
	empty.free()


func _test_patrol_vision() -> void:
	var patrol = _make_patrol([Vector3(0, 0, 0), Vector3(10, 0, 0)], 2.0)
	_check("巡逻指向 +X 时看见前方目标", patrol.sees(Vector3(5, 0, 0)))
	_check("巡逻指向 +X 时看不见背后目标", not patrol.sees(Vector3(-5, 0, 0)))
	_check("巡逻看不见射程外目标", not patrol.sees(Vector3(11, 0, 0)))
	patrol.tick(2.0)
	_check("巡逻移动后视锥原点跟随", patrol.sees(Vector3(8, 0, 0)))
	_check("巡逻移动后远处目标超出射程", not patrol.sees(Vector3(15, 0, 0)))
	patrol.free()

	var turned = _make_patrol([Vector3(0, 0, 0), Vector3(0, 0, 10)], 2.0)
	_check("朝向 +Z 时看见 +Z 目标", turned.sees(Vector3(0, 0, 5)))
	_check("朝向 +Z 时看不见 +X 目标", not turned.sees(Vector3(5, 0, 0)))
	turned.free()


func _test_patrol_vision_config() -> void:
	var patrol = _make_patrol([Vector3(0, 0, 0), Vector3(10, 0, 0)], 2.0)
	patrol.set_vision(20.0, 3.0)
	_check("缩小射程后 5m 目标不可见", not patrol.sees(Vector3(5, 0, 0)))
	_check("缩小射程后 2m 目标可见", patrol.sees(Vector3(2, 0, 0)))
	patrol.set_vision(60.0, 10.0)
	_check("放宽参数后目标重新可见", patrol.sees(Vector3(5, 0, 0)))
	_check("放宽半角后侧前方可见", patrol.sees(Vector3(5, 0, 5)))
	patrol.free()


func _test_patrol_spotted_signal() -> void:
	var patrol = _make_patrol([Vector3(0, 0, 0), Vector3(10, 0, 0)], 2.0)
	var spotted: Array = []
	patrol.spotted.connect(func(target_id: String) -> void: spotted.append(target_id))

	var target := {"id": "P1", "position": Vector3(5, 0, 0)}
	_check("看见带 id 的目标返回 true", patrol.sees(target))
	_check("首次看见目标发一次 spotted", spotted.size() == 1 and String(spotted[0]) == "P1")
	patrol.sees(target)
	patrol.sees(target)
	_check("持续看见不重复发 spotted", spotted.size() == 1)
	_check("目标离开视野返回 false", not patrol.sees({"id": "P1", "position": Vector3(-5, 0, 0)}))
	_check("目标离开视野后不新增 spotted", spotted.size() == 1)
	patrol.sees(target)
	_check("目标重新进入视野再次发 spotted", spotted.size() == 2)
	_check("无 id 的点不触发 spotted", patrol.sees(Vector3(5, 0, 0)) and spotted.size() == 2)
	_check("非法目标类型返回 false", not patrol.sees(42))
	patrol.free()


func _test_patrol_blocked_by_hazard() -> void:
	var patrol = _make_patrol([Vector3(0, 0, 0), Vector3(10, 0, 0)], 2.0)
	var source := FakeHazardSource.new()
	source.origin = Vector3(1, 0, 0)
	source.radius = 1.0
	source.active = ["H1"]
	patrol.set_hazard_source(source)
	var blocked: Array = []
	patrol.blocked_by_hazard.connect(func(hazard_id: String) -> void: blocked.append(hazard_id))

	patrol.tick(1.0)
	_check("危险范围内不推进", patrol.get_position().is_equal_approx(Vector3.ZERO))
	_check("被危险挡住时发一次 blocked_by_hazard",
		blocked.size() == 1 and String(blocked[0]) == "H1")
	patrol.tick(1.0)
	_check("持续被挡不重复发信号", blocked.size() == 1 and patrol.get_position().is_equal_approx(Vector3.ZERO))

	source.active.clear()
	patrol.tick(1.0)
	_check("危险解除后恢复推进", patrol.get_position().is_equal_approx(Vector3(2, 0, 0)))

	patrol.set_hazard_source(null)
	patrol.tick(1.0)
	_check("解除危险源后继续推进", patrol.get_position().is_equal_approx(Vector3(4, 0, 0)))
	patrol.free()


func _test_patrol_blocked_with_callable_source() -> void:
	var patrol = _make_patrol([Vector3(0, 0, 0), Vector3(10, 0, 0)], 2.0)
	# 允许直接给 Callable（W12 可以按需接线，不必先包一个对象）。
	var gate := {"on": true}
	patrol.set_hazard_source(func(position: Vector3) -> Array:
		return ["H2"] if gate["on"] and position.x < 3.0 else []
	)
	patrol.tick(2.0)
	_check("Callable 危险源也能挡住敌人", patrol.get_position().is_equal_approx(Vector3.ZERO))
	gate["on"] = false
	patrol.tick(5.0)
	_check("Callable 危险源解除后恢复推进",
		patrol.get_position().is_equal_approx(Vector3(10, 0, 0)))
	patrol.free()


func _test_patrol_does_not_tunnel_into_hazard() -> void:
	# 验收补充：危险出现在前进路径上时，大 delta 也不能一步穿进危险区。
	var patrol = _make_patrol([Vector3(0, 0, 0), Vector3(10, 0, 0)], 2.0)
	var source := FakeHazardSource.new()
	source.origin = Vector3(4, 0, 0)
	source.radius = 2.0
	source.active = ["H3"]
	patrol.set_hazard_source(source)
	var blocked: Array = []
	patrol.blocked_by_hazard.connect(func(hazard_id: String) -> void: blocked.append(hazard_id))

	patrol.tick(2.0)
	_check("大 delta 前进不穿进新危险区（停在边界附近）",
		absf(patrol.get_position().x - 2.0) <= 0.11)
	_check("路径采样发现危险时发 blocked_by_hazard",
		blocked.size() == 1 and String(blocked[0]) == "H3")
	patrol.tick(0.1)
	_check("贴着危险边界不重复发信号", blocked.size() == 1)
	source.active.clear()
	patrol.tick(1.0)
	_check("危险解除后继续推进", patrol.get_position().x > 2.5)
	patrol.free()


func _test_patrol_dedupes_hazard_ids() -> void:
	# 同一个 source 在同一次查询里返回重复 id 时，只按 id 发一次信号。
	var patrol = _make_patrol([Vector3(0, 0, 0), Vector3(10, 0, 0)], 2.0)
	var source := FakeHazardSource.new()
	source.origin = Vector3.ZERO
	source.radius = 1.0
	source.active = ["H1", "H1", "H2"]
	patrol.set_hazard_source(source)
	var blocked: Array = []
	patrol.blocked_by_hazard.connect(func(hazard_id: String) -> void: blocked.append(hazard_id))

	patrol.tick(0.1)
	_check("重复 hazard id 去重后只发 H1、H2 各一次",
		blocked.size() == 2 and String(blocked[0]) == "H1" and String(blocked[1]) == "H2")
	patrol.tick(0.1)
	_check("持续被挡仍不重复发信号", blocked.size() == 2)
	patrol.free()


func _test_patrol_static_guard() -> void:
	# 单 waypoint 的站桩守卫没有移动方向，需要显式朝向才能形成视野。
	var guard = _make_patrol([Vector3(0, 0, 0)], 0.0)
	guard.set_facing(Vector3(0, 0, -1))
	_check("站桩守卫按 set_facing 看见正面目标", guard.sees(Vector3(0, 0, -5)))
	_check("站桩守卫看不见背面目标", not guard.sees(Vector3(0, 0, 5)))
	guard.free()


func _test_patrol_node_target() -> void:
	# 未入树的 Node3D 调 get_global_position() 会报错并返回原点；应退回本地 position。
	# 额外用身后目标锁住修复：旧逻辑会把它误判到原点（可见）。
	var patrol = _make_patrol([Vector3(0, 0, 0), Vector3(10, 0, 0)], 2.0)
	var marker := Node3D.new()
	marker.position = Vector3(5, 0, 0)
	_check("未入树 Node3D 前方目标按 position 判定", patrol.sees(marker))
	marker.position = Vector3(-5, 0, 0)
	_check("未入树 Node3D 身后目标不可见", not patrol.sees(marker))
	marker.free()

	# 入树目标必须用 global_position（父节点带偏移时不能退回本地 position）。
	var parent := Node3D.new()
	root.add_child(parent)
	parent.position = Vector3(10, 0, 0)
	var child := Node3D.new()
	child.position = Vector3(-5, 0, 0)
	parent.add_child(child)
	_check("入树 Node3D 目标按 global_position 判定", patrol.sees(child))
	parent.free()
	patrol.free()


func _test_patrol_state() -> void:
	var patrol = _make_patrol([Vector3(0, 0, 0), Vector3(10, 0, 0)], 2.0)
	patrol.tick(1.0)
	var state: Dictionary = patrol.get_state()
	_check("get_state 报告当前位置",
		Vector3(state.get("position", Vector3.INF)).is_equal_approx(Vector3(2, 0, 0)))
	_check("get_state 报告速度", is_equal_approx(float(state.get("speed", -1.0)), 2.0))
	_check("get_state 报告 waypoint 数量", int(state.get("waypoint_count", -1)) == 2)
	_check("get_state 报告下一段索引", int(state.get("next_index", -1)) == 1)
	var vision: Dictionary = state.get("vision", {})
	_check("get_state 报告视锥半角/射程",
		is_equal_approx(float(vision.get("half_angle_deg", -1.0)), 45.0)
		and is_equal_approx(float(vision.get("range_m", -1.0)), 10.0))
	patrol.free()


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
		print("ENEMY_PATROL_TEST_PASS (%d checks)" % _checks)
		quit(0)
	else:
		printerr("ENEMY_PATROL_TEST_FAIL (%d/%d failed)" % [_failures.size(), _checks])
		for failure in _failures:
			printerr("  - ", failure)
		quit(1)
