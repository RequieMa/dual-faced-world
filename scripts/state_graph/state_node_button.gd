extends Button
## 左侧面板里的状态节点小块：
## - `existing`：代表图里已经有的节点，拖到右侧「结局规则」面板就是把它加成结局条件；
## - `template`：代表一个还没落地的「实体 · 状态」，拖到画布就新建一个节点。
##
## 拖拽数据统一带 `state_graph_node = true`，画布和结局面板各自用
## `_can_drop_data` 判断能不能接。

var mode := "existing"
var node_id := ""
var entity := ""
var state := ""


func configure_existing(p_node_id: String, p_entity: String, p_state: String) -> void:
	mode = "existing"
	node_id = p_node_id
	entity = p_entity
	state = p_state
	text = "%s · %s" % [entity, state]
	tooltip_text = "拖到右侧结局面板 = 作为条件\n拖到画布 = 复制一个节点\n点击 = 在图上选中"
	_setup_look(Color(0.55, 0.72, 0.95))


func configure_template(p_entity: String, p_state: String) -> void:
	mode = "template"
	node_id = ""
	entity = p_entity
	state = p_state
	text = "+ %s · %s" % [entity, state]
	tooltip_text = "拖到画布新建这个状态节点"
	_setup_look(Color(0.92, 0.72, 0.42))


func _setup_look(accent: Color) -> void:
	custom_minimum_size = Vector2(180, 32)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	clip_text = true
	alignment = HORIZONTAL_ALIGNMENT_LEFT
	add_theme_font_size_override("font_size", 14)
	add_theme_color_override("font_color", accent)
	add_theme_color_override("font_hover_color", accent.lightened(0.25))
	add_theme_color_override("font_pressed_color", accent.darkened(0.2))


func _get_drag_data(_at_position: Vector2) -> Variant:
	var data := {
		"state_graph_node": true,
		"kind": mode,
		"entity": entity,
		"state": state,
	}
	if mode == "existing":
		data["id"] = node_id
	set_drag_preview(_make_drag_preview())
	return data


func _make_drag_preview() -> Control:
	var preview := PanelContainer.new()
	preview.custom_minimum_size = Vector2(190, 38)
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0.12, 0.15, 0.21, 0.96)
	box.border_color = Color(0.45, 0.62, 0.9)
	box.set_border_width_all(1)
	box.set_corner_radius_all(6)
	box.content_margin_left = 10
	box.content_margin_right = 10
	preview.add_theme_stylebox_override("panel", box)
	var label := Label.new()
	label.text = "%s · %s" % [entity, state]
	label.add_theme_font_size_override("font_size", 14)
	preview.add_child(label)
	return preview
