extends Node
## W4 双画风渲染控制器（契约见 docs/MECHANICS_CONTRACTS.md §8）。
##
## 两层画风：`real` 用钢笔画（底色 + 反向外扩描边，同一个 shader 的两个 pass），
## `imaginary` 用铅笔画（纸白底 + 排线 + 颗粒噪点）。两层互相独立，可同时开启。
## 所有材质都由本模块在运行时创建并覆盖到目标节点的 material_override，
## 不改 project.godot 的渲染设置，也不新增 autoload。
##
## 用法（由 W12 装配）：把本节点挂到游戏根节点下，给需要上画风的节点
## add_to_group("real") / add_to_group("imaginary")，再调用 apply_style()。
## 新加入的节点只要在对应层开启时再调一次 apply_style() 就会补齐。
##
## group 只接受 W0 规范值 real / imaginary；friend / stranger 必须先经
## PersonGroup.normalize() 归一化后再传进来（见契约 §4）。

const INK_SHADER := "res://shaders/ink_outline.gdshader"
const PENCIL_SHADER := "res://shaders/pencil_sketch.gdshader"

const GROUP_REAL := "real"
const GROUP_IMAGINARY := "imaginary"
const GROUPS: Array[String] = [GROUP_REAL, GROUP_IMAGINARY]

## 最近一次非法调用的原因（get_state 也会带出）；合法调用会清空。
var last_error := ""

## group -> {enabled, shader, material, outline_material, params}
var _styles: Dictionary = {}
## group -> {instance_id: {node: WeakRef, previous: Material}}
var _applied: Dictionary = {}
## 参数名 -> {group, type, default, min, max}；两层参数名不重复，短名可直接用。
var _param_defs: Dictionary = {}


func _init() -> void:
	_param_defs = {
		"outline_width": {"group": GROUP_REAL, "type": "float", "default": 0.035, "min": 0.0, "max": 0.25},
		"outline_color": {"group": GROUP_REAL, "type": "color", "default": Color(0.06, 0.06, 0.08, 1.0)},
		"paper_color": {"group": GROUP_REAL, "type": "color", "default": Color(0.93, 0.90, 0.83, 1.0)},
		"grain_strength": {"group": GROUP_IMAGINARY, "type": "float", "default": 0.55, "min": 0.0, "max": 1.0},
		"grain_scale": {"group": GROUP_IMAGINARY, "type": "float", "default": 55.0, "min": 2.0, "max": 200.0},
		"stroke_strength": {"group": GROUP_IMAGINARY, "type": "float", "default": 0.5, "min": 0.0, "max": 1.0},
		"stroke_scale": {"group": GROUP_IMAGINARY, "type": "float", "default": 26.0, "min": 2.0, "max": 80.0},
		"shade_strength": {"group": GROUP_IMAGINARY, "type": "float", "default": 1.0, "min": 0.0, "max": 1.0},
		"sketch_paper_color": {"group": GROUP_IMAGINARY, "type": "color", "default": Color(0.92, 0.90, 0.84, 1.0)},
		"graphite_color": {"group": GROUP_IMAGINARY, "type": "color", "default": Color(0.16, 0.16, 0.18, 1.0)},
	}
	_build_styles()


func _ready() -> void:
	# 允许宿主先配置好画风、再挂进场景树；入树时把已开启的层补到节点上。
	for group in GROUPS:
		if _styles.has(group) and bool(_styles[group]["enabled"]):
			_apply_group(group)


## 开关某一层画风，并把运行时材质覆盖到该组节点上。
## 已开启时再次调用是幂等的（会补齐期间新加入的节点）。
func apply_style(group: String, enabled: bool) -> bool:
	last_error = ""
	var canonical := _canonical_group(group)
	if canonical.is_empty():
		_fail("未知 group: %s（只接受 real / imaginary）" % group)
		return false
	if not _styles.has(canonical):
		_fail("画风 shader 未加载: %s" % canonical)
		return false

	_styles[canonical]["enabled"] = enabled
	if enabled:
		_apply_group(canonical)
	else:
		_restore_group(canonical)
	return true


## 设置某一层画风的材质参数。name 可带 group 前缀（real./imaginary.），
## 也可直接用短名（两层参数名不重复）。数值会按 shader 的 hint_range 限幅。
func set_param(name: String, value: Variant) -> bool:
	last_error = ""
	var key := name.strip_edges()
	var group_filter := ""
	if key.contains("."):
		var parts := key.split(".", false, 1)
		if parts.size() != 2:
			_fail("参数名格式应为 name 或 group.name: %s" % name)
			return false
		group_filter = _canonical_group(parts[0])
		if group_filter.is_empty():
			_fail("未知 group 前缀: %s（只接受 real / imaginary）" % parts[0])
			return false
		key = parts[1].strip_edges()

	if not _param_defs.has(key):
		_fail("未知画风参数: %s" % key)
		return false
	var def: Dictionary = _param_defs[key]
	var group := String(def["group"])
	if not group_filter.is_empty() and group_filter != group:
		_fail("参数 %s 属于 %s，不能设置到 %s" % [key, group, group_filter])
		return false
	if not _styles.has(group):
		_fail("画风 shader 未加载: %s" % group)
		return false

	var normalized: Variant
	if String(def["type"]) == "float":
		var value_type := typeof(value)
		if value_type != TYPE_FLOAT and value_type != TYPE_INT:
			_fail("参数 %s 需要数值，收到 %s" % [key, type_string(value_type)])
			return false
		var numeric := float(value)
		if is_nan(numeric) or is_inf(numeric):
			_fail("参数 %s 不能是 NaN / Infinity" % key)
			return false
		normalized = clampf(numeric, float(def["min"]), float(def["max"]))
	elif String(def["type"]) == "color":
		if not value is Color:
			_fail("参数 %s 需要 Color，收到 %s" % [key, type_string(typeof(value))])
			return false
		normalized = value
	else:
		_fail("参数 %s 的类型定义未知" % key)
		return false

	(_styles[group]["params"] as Dictionary)[key] = normalized
	_write_param(_styles[group], key, normalized)
	return true


## 返回当前状态的深拷贝，调用方随便改不会影响内部。
func get_state() -> Dictionary:
	var styles: Dictionary = {}
	for group in GROUPS:
		if not _styles.has(group):
			continue
		var style: Dictionary = _styles[group]
		styles[group] = {
			"enabled": bool(style["enabled"]),
			"shader": String(style["shader"]),
			"params": (style["params"] as Dictionary).duplicate(true),
			"applied_nodes": _applied_count(group),
		}
	return {"styles": styles, "last_error": last_error}


## 供宿主（W12）取某一层的底层材质，便于对动态生成的节点直接赋值。
## 未知 group 返回 null。
func get_material(group: String) -> Material:
	var canonical := _canonical_group(group)
	if not _styles.has(canonical):
		return null
	return _styles[canonical]["material"]


# --- 内部 ---------------------------------------------------------------------

func _build_styles() -> void:
	var shader_paths := {GROUP_REAL: INK_SHADER, GROUP_IMAGINARY: PENCIL_SHADER}
	for group in GROUPS:
		var path := String(shader_paths[group])
		var shader: Shader = load(path)
		if shader == null:
			push_warning("StyleController: 无法加载画风 shader %s" % path)
			continue
		var material := ShaderMaterial.new()
		material.shader = shader
		var outline_material: ShaderMaterial = null
		if group == GROUP_REAL:
			# 钢笔画用同一 shader 的第二份材质做外扩描边 pass。
			outline_material = ShaderMaterial.new()
			outline_material.shader = shader
			outline_material.set_shader_parameter("outline_pass", true)
			material.next_pass = outline_material
		var params: Dictionary = {}
		for key in _param_defs:
			var def: Dictionary = _param_defs[key]
			if String(def["group"]) != group:
				continue
			var default_value: Variant = def["default"]
			params[key] = default_value
			material.set_shader_parameter(key, default_value)
			if outline_material != null:
				outline_material.set_shader_parameter(key, default_value)
		_styles[group] = {
			"enabled": false,
			"shader": path,
			"material": material,
			"outline_material": outline_material,
			"params": params,
		}


func _canonical_group(group: String) -> String:
	var value := group.strip_edges()
	if value == GROUP_REAL or value == GROUP_IMAGINARY:
		return value
	return ""


func _apply_group(group: String) -> void:
	if not is_inside_tree():
		return
	var tree := get_tree()
	if tree == null:
		return
	var applied: Dictionary = _applied.get(group, {})
	var material: Material = _styles[group]["material"]
	for node in tree.get_nodes_in_group(group):
		if not node is GeometryInstance3D:
			continue
		var target := node as GeometryInstance3D
		var id := target.get_instance_id()
		if applied.has(id):
			var record: Dictionary = applied[id]
			var reference: Variant = record.get("node")
			var tracked: Variant = reference.get_ref() if reference is WeakRef else null
			if tracked == target:
				continue
		var previous: Variant = target.material_override
		target.material_override = material
		applied[id] = {"node": weakref(target), "previous": previous}
	_applied[group] = applied


func _restore_group(group: String) -> void:
	var applied: Dictionary = _applied.get(group, {})
	var material: Material = _styles[group]["material"]
	for id in applied.keys():
		var record: Dictionary = applied[id]
		var reference: Variant = record.get("node")
		var target: Variant = reference.get_ref() if reference is WeakRef else null
		if target == null or not is_instance_valid(target):
			continue
		# 只还原仍然是我们覆盖的节点，别把别人后来换上的材质清掉。
		if (target as GeometryInstance3D).material_override == material:
			(target as GeometryInstance3D).material_override = record.get("previous")
	applied.clear()
	_applied[group] = applied


func _applied_count(group: String) -> int:
	var count := 0
	var applied: Dictionary = _applied.get(group, {})
	for id in applied:
		var record: Dictionary = applied[id]
		var reference: Variant = record.get("node")
		var target: Variant = reference.get_ref() if reference is WeakRef else null
		if target != null and is_instance_valid(target):
			count += 1
	return count


func _write_param(style: Dictionary, key: String, value: Variant) -> void:
	(style["material"] as ShaderMaterial).set_shader_parameter(key, value)
	var outline: Variant = style.get("outline_material")
	if outline is ShaderMaterial:
		(outline as ShaderMaterial).set_shader_parameter(key, value)


func _fail(message: String) -> void:
	last_error = message
	push_warning("StyleController: " + message)
