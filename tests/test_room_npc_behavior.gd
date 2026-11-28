extends SceneTree
## NPC 视锥/行为 + 房间家具回归。
## 运行：godot --headless --path . --script tests/test_room_npc_behavior.gd
##
## 覆盖：椅子贴近屏幕、观察房间家具有无、SpotLight 阴影视锥、NPC 初始停顿/
## 起步加速/走路起伏、墙后目标不可见（射线遮挡）。

const MAIN_SCENE := "res://scenes/main.tscn"
const NPC_SCRIPT := "res://scripts/room_demo/npc_actor.gd"
const EXPECTED_CHECKS := 40

var _failures: Array[String] = []
var _checks: int = 0


func _initialize() -> void:
	_check("存在 scenes/main.tscn", ResourceLoader.exists(MAIN_SCENE))
	await process_frame
	var packed := ResourceLoader.load(MAIN_SCENE) as PackedScene
	var demo = packed.instantiate()
	root.add_child(demo)

	# 1) 椅子应该就在屏幕前。
	var chair_z := float(demo.player.chair_position.z)
	var screen_z := float(demo.player.screen_position.z)
	_check("椅子在屏幕前 3m 内", absf(chair_z - screen_z) <= 3.0,
		"chair=%.2f screen=%.2f" % [chair_z, screen_z])

	# 2) 两个观察房间都有家具。
	for node_name in ["ShelfA", "SofaA", "CabinetA", "RugA", "PlanterA",
			"ShelfB", "SofaB", "CabinetB", "RugB", "PlanterB"]:
		_check("观察房间有家具 %s" % node_name, demo.find_child(node_name, true, false) != null)

	# 坐下后显示屏应该基本占满画面；滚动屏是 2D 右上角面板。
	demo.set_seated(true)
	var seated_camera: Camera3D = demo.player.camera
	var monitor_mesh := demo.find_child("MonitorScreen", true, false) as MeshInstance3D
	var monitor_quad := monitor_mesh.mesh as QuadMesh if monitor_mesh != null else null
	if monitor_quad != null:
		var distance := seated_camera.global_position.distance_to(Vector3(0, 1.55, -5.81))
		var angular := rad_to_deg(2.0 * atan((monitor_quad.size.y * 0.5) / distance))
		var ratio := angular / seated_camera.fov
		_check("坐下后显示屏高度约占视野 88%+", ratio >= 0.88,
			"ratio=%.3f angle=%.1f fov=%.1f" % [ratio, angular, seated_camera.fov])
		_check("屏幕上下边都在垂直视野内",
			seated_camera.is_position_in_frustum(Vector3(0, 2.65, -5.81))
			and seated_camera.is_position_in_frustum(Vector3(0, 0.45, -5.81)))
	_check("坐下后滚动屏面板可见", demo.ui.is_scroll_visible())
	var lens := demo.find_child("LensRect", true, false) as ColorRect
	_check("第一人称镜头畸变存在", lens != null and lens.material is ShaderMaterial)
	var view_size: Vector2 = demo.get_viewport().get_visible_rect().size
	var screen_center: Vector2 = view_size * 0.5
	var screen_edge: Vector2 = Vector2(view_size.x * 0.9, view_size.y * 0.5)
	var lens_center: Vector2 = demo.lens_source_position(screen_center)
	var lens_edge: Vector2 = demo.lens_source_position(screen_edge)
	_check("镜头畸变中心不偏移", lens_center.distance_to(screen_center) < 0.5,
		str(lens_center))
	_check("镜头畸变边缘鼠标向外补偿",
		lens_edge.distance_to(screen_center) > screen_edge.distance_to(screen_center),
		str(lens_edge))
	_check("监控屏与 viewport 同比例",
		monitor_quad != null and is_equal_approx(monitor_quad.size.x / monitor_quad.size.y,
			float(demo.monitor_viewport.size.x) / float(demo.monitor_viewport.size.y)),
		"" if monitor_quad == null else "quad=%.3f" % (monitor_quad.size.x / monitor_quad.size.y))
	_check("滚动屏 UI 高度适配 viewport",
		is_equal_approx(demo.scroll_ui.size.y, float(demo.scroll_viewport.size.y)),
		"ui=%.1f viewport=%d" % [demo.scroll_ui.size.y, demo.scroll_viewport.size.y])
	demo.tick(0.1)
	var scroll_drop = demo.ui._scroll_drop as Control
	_check("滚动屏拖放区可见", scroll_drop != null and scroll_drop.visible)
	_check("滚动屏拖放区有有效矩形",
		scroll_drop != null and scroll_drop.get_global_rect().size.x > 10.0,
		"" if scroll_drop == null else str(scroll_drop.get_global_rect()))
	demo.set_seated(false)

	# 3) 视锥是 spotlight，带阴影、角度/距离收小。
	var npc = demo.npcs[0]
	var spot := npc.find_child("VisionSpot", true, false) as SpotLight3D
	_check("NPC 有 SpotLight 视锥", spot != null)
	var cone := npc.find_child("VisionCone", true, false) as MeshInstance3D
	_check("NPC 有短可见锥体", cone != null)
	_check("视锥启用阴影（只照第一个面）", spot != null and spot.shadow_enabled)
	_check("视锥距离不大", spot != null and spot.spot_range <= 6.6,
		"" if spot == null else "range=%.2f" % spot.spot_range)
	_check("视锥角度不大", spot != null and spot.spot_angle <= 70.0,
		"" if spot == null else "angle=%.1f" % spot.spot_angle)
	_check("视锥不参与 GI", spot != null and is_equal_approx(spot.light_indirect_energy, 0.0))
	var cone_material := cone.material_override as StandardMaterial3D if cone != null else null
	_check("可见锥体双面渲染",
		cone_material != null and cone_material.cull_mode == BaseMaterial3D.CULL_DISABLED)
	_check("可见锥体透明度 80%",
		cone_material != null and is_equal_approx(cone_material.albedo_color.a, 0.8),
		"" if cone_material == null else str(cone_material.albedo_color.a))
	var vision_length := float(npc.get_state().get("vision_length", 0.0))
	_check("锥体一直画到遮挡距离",
		cone != null and absf(cone.scale.x - vision_length) < 0.05,
		"" if cone == null else "cone=%.2f vision=%.2f" % [cone.scale.x, vision_length])
	_check("NPC 初始在停顿", String(npc.state) == "pause", str(npc.state))

	# 4) NPC 有起步加速和走路起伏。
	npc.receive_signal(npc.global_position + Vector3(0, 0, -3.0), 0.0)
	npc.tick(0.1, [])
	var moving_speed := float(npc.get_state()["moving_speed"])
	_check("NPC 起步不是瞬时满速", moving_speed > 0.05 and moving_speed < npc.speed * 0.95,
		"speed=%.3f" % moving_speed)
	var visual := npc.find_child("Visual", true, false) as Node3D
	_check("NPC 走路有身体起伏", visual != null and absf(visual.position.y) > 0.002,
		"" if visual == null else "y=%.4f" % visual.position.y)

	# 5) 墙/家具能挡住视线：单独放一个 NPC + 一道墙。
	var isolated = load(NPC_SCRIPT).new()
	root.add_child(isolated)
	isolated.configure("npc_test", "reckless", Vector3.ZERO, [Vector3.ZERO])
	var wall := StaticBody3D.new()
	wall.position = Vector3(0, 1.0, -1.5)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(3.0, 3.0, 0.2)
	shape.shape = box
	wall.add_child(shape)
	root.add_child(wall)
	await physics_frame
	_check("真实线索在射线检测里可见", _clue_visible(demo))
	_check("墙后目标不可见", not isolated.sees_point(Vector3(0, 1.0, -3.0)),
		str(isolated.get_state()))
	_check("墙前目标仍可见", isolated.sees_point(Vector3(0, 1.0, -1.0)),
		str(isolated.get_state()))
	isolated.tick(0.1, [])
	_check("圆锥被墙截断", float(isolated.get_state()["vision_length"]) <= 1.6,
		str(isolated.get_state()))

	# 6) 视锥视觉参数和状态快照可读。
	var state: Dictionary = isolated.get_state()
	_check("状态含视锥参数", float(state.get("vision_range", 0.0)) > 0.0
		and float(state.get("vision_half_angle", 0.0)) > 0.0, str(state))
	_check("状态含扫视角度", state.has("look_yaw") and state.has("look_pitch"), str(state))

	demo.free()
	isolated.free()
	wall.free()
	_report()


func _clue_visible(demo) -> bool:
	var clue := demo.find_child("Clue_clue_a", true, false) as Node3D
	if clue == null or demo.npcs.is_empty():
		return false
	var npc = demo.npcs[0]
	npc.global_position = clue.position + Vector3(0, 0, 1.8)
	npc.look_at(Vector3(clue.position.x, 0, clue.position.z), Vector3.UP)
	return bool(npc.sees_point(clue.position))


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
	if _failures.is_empty() and _checks != EXPECTED_CHECKS:
		_failures.append("断言数守卫：期望 %d，实际 %d" % [EXPECTED_CHECKS, _checks])
	print("----")
	if _failures.is_empty():
		print("ROOM_NPC_BEHAVIOR_TEST_PASS (%d checks)" % _checks)
		quit(0)
	else:
		printerr("ROOM_NPC_BEHAVIOR_TEST_FAIL (%d/%d failed)" % [_failures.size(), _checks])
		for failure in _failures:
			printerr("  - ", failure)
		quit(1)
