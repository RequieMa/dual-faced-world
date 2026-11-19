extends SceneTree
## 解谜实验室的自动化测试。
## 运行：godot --headless --path . --script tests/test_puzzle_lab.gd
## 退出码 0 = 全绿，1 = 有用例失败。
##
## 覆盖：8 种谜题的「错误输入不通过 / 正确输入解开 / 信号 / 重置可重玩」，
## 以及实验室场景的进度统计、完成横幅、重复解谜不重复计数、整体重置。

const PUZZLE_DIR := "res://scripts/puzzles/"
const PUZZLE_FILES := {
	"keypad": "keypad_puzzle.gd",
	"key_door": "key_door_puzzle.gd",
	"sequence": "sequence_puzzle.gd",
	"combine": "combine_puzzle.gd",
	"wire": "wire_puzzle.gd",
	"dial": "dial_puzzle.gd",
	"hidden": "hidden_object_puzzle.gd",
	"testimony": "testimony_puzzle.gd",
}
const LAB_SCENE := "res://scenes/puzzle_lab.tscn"

var _failures: Array[String] = []
var _checks := 0
var _started := false


func _initialize() -> void:
	for id in PUZZLE_FILES.keys():
		_check("存在 %s%s" % [PUZZLE_DIR, PUZZLE_FILES[id]],
			ResourceLoader.exists(PUZZLE_DIR + String(PUZZLE_FILES[id])))
	_check("存在 scenes/puzzle_lab.tscn", ResourceLoader.exists(LAB_SCENE))


func _process(_delta: float) -> bool:
	if _started:
		return false
	_started = true
	_run_tests()
	return false


func _run_tests() -> void:
	_test_keypad()
	_test_key_door()
	_test_sequence()
	_test_combine()
	_test_wire()
	_test_dial()
	_test_hidden()
	_test_testimony()
	await _test_lab_scene()
	_report()


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
		print("PUZZLE_LAB_TEST_PASS (%d checks)" % _checks)
		quit(0)
	else:
		printerr("PUZZLE_LAB_TEST_FAIL (%d/%d failed)" % [_failures.size(), _checks])
		for failure in _failures:
			printerr("  - ", failure)
		quit(1)


# --- 工具 ---------------------------------------------------------------------

func _new_puzzle(id: String, title: String, hint: String):
	var script_resource = load(PUZZLE_DIR + String(PUZZLE_FILES[id]))
	if script_resource == null:
		_check("%s 可加载" % id, false)
		return null
	var puzzle = script_resource.new()
	root.add_child(puzzle)
	puzzle.setup(id, title, hint)
	return puzzle


func _free_puzzle(puzzle) -> void:
	if puzzle == null:
		return
	if puzzle.get_parent() != null:
		puzzle.get_parent().remove_child(puzzle)
	puzzle.queue_free()


# --- 8 个谜题 ----------------------------------------------------------------

func _test_keypad() -> void:
	var puzzle = _new_puzzle("keypad", "数字密码锁", "40 + 12")
	if puzzle == null:
		return
	var signals: Array = []
	puzzle.solved.connect(func(id: String) -> void: signals.append(id))

	for digit in ["1", "2", "3", "4"]:
		puzzle.press_digit(digit)
	_check("keypad：输错 1234 不会解开", not puzzle.is_solved)
	_check("keypad：错误提交返回 false 并记一次失败", puzzle.submit_code() == false and puzzle.attempts == 1)
	_check("keypad：错误后输入被清空", puzzle.get_entry() == "")

	for digit in ["4", "0", "1", "2"]:
		puzzle.press_digit(digit)
	_check("keypad：正确密码 4012 解开", puzzle.submit_code() == true and puzzle.is_solved)
	_check("keypad：发出 solved 信号且只发一次", signals.size() == 1 and String(signals[0]) == "keypad")
	_check("keypad：解开后再提交不会重复触发", puzzle.submit_code() == false and signals.size() == 1)
	_check("keypad：解开后页内重置按钮被禁用（避免与实验室进度不一致）", not puzzle.is_reset_enabled())
	puzzle.reset()
	_check("keypad：重置后可重玩", not puzzle.is_solved and puzzle.get_entry() == "" and puzzle.attempts == 0)
	_check("keypad：重置后页内重置按钮恢复", puzzle.is_reset_enabled())
	_free_puzzle(puzzle)


func _test_key_door() -> void:
	var puzzle = _new_puzzle("key_door", "钥匙与门", "黄铜钥匙 / 生锈钥匙")
	if puzzle == null:
		return
	_check("key_door：先拿到黄铜钥匙", puzzle.pickup("黄铜钥匙"))
	_check("key_door：对错目标有反馈", puzzle.use("黄铜钥匙", "窗户") == false and puzzle.attempts == 1)
	puzzle.pickup("生锈钥匙")
	_check("key_door：生锈钥匙开铁门失败", puzzle.use("生锈钥匙", "铁门") == false and not puzzle.is_solved)
	_check("key_door：失败后生锈钥匙断在锁里", not puzzle.get_inventory().has("生锈钥匙"))
	_check("key_door：黄铜钥匙开铁门成功", puzzle.use("黄铜钥匙", "铁门") == true and puzzle.is_solved and puzzle.door_open)
	puzzle.reset()
	_check("key_door：重置清空背包", puzzle.get_inventory().is_empty() and not puzzle.is_solved)
	_free_puzzle(puzzle)


func _test_sequence() -> void:
	var puzzle = _new_puzzle("sequence", "开关顺序", "B → D → A → C → E")
	if puzzle == null:
		return
	_check("sequence：第一步按错就复位", puzzle.press(1) == false and puzzle.get_progress().is_empty() and puzzle.attempts == 1)
	_check("sequence：前两步正确", puzzle.press(2) and puzzle.press(4) and puzzle.get_progress().size() == 2)
	_check("sequence：第三步按错复位", puzzle.press(2) == false and puzzle.get_progress().is_empty())
	for value in [2, 4, 1, 3, 5]:
		puzzle.press(value)
	_check("sequence：完整顺序解开", puzzle.is_solved)
	puzzle.reset()
	_check("sequence：重置后可重玩", not puzzle.is_solved and puzzle.get_progress().is_empty())
	_free_puzzle(puzzle)


func _test_combine() -> void:
	var puzzle = _new_puzzle("combine", "物品组合", "镜片 + 镜筒")
	if puzzle == null:
		return
	_check("combine：不能凭空合成", puzzle.combine("镜片", "不存在的东西") == false)
	_check("combine：错误组合有反馈", puzzle.combine("镜片", "纸条") == false and puzzle.attempts >= 1)
	_check("combine：镜片 + 镜筒 → 望远镜", puzzle.combine("镜片", "镜筒") and puzzle.get_inventory().has("望远镜"))
	_check("combine：用望远镜观察窗台解开", puzzle.use("望远镜", "窗台") and puzzle.is_solved)
	puzzle.reset()
	_check("combine：重置回到初始三件物品", puzzle.get_inventory().size() == 3 and not puzzle.is_solved)
	_free_puzzle(puzzle)


func _test_wire() -> void:
	var puzzle = _new_puzzle("wire", "线路连接", "红→1…")
	if puzzle == null:
		return
	_check("wire：接错会弹开", puzzle.connect_wire("红", "2") == false and puzzle.get_connected().is_empty() and puzzle.attempts == 1)
	_check("wire：红→1 接对", puzzle.connect_wire("红", "1") and puzzle.get_connected().size() == 1)
	_check("wire：蓝→2 接对", puzzle.connect_wire("蓝", "2"))
	_check("wire：绿→3 接对", puzzle.connect_wire("绿", "3"))
	_check("wire：黄→4 接对并解开", puzzle.connect_wire("黄", "4") and puzzle.is_solved)
	puzzle.reset()
	_check("wire：重置后未解开", not puzzle.is_solved and puzzle.get_connected().is_empty())
	_free_puzzle(puzzle)


func _test_dial() -> void:
	var puzzle = _new_puzzle("dial", "转盘拨轮", "3 · 7 · 1")
	if puzzle == null:
		return
	puzzle.rotate(0, 1)
	_check("dial：拨一下不会解开", not puzzle.is_solved and puzzle.get_values()[0] == 1)
	puzzle.rotate(0, 3)
	_check("dial：拨轮累加", puzzle.get_values()[0] == 4)
	puzzle.rotate(0, -1)
	puzzle.rotate(1, 7)
	puzzle.rotate(2, 1)
	_check("dial：三位拨到 3-7-1 解开", puzzle.is_solved)
	puzzle.reset()
	_check("dial：重置回 0-0-0", puzzle.get_values() == [0, 0, 0] and not puzzle.is_solved)
	# 回归：build_body() 必须清空 _value_labels，否则重复重置会累积已释放的 Label
	puzzle.reset()
	puzzle.rotate(0, 1)
	_check("dial：重复重置后数值仍能更新（Label 引用不泄漏）",
		puzzle.get_values()[0] == 1 and puzzle._value_labels.size() == 3 and puzzle._value_labels[0].text == "1",
		"labels=%d text=%s" % [puzzle._value_labels.size(), puzzle._value_labels[0].text if puzzle._value_labels.size() > 0 else "n/a"])
	_free_puzzle(puzzle)


func _test_hidden() -> void:
	var puzzle = _new_puzzle("hidden", "隐藏物", "5 件")
	if puzzle == null:
		return
	var spots: Array = puzzle.get_spots()
	var found_count := 0
	for index in range(spots.size()):
		var target := String(spots[index]["target"])
		var hit: bool = puzzle.search(index)
		if target.is_empty():
			_check("hidden：翻空位置「%s」不计数" % String(spots[index]["label"]), hit == false)
		else:
			found_count += 1
			_check("hidden：在「%s」找到 %s" % [String(spots[index]["label"]), target], hit)
	_check("hidden：5 件目标物全部找到后解开", found_count == 5 and puzzle.is_solved)
	puzzle.reset()
	_check("hidden：重置后未解开", not puzzle.is_solved and puzzle.get_found().is_empty())
	_free_puzzle(puzzle)


func _test_testimony() -> void:
	var puzzle = _new_puzzle("testimony", "证词推理", "选矛盾")
	if puzzle == null:
		return
	_check("testimony：选错证词不通过", puzzle.select("甲") == false and not puzzle.is_solved)
	_check("testimony：选中矛盾证词丙后解开", puzzle.select("丙") == true and puzzle.is_solved)
	puzzle.reset()
	_check("testimony：重置后可重玩", not puzzle.is_solved and puzzle.get_selected() == "")
	_free_puzzle(puzzle)


# --- 实验室场景 ---------------------------------------------------------------

func _solve_puzzle(puzzle) -> void:
	if puzzle == null:
		return
	match String(puzzle.puzzle_id):
		"keypad":
			for digit in ["4", "0", "1", "2"]:
				puzzle.press_digit(digit)
			puzzle.submit_code()
		"key_door":
			puzzle.pickup("黄铜钥匙")
			puzzle.use("黄铜钥匙", "铁门")
		"sequence":
			for value in [2, 4, 1, 3, 5]:
				puzzle.press(value)
		"combine":
			puzzle.combine("镜片", "镜筒")
			puzzle.use("望远镜", "窗台")
		"wire":
			for pair in [["红", "1"], ["蓝", "2"], ["绿", "3"], ["黄", "4"]]:
				puzzle.connect_wire(pair[0], pair[1])
		"dial":
			puzzle.rotate(0, 3)
			puzzle.rotate(1, 7)
			puzzle.rotate(2, 1)
		"hidden":
			var spots: Array = puzzle.get_spots()
			for index in range(spots.size()):
				if not String(spots[index]["target"]).is_empty():
					puzzle.search(index)
		"testimony":
			puzzle.select("丙")


func _test_lab_scene() -> void:
	if not ResourceLoader.exists(LAB_SCENE):
		_check("实验室场景存在", false)
		return
	var packed := load(LAB_SCENE) as PackedScene
	var lab := packed.instantiate() if packed != null else null
	_check("puzzle_lab.tscn 可实例化", lab != null)
	if lab == null:
		return
	root.add_child(lab)
	await create_timer(0.1).timeout

	_check("实验室有 8 个谜题台", lab.get_puzzle_defs().size() == 8)
	_check("初始进度 0/8", lab.solved_count() == 0 and not lab.is_complete())

	# 回归：全屏 UI 根节点必须是 IGNORE，否则会把 3D 台子的鼠标事件吃掉
	var root_ui := lab.get_node_or_null("UI/Root") as Control
	_check("全屏 UI 根节点不吞鼠标事件", root_ui != null and root_ui.mouse_filter == Control.MOUSE_FILTER_IGNORE,
		"filter=%s" % (str(root_ui.mouse_filter) if root_ui != null else "n/a"))

	# 回归：点 3D 台子要能打开谜题。
	# headless 下没有真实的 3D 拾取（取决于窗口/渲染），这里直接触发 Area3D 的
	# input_event 信号来覆盖「信号 → 处理器」这一段；真实鼠标点台子已在真机验证。
	var area := lab.get_node_or_null("Station_02/ClickArea") as Area3D
	_check("2 号台子有 ClickArea（Area3D）", area != null)
	if area != null:
		var press := InputEventMouseButton.new()
		press.button_index = MOUSE_BUTTON_LEFT
		press.pressed = true
		area.input_event.emit(null, press, Vector3.ZERO, Vector3.UP, 0)
		await create_timer(0.1).timeout
		_check("点击 3D 台子 2 能打开谜题（key_door）",
			int(lab.get_lab_snapshot()["active_index"]) == 1,
			"active=%s" % str(lab.get_lab_snapshot()["active_index"]))
		lab.close_puzzle()

	for index in range(8):
		lab.open_puzzle(index)
		var puzzle = lab.get_active_puzzle()
		var expected_id := String(lab.get_puzzle_defs()[index]["id"])
		_check("第 %d 个谜题可打开（%s）" % [index + 1, expected_id],
			puzzle != null and String(puzzle.puzzle_id) == expected_id)
		_check("打开谜题不会改变进度", lab.solved_count() == index)
		_solve_puzzle(puzzle)
		_check("解开后进度变成 %d/8" % (index + 1), lab.solved_count() == index + 1,
			"got %d" % lab.solved_count())
		lab.close_puzzle()
		_check("关闭后没有活动页面", lab.get_active_puzzle() == null)

	_check("8 个全部解开后 is_complete", lab.is_complete())
	var banner := lab.get_node_or_null("UI/Root/CompleteBanner")
	_check("完成横幅可见", banner != null and banner.visible)
	lab.open_puzzle(0)
	_check("打开谜题页面时完成横幅隐藏（不压住页面）", banner != null and not banner.visible)
	lab.close_puzzle()
	_check("关闭谜题页面后完成横幅恢复", banner != null and banner.visible)
	var snapshot: Dictionary = lab.get_lab_snapshot()
	_check("快照显示 8/8", int(snapshot["solved_count"]) == 8 and String(snapshot["progress_text"]).contains("8 / 8"))

	lab.open_puzzle(0)
	_solve_puzzle(lab.get_active_puzzle())
	_check("重复解开同一个谜题不会重复计数", lab.solved_count() == 8)
	lab.close_puzzle()

	lab.reset_lab()
	_check("reset_lab 清空进度", lab.solved_count() == 0 and not lab.is_complete())
	lab.queue_free()
