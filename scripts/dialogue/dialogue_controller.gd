extends Control
## 两类对话框控制器（W3）。
##
## 契约见 docs/MECHANICS_CONTRACTS.md §5：
##   load_defs(path) / start(dialogue_id, group_override = "") / advance() / is_active() / get_state()
##   signal line_shown(line) / finished(dialogue_id)
##
## 额外错误语义：坏 JSON / 缺字段 / 未知 id / 空台词一律兜底不崩，并发 `error_occurred`。
## 台词全部来自 `resources/data/dialogues.json`（经 ConfigLoader + schema 校验），
## 这里不写死任何剧情；UI 也全部代码内构建（本流不允许新增场景）。
## 主题由 `dialogue_theme.gd` 按 group 提供两套样式，UI 只消费不判断。

signal line_shown(line: Dictionary)     # {"speaker", "text", "group"}，group 已归一化
signal finished(dialogue_id: String)
signal error_occurred(message: String)

const CONFIG_LOADER := preload("res://scripts/config/config_loader.gd")
const DIALOGUE_THEME := preload("res://scripts/dialogue/dialogue_theme.gd")
const DIALOGUE_SCHEMA := "res://resources/data/schema/dialogues.schema.json"

## id -> {"id", "group", "lines"}；只有校验通过的整套定义才会替换进来。
var _defs: Dictionary = {}
var _theme = DIALOGUE_THEME.new()

var _dialogue_id := ""
var _group := ""
var _lines: Array = []
var _index := 0
var _active := false

var _panel: PanelContainer
var _speaker_label: Label
var _text_label: Label
var _hint_label: Label


func _ready() -> void:
	_build_ui()
	_update_ui()


# --- 公开接口（W0 契约） -------------------------------------------------------

## 读取并校验对话定义。失败返回 false、清空旧定义并发 error_occurred，不抛错。
func load_defs(path: String) -> bool:
	_stop()
	_defs.clear()
	var loader = CONFIG_LOADER.new()
	var data: Dictionary = loader.load_json(path, DIALOGUE_SCHEMA)
	if data.is_empty():
		_fail("加载对话定义失败: %s%s" % [path, _join_loader_errors(loader.last_errors)])
		return false
	return _index_defs(data, path)


## 开始一段对话；group_override 非空时覆盖数据里的 group（两者都会归一化）。
## 未知 id / 空台词返回 false 且不发 line_shown。
func start(dialogue_id: String, group_override: String = "") -> bool:
	if not _defs.has(dialogue_id):
		_fail("未知对话 id: %s" % dialogue_id)
		return false
	var definition: Dictionary = _defs[dialogue_id]
	var lines: Array = definition["lines"]
	if lines.is_empty():
		_fail("对话没有台词: %s" % dialogue_id)
		return false

	var group_source := group_override.strip_edges()
	if group_source.is_empty():
		group_source = String(definition["group"])

	_stop()
	_dialogue_id = dialogue_id
	_group = DIALOGUE_THEME.normalize_group(group_source)
	_lines = lines
	_index = 0
	_active = true
	_show_current()
	return true


## 前进一行；最后一行之后发 finished，再 advance 无副作用。
func advance() -> void:
	if not _active:
		return
	_index += 1
	if _index < _lines.size():
		_show_current()
		return
	var ended_id := _dialogue_id
	_stop()
	finished.emit(ended_id)


func is_active() -> bool:
	return _active


func get_state() -> Dictionary:
	var line: Dictionary = {}
	if _active and _index >= 0 and _index < _lines.size():
		line = (_lines[_index] as Dictionary).duplicate(true)
	return {
		"active": _active,
		"dialogue_id": _dialogue_id,
		"group": _group,
		"index": _index,
		"total": _lines.size(),
		"line": line,
	}


## 调试 / 测试用（不属于 W0 契约，W12 不要依赖）：把已构建 UI 的外观摊平成数据，
## 避免测试依赖字体渲染或截图。
func get_ui_state() -> Dictionary:
	var built := _panel != null
	var box: StyleBoxFlat = null
	if built:
		box = _panel.get_theme_stylebox("panel") as StyleBoxFlat
	var style: Dictionary = {}
	if not _group.is_empty():
		style = _theme.get_style(_group)
	return {
		"built": built,
		"visible": built and _panel.visible,
		"speaker": _speaker_label.text if _speaker_label != null else "",
		"text": _text_label.text if _text_label != null else "",
		"group": _group,
		"border_width": box.border_width_left if box != null else -1,
		"bg_color": box.bg_color if box != null else Color(0, 0, 0, 0),
		"font_size": _text_label.get_theme_font_size("font_size") if _text_label != null else -1,
		"style": style,
	}


# --- 内部 ---------------------------------------------------------------------

func _index_defs(data: Dictionary, path: String) -> bool:
	var dialogues: Array = data["dialogues"]
	var loaded: Dictionary = {}
	for entry in dialogues:
		var dialogue: Dictionary = entry
		var id := String(dialogue.get("id", ""))
		if id.is_empty():
			_fail("对话定义缺少 id: %s" % path)
			return false
		if loaded.has(id):
			_fail("对话 id 重复: %s" % id)
			return false
		var lines: Array = dialogue.get("lines", [])
		if lines.is_empty():
			_fail("对话没有台词: %s" % id)
			return false
		loaded[id] = {
			"id": id,
			"group": DIALOGUE_THEME.normalize_group(String(dialogue.get("group", ""))),
			"lines": lines.duplicate(true),
		}
	_defs = loaded
	return true


func _show_current() -> void:
	var source: Dictionary = _lines[_index]
	_update_ui()
	line_shown.emit({
		"speaker": String(source.get("speaker", "")),
		"text": String(source.get("text", "")),
		"group": _group,
	})


## 清空播放状态（不广播 finished）；load_defs / start / advance 结束共用。
func _stop() -> void:
	_active = false
	_dialogue_id = ""
	_group = ""
	_lines = []
	_index = 0
	_update_ui()


func _fail(message: String) -> void:
	# 不 push_warning：错误通过 signal 暴露，调用方（W12 / 关卡）自己决定怎么记录，
	# 这样 headless 测试的输出不会被预期内的失败用例污染（同 ConfigLoader 的取舍）。
	error_occurred.emit(message)


func _join_loader_errors(errors: Array) -> String:
	if errors.is_empty():
		return ""
	var parts: Array[String] = []
	for error_text in errors:
		parts.append(String(error_text))
	return " (" + "; ".join(parts) + ")"


# --- UI（代码内构建） ---------------------------------------------------------

func _build_ui() -> void:
	if _panel != null:
		return
	# 根节点只当层用，不拦输入；真正可点击的是底部对话框。
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	_panel = PanelContainer.new()
	_panel.name = "DialoguePanel"
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_panel.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	_panel.offset_left = 32
	_panel.offset_right = -32
	_panel.offset_top = -216
	_panel.offset_bottom = -32
	add_child(_panel)

	var margin := MarginContainer.new()
	margin.name = "DialogueContent"
	for side in ["margin_left", "margin_top", "margin_right", "margin_bottom"]:
		margin.add_theme_constant_override(side, 10)
	_panel.add_child(margin)

	var column := VBoxContainer.new()
	column.name = "DialogueColumn"
	column.add_theme_constant_override("separation", 6)
	margin.add_child(column)

	_speaker_label = Label.new()
	_speaker_label.name = "Speaker"
	column.add_child(_speaker_label)

	_text_label = Label.new()
	_text_label.name = "Text"
	_text_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_text_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(_text_label)

	_hint_label = Label.new()
	_hint_label.name = "Hint"
	_hint_label.text = "点击对话框继续"
	_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	column.add_child(_hint_label)

	_panel.gui_input.connect(_on_panel_gui_input)


func _update_ui() -> void:
	if _panel == null:
		return
	var showing := _active and _index >= 0 and _index < _lines.size()
	_panel.visible = showing
	if not showing:
		return

	var style: Dictionary = _theme.get_style(_group)
	_panel.add_theme_stylebox_override("panel", _theme.make_stylebox(_group))
	_speaker_label.text = String(_lines[_index].get("speaker", ""))
	_speaker_label.add_theme_font_size_override("font_size", int(style["speaker_font_size"]))
	_speaker_label.add_theme_color_override("font_color", style["speaker_color"])
	_text_label.text = String(_lines[_index].get("text", ""))
	_text_label.add_theme_font_size_override("font_size", int(style["font_size"]))
	_text_label.add_theme_color_override("font_color", style["text_color"])


func _on_panel_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mouse := event as InputEventMouseButton
		if mouse.button_index == MOUSE_BUTTON_LEFT and mouse.pressed:
			advance()
