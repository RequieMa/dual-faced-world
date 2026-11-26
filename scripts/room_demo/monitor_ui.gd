extends Control
## 3D 监控台屏幕里渲染的 UI（放在 SubViewport 里，贴到控制室墙上的物理大屏）。
##
## 不是全屏 2D 覆盖：玩家坐下后仍然用第一人称看着 3D 大屏；本脚本只负责
## 屏幕纹理里的 2×2 画面 / 放大画面 / 停留条。点击通过 room_demo 把鼠标事件
## 转发进这个 SubViewport。

signal feed_clicked(feed_id: String)
signal close_feed_requested
signal laser_requested(feed_id: String, normalized_pos: Vector2)

const COLOR_TEXT := Color(0.86, 0.92, 1.0)
const COLOR_MUTED := Color(0.58, 0.66, 0.8)
const COLOR_ACCENT := Color(0.42, 0.82, 1.0)

var _feeds: Array[Dictionary] = []
var _feed_buttons: Dictionary = {}
var _feed_labels: Dictionary = {}
var _selected := ""

var _grid: GridContainer
var _grid_box: VBoxContainer
var _big_box: VBoxContainer
var _big_feed: TextureRect
var _big_title: Label
var _dwell_bar: ProgressBar
var _dwell_label: Label
var _notice: Label


func setup() -> void:
	size = Vector2(1280, 800)
	var bg := ColorRect.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.025, 0.04, 0.06, 1.0)
	add_child(bg)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 20)
	margin.add_theme_constant_override("margin_right", 20)
	margin.add_theme_constant_override("margin_top", 14)
	margin.add_theme_constant_override("margin_bottom", 14)
	add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 6)
	margin.add_child(root)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 10)
	root.add_child(header)
	var title := _label("监控台 · 4 路机位", 34, COLOR_TEXT)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	_notice = _label("", 18, COLOR_ACCENT)
	header.add_child(_notice)

	_grid_box = VBoxContainer.new()
	_grid_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(_grid_box)
	_grid = GridContainer.new()
	_grid.columns = 2
	_grid.add_theme_constant_override("h_separation", 10)
	_grid.add_theme_constant_override("v_separation", 10)
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_grid_box.add_child(_grid)

	_big_box = VBoxContainer.new()
	_big_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_big_box.visible = false
	root.add_child(_big_box)
	_big_title = _label("", 24, COLOR_ACCENT)
	_big_box.add_child(_big_title)
	_big_feed = TextureRect.new()
	_big_feed.custom_minimum_size = Vector2(1240, 620)
	_big_feed.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_big_feed.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_big_feed.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_big_feed.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_big_feed.mouse_filter = Control.MOUSE_FILTER_STOP
	_big_feed.gui_input.connect(_on_big_feed_input)
	_big_box.add_child(_big_feed)
	var back := _button("返回 4 路画面")
	back.pressed.connect(func(): close_feed_requested.emit())
	_big_box.add_child(back)

	var dwell_row := HBoxContainer.new()
	dwell_row.add_theme_constant_override("separation", 10)
	root.add_child(dwell_row)
	_dwell_bar = ProgressBar.new()
	_dwell_bar.custom_minimum_size = Vector2(0, 18)
	_dwell_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_dwell_bar.show_percentage = false
	dwell_row.add_child(_dwell_bar)
	_dwell_label = _label("", 18, COLOR_MUTED)
	_dwell_label.custom_minimum_size = Vector2(260, 0)
	dwell_row.add_child(_dwell_label)

	var hint := _label("点小画面放大 · 放大画面右键发激光 · 按 F 站起", 17, COLOR_MUTED)
	root.add_child(hint)


func refresh_feeds(feeds: Array[Dictionary]) -> void:
	_feeds = feeds
	for child in _grid.get_children():
		child.queue_free()
	_feed_buttons.clear()
	_feed_labels.clear()
	for feed in feeds:
		var feed_id := String(feed.get("id", ""))
		var cell := PanelContainer.new()
		cell.add_theme_stylebox_override("panel", _panel_style(Color(0.07, 0.1, 0.14)))
		_grid.add_child(cell)
		var box := VBoxContainer.new()
		box.add_theme_constant_override("separation", 2)
		cell.add_child(box)
		var view := TextureButton.new()
		view.custom_minimum_size = Vector2(600, 270)
		view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		view.texture_normal = _feed_texture(feed)
		view.ignore_texture_size = true
		view.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
		view.pressed.connect(_on_feed_pressed.bind(feed_id))
		box.add_child(view)
		var label := _label(feed_id, 17, COLOR_MUTED)
		box.add_child(label)
		_feed_buttons[feed_id] = view
		_feed_labels[feed_id] = label


func refresh_feed_states(session) -> void:
	if session == null:
		return
	var snapshot: Dictionary = session.get_state()
	var cooldowns: Dictionary = snapshot.get("cooldowns", {})
	var burned: Array = snapshot.get("burned", [])
	var current := String(snapshot.get("current", ""))
	for feed in _feeds:
		var feed_id := String(feed.get("id", ""))
		var label: Label = _feed_labels.get(feed_id)
		var button: TextureButton = _feed_buttons.get(feed_id)
		if label == null:
			continue
		if burned.has(feed_id):
			label.text = "%s · 烧毁" % feed_id
			label.add_theme_color_override("font_color", Color(0.95, 0.45, 0.4))
			if button != null:
				button.modulate = Color(0.2, 0.2, 0.24, 1.0)
		elif cooldowns.has(feed_id):
			label.text = "%s · 冷却 %.1fs" % [feed_id, float(cooldowns[feed_id])]
			label.add_theme_color_override("font_color", Color(0.9, 0.72, 0.35))
			if button != null:
				button.modulate = Color(0.55, 0.55, 0.6, 1.0)
		elif feed_id == current:
			label.text = "%s · 监控中" % feed_id
			label.add_theme_color_override("font_color", COLOR_ACCENT)
			if button != null:
				button.modulate = Color(1, 1, 1, 1)
		else:
			label.text = "%s · 待机" % feed_id
			label.add_theme_color_override("font_color", COLOR_MUTED)
			if button != null:
				button.modulate = Color(1, 1, 1, 1)


func set_selected(feed_id: String) -> void:
	_selected = feed_id
	_grid_box.visible = feed_id.is_empty()
	_big_box.visible = not feed_id.is_empty()
	if feed_id.is_empty():
		return
	_big_title.text = "放大画面 · %s（右键发射激光）" % feed_id
	var feed := _feed_by_id(feed_id)
	_big_feed.texture = _feed_texture(feed)
	_big_box.visible = true


func update_dwell(remain: float, total: float) -> void:
	if _dwell_bar == null:
		return
	_dwell_bar.max_value = maxf(total, 0.001)
	_dwell_bar.value = maxf(remain, 0.0)
	_dwell_label.text = "停留 %.1fs / %.1fs" % [maxf(remain, 0.0), total]


func set_notice(text: String) -> void:
	if _notice != null:
		_notice.text = text


func _on_feed_pressed(feed_id: String) -> void:
	feed_clicked.emit(feed_id)


func _on_big_feed_input(event: InputEvent) -> void:
	var mouse := event as InputEventMouseButton
	if mouse == null or not mouse.pressed or mouse.button_index != MOUSE_BUTTON_RIGHT:
		return
	var size := _big_feed.size
	if size.x <= 0.0 or size.y <= 0.0:
		return
	laser_requested.emit(_selected, _big_feed.get_local_mouse_position() / size)
	_big_feed.accept_event()


func _feed_by_id(feed_id: String) -> Dictionary:
	for feed in _feeds:
		if String(feed.get("id", "")) == feed_id:
			return feed
	return {}


func _feed_texture(feed: Dictionary) -> Texture2D:
	var viewport = feed.get("viewport")
	if viewport is SubViewport:
		return viewport.get_texture()
	return null


func _label(text: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label


func _button(text: String) -> Button:
	var button := Button.new()
	button.text = text
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size = Vector2(0, 34)
	return button


func _panel_style(bg: Color) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = bg
	box.border_color = Color(0.2, 0.32, 0.45)
	box.set_border_width_all(1)
	box.set_corner_radius_all(4)
	box.content_margin_left = 4
	box.content_margin_right = 4
	box.content_margin_top = 4
	box.content_margin_bottom = 4
	return box
