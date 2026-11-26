extends VBoxContainer
## 左侧面板：列出图里所有「实体 · 状态」，每个小块都能：
## - 拖到画布 → 复制一个同类节点；
## - 拖到右侧结局面板 → 作为该结局的触发条件；
## - 点击 → 在画布上选中并编辑。
##
## 下方还提供「新建状态节点」输入框和几个常用模板（拖到画布直接落地）。

const BUTTON_SCRIPT := preload("res://scripts/state_graph/state_node_button.gd")
const TEMPLATES := [
	["敌人", "潜行"],
	["敌人", "追击"],
	["摄像头", "冷却"],
	["朋友", "被挡住"],
	["门", "故障"],
	["线索", "已丢失"],
]

var editor = null
var _model = null

@onready var _chips: VBoxContainer = $Chips
@onready var _entity_edit: LineEdit = $EntityEdit
@onready var _state_edit: LineEdit = $StateEdit
@onready var _add_button: Button = $AddButton
@onready var _templates: GridContainer = $Templates


func setup(p_editor) -> void:
	editor = p_editor
	_model = editor.model
	if not _model.changed.is_connected(_on_model_changed):
		_model.changed.connect(_on_model_changed)
	_add_button.pressed.connect(_on_add_pressed)
	_build_templates()
	_refresh()


func _build_templates() -> void:
	for child in _templates.get_children():
		_templates.remove_child(child)
		child.queue_free()
	for entry in TEMPLATES:
		var chip = BUTTON_SCRIPT.new()
		chip.configure_template(String(entry[0]), String(entry[1]))
		_templates.add_child(chip)


func _on_model_changed() -> void:
	_refresh()


func _refresh() -> void:
	for child in _chips.get_children():
		_chips.remove_child(child)
		child.queue_free()

	var count := 0
	for node in _model.nodes:
		if String(node.get("kind", "state")) != "state":
			continue
		var node_id := String(node["id"])
		var chip = BUTTON_SCRIPT.new()
		chip.configure_existing(node_id, String(node.get("entity", "")), String(node.get("state", "")))
		chip.pressed.connect(func(): editor.select_node(node_id))
		_chips.add_child(chip)
		count += 1

	if count == 0:
		var empty := Label.new()
		empty.text = "（图里还没有状态节点）"
		empty.add_theme_font_size_override("font_size", 12)
		empty.add_theme_color_override("font_color", Color(0.62, 0.66, 0.76))
		_chips.add_child(empty)


func _on_add_pressed() -> void:
	var entity := _entity_edit.text.strip_edges()
	var state := _state_edit.text.strip_edges()
	if entity.is_empty() or state.is_empty():
		editor.set_status("实体名和状态名都要填", true)
		return
	var node_id := String(editor.add_state_node(entity, state, editor.next_free_position()))
	if node_id.is_empty():
		return
	_state_edit.text = ""
	_state_edit.grab_focus()
	editor.set_status("已新增节点：%s · %s" % [entity, state])
