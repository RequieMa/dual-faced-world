extends Node3D
## 解谜实验室（demo-scene）：一个房间里摆 8 个解谜台，覆盖常规解谜类型。
##
## - 左侧列表或直接点 3D 台子都能打开谜题；解开后台子顶面变绿、列表打勾。
## - 8 个谜题各自是独立的 Control 脚本（scripts/puzzles/），可以单独复用/单测；
##   本脚本只负责搭房间、串进度和开关页面。
## - 全部美术都是程序化占位（BoxMesh / Label3D / 自绘 UI），不依赖任何外部素材；
##   素材来源与替换方式见 docs/PUZZLE_LAB.md。

const PUZZLE_DEFS := [
	{"id": "keypad", "title": "数字密码锁", "hint": "值班记录：第 40 次巡查，12 号柜。",
		"path": "res://scripts/puzzles/keypad_puzzle.gd"},
	{"id": "key_door", "title": "钥匙与门", "hint": "黄铜钥匙挂在门边，抽屉里还有一把生锈的。",
		"path": "res://scripts/puzzles/key_door_puzzle.gd"},
	{"id": "sequence", "title": "开关顺序", "hint": "墙上的图纸：B → D → A → C → E",
		"path": "res://scripts/puzzles/sequence_puzzle.gd"},
	{"id": "combine", "title": "物品组合", "hint": "镜片和镜筒好像能拼成什么。",
		"path": "res://scripts/puzzles/combine_puzzle.gd"},
	{"id": "wire", "title": "线路连接", "hint": "红→1、蓝→2、绿→3、黄→4（端子顺序被打乱）。",
		"path": "res://scripts/puzzles/wire_puzzle.gd"},
	{"id": "dial", "title": "转盘拨轮", "hint": "门牌号 3 · 7 · 1。",
		"path": "res://scripts/puzzles/dial_puzzle.gd"},
	{"id": "hidden", "title": "隐藏物", "hint": "房间里有 5 件东西藏得很浅。",
		"path": "res://scripts/puzzles/hidden_object_puzzle.gd"},
	{"id": "testimony", "title": "证词推理", "hint": "四条证词里有一条与现场矛盾。",
		"path": "res://scripts/puzzles/testimony_puzzle.gd"},
]

const STATION_POSITIONS: Array[Vector3] = [
	Vector3(-6.0, 0.0, -2.0), Vector3(-2.0, 0.0, -2.0), Vector3(2.0, 0.0, -2.0), Vector3(6.0, 0.0, -2.0),
	Vector3(-6.0, 0.0, 2.0), Vector3(-2.0, 0.0, 2.0), Vector3(2.0, 0.0, 2.0), Vector3(6.0, 0.0, 2.0),
]
const STATION_COLORS: Array[Color] = [
	Color(0.95, 0.55, 0.30), Color(0.95, 0.80, 0.30), Color(0.45, 0.85, 0.55), Color(0.35, 0.75, 0.95),
	Color(0.60, 0.55, 0.95), Color(0.90, 0.45, 0.75), Color(0.55, 0.85, 0.85), Color(0.85, 0.70, 0.45),
]

var _solved: Array[bool] = []
var _active_index := -1
var _active_puzzle: Control = null
var _station_materials: Array[StandardMaterial3D] = []
var _station_buttons: Array[Button] = []
var _progress_label: Label = null
var _overlay: Control = null
var _slot: Control = null
var _banner: Label = null


func _ready() -> void:
	_solved.resize(PUZZLE_DEFS.size())
	_solved.fill(false)
	_build_world()
	_build_ui()
	_refresh_ui()


# --- 对外查询（eval / 测试） ---------------------------------------------------

func get_lab_snapshot() -> Dictionary:
	return {
		"total": PUZZLE_DEFS.size(),
		"solved_count": solved_count(),
		"solved": _solved.duplicate(),
		"active_index": _active_index,
		"active_puzzle": String(_active_puzzle.puzzle_id) if _active_puzzle != null else "",
		"progress_text": _progress_label.text if _progress_label != null else "",
	}


func get_puzzle_defs() -> Array:
	return PUZZLE_DEFS.duplicate(true)


func get_active_puzzle() -> Control:
	return _active_puzzle


func solved_count() -> int:
	var total := 0
	for flag in _solved:
		if flag:
			total += 1
	return total


func is_complete() -> bool:
	return solved_count() == PUZZLE_DEFS.size()


# --- 开关谜题页面 -------------------------------------------------------------

func open_puzzle(index: int) -> void:
	if index < 0 or index >= PUZZLE_DEFS.size():
		return
	close_puzzle()
	var definition: Dictionary = PUZZLE_DEFS[index]
	var script_resource = load(String(definition["path"]))
	if script_resource == null:
		push_error("谜题脚本加载失败: %s" % String(definition["path"]))
		return
	var puzzle = script_resource.new()
	puzzle.name = "Puzzle_%s" % String(definition["id"])
	puzzle.setup(String(definition["id"]), String(definition["title"]), String(definition["hint"]))
	puzzle.solved.connect(_on_puzzle_solved)
	puzzle.close_requested.connect(close_puzzle)
	_slot.add_child(puzzle)
	puzzle.set_anchors_preset(Control.PRESET_FULL_RECT)
	_active_puzzle = puzzle
	_active_index = index
	_overlay.visible = true
	_refresh_ui()


func close_puzzle() -> void:
	if _overlay != null:
		_overlay.visible = false
	if _active_puzzle != null:
		if is_instance_valid(_active_puzzle) and _active_puzzle.get_parent() != null:
			_active_puzzle.get_parent().remove_child(_active_puzzle)
			_active_puzzle.queue_free()
		_active_puzzle = null
	_active_index = -1
	_refresh_ui()


func reset_lab() -> void:
	for index in range(_solved.size()):
		_solved[index] = false
		if index < _station_materials.size():
			_apply_station_color(index, false)
	close_puzzle()
	_refresh_ui()


# --- 3D 房间 ------------------------------------------------------------------

func _build_world() -> void:
	var floor := MeshInstance3D.new()
	floor.name = "Floor"
	var plane := PlaneMesh.new()
	plane.size = Vector2(26.0, 18.0)
	var material := ShaderMaterial.new()
	material.shader = load("res://shaders/grid_ground.gdshader")
	plane.material = material
	floor.mesh = plane
	add_child(floor)

	var wall_material := StandardMaterial3D.new()
	wall_material.albedo_color = Color(0.13, 0.16, 0.21)
	_add_box("WallBack", Vector3(0.0, 3.0, -9.0), Vector3(26.0, 6.0, 0.4), wall_material)
	_add_box("WallLeft", Vector3(-13.0, 3.0, 0.0), Vector3(0.4, 6.0, 18.0), wall_material)

	for index in range(PUZZLE_DEFS.size()):
		_add_station(index)


func _add_station(index: int) -> void:
	var station := Node3D.new()
	station.name = "Station_%02d" % (index + 1)
	station.position = STATION_POSITIONS[index]
	add_child(station)

	var body_material := StandardMaterial3D.new()
	body_material.albedo_color = Color(0.22, 0.25, 0.30)
	_add_box_to(station, "Pedestal", Vector3(0.0, 0.45, 0.0), Vector3(1.6, 0.9, 1.6), body_material)

	var top_material := StandardMaterial3D.new()
	top_material.albedo_color = STATION_COLORS[index]
	top_material.emission_enabled = true
	top_material.emission = STATION_COLORS[index]
	top_material.emission_energy_multiplier = 0.7
	_add_box_to(station, "Top", Vector3(0.0, 1.0, 0.0), Vector3(1.2, 0.25, 1.2), top_material)
	_station_materials.append(top_material)

	var label := Label3D.new()
	label.text = "%d · %s" % [index + 1, String(PUZZLE_DEFS[index]["title"])]
	label.font_size = 56
	label.pixel_size = 0.0055
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.modulate = Color(0.92, 0.96, 1.0)
	label.position = Vector3(0.0, 2.15, 0.0)
	station.add_child(label)

	var area := Area3D.new()
	area.name = "ClickArea"
	area.input_ray_pickable = true
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(1.9, 2.5, 1.9)
	shape.shape = box
	shape.position = Vector3(0.0, 1.25, 0.0)
	area.add_child(shape)
	station.add_child(area)
	area.input_event.connect(_on_station_input.bind(index))


func _on_station_input(_camera: Node, event: InputEvent, _position: Vector3, _normal: Vector3,
		_shape_index: int, index: int) -> void:
	var mouse := event as InputEventMouseButton
	if mouse != null and mouse.pressed and mouse.button_index == MOUSE_BUTTON_LEFT:
		open_puzzle(index)


# --- UI ----------------------------------------------------------------------

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	layer.name = "UI"
	add_child(layer)
	var ui := Control.new()
	ui.name = "Root"
	ui.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(ui)

	var panel := PanelContainer.new()
	panel.name = "StationList"
	panel.anchor_right = 0.0
	panel.anchor_bottom = 1.0
	panel.offset_left = 16.0
	panel.offset_top = 16.0
	panel.offset_right = 336.0
	panel.offset_bottom = -16.0
	# 实心面板：默认主题是半透明的，会把后面的解谜台透出来。
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.045, 0.055, 0.075, 0.94)
	style.border_color = Color(0.20, 0.25, 0.32, 1.0)
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(1.0)
	panel.add_theme_stylebox_override("panel", style)
	ui.add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 14)
	margin.add_theme_constant_override("margin_right", 14)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_bottom", 12)
	panel.add_child(margin)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 6)
	margin.add_child(column)
	column.add_child(_make_label("解谜实验室", 22, Color(0.94, 0.97, 1.0)))
	column.add_child(_make_label("8 种常规解谜 · 点台子或下面的列表", 12, Color(0.70, 0.80, 0.95)))
	_progress_label = _make_label("进度：0 / 8", 15, Color(1.0, 0.85, 0.45))
	_progress_label.name = "ProgressLabel"
	column.add_child(_progress_label)
	column.add_child(HSeparator.new())
	for index in range(PUZZLE_DEFS.size()):
		var button := Button.new()
		button.name = "StationButton_%d" % (index + 1)
		button.text = "%d. %s" % [index + 1, String(PUZZLE_DEFS[index]["title"])]
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.pressed.connect(open_puzzle.bind(index))
		column.add_child(button)
		_station_buttons.append(button)
	column.add_child(HSeparator.new())
	column.add_child(_make_label("解开全部 8 个会亮起完成横幅；ESC 关闭谜题页面。", 11,
		Color(0.62, 0.70, 0.82)))

	_overlay = Control.new()
	_overlay.name = "PuzzleOverlay"
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.visible = false
	_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	ui.add_child(_overlay)
	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.03, 0.05, 0.72)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.add_child(center)
	var frame := PanelContainer.new()
	frame.custom_minimum_size = Vector2(760, 560)
	frame.mouse_filter = Control.MOUSE_FILTER_STOP
	center.add_child(frame)
	_slot = Control.new()
	_slot.name = "PuzzleSlot"
	_slot.custom_minimum_size = Vector2(760, 560)
	frame.add_child(_slot)

	_banner = _make_label("8 / 8 全部解开 —— 这个房间里没有秘密了。", 22, Color(0.50, 1.0, 0.65))
	_banner.name = "CompleteBanner"
	_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_banner.anchor_top = 1.0
	_banner.anchor_bottom = 1.0
	_banner.anchor_right = 1.0
	_banner.offset_top = -70.0
	_banner.offset_bottom = -24.0
	_banner.visible = false
	ui.add_child(_banner)


func _unhandled_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key != null and key.pressed and key.keycode == KEY_ESCAPE and _active_index >= 0:
		close_puzzle()
		get_viewport().set_input_as_handled()


# --- 进度 ---------------------------------------------------------------------

func _on_puzzle_solved(puzzle_id: String) -> void:
	var index := _index_of(puzzle_id)
	if index < 0 or _solved[index]:
		return
	_solved[index] = true
	_apply_station_color(index, true)
	_refresh_ui()


func _index_of(puzzle_id: String) -> int:
	for index in range(PUZZLE_DEFS.size()):
		if String(PUZZLE_DEFS[index]["id"]) == puzzle_id:
			return index
	return -1


func _apply_station_color(index: int, solved: bool) -> void:
	if index < 0 or index >= _station_materials.size():
		return
	var material: StandardMaterial3D = _station_materials[index]
	if solved:
		material.albedo_color = Color(0.35, 0.85, 0.50)
		material.emission = Color(0.35, 0.85, 0.50)
		material.emission_energy_multiplier = 1.8
	else:
		material.albedo_color = STATION_COLORS[index]
		material.emission = STATION_COLORS[index]
		material.emission_energy_multiplier = 0.7


func _refresh_ui() -> void:
	if _progress_label != null:
		_progress_label.text = "进度：%d / %d" % [solved_count(), PUZZLE_DEFS.size()]
	for index in range(_station_buttons.size()):
		var mark := "✓ " if _solved[index] else ""
		_station_buttons[index].text = "%s%d. %s" % [mark, index + 1, String(PUZZLE_DEFS[index]["title"])]
	if _banner != null:
		_banner.visible = is_complete()


# --- 小工具 -------------------------------------------------------------------

func _make_label(text: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	return label


func _add_box(node_name: String, at: Vector3, size: Vector3, material: Material) -> void:
	_add_box_to(self, node_name, at, size, material)


func _add_box_to(parent: Node3D, node_name: String, at: Vector3, size: Vector3, material: Material) -> void:
	var node := MeshInstance3D.new()
	node.name = node_name
	var box := BoxMesh.new()
	box.size = size
	box.material = material
	node.mesh = box
	node.position = at
	parent.add_child(node)
