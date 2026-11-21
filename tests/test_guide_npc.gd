extends SceneTree
## GuideableNpc 状态机自动化测试（W2）。
## 运行：godot --headless --path . --script tests/test_guide_npc.gd
## 退出码 0 = 全绿，1 = 有用例失败。
##
## 覆盖：IDLE / WAIT / FOLLOW / OPEN_DOOR 的全部合法迁移、未知提示、
## 到达信号只发一次、real / imaginary 两组人行为一致、序列化往返与非法字段。

const NPC_SCRIPT := "res://scripts/guide/guideable_npc.gd"
const DOOR_SCRIPT := "res://scripts/guide/guideable_door.gd"

var _failures: Array[String] = []
var _checks := 0
var _started := false


func _initialize() -> void:
	_check("存在 guideable_npc.gd", ResourceLoader.exists(NPC_SCRIPT))
	_check("存在 guideable_door.gd", ResourceLoader.exists(DOOR_SCRIPT))


func _process(_delta: float) -> bool:
	if _started:
		return false
	_started = true
	_run_tests()
	return false


func _run_tests() -> void:
	_test_setup_and_groups()
	_test_wait_transition()
	_test_follow_transition()
	_test_follow_to_wait()
	_test_open_door_transition()
	_test_state_machine_matrix()
	_test_unknown_hint()
	_test_serialization()
	_test_illegal_values()
	_report()


# --- 断言 / 工具 -------------------------------------------------------------

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
		print("GUIDE_NPC_TEST_PASS (%d checks)" % _checks)
		quit(0)
	else:
		printerr("GUIDE_NPC_TEST_FAIL (%d/%d failed)" % [_failures.size(), _checks])
		for failure in _failures:
			printerr("  - ", failure)
		quit(1)


func _new_npc():
	var script = load(NPC_SCRIPT)
	if script == null:
		return null
	var npc = script.new()
	root.add_child(npc)
	return npc


func _new_door():
	var script = load(DOOR_SCRIPT)
	if script == null:
		return null
	var door = script.new()
	root.add_child(door)
	return door


func _free_node(node) -> void:
	if node == null:
		return
	if node.get_parent() != null:
		node.get_parent().remove_child(node)
	node.queue_free()


func _state_name(npc) -> String:
	return String(npc.get_state().get("state", ""))


func _approx(a: Vector3, b: Vector3) -> bool:
	return a.distance_to(b) < 0.0001


# --- setup / 两组人 -----------------------------------------------------------

func _test_setup_and_groups() -> void:
	var npc = _new_npc()
	if npc == null:
		return

	_check("新建 NPC 默认 IDLE", _state_name(npc) == "IDLE")
	npc.setup("npc_a", "real")
	_check("setup 记录 id", String(npc.get_state().get("id", "")) == "npc_a")
	_check("get_target_id 返回 id", String(npc.get_target_id()) == "npc_a")
	_check("real 保持 real", String(npc.get_state().get("group", "")) == "real")
	npc.setup("npc_b", "imaginary")
	_check("imaginary 保持 imaginary", String(npc.get_state().get("group", "")) == "imaginary")
	npc.setup("npc_c", "friend")
	_check("friend 归一化为 imaginary", String(npc.get_state().get("group", "")) == "imaginary")
	npc.setup("npc_cn", "real")
	npc.set_route([Vector3.ZERO, Vector3(1.0, 0.0, 0.0)])
	_check("中文别名「跟我来」-> FOLLOW", npc.on_hint("跟我来") == true and _state_name(npc) == "FOLLOW")
	_check("中文别名「等待」-> WAIT", npc.on_hint("等待") == true and _state_name(npc) == "WAIT")
	_check("中文别名「开门」-> OPEN_DOOR", npc.on_hint("开门") == true and _state_name(npc) == "OPEN_DOOR")
	npc.setup("npc_d", "stranger")
	_check("stranger 归一化为 real", String(npc.get_state().get("group", "")) == "real")
	npc.setup("npc_e", "unknown-group")
	_check("未知 group 兜底为 real", String(npc.get_state().get("group", "")) == "real")
	npc.setup("npc_f", "")
	_check("空 group 兜底为 real", String(npc.get_state().get("group", "")) == "real")

	# 两组人都用同一套状态机（不预设剧情差异）。
	for group in ["real", "imaginary"]:
		var actor = _new_npc()
		actor.setup("actor_" + String(group), String(group))
		actor.set_route([Vector3.ZERO, Vector3(2.0, 0.0, 0.0)])
		actor.set_speed(2.0)
		_check("%s 组能接受 follow" % group, actor.on_hint("follow") == true)
		_check("%s 组进入 FOLLOW" % group, _state_name(actor) == "FOLLOW")
		var arrived: Array = []
		actor.arrived.connect(func(id: String) -> void: arrived.append(id))
		actor.tick(1.0)
		_check("%s 组到达后发 arrived" % group, arrived.size() == 1 and _state_name(actor) == "WAIT")
		_free_node(actor)

	_free_node(npc)


# --- WAIT ---------------------------------------------------------------------

func _test_wait_transition() -> void:
	var npc = _new_npc()
	if npc == null:
		return
	npc.setup("npc_wait", "real")

	_check("IDLE -> WAIT：wait 返回 true", npc.on_hint("wait") == true)
	_check("IDLE -> WAIT：状态为 WAIT", _state_name(npc) == "WAIT")
	var position_before: Vector3 = npc.position
	npc.tick(1.0)
	_check("WAIT 下 tick 不移动", _approx(npc.position, position_before))
	_check("WAIT 下重复 wait 幂等", npc.on_hint("wait") == true and _state_name(npc) == "WAIT")
	_check("IDLE 下 tick 不移动", _state_name(npc) == "WAIT")

	npc.set_route([Vector3.ZERO, Vector3(2.0, 0.0, 0.0)])
	_check("WAIT -> FOLLOW：follow 返回 true", npc.on_hint("follow") == true)
	_check("WAIT -> FOLLOW：状态为 FOLLOW", _state_name(npc) == "FOLLOW")

	_free_node(npc)


# --- FOLLOW -------------------------------------------------------------------

func _test_follow_transition() -> void:
	var npc = _new_npc()
	if npc == null:
		return
	npc.setup("npc_follow", "real")
	npc.set_route([Vector3.ZERO, Vector3(2.0, 0.0, 0.0), Vector3(2.0, 0.0, 2.0)])
	npc.set_speed(2.0)

	var arrived: Array = []
	npc.arrived.connect(func(id: String) -> void: arrived.append(id))

	_check("IDLE -> FOLLOW：follow 返回 true", npc.on_hint("follow") == true)
	_check("IDLE -> FOLLOW：状态为 FOLLOW", _state_name(npc) == "FOLLOW")
	_check("FOLLOW 刚进入时未 arrived", arrived.is_empty())

	npc.tick(0.5)
	_check("FOLLOW 第一段走到中点", _approx(npc.position, Vector3(1.0, 0.0, 0.0)), str(npc.position))
	var mid_route: Vector3 = npc.position
	var mid_index: int = int(npc.get_state().get("waypoint_index", -1))
	_check("FOLLOW 中重复 follow 幂等", npc.on_hint("follow") == true and _state_name(npc) == "FOLLOW")
	_check("FOLLOW 中重复 follow 不重置进度",
		_approx(npc.position, mid_route)
		and int(npc.get_state().get("waypoint_index", -1)) == mid_index)
	npc.tick(0.5)
	_check("FOLLOW 走到第一个路点", _approx(npc.position, Vector3(2.0, 0.0, 0.0)), str(npc.position))
	_check("第二段尚未到达", arrived.is_empty())
	npc.tick(0.5)
	_check("FOLLOW 走上第二段", _approx(npc.position, Vector3(2.0, 0.0, 1.0)), str(npc.position))
	npc.tick(0.5)
	_check("到终点后发 arrived", arrived.size() == 1)
	if arrived.size() == 1:
		_check("arrived 带 npc_id", String(arrived[0]) == "npc_follow")
	_check("到终点后回到 WAIT", _state_name(npc) == "WAIT")
	npc.tick(1.0)
	_check("到达后继续 tick 不重复 arrived", arrived.size() == 1)

	_free_node(npc)


func _test_follow_to_wait() -> void:
	var npc = _new_npc()
	if npc == null:
		return
	npc.setup("npc_switch", "imaginary")
	npc.set_route([Vector3.ZERO, Vector3(4.0, 0.0, 0.0)])
	npc.set_speed(1.0)

	npc.on_hint("follow")
	npc.tick(1.0)
	_check("FOLLOW 中途有位移", not _approx(npc.position, Vector3.ZERO))
	_check("FOLLOW -> WAIT：wait 返回 true", npc.on_hint("wait") == true)
	_check("FOLLOW -> WAIT：状态为 WAIT", _state_name(npc) == "WAIT")
	var frozen: Vector3 = npc.position
	npc.tick(1.0)
	_check("切到 WAIT 后停止移动", _approx(npc.position, frozen))

	# 中途从 FOLLOW 改 open_door 应沿用当前路点进度，而不是倒退回起点。
	npc.on_hint("follow")
	npc.tick(1.0)
	var mid: Vector3 = npc.position
	_check("FOLLOW -> OPEN_DOOR 返回 true", npc.on_hint("open_door") == true)
	_check("FOLLOW -> OPEN_DOOR 不倒退位置", _approx(npc.position, mid))
	_check("FOLLOW -> OPEN_DOOR 状态为 OPEN_DOOR", _state_name(npc) == "OPEN_DOOR")
	npc.tick(0.5)
	_check("FOLLOW -> OPEN_DOOR 继续向前走", npc.position.x > mid.x)

	_free_node(npc)


# --- OPEN_DOOR ----------------------------------------------------------------

func _test_open_door_transition() -> void:
	var npc = _new_npc()
	var door = _new_door()
	if npc == null or door == null:
		_free_node(npc)
		_free_node(door)
		return
	door.setup("door_a")
	npc.setup("npc_door", "real")
	npc.set_route([Vector3.ZERO, Vector3(1.0, 0.0, 0.0)])
	npc.set_speed(2.0)
	npc.set_door_target(door)

	var arrived: Array = []
	npc.arrived.connect(func(id: String) -> void: arrived.append(id))

	_check("IDLE -> OPEN_DOOR：open_door 返回 true", npc.on_hint("open_door") == true)
	_check("IDLE -> OPEN_DOOR：状态为 OPEN_DOOR", _state_name(npc) == "OPEN_DOOR")
	_check("开门动作开始时门未打开", door.is_open() == false)
	npc.tick(0.5)
	_check("OPEN_DOOR 到点后发 arrived", arrived.size() == 1)
	_check("OPEN_DOOR 到点后门被打开", door.is_open() == true)
	_check("OPEN_DOOR 到点后回到 WAIT", _state_name(npc) == "WAIT")

	# 没有门目标时也能完成动作，不应崩。
	var bare = _new_npc()
	bare.setup("npc_bare", "imaginary")
	bare.set_route([Vector3.ZERO, Vector3(1.0, 0.0, 0.0)])
	bare.set_speed(2.0)
	_check("无门目标也能进入 OPEN_DOOR", bare.on_hint("open_door") == true)
	bare.tick(0.5)
	_check("无门目标到达后回到 WAIT", _state_name(bare) == "WAIT")

	_free_node(bare)
	_free_node(npc)
	_free_node(door)


# --- 状态迁移矩阵 -------------------------------------------------------------

func _test_state_machine_matrix() -> void:
	var npc = _new_npc()
	if npc == null:
		return
	npc.setup("npc_matrix", "real")
	npc.set_route([Vector3.ZERO, Vector3(1.0, 0.0, 0.0), Vector3(2.0, 0.0, 0.0)])
	npc.set_speed(1.0)

	_check("矩阵：IDLE -> WAIT", npc.on_hint("wait") == true and _state_name(npc) == "WAIT")
	_check("矩阵：WAIT -> OPEN_DOOR", npc.on_hint("open_door") == true and _state_name(npc) == "OPEN_DOOR")
	npc.tick(2.0)
	_check("矩阵：OPEN_DOOR 到达 -> WAIT", _state_name(npc) == "WAIT")
	_check("矩阵：WAIT -> FOLLOW", npc.on_hint("follow") == true and _state_name(npc) == "FOLLOW")
	_check("矩阵：FOLLOW -> OPEN_DOOR", npc.on_hint("open_door") == true and _state_name(npc) == "OPEN_DOOR")
	_check("矩阵：OPEN_DOOR -> WAIT", npc.on_hint("wait") == true and _state_name(npc) == "WAIT")
	_check("矩阵：WAIT -> FOLLOW（再次）", npc.on_hint("follow") == true and _state_name(npc) == "FOLLOW")
	_check("矩阵：FOLLOW -> FOLLOW 幂等", npc.on_hint("follow") == true and _state_name(npc) == "FOLLOW")
	_check("矩阵：FOLLOW -> OPEN_DOOR（再次）", npc.on_hint("open_door") == true and _state_name(npc) == "OPEN_DOOR")
	_check("矩阵：OPEN_DOOR -> OPEN_DOOR 幂等", npc.on_hint("open_door") == true and _state_name(npc) == "OPEN_DOOR")
	_check("矩阵：OPEN_DOOR -> WAIT（再次）", npc.on_hint("wait") == true and _state_name(npc) == "WAIT")
	_check("矩阵：WAIT -> WAIT 幂等", npc.on_hint("wait") == true and _state_name(npc) == "WAIT")

	_free_node(npc)


# --- 非法输入 ----------------------------------------------------------------

func _test_unknown_hint() -> void:
	var npc = _new_npc()
	if npc == null:
		return
	npc.setup("npc_unknown", "real")
	npc.set_route([Vector3.ZERO, Vector3(1.0, 0.0, 0.0)])

	var needs: Array = []
	npc.needs_hint.connect(func(id: String, hint: String) -> void:
		needs.append({"id": id, "hint": hint})
	)

	_check("未知提示返回 false", npc.on_hint("dance") == false)
	_check("未知提示保持 IDLE", _state_name(npc) == "IDLE")
	_check("未知提示发 needs_hint", needs.size() == 1)
	if needs.size() == 1:
		_check("needs_hint 带 npc_id", String(needs[0]["id"]) == "npc_unknown")
		_check("needs_hint 给出可用提示", String(needs[0]["hint"]) == "follow")
	_check("空提示返回 false", npc.on_hint("   ") == false)

	# 没有路点时 follow 不是有效命令：返回 false 并请求提示。
	var no_route = _new_npc()
	no_route.setup("npc_no_route", "real")
	var no_route_needs: Array = []
	no_route.needs_hint.connect(func(id: String, hint: String) -> void:
		no_route_needs.append(id + ":" + hint)
	)
	_check("无路点 follow 返回 false", no_route.on_hint("follow") == false)
	_check("无路点 follow 请求 wait", no_route_needs.size() == 1 and String(no_route_needs[0]) == "npc_no_route:wait")
	_check("无路点 follow 保持 IDLE", _state_name(no_route) == "IDLE")

	# FOLLOW 中收到未知提示：请求提示但不打断当前移动。
	var moving = _new_npc()
	moving.setup("npc_moving", "imaginary")
	moving.set_route([Vector3.ZERO, Vector3(2.0, 0.0, 0.0)])
	moving.on_hint("follow")
	var moving_needs: Array = []
	moving.needs_hint.connect(func(id: String, hint: String) -> void:
		moving_needs.append(id + ":" + hint)
	)
	_check("FOLLOW 中未知提示返回 false", moving.on_hint("dance") == false)
	_check("FOLLOW 中未知提示保持 FOLLOW", _state_name(moving) == "FOLLOW")
	_check("FOLLOW 中未知提示发 needs_hint", moving_needs.size() == 1)

	_free_node(moving)
	_free_node(no_route)
	_free_node(npc)


# --- 序列化 -------------------------------------------------------------------

func _test_serialization() -> void:
	var npc = _new_npc()
	if npc == null:
		return
	npc.setup("npc_save", "imaginary")
	npc.set_route([Vector3.ZERO, Vector3(2.0, 0.0, 0.0), Vector3(2.0, 0.0, 2.0)])
	npc.set_speed(2.0)
	npc.on_hint("follow")
	npc.tick(0.5)

	var saved: Dictionary = npc.to_dict()
	_check("to_dict 记录 id", String(saved.get("id", "")) == "npc_save")
	_check("to_dict 记录 group", String(saved.get("group", "")) == "imaginary")
	_check("to_dict 记录状态", String(saved.get("state_name", "")) == "FOLLOW")

	var restored = _new_npc()
	restored.from_dict(saved)
	_check("from_dict 恢复 id", String(restored.get_state().get("id", "")) == "npc_save")
	_check("from_dict 恢复 group", String(restored.get_state().get("group", "")) == "imaginary")
	_check("from_dict 恢复状态", _state_name(restored) == "FOLLOW")
	_check("from_dict 恢复位置", _approx(restored.position, npc.position), str(restored.position))
	_check("from_dict 恢复路点索引", int(restored.get_state().get("waypoint_index", -1)) == int(npc.get_state().get("waypoint_index", -2)))

	# 恢复后继续 tick 应能继续走到终点。
	restored.set_speed(2.0)
	var arrived: Array = []
	restored.arrived.connect(func(id: String) -> void: arrived.append(id))
	restored.tick(2.0)
	_check("恢复后可继续完成移动", arrived.size() == 1 and _state_name(restored) == "WAIT")

	# route 也接受 Vector3 形式（宿主内存里直接传，不经过 JSON 数组）。
	var vector_route = _new_npc()
	vector_route.from_dict({"state": 2, "route": [Vector3(0, 0, 0), Vector3(1, 0, 0)]})
	_check("from_dict 接受 Vector3 route", int(vector_route.get_state().get("route_size", 0)) == 2)
	_check("from_dict 恢复 FOLLOW 状态", _state_name(vector_route) == "FOLLOW")

	_free_node(vector_route)
	_free_node(restored)
	_free_node(npc)


func _test_illegal_values() -> void:
	var npc = _new_npc()
	if npc == null:
		return
	npc.setup("npc_illegal", "real")
	npc.set_route([Vector3.ZERO, Vector3(1.0, 0.0, 0.0)])

	npc.tick(-1.0)
	_check("负数 delta 不移动", _approx(npc.position, Vector3.ZERO))
	npc.tick(0.0)
	_check("零 delta 不移动", _approx(npc.position, Vector3.ZERO))

	npc.set_route([Vector3.ZERO, "bad", Vector3(1.0, 0.0, 0.0)])
	_check("set_route 跳过非法条目", npc.get_state().get("route_size", 0) == 2)
	npc.set_speed(-5.0)
	_check("set_speed 拒绝非正数", float(npc.get_state().get("speed", 0.0)) > 0.0)
	npc.set_speed(1.5)
	_check("set_speed 接受正数", is_equal_approx(float(npc.get_state().get("speed", 0.0)), 1.5))

	# 非法 to_dict 字段：不崩、类型不符的字段被忽略。
	var damaged := {
		"id": 123,
		"group": 456,
		"state": "FOLLOW",
		"state_name": 789,
		"position": "not-a-vector",
		"waypoint_index": "not-an-int",
		"speed": "fast",
		"route": "not-an-array",
	}
	npc.from_dict(damaged)
	_check("非法 from_dict 不改变状态", _state_name(npc) == "IDLE")
	_check("非法 from_dict 不改变 id", String(npc.get_state().get("id", "")) == "npc_illegal")

	var empty = _new_npc()
	empty.from_dict({})
	_check("空 from_dict 保持默认状态", _state_name(empty) == "IDLE")
	_check("空 from_dict 保持默认位置", _approx(empty.position, Vector3.ZERO))

	# 没有 route 时 tick 不会崩。
	var idle = _new_npc()
	idle.setup("npc_idle", "real")
	idle.tick(1.0)
	_check("IDLE 无 route tick 不崩", _state_name(idle) == "IDLE")

	_free_node(idle)
	_free_node(empty)
	_free_node(npc)
