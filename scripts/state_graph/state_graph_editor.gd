extends Control
## 状态图编辑器（2D 设计工具，不参与正式玩法）。
##
## 左边：所有「实体 · 状态」小块 + 新建 + 切换连线；
## 中间：GraphEdit 画布，状态节点可拖动、可连线，结局节点显示触发条件；
## 右边：节点检查器 + 结局规则面板（把左侧节点拖进来 → 生成结局）。
##
## 数据落在 `resources/data/state_graph.json`，和 `StateGraphModel` 共用一套 schema；
## 改完点「保存」即可回到游戏/测试里用。测试入口见 `tests/test_state_graph.gd`。

const MODEL_SCRIPT := preload("res://scripts/state_graph/state_graph_model.gd")
const DATA_PATH := "res://resources/data/state_graph.json"

## 常用但默认图里还没有的状态，做成可拖拽模板。
const TEMPLATES := [
	["敌人", "潜行"],
	["敌人", "追击"],
	["摄像头", "冷却"],
	["朋友", "被挡住"],
	["门", "故障"],
	["线索", "已丢失"],
]

var model = null

@onready var canvas: GraphEdit = $Margin/Root/Split/CanvasFrame/Canvas
@onready var palette = $Margin/Root/Split/PaletteScroll/Palette
@onready var outcome_panel = $Margin/Root/Split/InspectorScroll/Inspector/OutcomePanel

@onready var _title_label: Label = $Margin/Root/Header/Title
@onready var _status_label: Label = $Margin/Root/Header/StatusLabel
@onready var _save_button: Button = $Margin/Root/Header/SaveButton
@onready var _reload_button: Button = $Margin/Root/Header/ReloadButton
@onready var _arrange_button: Button = $Margin/Root/Header/ArrangeButton
@onready var _fit_button: Button = $Margin/Root/Header/FitButton

@onready var _selection_label: Label = $Margin/Root/Split/InspectorScroll/Inspector/SelectionLabel
@onready var _node_edit_box: VBoxContainer = $Margin/Root/Split/InspectorScroll/Inspector/NodeEditBox
@onready var _entity_edit: LineEdit = $Margin/Root/Split/InspectorScroll/Inspector/NodeEditBox/EntityRow/EntityEdit
@onready var _state_edit: LineEdit = $Margin/Root/Split/InspectorScroll/Inspector/NodeEditBox/StateRow/StateEdit
@onready var _apply_node_button: Button = $Margin/Root/Split/InspectorScroll/Inspector/NodeEditBox/NodeButtons/ApplyNodeButton
@onready var _delete_node_button: Button = $Margin/Root/Split/InspectorScroll/Inspector/NodeEditBox/NodeButtons/DeleteNodeButton

@onready var _outcome_edit_box: VBoxContainer = $Margin/Root/Split/InspectorScroll/Inspector/OutcomeEditBox
@onready var _outcome_name_edit: LineEdit = $Margin/Root/Split/InspectorScroll/Inspector/OutcomeEditBox/OutcomeNameEdit
@onready var _outcome_tone_select: OptionButton = $Margin/Root/Split/InspectorScroll/Inspector/OutcomeEditBox/OutcomeToneSelect
@onready var _apply_outcome_button: Button = $Margin/Root/Split/InspectorScroll/Inspector/OutcomeEditBox/OutcomeButtons/ApplyOutcomeButton
@onready var _delete_outcome_button: Button = $Margin/Root/Split/InspectorScroll/Inspector/OutcomeEditBox/OutcomeButtons/DeleteOutcomeButton

@onready var _edge_from: OptionButton = $Margin/Root/Split/InspectorScroll/Inspector/EdgeSection/EdgeFrom
@onready var _edge_to: OptionButton = $Margin/Root/Split/InspectorScroll/Inspector/EdgeSection/EdgeTo
@onready var _edge_label_edit: LineEdit = $Margin/Root/Split/InspectorScroll/Inspector/EdgeSection/EdgeLabelEdit
@onready var _add_edge_button: Button = $Margin/Root/Split/InspectorScroll/Inspector/EdgeSection/AddEdgeButton
@onready var _edge_list: ItemList = $Margin/Root/Split/InspectorScroll/Inspector/EdgeSection/EdgeList
@onready var _delete_edge_button: Button = $Margin/Root/Split/InspectorScroll/Inspector/EdgeSection/DeleteEdgeButton

var _selected_ids: Array[String] = []
var _active_id := ""
var _dirty := false


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_install_cjk_font()
	model = MODEL_SCRIPT.new()
	model.changed.connect(_on_model_changed)

	canvas.setup(model)
	canvas.node_picked.connect(_on_node_picked)
	canvas.error_message.connect(_on_canvas_error)
	canvas.status_message.connect(func(message: String): set_status(message))
	canvas.positions_changed.connect(func():
		_dirty = true
		_refresh_title()
	)
	palette.setup(self)
	outcome_panel.setup(self)

	_connect_ui()
	_refresh_edge_options()
	_refresh_edge_list()

	if model.load_from(DATA_PATH):
		_dirty = false
		_refresh_title()
		set_status("已载入 %d 个节点 / %d 条切换 / %d 个结局" % [
			model.nodes.size(), model.edges.size(), model.outcomes.size()
		])
	else:
		set_status("默认状态图载入失败：%s" % str(model.last_errors), true)
	_refresh_inspector()


func _install_cjk_font() -> void:
	# 默认主题在部分平台没有中文字形；显式给系统字体兜底，避免整屏方块。
	var font := SystemFont.new()
	font.font_names = PackedStringArray([
		"Microsoft YaHei UI", "Microsoft YaHei", "Noto Sans CJK SC",
		"PingFang SC", "SimHei", "Noto Sans",
	])
	var control_theme := Theme.new()
	control_theme.default_font = font
	control_theme.default_font_size = 14
	theme = control_theme


func _connect_ui() -> void:
	_save_button.pressed.connect(_on_save_pressed)
	_reload_button.pressed.connect(_on_reload_pressed)
	_arrange_button.pressed.connect(arrange_layout)
	_fit_button.pressed.connect(func(): canvas.fit_view())

	_apply_node_button.pressed.connect(_on_apply_node_pressed)
	_delete_node_button.pressed.connect(_on_delete_selected_pressed)

	_fill_tone_select()
	_apply_outcome_button.pressed.connect(_on_apply_outcome_pressed)
	_delete_outcome_button.pressed.connect(_on_delete_outcome_pressed)

	_add_edge_button.pressed.connect(_on_add_edge_pressed)
	_delete_edge_button.pressed.connect(_on_delete_edge_pressed)
	_edge_list.item_selected.connect(_on_edge_selected)


func _fill_tone_select() -> void:
	_outcome_tone_select.clear()
	_outcome_tone_select.add_item("中性")
	_outcome_tone_select.set_item_metadata(0, "neutral")
	_outcome_tone_select.add_item("成功")
	_outcome_tone_select.set_item_metadata(1, "win")
	_outcome_tone_select.add_item("失败")
	_outcome_tone_select.set_item_metadata(2, "fail")
	_outcome_tone_select.select(0)


# --- 对外 API（测试 / 画布 / 面板共用） ---------------------------------------

func add_state_node(entity: String, state: String, pos: Vector2) -> String:
	var node_id := String(model.add_node(entity, state, pos))
	if node_id.is_empty():
		set_status("新增节点失败：%s" % str(model.last_errors), true)
		return ""
	select_node(node_id)
	_dirty = true
	_refresh_title()
	return node_id


func connect_nodes(from_id: String, to_id: String, label: String) -> bool:
	var edge_id := String(model.add_edge(from_id, to_id, label))
	if edge_id.is_empty():
		set_status("新增切换失败：%s" % str(model.last_errors), true)
		return false
	_dirty = true
	_refresh_title()
	set_status("已新增切换：%s → %s" % [model.node_label(from_id), model.node_label(to_id)])
	return true


func save_to(path: String) -> bool:
	canvas.sync_positions()
	var ok: bool = model.save_to(path)
	if ok:
		_dirty = false
		_refresh_title()
		set_status("已保存到 %s" % path)
	else:
		set_status("保存失败：%s" % str(model.last_errors), true)
	return ok


func load_from(path: String) -> bool:
	var ok: bool = model.load_from(path)
	if ok:
		_selected_ids.clear()
		_active_id = ""
		_dirty = false
		_refresh_title()
		canvas.set_selection([])
		_refresh_inspector()
		set_status("已载入 %s" % path)
	else:
		set_status("载入失败：%s" % str(model.last_errors), true)
	return ok


func get_graph_node_count() -> int:
	return canvas.get_graph_node_count()


func select_node(node_id: String) -> void:
	if not model.has_node(node_id):
		return
	_selected_ids = [node_id]
	_active_id = node_id
	canvas.set_selection(_selected_ids)
	canvas.focus_node(node_id)
	_refresh_inspector()


func next_outcome_position(condition_ids: Array) -> Vector2:
	var max_x := 0.0
	var sum_y := 0.0
	var count := 0
	for raw in condition_ids:
		var node: Dictionary = model.find_node(String(raw))
		if node.is_empty():
			continue
		var pos: Vector2 = node.get("pos", Vector2.ZERO)
		max_x = max(max_x, pos.x)
		sum_y += pos.y
		count += 1
	if count == 0:
		return next_free_position()
	return Vector2(max_x + 300.0, sum_y / float(count))


func next_free_position() -> Vector2:
	if canvas.size.x > 1.0 and canvas.zoom > 0.0:
		return (canvas.scroll_offset + canvas.size * 0.5) / canvas.zoom
	return Vector2(40.0, 40.0 + float(model.nodes.size() % 12) * 130.0)


func arrange_layout() -> void:
	canvas.sync_positions()
	var x := 40.0
	var entities: Array = model.entities()
	for entity in entities:
		var y := 40.0
		for node in model.nodes_of(String(entity)):
			model.move_node(String(node["id"]), Vector2(x, y), false)
			y += 135.0
		x += 300.0
	var outcome_y := 40.0
	for outcome in model.outcomes:
		model.move_node(String(outcome["id"]), Vector2(x, outcome_y), false)
		outcome_y += 135.0
	canvas.rebuild()
	_dirty = true
	_refresh_title()
	set_status("已按实体分列整理布局")


func set_status(message: String, is_error: bool = false) -> void:
	if _status_label == null:
		return
	_status_label.text = message
	_status_label.add_theme_color_override("font_color",
		Color(0.98, 0.55, 0.52) if is_error else Color(0.68, 0.76, 0.9))


# --- 信号 ---------------------------------------------------------------------

func _on_model_changed() -> void:
	_dirty = true
	_refresh_title()
	_refresh_edge_options()
	_refresh_edge_list()
	_refresh_inspector()


func _refresh_title() -> void:
	if _title_label == null:
		return
	_title_label.text = "状态图编辑器 · 状态 / 切换 / 结局" + ("  ● 未保存" if _dirty else "")


func _on_node_picked(node_id: String, additive: bool) -> void:
	if not model.has_node(node_id):
		return
	if additive:
		if _selected_ids.has(node_id):
			_selected_ids.erase(node_id)
		else:
			_selected_ids.append(node_id)
		if _selected_ids.has(node_id):
			_active_id = node_id
		elif not _selected_ids.is_empty():
			_active_id = _selected_ids[-1]
		else:
			_active_id = ""
	else:
		_selected_ids = [node_id]
		_active_id = node_id
	canvas.set_selection(_selected_ids)
	_refresh_inspector()


func _on_canvas_error(message: String) -> void:
	set_status(message, true)


# --- 检查器 -------------------------------------------------------------------

func _refresh_inspector() -> void:
	if _active_id.is_empty() or not model.has_node(_active_id):
		_selection_label.text = "未选中节点。点画布节点，或从左侧拖一个进来。"
		_node_edit_box.visible = false
		_outcome_edit_box.visible = false
		return
	var kind := String(model.node_kind(_active_id))
	if kind == "state":
		_node_edit_box.visible = true
		_outcome_edit_box.visible = false
		var node: Dictionary = model.find_node(_active_id)
		_entity_edit.text = String(node.get("entity", ""))
		_state_edit.text = String(node.get("state", ""))
		_selection_label.text = "已选状态节点：%s" % model.node_label(_active_id)
	else:
		_node_edit_box.visible = false
		_outcome_edit_box.visible = true
		var outcome: Dictionary = model.find_node(_active_id)
		_outcome_name_edit.text = String(outcome.get("label", ""))
		_set_tone_selected(String(outcome.get("tone", "neutral")))
		_selection_label.text = "已选结局节点：%s（条件 %d 个）" % [
			String(outcome.get("label", "")), (outcome.get("requires", []) as Array).size()
		]


func _set_tone_selected(tone: String) -> void:
	for index in range(_outcome_tone_select.item_count):
		if String(_outcome_tone_select.get_item_metadata(index)) == tone:
			_outcome_tone_select.select(index)
			return


func _on_apply_node_pressed() -> void:
	if _active_id.is_empty() or String(model.node_kind(_active_id)) != "state":
		return
	if model.set_node_label(_active_id, _entity_edit.text, _state_edit.text):
		set_status("已更新节点：%s" % model.node_label(_active_id))
	else:
		set_status("更新节点失败：实体和状态都不能为空", true)


func _on_delete_selected_pressed() -> void:
	if _active_id.is_empty():
		return
	var label := String(model.node_label(_active_id))
	if model.remove_node(_active_id):
		_selected_ids.clear()
		_active_id = ""
		canvas.set_selection([])
		_refresh_inspector()
		set_status("已删除节点：%s" % label)


func _on_apply_outcome_pressed() -> void:
	if _active_id.is_empty() or String(model.node_kind(_active_id)) != "outcome":
		return
	var tone := String(_outcome_tone_select.get_item_metadata(max(_outcome_tone_select.selected, 0)))
	var ok_label: bool = model.set_outcome_label(_active_id, _outcome_name_edit.text)
	var ok_tone: bool = model.set_outcome_tone(_active_id, tone)
	if ok_label and ok_tone:
		set_status("已更新结局：%s" % _outcome_name_edit.text.strip_edges())
	else:
		set_status("更新结局失败：名字不能为空", true)


func _on_delete_outcome_pressed() -> void:
	if _active_id.is_empty():
		return
	if model.remove_outcome(_active_id):
		_selected_ids.clear()
		_active_id = ""
		canvas.set_selection([])
		_refresh_inspector()
		set_status("已删除结局")


# --- 切换连线 -----------------------------------------------------------------

func _refresh_edge_options() -> void:
	var keep_from := _selected_metadata(_edge_from)
	var keep_to := _selected_metadata(_edge_to)
	_edge_from.clear()
	_edge_to.clear()
	for node in model.nodes:
		if String(node.get("kind", "state")) != "state":
			continue
		var label := "%s · %s" % [String(node.get("entity", "")), String(node.get("state", ""))]
		_edge_from.add_item(label)
		_edge_from.set_item_metadata(_edge_from.item_count - 1, String(node["id"]))
		_edge_to.add_item(label)
		_edge_to.set_item_metadata(_edge_to.item_count - 1, String(node["id"]))
	if _edge_from.item_count == 0:
		_edge_from.add_item("（还没有状态节点）")
	if _edge_to.item_count == 0:
		_edge_to.add_item("（还没有状态节点）")
	_select_metadata(_edge_from, keep_from)
	_select_metadata(_edge_to, keep_to)
	_add_edge_button.disabled = _edge_from.item_count < 1 or _edge_to.item_count < 1


func _selected_metadata(option: OptionButton) -> String:
	if option.selected < 0 or option.item_count == 0:
		return ""
	var meta: Variant = option.get_item_metadata(option.selected)
	return "" if meta == null else String(meta)


func _select_metadata(option: OptionButton, wanted: String) -> void:
	if wanted.is_empty():
		return
	for index in range(option.item_count):
		if String(option.get_item_metadata(index)) == wanted:
			option.select(index)
			return


func _on_add_edge_pressed() -> void:
	var from_id := _selected_metadata(_edge_from)
	var to_id := _selected_metadata(_edge_to)
	if from_id.is_empty() or to_id.is_empty():
		set_status("先选择两个状态节点", true)
		return
	if not connect_nodes(from_id, to_id, _edge_label_edit.text):
		return
	_edge_label_edit.text = ""


func _refresh_edge_list() -> void:
	_edge_list.clear()
	for edge in model.edges:
		var from_id := String(edge.get("from", ""))
		var to_id := String(edge.get("to", ""))
		var label := String(edge.get("label", ""))
		var text := "%s → %s" % [model.node_label(from_id), model.node_label(to_id)]
		if not label.is_empty():
			text += "  ［%s］" % label
		_edge_list.add_item(text)
		_edge_list.set_item_metadata(_edge_list.item_count - 1, String(edge["id"]))
	_delete_edge_button.disabled = _edge_list.item_count == 0


func _on_edge_selected(index: int) -> void:
	var edge_id := String(_edge_list.get_item_metadata(index))
	var edge: Dictionary = model.find_edge(edge_id)
	if edge.is_empty():
		return
	select_node(String(edge.get("from", "")))


func _on_delete_edge_pressed() -> void:
	var selected := _edge_list.get_selected_items()
	if selected.is_empty():
		return
	var edge_id := String(_edge_list.get_item_metadata(selected[0]))
	if model.remove_edge(edge_id):
		set_status("已删除切换")


# --- 顶部按钮 -----------------------------------------------------------------

func _on_save_pressed() -> void:
	save_to(DATA_PATH)


func _on_reload_pressed() -> void:
	load_from(DATA_PATH)
