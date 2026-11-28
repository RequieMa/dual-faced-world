extends CanvasLayer
## 主 demo 的 HUD + 监控台 UI（程序化搭建，避免场景文件过大）。
##
## 非坐下：准星、目标、F 提示、底部照片库。
## 坐下：2×2 监控画面；点小画面放大；放大画面右键发射激光；右侧滚动屏接受照片拖放。

signal feed_clicked(feed_id: String)
signal close_feed_requested
signal stand_requested
signal laser_requested(feed_id: String, normalized_pos: Vector2)
signal photo_dropped(photo_id: String)
signal scroll_send_requested

const COLOR_TEXT := Color(0.86, 0.9, 0.97)
const COLOR_MUTED := Color(0.62, 0.68, 0.78)
const COLOR_ACCENT := Color(0.45, 0.78, 1.0)

var _feeds: Array[Dictionary] = []
var _feed_buttons: Dictionary = {}
var _feed_labels: Dictionary = {}
var _selected := ""

var _hud: Control
var _seat_ui: Control
var _crosshair: Label
var _objective: Label
var _prompt: Label
var _notification: Label
var _back_button: Button
var _photo_grid: HBoxContainer
var _photo_panel: PanelContainer
var _feed_grid: GridContainer
var _big_feed: TextureRect
var _big_feed_title: Label
var _feed_grid_box: VBoxContainer
var _dwell_bar: ProgressBar
var _dwell_label: Label
var _feed_hint: Label
var _seat_notice: Label
var _screen_drop: Button
var _screen_result: Label
var _screen_list: VBoxContainer
var _complete: Control
var _scroll_panel: PanelContainer
var _scroll_preview: TextureRect
var _scroll_drop: Button
var _scroll_send: Button
var _seat_active := false


func setup() -> void:
	_build_hud()
	_build_scroll_overlay()
	_build_complete()


func _build_scroll_overlay() -> void:
	_scroll_panel = PanelContainer.new()
	_scroll_panel.name = "ScrollPanel"
	_scroll_panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_scroll_panel.offset_left = -300
	_scroll_panel.offset_top = 18
	_scroll_panel.offset_right = -18
	_scroll_panel.offset_bottom = 136
	_scroll_panel.visible = false
	_scroll_panel.add_theme_stylebox_override("panel",
		_panel_style(Color(0.02, 0.08, 0.1, 0.94), Color(0.35, 0.9, 0.82)))
	add_child(_scroll_panel)

	var stack := Control.new()
	stack.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_scroll_panel.add_child(stack)

	_scroll_preview = TextureRect.new()
	_scroll_preview.name = "ScrollPreview"
	_scroll_preview.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_scroll_preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_scroll_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_scroll_preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stack.add_child(_scroll_preview)

	# 透明拖放层：照片仓库里的照片拖到这块 2D 面板即可组合。
	_scroll_drop = PhotoDropZone.new()
	_scroll_drop.text = ""
	_scroll_drop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_scroll_drop.add_theme_stylebox_override("normal",
		_panel_style(Color(0.04, 0.16, 0.17, 0.10), Color(0.35, 0.9, 0.82)))
	_scroll_drop.add_theme_stylebox_override("hover",
		_panel_style(Color(0.06, 0.24, 0.25, 0.20), Color(0.45, 1.0, 0.9)))
	_scroll_drop.photo_dropped.connect(func(photo_id: String): photo_dropped.emit(photo_id))
	stack.add_child(_scroll_drop)

	_scroll_send = Button.new()
	_scroll_send.name = "ScrollSend"
	_scroll_send.text = "发送"
	_scroll_send.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_scroll_send.offset_left = -78
	_scroll_send.offset_top = -38
	_scroll_send.offset_right = -6
	_scroll_send.offset_bottom = -6
	_scroll_send.focus_mode = Control.FOCUS_NONE
	_scroll_send.pressed.connect(func(): scroll_send_requested.emit())
	stack.add_child(_scroll_send)


func set_scroll_texture(texture: Texture2D) -> void:
	if _scroll_preview != null:
		_scroll_preview.texture = texture


func is_scroll_visible() -> bool:
	return _scroll_panel != null and _scroll_panel.visible


func _build_hud() -> void:
	_hud = Control.new()
	_hud.name = "Hud"
	_hud.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_hud)

	_crosshair = Label.new()
	_crosshair.text = "+"
	_crosshair.add_theme_font_size_override("font_size", 20)
	_crosshair.add_theme_color_override("font_color", COLOR_ACCENT)
	_crosshair.set_anchors_preset(Control.PRESET_CENTER)
	_crosshair.position = Vector2(-6, -14)
	_crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud.add_child(_crosshair)

	_objective = _label("目标：坐进监控椅（F）", 17, COLOR_TEXT)
	_objective.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_objective.position = Vector2(22, 18)
	_objective.custom_minimum_size = Vector2(600, 0)
	_hud.add_child(_objective)

	_back_button = _button("← 返回 4 路画面")
	_back_button.name = "BackToGrid"
	_back_button.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_back_button.position = Vector2(22, 52)
	_back_button.custom_minimum_size = Vector2(190, 34)
	_back_button.visible = false
	_back_button.pressed.connect(func(): close_feed_requested.emit())
	_hud.add_child(_back_button)

	_notification = _label("", 15, COLOR_ACCENT)
	# 响应结果放正上方，避免被右上角滚动屏遮住。
	_notification.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_notification.position = Vector2(-300, 18)
	_notification.custom_minimum_size = Vector2(600, 0)
	_notification.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hud.add_child(_notification)

	_prompt = _label("", 16, COLOR_TEXT)
	_prompt.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_prompt.position = Vector2(-320, -150)
	_prompt.custom_minimum_size = Vector2(640, 0)
	_prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hud.add_child(_prompt)

	_photo_panel = PanelContainer.new()
	_photo_panel.name = "PhotoPanel"
	_photo_panel.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_photo_panel.offset_left = 12
	_photo_panel.offset_right = -12
	_photo_panel.offset_top = -126
	_photo_panel.offset_bottom = -12
	_photo_panel.custom_minimum_size = Vector2(0, 114)
	_photo_panel.add_theme_stylebox_override("panel", _panel_style(Color(0.06, 0.08, 0.11, 0.88)))
	_hud.add_child(_photo_panel)
	var photo_box := VBoxContainer.new()
	photo_box.add_theme_constant_override("separation", 4)
	_photo_panel.add_child(photo_box)
	photo_box.add_child(_label("照片仓库（拖到滚动屏可组合）", 13, COLOR_MUTED))
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	photo_box.add_child(scroll)
	_photo_grid = HBoxContainer.new()
	_photo_grid.add_theme_constant_override("separation", 6)
	_photo_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_photo_grid)
	refresh_photos([])


func _build_seat_ui() -> void:
	_seat_ui = Control.new()
	_seat_ui.name = "SeatUI"
	_seat_ui.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_seat_ui.visible = false
	_seat_ui.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_seat_ui)

	var dim := ColorRect.new()
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.02, 0.03, 0.05, 0.72)
	_seat_ui.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.offset_bottom = -110
	_seat_ui.add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(1000, 460)
	panel.add_theme_stylebox_override("panel", _panel_style(Color(0.055, 0.07, 0.1, 0.98)))
	center.add_child(panel)

	var root_box := VBoxContainer.new()
	root_box.add_theme_constant_override("separation", 6)
	panel.add_child(root_box)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	root_box.add_child(header)
	var title := _label("监控台 · 4 路机位", 19, COLOR_TEXT)
	title.autowrap_mode = TextServer.AUTOWRAP_OFF
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)
	var stand_button := _button("站起（F / Esc）")
	stand_button.pressed.connect(func(): stand_requested.emit())
	header.add_child(stand_button)

	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 10)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root_box.add_child(body)

	var left := VBoxContainer.new()
	left.add_theme_constant_override("separation", 5)
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(left)

	_feed_grid_box = VBoxContainer.new()
	_feed_grid_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left.add_child(_feed_grid_box)
	_feed_grid = GridContainer.new()
	_feed_grid.columns = 2
	_feed_grid.add_theme_constant_override("h_separation", 6)
	_feed_grid.add_theme_constant_override("v_separation", 6)
	_feed_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_feed_grid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_feed_grid_box.add_child(_feed_grid)

	var big_box := VBoxContainer.new()
	big_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_feed_grid_box.add_child(big_box)
	_big_feed_title = _label("", 15, COLOR_ACCENT)
	big_box.add_child(_big_feed_title)
	_big_feed = TextureRect.new()
	_big_feed.custom_minimum_size = Vector2(640, 360)
	_big_feed.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_big_feed.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_big_feed.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_big_feed.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_big_feed.mouse_filter = Control.MOUSE_FILTER_STOP
	_big_feed.gui_input.connect(_on_big_feed_input)
	big_box.add_child(_big_feed)
	var back := _button("返回 4 路画面")
	back.pressed.connect(func(): close_feed_requested.emit())
	big_box.add_child(back)
	_big_feed.visible = false
	big_box.visible = false

	var dwell_row := HBoxContainer.new()
	dwell_row.add_theme_constant_override("separation", 8)
	left.add_child(dwell_row)
	_dwell_bar = ProgressBar.new()
	_dwell_bar.custom_minimum_size = Vector2(0, 14)
	_dwell_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_dwell_bar.show_percentage = false
	dwell_row.add_child(_dwell_bar)
	_dwell_label = _label("", 13, COLOR_MUTED)
	_dwell_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	_dwell_label.custom_minimum_size = Vector2(190, 0)
	dwell_row.add_child(_dwell_label)
	_feed_hint = _label("点小画面放大；放大画面右键发射激光。S 截图。", 13, COLOR_MUTED)
	left.add_child(_feed_hint)
	_seat_notice = _label("", 13, COLOR_ACCENT)
	left.add_child(_seat_notice)

	var right := VBoxContainer.new()
	right.custom_minimum_size = Vector2(290, 0)
	right.add_theme_constant_override("separation", 6)
	body.add_child(right)

	var screen_panel := PanelContainer.new()
	screen_panel.add_theme_stylebox_override("panel", _panel_style(Color(0.09, 0.11, 0.16, 0.95)))
	right.add_child(screen_panel)
	var screen_box := VBoxContainer.new()
	screen_box.add_theme_constant_override("separation", 5)
	screen_panel.add_child(screen_box)
	screen_box.add_child(_label("滚动屏", 17, COLOR_ACCENT))
	var drop_zone := PhotoDropZone.new()
	drop_zone.text = "把照片拖到这里"
	drop_zone.custom_minimum_size = Vector2(0, 72)
	drop_zone.add_theme_stylebox_override("normal",
		_panel_style(Color(0.12, 0.16, 0.22, 1.0), Color(0.45, 0.62, 0.9)))
	drop_zone.photo_dropped.connect(func(photo_id: String): photo_dropped.emit(photo_id))
	_screen_drop = drop_zone
	screen_box.add_child(drop_zone)
	_screen_result = _label("等待照片……", 13, COLOR_TEXT)
	_screen_result.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	screen_box.add_child(_screen_result)
	_screen_list = VBoxContainer.new()
	_screen_list.add_theme_constant_override("separation", 2)
	screen_box.add_child(_screen_list)
	screen_box.add_child(_label("可拖入任意张照片；点击发送后统一判定门禁码 / 水+被子提示 / 截图目标。", 12, COLOR_MUTED))

	var help := _label("WASD 走动 · 鼠标看 · 靠近椅子 F 坐下\n坐下后：点画面放大 · 右键发激光 · S 截图", 13, COLOR_MUTED)
	right.add_child(help)


func _build_complete() -> void:
	_complete = Control.new()
	_complete.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_complete.visible = false
	_complete.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_complete)
	var dim := ColorRect.new()
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.01, 0.02, 0.04, 0.85)
	_complete.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_complete.add_child(center)
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(640, 0)
	box.add_theme_constant_override("separation", 12)
	center.add_child(box)
	var complete_label := _label("你逃出去了。", 42, Color(0.6, 0.95, 0.7))
	complete_label.name = "CompleteLabel"
	complete_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	complete_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	complete_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(complete_label)
	var hint := _label("Demo 完成 · 按 R 重开", 18, COLOR_TEXT)
	hint.autowrap_mode = TextServer.AUTOWRAP_OFF
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(hint)


# --- 对外 API -----------------------------------------------------------------

func is_seat_visible() -> bool:
	return _seat_active


func set_feed_zoomed(value: bool) -> void:
	if _back_button != null:
		_back_button.visible = _seat_active and value


func is_feed_zoomed() -> bool:
	return _back_button != null and _back_button.visible


func show_seat() -> void:
	_seat_active = true
	set_feed_zoomed(false)
	if _crosshair != null:
		_crosshair.visible = false
	if _objective != null:
		_objective.visible = false
	if _prompt != null:
		_prompt.visible = false
	if _notification != null:
		_notification.visible = false
	if _photo_panel != null:
		_photo_panel.visible = true
	if _scroll_panel != null:
		_scroll_panel.visible = true


func hide_seat() -> void:
	_seat_active = false
	set_feed_zoomed(false)
	if _crosshair != null:
		_crosshair.visible = true
	if _objective != null:
		_objective.visible = true
	if _prompt != null:
		_prompt.visible = true
	if _notification != null:
		_notification.visible = true
	if _seat_notice != null:
		_seat_notice.text = ""
	if _scroll_panel != null:
		_scroll_panel.visible = false


func set_scroll_drop_rect(_rect: Rect2) -> void:
	pass


func set_scroll_drop_visible(value: bool) -> void:
	if _scroll_panel != null:
		_scroll_panel.visible = value
	if _photo_panel != null and _hud != null and _photo_panel.get_parent() != _hud:
		_photo_panel.reparent(_hud)
		_photo_panel.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
		_photo_panel.offset_left = 12
		_photo_panel.offset_right = -12
		_photo_panel.offset_top = -126
		_photo_panel.offset_bottom = -12


func set_selected(feed_id: String) -> void:
	_selected = feed_id
	if _feed_grid_box == null:
		return
	_feed_grid_box.get_child(0).visible = feed_id.is_empty()
	_feed_grid_box.get_child(1).visible = not feed_id.is_empty()
	_big_feed.visible = not feed_id.is_empty()
	if not feed_id.is_empty():
		_big_feed_title.text = "放大画面 · %s" % feed_id
		var found := false
		for feed in _feeds:
			if String(feed.get("id", "")) == feed_id:
				_big_feed.texture = feed.get("viewport", null).get_texture() if feed.get("viewport", null) != null else null
				found = true
				break
		if not found:
			_big_feed.texture = null


func refresh_feeds(feeds: Array[Dictionary]) -> void:
	_feeds = feeds
	for child in _feed_grid.get_children():
		child.queue_free()
	_feed_buttons.clear()
	_feed_labels.clear()
	for feed in feeds:
		var feed_id := String(feed.get("id", ""))
		var cell := PanelContainer.new()
		cell.add_theme_stylebox_override("panel", _panel_style(Color(0.08, 0.1, 0.14, 0.95)))
		_feed_grid.add_child(cell)
		var box := VBoxContainer.new()
		box.add_theme_constant_override("separation", 2)
		cell.add_child(box)
		var view := TextureButton.new()
		view.custom_minimum_size = Vector2(300, 160)
		view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		view.texture_normal = feed.get("viewport", null).get_texture() if feed.get("viewport", null) != null else null
		view.ignore_texture_size = true
		view.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
		view.pressed.connect(func(): feed_clicked.emit(feed_id))
		box.add_child(view)
		var label := _label(feed_id, 12, COLOR_MUTED)
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
				button.modulate = Color(0.25, 0.25, 0.28, 1.0)
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


func update_dwell(remain: float, total: float) -> void:
	if _dwell_bar == null:
		return
	_dwell_bar.max_value = maxf(total, 0.001)
	_dwell_bar.value = maxf(remain, 0.0)
	_dwell_label.text = "停留 %.1fs / %.1fs" % [maxf(remain, 0.0), total]


func refresh_photos(photos: Array) -> void:
	if _photo_grid == null:
		return
	for child in _photo_grid.get_children():
		_photo_grid.remove_child(child)
		child.queue_free()
	if photos.is_empty():
		var empty := _label("还没有照片：NPC 找到线索会自动拍照", 12, COLOR_MUTED)
		empty.autowrap_mode = TextServer.AUTOWRAP_OFF
		empty.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_photo_grid.add_child(empty)
		return
	for photo in photos:
		var card := PhotoCard.new()
		card.configure(photo)
		_photo_grid.add_child(card)


func set_objective(text: String) -> void:
	if _objective != null:
		_objective.text = "目标：" + text


func set_prompt(text: String) -> void:
	if _prompt != null:
		_prompt.text = text


func set_notification(text: String) -> void:
	if _notification != null:
		_notification.text = text
	if _seat_notice != null:
		_seat_notice.text = text


func set_screen_result(text: String) -> void:
	if _screen_result != null:
		_screen_result.text = text


func set_feed_hint(text: String) -> void:
	if _feed_hint != null:
		_feed_hint.text = text


func show_complete(text: String = "你逃出去了。") -> void:
	if _scroll_panel != null:
		_scroll_panel.visible = false
	if _hud != null:
		_hud.visible = false
	if _seat_ui != null:
		_seat_ui.visible = false
	if _complete != null:
		_complete.visible = true
		var label := _complete.find_child("CompleteLabel", true, false)
		if label is Label:
			label.text = text


# --- 输入 ---------------------------------------------------------------------

func _on_big_feed_input(event: InputEvent) -> void:
	var mouse := event as InputEventMouseButton
	if mouse == null or not mouse.pressed:
		return
	if mouse.button_index != MOUSE_BUTTON_RIGHT:
		return
	var size := _big_feed.size
	if size.x <= 0.0 or size.y <= 0.0:
		return
	var normalized := _big_feed.get_local_mouse_position() / size
	laser_requested.emit(_selected, normalized)
	_big_feed.accept_event()


# --- 构建工具 -----------------------------------------------------------------

func _label(text: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label


func _button(text: String) -> Button:
	var button := Button.new()
	button.text = text
	button.focus_mode = Control.FOCUS_NONE
	return button


func _panel_style(bg: Color, border: Color = Color(0.2, 0.26, 0.35)) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = bg
	box.border_color = border
	box.set_border_width_all(1)
	box.set_corner_radius_all(6)
	box.content_margin_left = 8
	box.content_margin_right = 8
	box.content_margin_top = 6
	box.content_margin_bottom = 6
	return box


# --- 内部类 -------------------------------------------------------------------

class PhotoDropZone extends Button:
	signal photo_dropped(photo_id: String)

	func _init() -> void:
		focus_mode = Control.FOCUS_NONE

	func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
		return data is Dictionary and String((data as Dictionary).get("photo_id", "")) != ""

	func _drop_data(_at_position: Vector2, data: Variant) -> void:
		if _can_drop_data(_at_position, data):
			photo_dropped.emit(String((data as Dictionary)["photo_id"]))


class PhotoCard extends Button:
	var photo: Dictionary = {}

	func configure(p: Dictionary) -> void:
		photo = p
		var id := String(p.get("id", ""))
		name = "PhotoCard_" + id
		text = String(p.get("label", "照片"))
		custom_minimum_size = Vector2(126, 78)
		clip_text = true
		focus_mode = Control.FOCUS_NONE
		tooltip_text = "拖到滚动屏：%s" % text
		var texture: Texture2D = p.get("texture", null)
		if texture != null:
			icon = texture
			expand_icon = true
			icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
			vertical_icon_alignment = VERTICAL_ALIGNMENT_TOP

	func _get_drag_data(_at_position: Vector2) -> Variant:
		var data := {"photo_id": String(photo.get("id", ""))}
		var preview := PanelContainer.new()
		preview.custom_minimum_size = Vector2(140, 84)
		var box := StyleBoxFlat.new()
		box.bg_color = Color(0.12, 0.16, 0.22, 0.98)
		box.border_color = Color(0.5, 0.72, 1.0)
		box.set_border_width_all(1)
		box.set_corner_radius_all(6)
		preview.add_theme_stylebox_override("panel", box)
		var label := Label.new()
		label.text = text
		label.add_theme_font_size_override("font_size", 13)
		preview.add_child(label)
		set_drag_preview(preview)
		return data
