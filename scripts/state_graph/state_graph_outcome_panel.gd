extends PanelContainer
## 右侧「结局规则」面板：
## - 把左侧的状态节点拖进来 → 变成结局条件；
## - 填结局名、选色调（中性/成功/失败）→「生成结局」；
## - 生成后画布上出现一个结局节点，并自动连上所有条件。
##
## 也支持先把节点连到已有结局（画布上的「作为条件」端口），再回来改名字。

const TONE_SYMBOLS := {
	"neutral": "◆",
	"win": "★",
	"fail": "✖",
}
const TONES := ["neutral", "win", "fail"]

var editor = null
var _model = null
var _condition_ids: Array[String] = []

@onready var _condition_list: VBoxContainer = $OutcomeBox/ConditionList
@onready var _name_edit: LineEdit = $OutcomeBox/OutcomeNameRow/OutcomeName
@onready var _tone_select: OptionButton = $OutcomeBox/ToneRow/ToneSelect
@onready var _create_button: Button = $OutcomeBox/CreateButton
@onready var _outcome_list: VBoxContainer = $OutcomeBox/OutcomeList


func setup(p_editor) -> void:
	editor = p_editor
	_model = editor.model
	if not _model.changed.is_connected(_on_model_changed):
		_model.changed.connect(_on_model_changed)
	_style_drop_zone()
	_fill_tones()
	_create_button.pressed.connect(_on_create_pressed)
	_refresh()


func _style_drop_zone() -> void:
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0.1, 0.115, 0.16, 0.92)
	box.border_color = Color(0.47, 0.37, 0.64)
	box.set_border_width_all(1)
	box.set_corner_radius_all(6)
	box.content_margin_left = 8
	box.content_margin_right = 8
	box.content_margin_top = 8
	box.content_margin_bottom = 8
	add_theme_stylebox_override("panel", box)


func _fill_tones() -> void:
	_tone_select.clear()
	_tone_select.add_item("中性（不判定输赢）")
	_tone_select.set_item_metadata(0, "neutral")
	_tone_select.add_item("成功（win）")
	_tone_select.set_item_metadata(1, "win")
	_tone_select.add_item("失败（fail）")
	_tone_select.set_item_metadata(2, "fail")
	_tone_select.select(0)
	_tone_select.item_selected.connect(func(_index: int): _refresh_condition_hint())


func _on_model_changed() -> void:
	_refresh()


func _refresh() -> void:
	_prune_conditions()
	_refresh_conditions()
	_refresh_outcomes()


func _prune_conditions() -> void:
	var kept: Array[String] = []
	for node_id in _condition_ids:
		if _model.has_node(node_id) and String(_model.node_kind(node_id)) == "state":
			kept.append(node_id)
	_condition_ids = kept


# --- 条件 ---------------------------------------------------------------------

func add_condition(node_id: String) -> bool:
	if not _model.has_node(node_id) or String(_model.node_kind(node_id)) != "state":
		_status("只能把状态节点加成结局条件", true)
		return false
	if _condition_ids.has(node_id):
		_status("这个节点已经在结局条件里了", true)
		return false
	_condition_ids.append(node_id)
	_refresh_conditions()
	_status("已加入条件：%s" % _model.node_label(node_id))
	return true


func remove_condition(node_id: String) -> void:
	var kept: Array[String] = []
	for existing in _condition_ids:
		if existing != node_id:
			kept.append(existing)
	_condition_ids = kept
	_refresh_conditions()


func clear_conditions() -> void:
	_condition_ids.clear()
	_refresh_conditions()


func get_condition_ids() -> Array[String]:
	return _condition_ids.duplicate()


func _refresh_conditions() -> void:
	for child in _condition_list.get_children():
		_condition_list.remove_child(child)
		child.queue_free()

	if _condition_ids.is_empty():
		var hint := Label.new()
		hint.name = "EmptyHint"
		hint.text = "还没有条件：把左侧节点拖到这里，或从画布上的「作为条件」端口连过来。"
		hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		hint.add_theme_font_size_override("font_size", 12)
		hint.add_theme_color_override("font_color", Color(0.62, 0.66, 0.76))
		_condition_list.add_child(hint)
		_refresh_condition_hint()
		return

	for node_id in _condition_ids:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 4)
		var label := Label.new()
		label.text = "◈ " + String(_model.node_label(node_id))
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.clip_text = true
		label.add_theme_font_size_override("font_size", 13)
		var remove_button := Button.new()
		remove_button.text = "✕"
		remove_button.tooltip_text = "从条件里移除"
		remove_button.custom_minimum_size = Vector2(28, 24)
		remove_button.pressed.connect(func(): remove_condition(node_id))
		row.add_child(label)
		row.add_child(remove_button)
		_condition_list.add_child(row)
	_refresh_condition_hint()


func _refresh_condition_hint() -> void:
	if _condition_ids.is_empty():
		_create_button.text = "生成结局（先加条件）"
	else:
		_create_button.text = "生成结局（%d 个条件）" % _condition_ids.size()


# --- 生成/列出结局 -------------------------------------------------------------

func create_outcome(label: String = "", tone: String = "") -> String:
	var clean_label := label.strip_edges()
	if clean_label.is_empty():
		clean_label = _name_edit.text.strip_edges()
	if clean_label.is_empty():
		_status("先给结局起个名字", true)
		return ""
	if _condition_ids.is_empty():
		_status("结局至少要有一个触发条件", true)
		return ""
	var clean_tone := tone
	if clean_tone.is_empty():
		clean_tone = String(_tone_select.get_item_metadata(max(_tone_select.selected, 0)))
	if not TONES.has(clean_tone):
		clean_tone = "neutral"
	var pos: Vector2 = editor.next_outcome_position(_condition_ids)
	var outcome_id := String(_model.add_outcome(_condition_ids, clean_label, clean_tone, pos))
	if outcome_id.is_empty():
		_status("生成结局失败：%s" % str(_model.last_errors), true)
		return ""
	_name_edit.text = ""
	clear_conditions()
	_status("已生成结局：%s" % clean_label)
	editor.select_node(outcome_id)
	return outcome_id


func _on_create_pressed() -> void:
	create_outcome()


func _refresh_outcomes() -> void:
	for child in _outcome_list.get_children():
		_outcome_list.remove_child(child)
		child.queue_free()

	var outcomes: Array = _model.outcomes
	if outcomes.is_empty():
		var empty := Label.new()
		empty.text = "（还没有结局）"
		empty.add_theme_font_size_override("font_size", 12)
		empty.add_theme_color_override("font_color", Color(0.62, 0.66, 0.76))
		_outcome_list.add_child(empty)
		return

	for outcome in outcomes:
		var outcome_id := String(outcome["id"])
		var tone := String(outcome.get("tone", "neutral"))
		var requires: Array = outcome.get("requires", [])
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 4)
		var label := Label.new()
		label.text = "%s %s（%d 条件）" % [TONE_SYMBOLS.get(tone, "◆"), String(outcome.get("label", "")), requires.size()]
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.clip_text = true
		label.add_theme_font_size_override("font_size", 13)
		label.add_theme_color_override("font_color", _tone_color(tone))
		var view_button := Button.new()
		view_button.text = "查看"
		view_button.custom_minimum_size = Vector2(44, 24)
		view_button.pressed.connect(func(): editor.select_node(outcome_id))
		var delete_button := Button.new()
		delete_button.text = "删除"
		delete_button.custom_minimum_size = Vector2(44, 24)
		delete_button.pressed.connect(func(): _delete_outcome(outcome_id))
		row.add_child(label)
		row.add_child(view_button)
		row.add_child(delete_button)
		_outcome_list.add_child(row)


func _delete_outcome(outcome_id: String) -> void:
	if _model.remove_outcome(outcome_id):
		_status("已删除结局")
	else:
		_status("删除结局失败", true)


func _tone_color(tone: String) -> Color:
	match tone:
		"win":
			return Color(0.5, 0.9, 0.62)
		"fail":
			return Color(0.98, 0.55, 0.52)
		_:
			return Color(0.78, 0.82, 0.92)


# --- 拖放 ---------------------------------------------------------------------

func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	return data is Dictionary and bool((data as Dictionary).get("state_graph_node", false))


func _drop_data(_at_position: Vector2, data: Variant) -> void:
	if not _can_drop_data(_at_position, data):
		return
	var dict: Dictionary = data
	var kind := String(dict.get("kind", ""))
	if kind == "existing" and _model.has_node(String(dict.get("id", ""))):
		add_condition(String(dict["id"]))
		return
	var entity := String(dict.get("entity", "")).strip_edges()
	var state := String(dict.get("state", "")).strip_edges()
	if entity.is_empty() or state.is_empty():
		_status("拖入的节点缺少实体/状态", true)
		return
	var new_id := String(editor.add_state_node(entity, state, editor.next_outcome_position(_condition_ids)))
	if not new_id.is_empty():
		add_condition(new_id)


func _status(message: String, is_error: bool = false) -> void:
	if editor != null:
		editor.set_status(message, is_error)
