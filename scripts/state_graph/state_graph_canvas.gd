extends GraphEdit
## 状态图画布：把 `StateGraphModel` 渲染成 GraphEdit 里的 GraphNode 图。
##
## 图例：
## - 状态节点两行端口：第 1 行「切换」连状态 → 状态；第 2 行「作为条件」连状态 → 结局。
## - 结局节点只有一个输入端口，所有触发条件（requires）都连到它；节点体内列出条件。
## - 拖动节点只更新模型坐标，不重建图；增删节点/连线/结局才整图重建。
##
## 画布不直接弹窗，错误通过 `error_message` 交给编辑器显示到状态栏。

signal node_picked(node_id: String, additive: bool)
signal error_message(message: String)
signal status_message(message: String)


## 状态节点标题栏右侧的小拖手：把「画布上的节点」直接拖进右侧结局面板。
class DragHandle extends Button:
	var node_id := ""
	var entity := ""
	var state := ""

	func _ready() -> void:
		text = "拖"
		tooltip_text = "拖到右侧「结局规则」面板 = 把这个状态加入结局条件"
		custom_minimum_size = Vector2(24, 22)
		focus_mode = Control.FOCUS_NONE
		flat = true
		add_theme_font_size_override("font_size", 15)
		add_theme_color_override("font_color", Color(0.78, 0.58, 1.0))

	func _get_drag_data(_at_position: Vector2) -> Variant:
		var data := {
			"state_graph_node": true,
			"kind": "existing",
			"id": node_id,
			"entity": entity,
			"state": state,
		}
		var preview := PanelContainer.new()
		preview.custom_minimum_size = Vector2(190, 36)
		var box := StyleBoxFlat.new()
		box.bg_color = Color(0.16, 0.12, 0.22, 0.96)
		box.border_color = Color(0.78, 0.58, 1.0)
		box.set_border_width_all(1)
		box.set_corner_radius_all(6)
		box.content_margin_left = 10
		box.content_margin_right = 10
		preview.add_theme_stylebox_override("panel", box)
		var label := Label.new()
		label.text = "%s · %s" % [entity, state]
		label.add_theme_font_size_override("font_size", 14)
		preview.add_child(label)
		set_drag_preview(preview)
		return data

const PORT_TRANSITION := Color(0.42, 0.68, 1.0)
const PORT_CONDITION := Color(0.78, 0.58, 1.0)

const TONE_COLORS := {
	"neutral": Color(0.72, 0.78, 0.9),
	"win": Color(0.42, 0.86, 0.55),
	"fail": Color(0.95, 0.45, 0.42),
}
const TONE_SYMBOLS := {
	"neutral": "◆",
	"win": "★",
	"fail": "✖",
}

var model = null
var _rebuilding := false
var _selecting_silently := false
## GraphEdit 自己处理连线/删除的输入过程中不要整图重建，等这一帧结束再重建。
var _suspend_rebuild := false


func _ready() -> void:
	show_grid = true
	show_menu = false
	minimap_enabled = true
	minimap_size = Vector2(170, 110)
	right_disconnects = true
	connection_lines_curvature = 0.24
	connection_lines_thickness = 2.0
	connection_lines_antialiased = true
	zoom_min = 0.3
	zoom_max = 1.8
	zoom = 0.75
	snapping_enabled = true
	snapping_distance = 10
	add_theme_stylebox_override("panel", _make_box(Color(0.07, 0.08, 0.11), Color(0.16, 0.19, 0.25), 1, 8))
	connection_request.connect(_on_connection_request)
	disconnection_request.connect(_on_disconnection_request)
	delete_nodes_request.connect(_on_delete_nodes_request)
	end_node_move.connect(_on_end_node_move)
	node_selected.connect(_on_node_selected)


func setup(graph_model) -> void:
	model = graph_model
	if not model.changed.is_connected(_on_model_changed):
		model.changed.connect(_on_model_changed)
	rebuild()


func _on_model_changed() -> void:
	if _suspend_rebuild:
		return
	rebuild()


# --- 构建 ---------------------------------------------------------------------

func rebuild() -> void:
	if model == null or _rebuilding:
		return
	_rebuilding = true
	var keep_offset: Vector2 = scroll_offset
	var keep_zoom: float = zoom

	clear_connections()
	for child in get_children():
		if child is GraphNode:
			remove_child(child)
			child.queue_free()

	for node in model.nodes:
		_make_graph_node(node)
	for edge in model.edges:
		var from_id := String(edge.get("from", ""))
		var to_id := String(edge.get("to", ""))
		if model.node_kind(from_id) != "state" or model.node_kind(to_id) != "state":
			continue
		connect_node(StringName(from_id), 0, StringName(to_id), 0)
	for outcome in model.outcomes:
		var outcome_id := String(outcome["id"])
		for raw in outcome.get("requires", []):
			var state_id := String(raw)
			if model.node_kind(state_id) == "state":
				connect_node(StringName(state_id), 1, StringName(outcome_id), 0)

	scroll_offset = keep_offset
	zoom = keep_zoom
	_rebuilding = false


func get_graph_node_count() -> int:
	var count := 0
	for child in get_children():
		if child is GraphNode:
			count += 1
	return count


func _make_graph_node(node: Dictionary) -> void:
	var node_id := String(node["id"])
	var kind := String(node.get("kind", "state"))
	var graph_node := GraphNode.new()
	graph_node.name = StringName(node_id)
	graph_node.draggable = true
	graph_node.resizable = false
	graph_node.selectable = true
	graph_node.custom_minimum_size = Vector2(205, 0)
	graph_node.position_offset = node.get("pos", Vector2.ZERO)

	if kind == "outcome":
		_build_outcome_node(graph_node, node)
	else:
		_build_state_node(graph_node, node)

	add_child(graph_node)
	graph_node.reset_size()
	graph_node.position_offset = node.get("pos", Vector2.ZERO)


func _build_state_node(graph_node: GraphNode, node: Dictionary) -> void:
	graph_node.title = "%s · %s" % [String(node.get("entity", "")), String(node.get("state", ""))]
	graph_node.tooltip_text = "拖动标题移动；从「切换」端口连到另一个状态；\n从「作为条件」端口连到结局，或把左侧节点拖进右侧结局面板。"
	_apply_title_style(graph_node, Color(0.2, 0.28, 0.4), Color(0.36, 0.5, 0.7))

	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 4)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var left := Label.new()
	left.text = "◀ 切换"
	left.mouse_filter = Control.MOUSE_FILTER_IGNORE
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var right := Label.new()
	right.text = "切换 ▶"
	right.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(left)
	row.add_child(right)
	graph_node.add_child(row)
	graph_node.set_slot(0, true, 0, PORT_TRANSITION, true, 0, PORT_TRANSITION)

	var condition_row := HBoxContainer.new()
	condition_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	condition_row.add_theme_constant_override("separation", 4)
	condition_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var spacer := Control.new()
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var condition_label := Label.new()
	condition_label.text = "作为条件 ▶"
	condition_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	condition_label.tooltip_text = "拖到结局节点，把这个状态加入结局条件"
	condition_row.add_child(spacer)
	condition_row.add_child(condition_label)
	graph_node.add_child(condition_row)
	graph_node.set_slot(1, false, 0, Color.TRANSPARENT, true, 0, PORT_CONDITION)

	var handle := DragHandle.new()
	handle.node_id = String(node["id"])
	handle.entity = String(node.get("entity", ""))
	handle.state = String(node.get("state", ""))
	graph_node.get_titlebar_hbox().add_child(handle)


func _build_outcome_node(graph_node: GraphNode, node: Dictionary) -> void:
	var tone := String(node.get("tone", "neutral"))
	var tone_color: Color = TONE_COLORS.get(tone, TONE_COLORS["neutral"])
	var symbol: String = TONE_SYMBOLS.get(tone, "◆")
	var requires: Array = node.get("requires", [])
	graph_node.title = "%s 结局：%s" % [symbol, String(node.get("label", "结局"))]
	graph_node.tooltip_text = "触发条件（%d 个）：\n%s\n\n把左侧状态节点拖进来，或从状态节点的「作为条件」端口连过来。" % [
		requires.size(), _condition_summary(requires)
	]
	_apply_title_style(graph_node, tone_color.darkened(0.62), tone_color)

	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 4)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var hint := Label.new()
	hint.text = "◀ 条件（%d）" % requires.size()
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hint.tooltip_text = "把状态节点拖到这里（或从左侧面板拖进来）"
	row.add_child(hint)
	graph_node.add_child(row)
	graph_node.set_slot(0, true, 0, tone_color, false, 0, Color.TRANSPARENT)

	var slot_index := 1
	for raw in requires:
		var state_id := String(raw)
		var item := Label.new()
		item.text = "• " + _state_label(state_id)
		item.mouse_filter = Control.MOUSE_FILTER_IGNORE
		item.tooltip_text = "条件：%s" % _state_label(state_id)
		graph_node.add_child(item)
		graph_node.set_slot(slot_index, false, 0, Color.TRANSPARENT, false, 0, Color.TRANSPARENT, null, null, false)
		slot_index += 1


func _state_label(state_id: String) -> String:
	if model == null or not model.has_node(state_id):
		return state_id
	return model.node_label(state_id)


func _condition_summary(requires: Array) -> String:
	if requires.is_empty():
		return "（还没有条件：不会触发）"
	var parts: Array[String] = []
	for raw in requires:
		parts.append(_state_label(String(raw)))
	return "、".join(parts)


func _apply_title_style(graph_node: GraphNode, bg: Color, border: Color) -> void:
	graph_node.add_theme_stylebox_override("titlebar", _make_box(bg, border, 1, 6))
	graph_node.add_theme_stylebox_override("titlebar_selected", _make_box(bg.lightened(0.12), border.lightened(0.2), 2, 6))
	graph_node.add_theme_stylebox_override("panel", _make_box(Color(0.1, 0.12, 0.16), Color(0.18, 0.21, 0.28), 1, 6))
	graph_node.add_theme_stylebox_override("panel_selected", _make_box(Color(0.13, 0.16, 0.21), border, 2, 6))


func _make_box(bg: Color, border: Color, border_width: int, radius: int) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = bg
	box.border_color = border
	box.set_border_width_all(border_width)
	box.set_corner_radius_all(radius)
	box.content_margin_left = 8
	box.content_margin_right = 8
	box.content_margin_top = 4
	box.content_margin_bottom = 4
	return box


# --- 选中 ---------------------------------------------------------------------

func select_node(node_id: String) -> void:
	set_selection([node_id])
	focus_node(node_id)


## 把节点滚进可视区域（已经完整可见就不动）。
func focus_node(node_id: String) -> void:
	var graph_node := get_node_or_null(NodePath(node_id)) as GraphNode
	if graph_node == null or size.x <= 1.0 or zoom <= 0.0:
		return
	var node_rect := Rect2(graph_node.position_offset, graph_node.size)
	var view_rect := Rect2(scroll_offset / zoom, size / zoom)
	if view_rect.encloses(node_rect):
		return
	scroll_offset = node_rect.get_center() * zoom - size * 0.5


## 把整张图缩到当前画布大小（最小缩放仍保证文字可辨认）。
func fit_view() -> void:
	var bounds := Rect2()
	var first := true
	for child in get_children():
		if child is GraphNode:
			var node_rect := Rect2(child.position_offset, child.size)
			if first:
				bounds = node_rect
				first = false
			else:
				bounds = bounds.merge(node_rect)
	if first or size.x <= 1.0 or size.y <= 1.0:
		return
	var margin := 36.0
	var available := size - Vector2(margin * 2.0, margin * 2.0)
	var target_zoom: float = minf(available.x / maxf(bounds.size.x, 1.0), available.y / maxf(bounds.size.y, 1.0))
	zoom = clamp(target_zoom, zoom_min, zoom_max)
	scroll_offset = bounds.position * zoom - Vector2(margin, margin)


func set_selection(node_ids: Array) -> void:
	var wanted := {}
	for raw in node_ids:
		wanted[String(raw)] = true
	_selecting_silently = true
	for child in get_children():
		if child is GraphNode:
			child.selected = wanted.has(String(child.name))
	_selecting_silently = false


func _on_node_selected(node: Node) -> void:
	if _selecting_silently or not node is GraphNode:
		return
	var additive := Input.is_key_pressed(KEY_CTRL) or Input.is_key_pressed(KEY_SHIFT)
	node_picked.emit(String(node.name), additive)


# --- 拖拽入画布 ---------------------------------------------------------------

func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	return data is Dictionary and bool((data as Dictionary).get("state_graph_node", false))


func _drop_data(at_position: Vector2, data: Variant) -> void:
	if not _can_drop_data(at_position, data):
		return
	var dict: Dictionary = data
	var entity := String(dict.get("entity", "")).strip_edges()
	var state := String(dict.get("state", "")).strip_edges()
	if entity.is_empty() or state.is_empty():
		error_message.emit("拖入的节点缺少实体/状态")
		return
	var graph_pos: Vector2 = (at_position + scroll_offset) / zoom
	var new_id := String(model.add_node(entity, state, graph_pos))
	if not new_id.is_empty():
		status_message.emit("已新建节点：%s · %s" % [entity, state])
		node_picked.emit(new_id, false)


# --- 连线 ---------------------------------------------------------------------

func _on_connection_request(from_node: StringName, from_port: int, to_node: StringName, to_port: int) -> void:
	var from_id := String(from_node)
	var to_id := String(to_node)
	var from_kind := String(model.node_kind(from_id))
	var to_kind := String(model.node_kind(to_id))

	if from_kind != "state":
		error_message.emit("只有状态节点可以作为连线起点")
		return
	_suspend_rebuild = true
	if to_kind == "outcome":
		if model.add_requirement(to_id, from_id):
			status_message.emit("已加入结局条件：%s" % model.node_label(from_id))
		else:
			error_message.emit("这个状态已经在结局条件里了")
		_finish_suspended_rebuild()
		return
	if to_kind != "state":
		_suspend_rebuild = false
		error_message.emit("连线终点必须是状态或结局节点")
		return
	if from_port == 1:
		_suspend_rebuild = false
		error_message.emit("「作为条件」端口只能连到结局节点")
		return
	if not model.find_edge_between(from_id, to_id).is_empty():
		_suspend_rebuild = false
		error_message.emit("这两个状态之间已经有一条切换了")
		return
	if String(model.add_edge(from_id, to_id, "")).is_empty():
		error_message.emit("连线失败：%s" % str(model.last_errors))
	else:
		status_message.emit("已新增切换：%s → %s" % [model.node_label(from_id), model.node_label(to_id)])
	_finish_suspended_rebuild()


func _on_disconnection_request(from_node: StringName, from_port: int, to_node: StringName, to_port: int) -> void:
	var from_id := String(from_node)
	var to_id := String(to_node)
	_suspend_rebuild = true
	if String(model.node_kind(to_id)) == "outcome":
		if model.remove_requirement(to_id, from_id):
			status_message.emit("已移除结局条件：%s" % model.node_label(from_id))
		else:
			error_message.emit("移除结局条件失败")
		_finish_suspended_rebuild()
		return
	var edge: Dictionary = model.find_edge_between(from_id, to_id)
	if edge.is_empty():
		error_message.emit("没找到对应的切换连线")
		_finish_suspended_rebuild()
		return
	if model.remove_edge(String(edge["id"])):
		status_message.emit("已删除切换")
	else:
		error_message.emit("删除切换失败")
	_finish_suspended_rebuild()


func _on_delete_nodes_request(nodes: Array) -> void:
	var removing: Array[String] = []
	for raw in nodes:
		removing.append(String(raw))
	_suspend_rebuild = true
	for node_id in removing:
		model.remove_node(node_id)
	status_message.emit("已删除 %d 个节点" % removing.size())
	_finish_suspended_rebuild()


func _finish_suspended_rebuild() -> void:
	_suspend_rebuild = false
	call_deferred("rebuild")


# --- 坐标 ---------------------------------------------------------------------

func _on_end_node_move() -> void:
	sync_positions()


## 把 GraphNode 的最终坐标写回模型（不触发重建）。
func sync_positions() -> void:
	if model == null:
		return
	for child in get_children():
		if child is GraphNode:
			model.move_node(String(child.name), child.position_offset, false)
