extends Control
## 解谜 demo 的谜题基类：统一外壳（标题 / 线索 / 状态 / 重置 / 返回），
## 子类只需要实现 build_body()（在 body_box 里搭自己的 UI）和覆写 reset() 清状态。
##
## 每个谜题都是可独立实例化的 Control：既能在实验室场景里当页面用，也能在测试里
## 直接 new() 出来驱动（不依赖 3D 场景）。

signal solved(puzzle_id: String)
signal close_requested()
signal state_changed()

var puzzle_id := ""
var display_title := ""
var hint_text := ""
var is_solved := false
var attempts := 0
var body_box: VBoxContainer = null
var status_label: Label = null


## 由实验室调用：设置元数据并搭好外壳 + 谜题本体。
func setup(id: String, title: String, hint: String) -> void:
	puzzle_id = id
	display_title = title
	hint_text = hint
	_build_shell()
	build_body()


# --- 子类需要实现的 -----------------------------------------------------------

func build_body() -> void:
	push_warning("puzzle_base: 子类没有实现 build_body()")


## 默认重置：清状态、清空 body、重建 UI。子类覆写时先清自己的模型状态再 super.reset()。
func reset() -> void:
	is_solved = false
	attempts = 0
	if status_label != null:
		status_label.text = ""
	if body_box != null:
		for child in body_box.get_children():
			body_box.remove_child(child)
			child.queue_free()
		build_body()
	state_changed.emit()


# --- 通用工具 ----------------------------------------------------------------

func make_label(text: String, font_size: int = 15, color: Color = Color(0.9, 0.94, 1.0)) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	return label


func make_button(text: String, callback: Callable, min_width: float = 0.0) -> Button:
	var button := Button.new()
	button.text = text
	if min_width > 0.0:
		button.custom_minimum_size = Vector2(min_width, 38)
	button.pressed.connect(callback)
	return button


func set_status(text: String, positive: bool = false) -> void:
	if status_label == null:
		return
	status_label.text = text
	status_label.add_theme_color_override("font_color",
		Color(0.45, 0.95, 0.6) if positive else Color(1.0, 0.78, 0.42))


## 记一次失败反馈。
func fail(message: String) -> void:
	attempts += 1
	set_status(message, false)
	state_changed.emit()


## 解谜成功（幂等）：只第一次生效。
func succeed(message: String = "解开了！") -> bool:
	if is_solved:
		return false
	is_solved = true
	set_status(message, true)
	solved.emit(puzzle_id)
	state_changed.emit()
	return true


## 解谜成功但保持页面（用于「解开后可以重玩」的谜题）。
func is_finished() -> bool:
	return is_solved


func get_state() -> Dictionary:
	return {"id": puzzle_id, "title": display_title, "solved": is_solved, "attempts": attempts}


# --- 内部 ---------------------------------------------------------------------

func _build_shell() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var panel := PanelContainer.new()
	panel.name = "Panel"
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	# 实心面板：默认主题是半透明的，房间会透上来。
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.055, 0.065, 0.085, 0.98)
	style.border_color = Color(0.24, 0.30, 0.38, 1.0)
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	panel.add_theme_stylebox_override("panel", style)
	add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 20)
	margin.add_theme_constant_override("margin_right", 20)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_bottom", 16)
	panel.add_child(margin)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	margin.add_child(column)

	var title_label := make_label(display_title, 24, Color(0.94, 0.97, 1.0))
	column.add_child(title_label)

	var hint_label := make_label("线索：" + hint_text, 14, Color(0.70, 0.80, 0.96))
	hint_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(hint_label)

	column.add_child(HSeparator.new())

	body_box = VBoxContainer.new()
	body_box.name = "Body"
	body_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body_box.add_theme_constant_override("separation", 8)
	column.add_child(body_box)

	var footer := HBoxContainer.new()
	footer.add_theme_constant_override("separation", 8)
	column.add_child(footer)
	status_label = make_label("", 14, Color(1.0, 0.78, 0.42))
	status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status_label.name = "Status"
	footer.add_child(status_label)
	footer.add_child(make_button("重置", reset))
	footer.add_child(make_button("返回房间", func() -> void: close_requested.emit()))
