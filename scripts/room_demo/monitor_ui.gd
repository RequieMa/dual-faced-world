extends Control
## 3D 监控台屏幕里渲染的 UI（放在 SubViewport 里，贴到控制室墙上的物理大屏）。
##
## 不是全屏 2D 覆盖：玩家坐下后仍然用第一人称看着 3D 大屏；本脚本只负责
## 屏幕纹理里的 2×2 画面 / 放大画面 / 停留条。点击通过 room_demo 把鼠标事件
## 转发进这个 SubViewport。

signal feed_clicked(feed_id: String)
signal close_feed_requested
signal laser_requested(feed_id: String, normalized_pos: Vector2)

const FISHEYE_SHADER := preload("res://shaders/fisheye_feed.gdshader")
const FISHEYE_STRENGTH := 0.10
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
var _fisheye_material: ShaderMaterial
var _snow_textures: Array[ImageTexture] = []
var _laser_line: Line2D
var _laser_tween: Tween


func setup() -> void:
	size = Vector2(1280, 800)
	_build_snow_textures()
	_fisheye_material = ShaderMaterial.new()
	_fisheye_material.shader = FISHEYE_SHADER
	_fisheye_material.set_shader_parameter("strength", FISHEYE_STRENGTH)
	_fisheye_material.set_shader_parameter("zoom", 1.0)
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
	_big_feed.material = _fisheye_material
	_big_feed.gui_input.connect(_on_big_feed_input)
	_big_box.add_child(_big_feed)
	_laser_line = Line2D.new()
	_laser_line.name = "LaserLine"
	_laser_line.width = 3.0
	_laser_line.default_color = Color(1.0, 0.08, 0.03, 0.95)
	_laser_line.joint_mode = Line2D.LINE_JOINT_ROUND
	_laser_line.begin_cap_mode = Line2D.LINE_CAP_ROUND
	_laser_line.end_cap_mode = Line2D.LINE_CAP_ROUND
	_laser_line.z_index = 10
	_laser_line.visible = false
	_big_feed.add_child(_laser_line)
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
		# TextureButton 内部会把状态贴图打包成 atlas，CanvasItem shader 的 TEXTURE/UV
		# 不是整张画面；这里用 TextureRect + gui_input，鱼眼 shader 才能覆盖整张画面。
		var view := TextureRect.new()
		view.custom_minimum_size = Vector2(600, 270)
		view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		view.texture = _feed_texture(feed)
		view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		view.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		view.mouse_filter = Control.MOUSE_FILTER_STOP
		view.material = _fisheye_material
		view.gui_input.connect(_on_feed_view_input.bind(feed_id))
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
		var button: Control = _feed_buttons.get(feed_id)
		if label == null:
			continue
		if burned.has(feed_id):
			label.text = "%s · 烧毁" % feed_id
			label.add_theme_color_override("font_color", Color(0.95, 0.45, 0.4))
			if button is TextureRect:
				(button as TextureRect).texture = _snow_texture()
				button.modulate = Color(0.85, 0.85, 0.9, 1.0)
			elif button != null:
				button.modulate = Color(0.2, 0.2, 0.24, 1.0)
		elif cooldowns.has(feed_id):
			label.text = "%s · 冷却 %.1fs" % [feed_id, float(cooldowns[feed_id])]
			label.add_theme_color_override("font_color", Color(0.9, 0.72, 0.35))
			if button is TextureRect:
				(button as TextureRect).texture = _feed_texture(feed)
				button.modulate = Color(0.55, 0.55, 0.6, 1.0)
		elif feed_id == current:
			label.text = "%s · 监控中" % feed_id
			label.add_theme_color_override("font_color", COLOR_ACCENT)
			if button is TextureRect:
				(button as TextureRect).texture = _feed_texture(feed)
				button.modulate = Color(1, 1, 1, 1)
		else:
			label.text = "%s · 待机" % feed_id
			label.add_theme_color_override("font_color", COLOR_MUTED)
			if button is TextureRect:
				(button as TextureRect).texture = _feed_texture(feed)
				button.modulate = Color(1, 1, 1, 1)


func set_selected(feed_id: String) -> void:
	_selected = feed_id
	if _laser_line != null:
		_laser_line.visible = false
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


func _on_feed_view_input(event: InputEvent, feed_id: String) -> void:
	var mouse := event as InputEventMouseButton
	if mouse != null and mouse.pressed and mouse.button_index == MOUSE_BUTTON_LEFT:
		feed_clicked.emit(feed_id)


func _on_big_feed_input(event: InputEvent) -> void:
	var mouse := event as InputEventMouseButton
	if mouse == null or not mouse.pressed or mouse.button_index != MOUSE_BUTTON_RIGHT:
		return
	var size := _big_feed.size
	if size.x <= 0.0 or size.y <= 0.0:
		return
	var uv := _big_feed.get_local_mouse_position() / size
	# 从相机视角看，3D 光束沿视线只能看到一个端点；这里补屏幕空间射线。
	_flash_laser(_big_feed.get_local_mouse_position())
	laser_requested.emit(_selected, _undistort_uv(uv))
	_big_feed.accept_event()


func _flash_laser(local_point: Vector2) -> void:
	if _laser_line == null:
		return
	if _laser_tween != null and _laser_tween.is_valid():
		_laser_tween.kill()
	_laser_line.points = PackedVector2Array([_big_feed.size * 0.5, local_point])
	_laser_line.modulate.a = 1.0
	_laser_line.visible = true
	_laser_tween = create_tween()
	_laser_tween.tween_interval(0.45)
	_laser_tween.tween_property(_laser_line, "modulate:a", 0.0, 0.35)
	_laser_tween.tween_callback(func(): _laser_line.visible = false)


func uses_fisheye() -> bool:
	return _fisheye_material != null and _fisheye_material.shader == FISHEYE_SHADER


## 画面被鱼眼 shader 向外弯过；右键激光需要把点击坐标反变换回原始画面 UV。
func _undistort_uv(uv: Vector2) -> Vector2:
	# shader 是 p_src = p_screen * (1 - s*r^2)；这里反解 p_screen。
	var p := uv * 2.0 - Vector2.ONE
	for i in 3:
		var radius_squared := p.length_squared()
		p /= maxf(1.0 - FISHEYE_STRENGTH * radius_squared, 0.15)
	return (p * 0.5 + Vector2(0.5, 0.5)).clamp(Vector2.ZERO, Vector2.ONE)


func _feed_by_id(feed_id: String) -> Dictionary:
	for feed in _feeds:
		if String(feed.get("id", "")) == feed_id:
			return feed
	return {}


## 烧毁机位显示动态雪花：几张随机噪声轮播，避免停在最后一帧。
func _build_snow_textures() -> void:
	for frame in 4:
		var image := Image.create(320, 180, false, Image.FORMAT_RGB8)
		for y in 180:
			for x in 320:
				var value := randi() % 256
				image.set_pixel(x, y, Color8(value, value, value))
		_snow_textures.append(ImageTexture.create_from_image(image))


func _snow_texture() -> Texture2D:
	if _snow_textures.is_empty():
		return null
	var index := (Time.get_ticks_msec() / 90) % _snow_textures.size()
	return _snow_textures[index]


func is_burned_visual(feed_id: String) -> bool:
	var view := _feed_buttons.get(feed_id) as TextureRect
	return view != null and _snow_textures.has(view.texture)


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
