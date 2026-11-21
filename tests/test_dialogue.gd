extends SceneTree
## W3 两类对话框（路人 / 朋友）的自动化测试。
## 运行：godot --headless --path . --script tests/test_dialogue.gd
## 退出码 0 = 全绿，1 = 有用例失败。
##
## 覆盖：两套主题（颜色/边框/字号 + 可配置）、group 别名归一化、数据驱动台词、
## 逐行 advance、finished 信号、group 覆盖、坏 JSON / 缺字段 / 未知 id 的兜底与
## 错误信号、UI 节点按 group 切换样式（不依赖字体渲染）。
##
## 按 AGENTS.md §2：本文件先于实现写（红），实现后转绿。

const CONTROLLER_PATH := "res://scripts/dialogue/dialogue_controller.gd"
const THEME_PATH := "res://scripts/dialogue/dialogue_theme.gd"
const DEFS_PATH := "res://resources/data/dialogues.json"
const SCHEMA_PATH := "res://resources/data/schema/dialogues.schema.json"
const CONFIG_LOADER_PATH := "res://scripts/config/config_loader.gd"
var _temp_dir := "user://dialogue_test"

var _failures: Array[String] = []
var _checks := 0
var _started := false


func _initialize() -> void:
	_check("存在 scripts/dialogue/dialogue_controller.gd", ResourceLoader.exists(CONTROLLER_PATH))
	_check("存在 scripts/dialogue/dialogue_theme.gd", ResourceLoader.exists(THEME_PATH))
	_check("存在 resources/data/dialogues.json（示例 2 段）", ResourceLoader.exists(DEFS_PATH))
	_check("存在 resources/data/schema/dialogues.schema.json", ResourceLoader.exists(SCHEMA_PATH))


func _process(_delta: float) -> bool:
	if _started:
		return false
	_started = true
	# 模块缺失时只报「文件不存在」，不往下跑（否则每个用例都会二次报错）。
	if not ResourceLoader.exists(CONTROLLER_PATH) or not ResourceLoader.exists(THEME_PATH):
		_report()
		return false
	# 每次进程独立目录：run_all / 并行跑测不会互删 user:// 下的临时文件。
	_temp_dir = "user://dialogue_test_%d" % OS.get_process_id()
	_ensure_temp_dir()
	_test_theme_two_styles()
	_test_theme_normalize()
	_test_theme_configurable()
	_test_sample_data()
	_test_load_and_advance()
	_test_group_override()
	_test_errors()
	_test_state_and_restart()
	_test_ui_switch()
	_cleanup()
	_report()
	return false


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


func _report() -> void:
	print("----")
	if _failures.is_empty():
		print("DIALOGUE_TEST_PASS (%d checks)" % _checks)
		quit(0)
	else:
		printerr("DIALOGUE_TEST_FAIL (%d/%d failed)" % [_failures.size(), _checks])
		for failure in _failures:
			printerr("  - ", failure)
		quit(1)


func _new_controller():
	var script = load(CONTROLLER_PATH)
	if script == null:
		_check("DialogueController 脚本可加载", false)
		return null
	return script.new()


func _new_theme():
	var script = load(THEME_PATH)
	if script == null:
		_check("DialogueTheme 脚本可加载", false)
		return null
	return script.new()


## 收集控制器信号；返回的数组随信号增长，供用例断言。
func _watch(controller) -> Dictionary:
	var shown: Array = []
	var finished_ids: Array = []
	var errors: Array = []
	controller.line_shown.connect(func(line: Dictionary) -> void: shown.append(line))
	controller.finished.connect(func(dialogue_id: String) -> void: finished_ids.append(dialogue_id))
	controller.error_occurred.connect(func(message: String) -> void: errors.append(message))
	return {"shown": shown, "finished": finished_ids, "errors": errors}


func _ensure_temp_dir() -> void:
	var absolute := ProjectSettings.globalize_path(_temp_dir)
	if not DirAccess.dir_exists_absolute(absolute):
		DirAccess.make_dir_recursive_absolute(absolute)


func _write(name: String, content: String) -> String:
	var path := _temp_dir + "/" + name
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(content)
	file.close()
	return path


func _cleanup() -> void:
	var absolute := ProjectSettings.globalize_path(_temp_dir)
	if DirAccess.dir_exists_absolute(absolute):
		for file_name in DirAccess.get_files_at(absolute):
			DirAccess.remove_absolute(absolute + "/" + file_name)
		DirAccess.remove_absolute(absolute)


## 2 段合法测试数据：一段 real（2 行）、一段 imaginary（1 行）。
func _write_valid() -> String:
	return _write("valid.json", JSON.stringify({
		"dialogues": [
			{
				"id": "d_real",
				"group": "real",
				"lines": [
					{"speaker": "A", "text": "一"},
					{"speaker": "B", "text": "二"},
				],
			},
			{
				"id": "d_imaginary",
				"group": "imaginary",
				"lines": [
					{"speaker": "C", "text": "三"},
				],
			},
		],
	}))


# --- 主题 ---------------------------------------------------------------------

func _test_theme_two_styles() -> void:
	var theme = _new_theme()
	if theme == null:
		return
	var real: Dictionary = theme.get_style("real")
	var imaginary: Dictionary = theme.get_style("imaginary")
	for field in ["bg_color", "border_color", "text_color", "speaker_color",
			"border_width", "corner_radius", "font_size", "speaker_font_size", "padding"]:
		_check("两套主题都有字段：%s" % field, real.has(field) and imaginary.has(field))
	_check("两套主题背景色不同", real["bg_color"] != imaginary["bg_color"], str(real["bg_color"]))
	_check("两套主题边框色不同", real["border_color"] != imaginary["border_color"])
	_check("两套主题边框宽度不同",
		int(real["border_width"]) != int(imaginary["border_width"]),
		"%s vs %s" % [real["border_width"], imaginary["border_width"]])
	_check("两套主题字号不同",
		int(real["font_size"]) != int(imaginary["font_size"]),
		"%s vs %s" % [real["font_size"], imaginary["font_size"]])
	_check("real = 路人、imaginary = 朋友",
		String(real["display_name"]) == "路人" and String(imaginary["display_name"]) == "朋友",
		"%s / %s" % [real["display_name"], imaginary["display_name"]])


func _test_theme_normalize() -> void:
	var theme = _new_theme()
	if theme == null:
		return
	_check("real 归一化为 real", String(theme.normalize_group("real")) == "real")
	_check("imaginary 归一化为 imaginary", String(theme.normalize_group("imaginary")) == "imaginary")
	_check("stranger 归一化为 real（路人）", String(theme.normalize_group("stranger")) == "real")
	_check("friend 归一化为 imaginary（朋友）", String(theme.normalize_group("friend")) == "imaginary")
	_check("别名大小写不敏感", String(theme.normalize_group("FRIEND")) == "imaginary")
	_check("未知 group 兜底为 real 不崩溃", String(theme.normalize_group("alien")) == "real")
	_check("get_style 接受 friend 别名",
		theme.get_style("friend")["bg_color"] == theme.get_style("imaginary")["bg_color"])
	_check("get_style 接受 stranger 别名",
		theme.get_style("stranger")["bg_color"] == theme.get_style("real")["bg_color"])


func _test_theme_configurable() -> void:
	var theme = _new_theme()
	if theme == null:
		return
	var real_default: int = int(theme.get_style("real")["font_size"])
	theme.set_style_params("imaginary", {"font_size": 28, "border_color": Color(1, 0, 0, 1)})
	var imaginary: Dictionary = theme.get_style("imaginary")
	_check("主题字号可配置", int(imaginary["font_size"]) == 28, str(imaginary["font_size"]))
	_check("主题颜色可配置", imaginary["border_color"] == Color(1, 0, 0, 1), str(imaginary["border_color"]))
	_check("配置只影响目标 group", int(theme.get_style("real")["font_size"]) == real_default)
	var box: StyleBoxFlat = theme.make_stylebox("friend")
	_check("stylebox 使用配置后的边框色", box.border_color == Color(1, 0, 0, 1))
	_check("stylebox 边框宽度与主题一致",
		box.border_width_left == int(imaginary["border_width"]) and box.border_width_top == box.border_width_left)
	_check("stylebox 圆角与主题一致", box.corner_radius_top_left == int(imaginary["corner_radius"]))
	theme.set_style_params("friend", {"corner_radius": 2})
	_check("别名配置写到规范 group", int(theme.get_style("imaginary")["corner_radius"]) == 2)
	theme.set_style_params("real", {"border_width": 6, "padding": 22})
	var real_configured: Dictionary = theme.get_style("real")
	var real_box: StyleBoxFlat = theme.make_stylebox("real")
	_check("边框宽度可配置",
		int(real_configured["border_width"]) == 6 and real_box.border_width_left == 6,
		str(real_box.border_width_left))
	_check("内边距可配置", real_box.content_margin_left == 22, str(real_box.content_margin_left))
	theme.reset_style_params()
	_check("reset_style_params 恢复默认",
		int(theme.get_style("imaginary")["font_size"]) != 28
		and int(theme.get_style("imaginary")["corner_radius"]) != 2)


# --- 数据 ---------------------------------------------------------------------

func _test_sample_data() -> void:
	var loader_script = load(CONFIG_LOADER_PATH)
	if loader_script == null:
		_check("ConfigLoader 可加载", false)
		return
	var loader = loader_script.new()
	var data: Dictionary = loader.load_json(DEFS_PATH, SCHEMA_PATH)
	_check("示例 dialogues.json 通过 schema 校验", not data.is_empty(), str(loader.last_errors))
	if data.is_empty():
		return
	var dialogues: Array = data.get("dialogues", [])
	_check("示例数据有 2 段对话", dialogues.size() == 2, str(dialogues.size()))
	var groups: Array = []
	for entry in dialogues:
		groups.append(String(entry.get("group", "")))
	_check("示例数据覆盖 real 与 imaginary 两组",
		groups.has("real") and groups.has("imaginary"), str(groups))

	var controller = _new_controller()
	if controller == null:
		return
	_check("加载示例 dialogues.json 成功", controller.load_defs(DEFS_PATH))
	for entry in dialogues:
		var dialogue: Dictionary = entry
		_check("示例对话可 start：%s" % dialogue["id"],
			controller.start(String(dialogue["id"])))
		_check("示例对话 group 与数据一致：%s" % dialogue["id"],
			String(controller.get_state()["group"]) == String(dialogue["group"]))
	controller.free()


# --- 逐行播放 ----------------------------------------------------------------

func _test_load_and_advance() -> void:
	var controller = _new_controller()
	if controller == null:
		return
	var watch := _watch(controller)
	_check("加载合法 JSON 成功", controller.load_defs(_write_valid()))
	_check("加载成功后未播放", not controller.is_active())
	_check("start 合法 id 成功", controller.start("d_real"))
	_check("start 后立刻显示第一行", watch["shown"].size() == 1, str(watch["shown"]))
	if watch["shown"].size() == 1:
		var line: Dictionary = watch["shown"][0]
		_check("line_shown 带 speaker / text / group",
			line.get("speaker") == "A" and line.get("text") == "一" and line.get("group") == "real",
			str(line))
	_check("播放中 is_active 为真", controller.is_active())
	controller.advance()
	_check("advance 显示第二行", watch["shown"].size() == 2, str(watch["shown"].size()))
	if watch["shown"].size() == 2:
		_check("第二行内容正确", watch["shown"][1].get("text") == "二")
		_check("第二行 group 保持 real", watch["shown"][1].get("group") == "real")
	controller.advance()
	_check("最后一行后发 finished", watch["finished"] == ["d_real"], str(watch["finished"]))
	_check("结束后 is_active 为假", not controller.is_active())
	_check("结束后不补发多余的 line_shown", watch["shown"].size() == 2, str(watch["shown"].size()))
	controller.advance()
	_check("结束后再 advance 无副作用",
		watch["shown"].size() == 2 and watch["finished"].size() == 1)
	_check("单行对话也能 start", controller.start("d_imaginary"))
	controller.advance()
	_check("单行对话 advance 后直接 finished",
		watch["finished"] == ["d_real", "d_imaginary"] and not controller.is_active(),
		str(watch["finished"]))
	controller.free()


func _test_group_override() -> void:
	var controller = _new_controller()
	if controller == null:
		return
	var watch := _watch(controller)
	controller.load_defs(_write_valid())
	_check("friend 覆盖 real 对话：切到 imaginary",
		controller.start("d_real", "friend") and String(controller.get_state()["group"]) == "imaginary")
	if not watch["shown"].is_empty():
		_check("覆盖后 line_shown 的 group 已归一化",
			watch["shown"].back().get("group") == "imaginary", str(watch["shown"].back()))
	_check("stranger 覆盖 imaginary 对话：切到 real",
		controller.start("d_imaginary", "stranger") and String(controller.get_state()["group"]) == "real")
	_check("不传覆盖时用对话自带的 group",
		controller.start("d_imaginary") and String(controller.get_state()["group"]) == "imaginary")
	_check("真实 group 覆盖生效",
		controller.start("d_imaginary", "real") and String(controller.get_state()["group"]) == "real")
	_check("未知覆盖值兜底为 real 不崩溃",
		controller.start("d_imaginary", "alien") and String(controller.get_state()["group"]) == "real")
	controller.free()


# --- 兜底与错误信号 -----------------------------------------------------------

func _test_errors() -> void:
	var controller = _new_controller()
	if controller == null:
		return
	var watch := _watch(controller)
	var errors: Array = watch["errors"]

	_check("坏 JSON 加载失败", not controller.load_defs(_write("bad.json", "{oops")))
	_check("坏 JSON 有错误信号", errors.size() == 1, str(errors))
	_check("加载失败不发 line_shown", watch["shown"].is_empty(), str(watch["shown"]))
	_check("加载失败后 start 任何 id 都失败", not controller.start("d_real"))

	var before := errors.size()
	var missing_lines := _write("missing_lines.json",
		"{\"dialogues\": [{\"id\": \"no_lines\", \"group\": \"real\"}]}")
	_check("缺 lines 字段加载失败", not controller.load_defs(missing_lines))
	_check("缺字段有错误信号", errors.size() == before + 1, str(errors))

	before = errors.size()
	var bad_group := _write("bad_group.json",
		"{\"dialogues\": [{\"id\": \"alias\", \"group\": \"friend\", " +
		"\"lines\": [{\"speaker\": \"A\", \"text\": \"x\"}]}]}")
	_check("数据里写别名 friend 被 schema 拒绝（规范值才进数据）", not controller.load_defs(bad_group))
	_check("非法 group 有错误信号", errors.size() == before + 1, str(errors))

	before = errors.size()
	var bad_lines := _write("bad_lines.json",
		"{\"dialogues\": [{\"id\": \"x\", \"group\": \"real\", \"lines\": \"不是数组\"}]}")
	_check("lines 类型错误加载失败", not controller.load_defs(bad_lines))
	_check("类型错误有错误信号", errors.size() == before + 1, str(errors))

	before = errors.size()
	_check("根节点是数组时加载失败", not controller.load_defs(_write("array_root.json", "[1, 2, 3]")))
	_check("数组根有错误信号", errors.size() == before + 1, str(errors))

	before = errors.size()
	var empty_lines := _write("empty_lines.json",
		"{\"dialogues\": [{\"id\": \"empty\", \"group\": \"real\", \"lines\": []}]}")
	_check("空台词加载失败（不返回半成品）", not controller.load_defs(empty_lines))
	_check("空台词有错误信号", errors.size() == before + 1, str(errors))

	before = errors.size()
	var duplicate := _write("duplicate.json", JSON.stringify({"dialogues": [
		{"id": "dup", "group": "real", "lines": [{"speaker": "A", "text": "一"}]},
		{"id": "dup", "group": "imaginary", "lines": [{"speaker": "B", "text": "二"}]},
	]}))
	_check("重复 id 加载失败", not controller.load_defs(duplicate))
	_check("重复 id 有错误信号", errors.size() == before + 1, str(errors))

	before = errors.size()
	_check("文件不存在加载失败", not controller.load_defs(_temp_dir + "/no_such_file.json"))
	_check("文件不存在有错误信号", errors.size() == before + 1, str(errors))

	# 失败加载不能留下半成品：重新加载失败后旧定义也清空。
	_check("先加载合法数据", controller.load_defs(_write_valid()))
	_check("再加载坏数据失败", not controller.load_defs(_write("bad2.json", "{")))
	_check("失败后旧定义不会残留", not controller.start("d_real"))

	_check("重新加载合法数据成功", controller.load_defs(_write_valid()))
	_check("失败后重新加载可正常 start", controller.start("d_real"))
	before = errors.size()
	var shown_before: int = watch["shown"].size()
	_check("未知 dialogue_id 返回 false", not controller.start("no_such_dialogue"))
	_check("未知 dialogue_id 有错误信号", errors.size() == before + 1, str(errors))
	_check("未知 dialogue_id 不发 line_shown", watch["shown"].size() == shown_before)
	controller.free()


func _test_state_and_restart() -> void:
	var controller = _new_controller()
	if controller == null:
		return
	var watch := _watch(controller)
	_check("未加载时 state 为空", not controller.is_active()
		and String(controller.get_state().get("dialogue_id", "x")) == ""
		and int(controller.get_state().get("total", -1)) == 0)
	controller.load_defs(_write_valid())
	controller.start("d_real")
	controller.advance()
	var state: Dictionary = controller.get_state()
	_check("advance 后 index / total 正确",
		int(state.get("index", -1)) == 1 and int(state.get("total", -1)) == 2
		and String(state.get("group", "")) == "real",
		str(state))
	controller.start("d_imaginary")
	state = controller.get_state()
	_check("重新 start 会重置进度与 group",
		int(state.get("index", -1)) == 0 and String(state.get("group", "")) == "imaginary"
		and String(state.get("dialogue_id", "")) == "d_imaginary",
		str(state))
	_check("重新 start 不残留 finished", watch["finished"].is_empty(), str(watch["finished"]))
	controller.free()


# --- UI（无头，不断言字体渲染） -----------------------------------------------

func _test_ui_switch() -> void:
	var controller = _new_controller()
	var theme = _new_theme()
	if controller == null or theme == null:
		if controller != null:
			controller.free()
		return
	get_root().add_child(controller)
	var ui: Dictionary = controller.get_ui_state()
	_check("加入场景树后构建对话框 UI", bool(ui.get("built", false)))
	var real_style: Dictionary = theme.get_style("real")
	var imaginary_style: Dictionary = theme.get_style("imaginary")
	_check("初始不显示对话框", not bool(ui.get("visible", true)))

	controller.load_defs(_write_valid())
	controller.start("d_real")
	ui = controller.get_ui_state()
	_check("播放中对话框可见", bool(ui.get("visible", false)))
	_check("对话框显示当前台词",
		String(ui.get("speaker", "")) == "A" and String(ui.get("text", "")) == "一", str(ui))
	_check("real 对话套用路人主题（边框宽度）",
		int(ui.get("border_width", -1)) == int(real_style["border_width"]), str(ui))
	_check("real 对话套用路人主题（字号）",
		int(ui.get("font_size", -1)) == int(real_style["font_size"]), str(ui))

	controller.start("d_real", "friend")
	ui = controller.get_ui_state()
	_check("friend 覆盖切到朋友主题（边框宽度）",
		int(ui.get("border_width", -1)) == int(imaginary_style["border_width"]), str(ui))
	_check("friend 覆盖切到朋友主题（字号）",
		int(ui.get("font_size", -1)) == int(imaginary_style["font_size"]), str(ui))
	_check("两套 UI 主题确实不同",
		int(real_style["border_width"]) != int(imaginary_style["border_width"])
		and int(real_style["font_size"]) != int(imaginary_style["font_size"]))

	var panel: Control = controller.get_node_or_null("DialoguePanel")
	_check("存在可点击的对话框面板", panel != null)
	if panel != null:
		var click := InputEventMouseButton.new()
		click.button_index = MOUSE_BUTTON_LEFT
		click.pressed = true
		panel.gui_input.emit(click)
		ui = controller.get_ui_state()
		_check("点击对话框推进到下一行", String(ui.get("text", "")) == "二", str(ui))
	controller.advance()
	ui = controller.get_ui_state()
	_check("对话结束后隐藏对话框", not bool(ui.get("visible", true)), str(ui))
	controller.free()
