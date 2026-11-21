extends RefCounted
## 两类对话框的主题层（W3）。
##
## 机制「两类对话框」：同一个对话框组件按「真实的人 / 幻想中的朋友」套两套样式。
## 规范 group 是 `real` / `imaginary`（见 docs/MECHANICS_CONTRACTS.md §4），
## `stranger` / `friend` 只是给文案用的别名，必须先归一化再选样式。
##
## 样式全部是纯数据（颜色 / 边框宽度 / 圆角 / 字号 / 内边距），
## `set_style_params()` 可在运行时覆盖任意字段；不依赖字体/贴图，因此无头可测。

const REAL := "real"
const IMAGINARY := "imaginary"
const STRANGER_ALIAS := "stranger"
const FRIEND_ALIAS := "friend"

## PersonGroup（W2）是 group 归一化的单一入口；它还没合并时按契约同一映射兜底。
const PERSON_GROUP_PATH := "res://scripts/person/person_group.gd"

## 两套默认主题：real = 路人（冷色、细边框、小字号），imaginary = 朋友（暖紫、粗边框、大字号）。
const DEFAULT_STYLES := {
	"real": {
		"display_name": "路人",
		"bg_color": Color(0.06, 0.08, 0.11, 0.94),
		"border_color": Color(0.42, 0.57, 0.72, 1.0),
		"text_color": Color(0.85, 0.90, 0.96, 1.0),
		"speaker_color": Color(0.56, 0.74, 0.93, 1.0),
		"border_width": 1,
		"corner_radius": 4,
		"font_size": 16,
		"speaker_font_size": 17,
		"padding": 16,
	},
	"imaginary": {
		"display_name": "朋友",
		"bg_color": Color(0.14, 0.10, 0.18, 0.94),
		"border_color": Color(0.72, 0.53, 0.88, 1.0),
		"text_color": Color(0.96, 0.90, 0.96, 1.0),
		"speaker_color": Color(0.92, 0.72, 0.95, 1.0),
		"border_width": 3,
		"corner_radius": 12,
		"font_size": 19,
		"speaker_font_size": 21,
		"padding": 20,
	},
}

static var _person_group_script: Variant = null
static var _person_group_checked := false

var _overrides: Dictionary = {}


## 唯一归一化入口：friend -> imaginary，stranger -> real，未知值 -> real（不崩溃）。
## W2 的 PersonGroup 合并后优先委托它，保证全项目只有一套映射；W2 合并后可删掉下面的
## 兜底分支并补一条「委托已生效」的回归测试（见 PR 说明的后续动作）。
static func normalize_group(group: String) -> String:
	var value := group.strip_edges().to_lower()
	var person_group = _get_person_group_script()
	if person_group != null:
		return String(person_group.normalize(value))
	match value:
		REAL:
			return REAL
		IMAGINARY:
			return IMAGINARY
		STRANGER_ALIAS:
			return REAL
		FRIEND_ALIAS:
			return IMAGINARY
		_:
			push_warning("DialogueTheme: 未知 group \"%s\"，按 real 处理" % group)
			return REAL


static func _get_person_group_script() -> Variant:
	if not _person_group_checked:
		_person_group_checked = true
		if ResourceLoader.exists(PERSON_GROUP_PATH):
			_person_group_script = load(PERSON_GROUP_PATH)
	return _person_group_script


## 返回某个 group 的最终样式（默认值 + 运行时覆盖），group 会先归一化。
func get_style(group: String) -> Dictionary:
	var key := normalize_group(group)
	var style: Dictionary = (DEFAULT_STYLES[key] as Dictionary).duplicate(true)
	var overrides: Dictionary = _overrides.get(key, {})
	for field in overrides.keys():
		style[field] = overrides[field]
	return style


## 运行时改主题参数（例如策划调字号/边框）；field 没有白名单，方便向前兼容。
func set_style_params(group: String, params: Dictionary) -> void:
	var key := normalize_group(group)
	var merged: Dictionary = (_overrides.get(key, {}) as Dictionary).duplicate(true)
	for field in params.keys():
		merged[field] = params[field]
	_overrides[key] = merged


func reset_style_params() -> void:
	_overrides.clear()


## 把主题数据转成 PanelContainer 能直接用的 StyleBox。
func make_stylebox(group: String) -> StyleBoxFlat:
	var style := get_style(group)
	var box := StyleBoxFlat.new()
	box.bg_color = style["bg_color"]
	box.border_color = style["border_color"]
	box.set_border_width_all(int(style["border_width"]))
	box.set_corner_radius_all(int(style["corner_radius"]))
	var padding := int(style["padding"])
	box.content_margin_left = padding
	box.content_margin_right = padding
	box.content_margin_top = padding
	box.content_margin_bottom = padding
	return box
