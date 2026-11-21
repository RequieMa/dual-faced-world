extends SceneTree
## W4 双画风渲染（StyleController）单测。
## 运行：godot --headless --path . --script tests/test_style_controller.gd
## 退出码 0 = 全绿，1 = 有用例失败。
##
## 覆盖：shader 资源存在且可加载 / 两组画风独立开关 / 幂等 / 未知 group 报错不崩 /
## 参数读写与校验 / get_state 快照隔离 / 运行时 material_override 覆盖与还原。

const CONTROLLER := "res://scripts/render/style_controller.gd"
const INK_SHADER := "res://shaders/ink_outline.gdshader"
const PENCIL_SHADER := "res://shaders/pencil_sketch.gdshader"

var _failures: Array[String] = []
var _checks := 0
var _started := false


func _initialize() -> void:
	var paths := [CONTROLLER, INK_SHADER, PENCIL_SHADER]
	for path in paths:
		_check("存在 %s" % path, ResourceLoader.exists(path))
	if not ResourceLoader.exists(CONTROLLER) or not ResourceLoader.exists(INK_SHADER) \
			or not ResourceLoader.exists(PENCIL_SHADER):
		_report()


func _process(_delta: float) -> bool:
	# _initialize 阶段 root 还没进场景树，等第一帧再 new 节点/加组。
	if _started:
		return false
	_started = true
	_run_tests()
	return false


func _run_tests() -> void:
	_test_shader_resources()

	var controller = load(CONTROLLER).new()
	_check("StyleController 是 Node", controller is Node, str(controller))
	if not controller is Node:
		_report()
		return
	root.add_child(controller)

	_test_initial_state(controller)
	_test_apply(controller)
	_test_idempotent(controller)
	_test_new_nodes(controller)
	_test_disable(controller)
	_test_restore_previous(controller)
	_test_unknown_group(controller)
	_test_params(controller)
	_test_ready_applies_enabled()
	_test_state_snapshot(controller)

	controller.free()
	_report()


# --- 断言 ---------------------------------------------------------------------

func _check(label: String, condition: bool, detail: String = "") -> void:
	_checks += 1
	if condition:
		print("PASS  ", label)
	else:
		var message := label
		if not detail.is_empty():
			message += "  [" + detail + "]"
		_failures.append(message)
		printerr("FAIL  ", message)


func _report() -> void:
	print("----")
	if _failures.is_empty():
		print("STYLE_CONTROLLER_TEST_PASS (%d checks)" % _checks)
		quit(0)
	else:
		printerr("STYLE_CONTROLLER_TEST_FAIL (%d/%d failed)" % [_failures.size(), _checks])
		for failure in _failures:
			printerr("  - ", failure)
		quit(1)


# --- 工具 ---------------------------------------------------------------------

func _make_mesh(group: String) -> MeshInstance3D:
	var mesh := MeshInstance3D.new()
	mesh.name = "StyleTest_" + group + "_" + str(_checks)
	mesh.mesh = BoxMesh.new()
	mesh.add_to_group(group, true)
	root.add_child(mesh)
	return mesh


# --- 用例 ---------------------------------------------------------------------

func _test_shader_resources() -> void:
	var ink = load(INK_SHADER)
	var pencil = load(PENCIL_SHADER)
	_check("ink_outline.gdshader 可加载为 Shader", ink is Shader, str(ink))
	_check("pencil_sketch.gdshader 可加载为 Shader", pencil is Shader, str(pencil))
	if ink is Shader:
		_check("ink shader 含描边 pass 参数", (ink as Shader).code.contains("outline_pass"))
		_check("ink shader 是 spatial", (ink as Shader).code.contains("shader_type spatial"))
	if pencil is Shader:
		_check("pencil shader 含噪点参数", (pencil as Shader).code.contains("grain_strength"))
		_check("pencil shader 是 spatial", (pencil as Shader).code.contains("shader_type spatial"))


func _test_initial_state(controller) -> void:
	var state: Dictionary = controller.get_state()
	var styles: Dictionary = state.get("styles", {})
	_check("get_state 包含两层画风", styles.has("real") and styles.has("imaginary"), str(styles))
	_check("初始时 real 关闭", not bool(styles["real"]["enabled"]))
	_check("初始时 imaginary 关闭", not bool(styles["imaginary"]["enabled"]))
	_check("初始时没有已覆盖节点",
		int(styles["real"]["applied_nodes"]) == 0 and int(styles["imaginary"]["applied_nodes"]) == 0)
	_check("real 参数可读", (styles["real"]["params"] as Dictionary).has("outline_width"))
	_check("imaginary 参数可读", (styles["imaginary"]["params"] as Dictionary).has("grain_strength"))
	_check("imaginary 纸色参数可读", (styles["imaginary"]["params"] as Dictionary).has("sketch_paper_color"))

	var ink = controller.get_material("real")
	var pencil = controller.get_material("imaginary")
	_check("real 画风是 ShaderMaterial", ink is ShaderMaterial, str(ink))
	_check("imaginary 画风是 ShaderMaterial", pencil is ShaderMaterial, str(pencil))
	if ink is ShaderMaterial:
		_check("ink 材质指向 ink shader", (ink as ShaderMaterial).shader.resource_path == INK_SHADER)
		_check("ink 材质带描边第二层（next_pass）", (ink as ShaderMaterial).next_pass != null)
	if pencil is ShaderMaterial:
		_check("pencil 材质指向 pencil shader", (pencil as ShaderMaterial).shader.resource_path == PENCIL_SHADER)
	_check("未知组取材质返回 null", controller.get_material("stranger") == null)


func _test_apply(controller) -> void:
	var real_mesh := _make_mesh("real")
	var imaginary_mesh := _make_mesh("imaginary")
	var ink = controller.get_material("real")
	var pencil = controller.get_material("imaginary")

	_check("apply_style(real, true) 返回 true", controller.apply_style("real", true))
	_check("real 节点被运行时材质覆盖", real_mesh.material_override == ink,
		str(real_mesh.material_override))
	_check("只影响 real 组，不动 imaginary 节点", imaginary_mesh.material_override == null,
		str(imaginary_mesh.material_override))
	_check("get_state 记录 real 已开启", bool(controller.get_state()["styles"]["real"]["enabled"]))
	_check("get_state 统计 real 覆盖节点数", int(controller.get_state()["styles"]["real"]["applied_nodes"]) == 1,
		str(controller.get_state()["styles"]["real"]))

	_check("apply_style(imaginary, true) 返回 true", controller.apply_style("imaginary", true))
	_check("imaginary 节点被铅笔材质覆盖", imaginary_mesh.material_override == pencil,
		str(imaginary_mesh.material_override))
	_check("两层可同时开启",
		bool(controller.get_state()["styles"]["real"]["enabled"])
			and bool(controller.get_state()["styles"]["imaginary"]["enabled"]))


func _test_idempotent(controller) -> void:
	var real_mesh := _make_mesh("real")
	var ink = controller.get_material("real")
	_check("重复 apply_style(real, true) 返回 true", controller.apply_style("real", true))
	_check("重复开启不会叠加/换材质", real_mesh.material_override == ink)
	_check("重复开启不重复统计节点",
		int(controller.get_state()["styles"]["real"]["applied_nodes"]) == 2,
		str(controller.get_state()["styles"]["real"]))
	_check("重复开启 imaginary 同样幂等", controller.apply_style("imaginary", true)
		and controller.apply_style("imaginary", true))


func _test_new_nodes(controller) -> void:
	var late_mesh := _make_mesh("real")
	var ink = controller.get_material("real")
	_check("已开启后再次 apply 可补齐新节点", controller.apply_style("real", true)
		and late_mesh.material_override == ink)
	_check("新节点被计入覆盖数",
		int(controller.get_state()["styles"]["real"]["applied_nodes"]) == 3,
		str(controller.get_state()["styles"]["real"]))


func _test_disable(controller) -> void:
	var real_meshes := get_nodes_in_group("real")
	var imaginary_meshes := get_nodes_in_group("imaginary")
	_check("apply_style(real, false) 返回 true", controller.apply_style("real", false))
	var all_cleared := true
	for node in real_meshes:
		if node is MeshInstance3D and (node as MeshInstance3D).material_override != null:
			all_cleared = false
	_check("关闭 real 后清除运行时覆盖", all_cleared)
	_check("关闭 real 不影响 imaginary",
		(imaginary_meshes[0] as MeshInstance3D).material_override != null)
	_check("关闭后覆盖节点数归零",
		int(controller.get_state()["styles"]["real"]["applied_nodes"]) == 0)
	_check("重复关闭返回 true", controller.apply_style("real", false))
	_check("未知组关闭也不崩", not controller.apply_style("stranger", false))


func _test_restore_previous(controller) -> void:
	var mesh := _make_mesh("real")
	var previous := StandardMaterial3D.new()
	previous.albedo_color = Color(0.2, 0.4, 0.6)
	mesh.material_override = previous
	_check("开启 real 时覆盖原有材质", controller.apply_style("real", true)
		and mesh.material_override == controller.get_material("real"))
	_check("关闭 real 时恢复原有材质", controller.apply_style("real", false)
		and mesh.material_override == previous, str(mesh.material_override))
	# 清掉这个测试节点，避免影响后续计数
	mesh.free()


func _test_unknown_group(controller) -> void:
	_check("未知 group 开启返回 false", not controller.apply_style("stranger", true))
	_check("未知 group 写入错误信息",
		String(controller.get_state()["last_error"]).contains("stranger"),
		str(controller.get_state()["last_error"]))
	_check("未知 group 不会崩溃，后续合法调用仍可用", controller.apply_style("real", true))
	_check("合法调用清空上次错误", String(controller.get_state()["last_error"]).is_empty())
	controller.apply_style("real", false)


func _test_params(controller) -> void:
	var ink = controller.get_material("real")
	var pencil = controller.get_material("imaginary")

	_check("短名设置 real 参数", controller.set_param("outline_width", 0.08))
	_check("参数写入 ink 材质",
		is_equal_approx(float(ink.get_shader_parameter("outline_width")), 0.08),
		str(ink.get_shader_parameter("outline_width")))
	_check("参数可从 get_state 读到",
		is_equal_approx(float(controller.get_state()["styles"]["real"]["params"]["outline_width"]), 0.08))
	_check("带 group 前缀设置 imaginary 参数",
		controller.set_param("imaginary.grain_strength", 0.9))
	_check("参数写入 pencil 材质",
		is_equal_approx(float(pencil.get_shader_parameter("grain_strength")), 0.9),
		str(pencil.get_shader_parameter("grain_strength")))
	_check("带 group 前缀设置 real 参数",
		controller.set_param("real.outline_color", Color(0.9, 0.1, 0.05, 1.0)))
	_check("颜色参数写入 ink 材质",
		ink.get_shader_parameter("outline_color") == Color(0.9, 0.1, 0.05, 1.0),
		str(ink.get_shader_parameter("outline_color")))
	_check("第二层纸色参数也可写",
		controller.set_param("imaginary.sketch_paper_color", Color(0.8, 0.7, 0.6, 1.0)))
	_check("第二层纸色写入 pencil 材质",
		pencil.get_shader_parameter("sketch_paper_color") == Color(0.8, 0.7, 0.6, 1.0),
		str(pencil.get_shader_parameter("sketch_paper_color")))
	_check("设置相同值幂等", controller.set_param("outline_width", 0.08))
	_check("数值会被 hint_range 限幅", controller.set_param("outline_width", 9.0)
		and is_equal_approx(float(controller.get_state()["styles"]["real"]["params"]["outline_width"]), 0.25),
		str(controller.get_state()["styles"]["real"]["params"]["outline_width"]))
	_check("未知参数返回 false", not controller.set_param("no_such_param", 1.0))
	_check("未知参数写入错误信息",
		not String(controller.get_state()["last_error"]).is_empty())
	_check("类型不符返回 false", not controller.set_param("outline_width", "wide"))
	_check("group 前缀与参数不匹配返回 false",
		not controller.set_param("imaginary.outline_width", 0.1))
	_check("未知 group 前缀返回 false", not controller.set_param("friend.outline_width", 0.1))
	_check("未知 group 前缀写入错误信息",
		String(controller.get_state()["last_error"]).contains("friend"))
	_check("非法失败不污染已生效参数",
		is_equal_approx(float(controller.get_state()["styles"]["real"]["params"]["outline_width"]), 0.25))


func _test_ready_applies_enabled() -> void:
	# 允许宿主先 apply_style 再挂树：_ready 时把已开启的层补到节点上。
	var late_controller = load(CONTROLLER).new()
	_check("入树前 apply_style 只记录状态", late_controller.apply_style("imaginary", true))
	_check("入树前没有可覆盖节点",
		int(late_controller.get_state()["styles"]["imaginary"]["applied_nodes"]) == 0)
	var mesh := _make_mesh("imaginary")
	root.add_child(late_controller)
	_check("入树时自动补齐已开启层", mesh.material_override == late_controller.get_material("imaginary"),
		str(mesh.material_override))
	late_controller.free()
	mesh.free()


func _test_state_snapshot(controller) -> void:
	controller.apply_style("real", true)
	var snapshot: Dictionary = controller.get_state()
	(snapshot["styles"]["real"]["params"] as Dictionary)["outline_width"] = 123.0
	snapshot["styles"]["real"]["enabled"] = false
	var again: Dictionary = controller.get_state()
	_check("get_state 返回深拷贝，改快照不影响内部参数",
		is_equal_approx(float(again["styles"]["real"]["params"]["outline_width"]), 0.25),
		str(again["styles"]["real"]["params"]["outline_width"]))
	_check("get_state 返回深拷贝，改快照不影响开关",
		bool(again["styles"]["real"]["enabled"]))
	controller.apply_style("real", false)
