extends Control
## 线索板：archive / live 线索按时间排序；cause 用左侧装订线上的折线箭头
## 指向被引用的线索行。
##
## 箭头画在本节点的 _draw 里（子节点之后绘制会盖住它，所以行内容左侧留出装订线），
## 行本身是 Label，沿用项目现有 UI 的字体回退。

const GUTTER := 28.0
const ROW_HEIGHT := 21.0
const SOURCE_COLORS := {
	"archive": Color(0.62, 0.78, 1.0, 1.0),
	"live": Color(1.0, 0.74, 0.36, 1.0),
}

var _clue_manager: Node = null
var _row_by_id: Dictionary = {}
var _rows_root: VBoxContainer = null
var _scroll: ScrollContainer = null
var _title: Label = null
## 行是容器子节点，尺寸要等布局阶段；重建后多刷几帧，箭头才不会画在 0 尺寸上。
var _redraw_frames := 0


func _ready() -> void:
	_rows_root = get_node_or_null("BoardVBox/Scroll/Rows")
	_scroll = get_node_or_null("BoardVBox/Scroll")
	_title = get_node_or_null("BoardVBox/BoardTitle")
	if _scroll != null:
		var bar := _scroll.get_v_scroll_bar()
		if bar != null and not bar.value_changed.is_connected(_on_scrolled):
			bar.value_changed.connect(_on_scrolled)
	if not resized.is_connected(_on_resized):
		resized.connect(_on_resized)


func setup(clue_manager: Node) -> void:
	_clue_manager = clue_manager
	if clue_manager != null and not clue_manager.timeline_clue_registered.is_connected(_on_timeline_clue_registered):
		clue_manager.timeline_clue_registered.connect(_on_timeline_clue_registered)
	rebuild()


func rebuild() -> void:
	if _rows_root == null:
		return
	for child in _rows_root.get_children():
		child.queue_free()
	_row_by_id.clear()

	var clues: Array = _clue_manager.get_timeline_clues() if _clue_manager != null else []
	var archive_count := 0
	var live_count := 0
	for clue in clues:
		var row := _make_row(clue)
		_rows_root.add_child(row)
		_row_by_id[String(clue["id"])] = row
		if String(clue.get("source", "archive")) == "live":
			live_count += 1
		else:
			archive_count += 1

	if _title != null:
		_title.text = "线索板 · archive %d / live %d" % [archive_count, live_count]
	_redraw_frames = 3
	queue_redraw()


func get_row_count() -> int:
	return _row_by_id.size()


func _process(_delta: float) -> void:
	if _redraw_frames <= 0:
		return
	_redraw_frames -= 1
	queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.045, 0.055, 0.075, 0.86), true)
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.20, 0.25, 0.32, 1.0), false, 1.0)

	if _clue_manager == null:
		return
	var origin := get_global_rect().position
	for clue in _clue_manager.get_timeline_clues():
		var cause := String((clue as Dictionary).get("cause", ""))
		if cause.is_empty():
			continue
		var clue_id := String(clue["id"])
		if not _row_by_id.has(cause) or not _row_by_id.has(clue_id):
			continue
		var from_row: Control = _row_by_id[cause]
		var to_row: Control = _row_by_id[clue_id]
		var from_rect := from_row.get_global_rect()
		var to_rect := to_row.get_global_rect()
		if from_rect.size.y <= 0.0 or to_rect.size.y <= 0.0:
			continue
		var y_from := from_rect.position.y + from_rect.size.y * 0.5 - origin.y
		var y_to := to_rect.position.y + to_rect.size.y * 0.5 - origin.y
		var x := to_rect.position.x - origin.x + 10.0
		var color: Color = SOURCE_COLORS.get(String(clue.get("source", "archive")), Color.WHITE)
		color.a = 0.8
		draw_polyline(PackedVector2Array([
			Vector2(x + 8.0, y_from),
			Vector2(x, y_from),
			Vector2(x, y_to),
			Vector2(x + 7.0, y_to),
		]), color, 1.4)
		# 箭头
		draw_colored_polygon(PackedVector2Array([
			Vector2(x + 7.0, y_to),
			Vector2(x + 1.0, y_to - 3.2),
			Vector2(x + 1.0, y_to + 3.2),
		]), color)


# --- 内部 ---------------------------------------------------------------------

func _make_row(clue: Dictionary) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.custom_minimum_size = Vector2(0.0, ROW_HEIGHT)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(GUTTER, ROW_HEIGHT)
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(spacer)

	var label := Label.new()
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.text = "%.1fs  %s  %s->%s  [%s]" % [
		float(clue["t"]),
		String(clue["type"]),
		String(clue["actor"]),
		String(clue["target"]),
		String(clue.get("source", "archive")),
	]
	label.add_theme_font_size_override("font_size", 12)
	var color: Color = SOURCE_COLORS.get(String(clue.get("source", "archive")), Color.WHITE)
	label.add_theme_color_override("font_color", color)
	label.clip_text = true
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(label)
	return row


func _on_timeline_clue_registered(_clue: Dictionary) -> void:
	rebuild()


func _on_scrolled(_value: float) -> void:
	queue_redraw()


func _on_resized() -> void:
	queue_redraw()
