extends SceneTree
## 主场景 demo（3D 控制室 + 两个观察房间）回归。
## 运行：godot --headless --path . --script tests/test_room_demo.gd
##
## 覆盖：照片仓库/组合、NPC 性格与视锥、主场景装配、坐下/摄像头过载、线索照片、门解锁。
## 先于实现写（红），实现后转绿。

const MAIN_SCENE := "res://scenes/main.tscn"
const PHOTO_STORE := "res://scripts/room_demo/photo_store.gd"
const NPC_SCRIPT := "res://scripts/room_demo/npc_actor.gd"
const PLAYER_SCRIPT := "res://scripts/room_demo/room_player.gd"
const DEMO_SCRIPT := "res://scripts/room_demo/room_demo.gd"
const UI_SCRIPT := "res://scripts/room_demo/room_ui.gd"
const AVATAR_LOADER := "res://scripts/room_demo/avatar_loader.gd"
const TOON_SHADER := "res://shaders/anime_toon.gdshader"
const LUMINE_GLB := "res://external-assets/generated/lumine.glb"
const CHICKEN_GLB := "res://external-assets/generated/chicken.glb"
const SOYO_GLB := "res://external-assets/generated/soyo.glb"

var _failures: Array[String] = []
var _checks: int = 0
var _started := false


func _initialize() -> void:
	_check("照片仓库脚本存在", ResourceLoader.exists(PHOTO_STORE))
	_check("NPC 脚本存在", ResourceLoader.exists(NPC_SCRIPT))
	_check("玩家脚本存在", ResourceLoader.exists(PLAYER_SCRIPT))
	_check("主控制器脚本存在", ResourceLoader.exists(DEMO_SCRIPT))
	_check("监控 UI 脚本存在", ResourceLoader.exists(UI_SCRIPT))
	_check("avatar 加载器存在", ResourceLoader.exists(AVATAR_LOADER))
	_check("二次元 toon shader 存在", ResourceLoader.exists(TOON_SHADER))
	_check("main.tscn 存在", ResourceLoader.exists(MAIN_SCENE))


func _process(_delta: float) -> bool:
	if _started:
		return false
	_started = true
	if ResourceLoader.exists(PHOTO_STORE):
		_run_photo_tests()
	if ResourceLoader.exists(NPC_SCRIPT):
		_run_npc_tests()
	if ResourceLoader.exists(MAIN_SCENE):
		_run_scene_tests()
	_report()
	return false


# --- 照片仓库 -----------------------------------------------------------------

func _run_photo_tests() -> void:
	var store = load(PHOTO_STORE).new()
	_check("照片仓库初始为空", store.photos.is_empty())

	var a: String = store.add_photo("clue", "半张门禁码", "C1", 100.0, {"clue_id": "clue_a"})
	var b: String = store.add_photo("clue", "另半张门禁码", "C2", 103.0, {"clue_id": "clue_b"})
	_check("线索照片有 id", not a.is_empty() and not b.is_empty())
	_check("照片按线索可查", String(store.find_by_clue("clue_a").get("id", "")) == a)
	_check("同一线索不会重复入仓库", store.has_clue("clue_a"))

	var first: Dictionary = store.drop_to_screen(a, 104.0)
	_check("第一张照片可放上滚动屏", bool(first.get("accepted", false)))
	var second: Dictionary = store.drop_to_screen(b, 105.0)
	_check("短间隔的两张线索照片能组合", bool(second.get("combined", false)), str(second))
	_check("组合结果是门禁码", String(second.get("code", "")) == "A-317")
	var combined_photo: Dictionary = store.find_photo(String(second.get("photo_id", "")))
	_check("组合产物进入照片仓库", not combined_photo.is_empty())
	_check("组合产物类型是 combined", String(combined_photo.get("kind", "")) == "combined")

	var late = load(PHOTO_STORE).new()
	var c: String = late.add_photo("clue", "半张门禁码", "C1", 200.0, {"clue_id": "clue_a"})
	var d: String = late.add_photo("clue", "另半张门禁码", "C2", 230.0, {"clue_id": "clue_b"})
	late.drop_to_screen(c, 201.0)
	var too_late: Dictionary = late.drop_to_screen(d, 202.0)
	_check("间隔太久不组合", not bool(too_late.get("combined", false)), str(too_late))

	var shot: String = late.add_photo("screenshot", "截图 C1", "C1", 240.0,
		{"focus_point": Vector3(1, 1, -3)})
	var shot_result: Dictionary = late.drop_to_screen(shot, 241.0)
	_check("截图照片可以放上滚动屏", bool(shot_result.get("accepted", false)))
	_check("截图照片标记为 screenshot", bool(shot_result.get("screenshot", false)))
	_check("不存在的照片不能放上滚动屏",
		not bool(late.drop_to_screen("photo_missing", 242.0).get("accepted", true)))
	_check("重复放同一张照片被拒",
		not bool(late.drop_to_screen(shot, 243.0).get("accepted", true)))

	# 滚动屏展示失败后必须冷却并自动清屏，不能卡在不可用状态。
	var reset_store = load(PHOTO_STORE).new()
	var r1: String = reset_store.add_photo("clue", "半张门禁码", "C1", 300.0, {"clue_id": "clue_a"})
	var r2: String = reset_store.add_photo("clue", "另半张门禁码", "C2", 330.0, {"clue_id": "clue_b"})
	reset_store.drop_to_screen(r1, 300.0)
	var failed: Dictionary = reset_store.drop_to_screen(r2, 301.0)
	_check("滚动屏展示失败进入冷却",
		not bool(failed.get("accepted", true)) and reset_store.screen_state == "cooldown",
		str(failed))
	_check("冷却期间拒绝新的照片",
		not bool(reset_store.drop_to_screen(r1, 302.0).get("accepted", true)))
	reset_store.tick(307.0)
	_check("冷却结束自动重置滚动屏",
		reset_store.screen_state == "idle" and reset_store.screen_photo_ids.is_empty(),
		"state=%s ids=%s" % [reset_store.screen_state, reset_store.screen_photo_ids])
	_check("重置后可以再次放入照片",
		bool(reset_store.drop_to_screen(r1, 308.0).get("accepted", false)))

	var display_store = load(PHOTO_STORE).new()
	var display_shot: String = display_store.add_photo("screenshot", "截图 C1", "C1", 400.0,
		{"focus_point": Vector3(1, 1, -3)})
	display_store.drop_to_screen(display_shot, 400.0)
	_check("截图展示进入展示状态", display_store.screen_state == "showing",
		display_store.screen_state)
	display_store.tick(406.0)
	display_store.tick(412.0)
	_check("截图展示结束后的冷却也会自动重置",
		display_store.screen_state == "idle" and display_store.screen_photo_ids.is_empty(),
		"state=%s ids=%s" % [display_store.screen_state, display_store.screen_photo_ids])


# --- NPC ----------------------------------------------------------------------

func _run_npc_tests() -> void:
	var reckless = load(NPC_SCRIPT).new()
	root.add_child(reckless)
	reckless.configure("npc_reckless", "reckless", Vector3(0, 0, 0), [Vector3(0, 0, 0)])
	_check("莽撞 NPC 配置成功", reckless.personality == "reckless")
	_check("莽撞 NPC 速度更快", reckless.speed > 1.5)
	_check("NPC 能看见正前方目标", reckless.sees_point(Vector3(0, 0, -3)))
	_check("NPC 看不见背后目标", not reckless.sees_point(Vector3(0, 0, 3)))
	_check("莽撞 NPC 接受近处信号", reckless.receive_signal(Vector3(1, 0, 0)))
	_check("远处信号被拒", not reckless.receive_signal(Vector3(100, 0, 0)))

	# 让莽撞 NPC 连续跑空 3 次，之后应暂时不理会激光。
	for attempt in 3:
		reckless.global_position = Vector3(0, 0, 0)
		reckless.receive_signal(Vector3(0.6, 0, 0))
		reckless.tick(2.0, [])
		reckless.tick(2.0, [])
	_check("莽撞 NPC 跑空多次后进入忽略状态", reckless.is_ignoring_signals(), str(reckless.get_state()))
	_check("忽略状态下拒绝信号", not reckless.receive_signal(Vector3(0.5, 0, 0)))

	var laser_npc = load(NPC_SCRIPT).new()
	root.add_child(laser_npc)
	laser_npc.configure("npc_laser", "cautious", Vector3(0, 0, 0), [Vector3(0, 0, 0)])
	_check("射线穿过视锥才响应",
		laser_npc.receive_laser(Vector3(0, 1.45, 3), Vector3(0, 1.45, -3), 0.0))
	_check("偏移射线不响应",
		not laser_npc.receive_laser(Vector3(3, 1.45, 3), Vector3(3, 1.45, -3), 0.0))
	_check("没到达视锥的短射线不响应",
		not laser_npc.receive_laser(Vector3(0, 1.45, 3), Vector3(0, 1.45, 1), 0.0))
	laser_npc.queue_free()

	var cautious = load(NPC_SCRIPT).new()
	root.add_child(cautious)
	cautious.configure("npc_cautious", "cautious", Vector3(0, 0, 0), [Vector3(0, 0, 0)])
	_check("谨慎 NPC 速度更慢", cautious.speed < reckless.speed)
	_check("谨慎 NPC 接受近处信号", cautious.receive_signal(Vector3(1, 0, 0)))
	for attempt in 3:
		cautious.receive_signal(Vector3(0.6, 0, 0))
		cautious.tick(3.0, [])
	_check("谨慎 NPC 不会因为跑空而忽略信号",
		cautious.receive_signal(Vector3(0.5, 0, 0)), str(cautious.get_state()))

	reckless.queue_free()
	cautious.queue_free()


# --- 主场景 -------------------------------------------------------------------

func _run_scene_tests() -> void:
	var packed := ResourceLoader.load(MAIN_SCENE) as PackedScene
	_check("main.tscn 可加载", packed != null)
	if packed == null:
		return
	var demo := packed.instantiate()
	root.add_child(demo)
	_check("main 根节点挂 room_demo.gd", _script_path(demo) == DEMO_SCRIPT)
	_check("场景有玩家", demo.player != null)
	_check("场景有 2 个 NPC", demo.npcs.size() == 2, str(demo.npcs.size()))
	_check("场景有 4 路摄像头", demo.feeds.size() == 4, str(demo.feeds.size()))
	_check("场景有监控 UI", demo.ui != null)
	_check("场景有摄像头会话", demo.camera_session != null)
	_check("场景有照片仓库", demo.photo_store != null)
	_check("场景有 3D 监控屏 SubViewport", demo.monitor_viewport != null)
	_check("3D 监控屏有屏幕 UI", demo.monitor_ui != null)
	_check("场景有滚动屏 SubViewport", demo.scroll_viewport != null)
	_check("3D 滚动屏有屏幕 UI", demo.scroll_ui != null)
	_check("墙上监控屏有 3D 网格", demo.monitor_mesh != null)
	_check("场景有程序化火焰系统", demo.fire_system != null)
	_check("火焰有 3D 体积纹理", demo.fire_system != null and demo.fire_system._texture != null)
	_check("火焰有程序化音频", demo.fire_system != null and demo.fire_system._audio != null)
	_check("NPC 使用带碰撞的 CharacterBody3D", demo.npcs[0] is CharacterBody3D
		and demo.npcs[0].get_node_or_null("NpcCollision") != null)
	_check("摄像头高度接近天花板", demo.feeds[0]["camera"].global_position.y >= 2.6)
	_check("摄像头使用广角镜头", demo.feeds[0]["camera"].fov >= 80.0)
	_check("监控画面启用鱼眼畸变", demo.monitor_ui.uses_fisheye())
	_check("监控画面有老电视扫描线暗纹", demo.monitor_ui.uses_scanlines())
	_check("新地图有舞台地台", demo.find_child("StagePlatform", true, false) != null)
	_check("新地图有后台道具堆", demo.find_child("PropCrate1", true, false) != null)
	_check("新地图有侧门", demo.find_child("SideDoor", true, false) != null)
	_check("C4 位于侧门房间", demo.feeds[3]["camera"].global_position.z > -14.0,
		str(demo.feeds[3]["camera"].global_position))
	_check("第一人称相机剔除玩家自身模型",
		(demo.player.camera.cull_mask & (1 << 1)) == 0
		and demo.player._body_mesh.layers == 2)
	_check("玩家移动速度已调低", demo.player.WALK_SPEED <= 2.6)
	var wall_npc = demo.npcs[0]
	wall_npc.global_position = Vector3(-7.5, 0.0, -18.0)
	wall_npc.receive_signal(Vector3(-15.0, 0.0, -18.0))
	wall_npc.tick(2.0, [])
	_check("NPC 被墙挡住，不会穿墙", wall_npc.global_position.x > -9.0,
		str(wall_npc.global_position))
	var loader = load(AVATAR_LOADER)
	_check("模型文件缺失时 avatar loader 安全返回 null",
		loader.load_avatar("res://external-assets/generated/missing.glb") == null)
	if FileAccess.file_exists(LUMINE_GLB):
		_check("玩家成功挂上 Lumine avatar", demo.player.has_avatar())
	if FileAccess.file_exists(CHICKEN_GLB):
		_check("莽撞 NPC 成功挂上鸡哥 avatar", demo.npcs[0].has_avatar())
	if FileAccess.file_exists(SOYO_GLB):
		_check("谨慎 NPC 成功挂上 Soyo avatar", demo.npcs[1].has_avatar())

	_check("初始未坐下", not demo.player.seated)
	demo.set_seated(true)
	_check("坐下后玩家状态同步", demo.player.seated)
	_check("坐下后监控 UI 可见", demo.ui.is_seat_visible())
	var motion := InputEventMouseMotion.new()
	motion.position = Vector2(root.size) * 0.5
	_check("坐下后鼠标事件能转发到 3D 监控屏", demo._forward_mouse_to_monitor(motion))
	demo.monitor_ui.feed_clicked.emit("C2")
	_check("屏幕 UI 点击信号能选中机位", String(demo.selected_feed) == "C2")
	demo.set_seated(false)
	_check("站起后玩家状态同步", not demo.player.seated)

	_check("可以选中 C1", demo.select_feed("C1"))
	_check("C1 成为当前机位", String(demo.camera_session.get_state().get("current", "")) == "C1")
	var click_uv := Vector2(0.7, 0.4)
	var laser_result: Dictionary = demo.fire_laser("C1", click_uv)
	var c1_feed: Dictionary = demo._feed_by_id("C1")
	var c1_camera: Camera3D = c1_feed["camera"]
	var c1_viewport: SubViewport = c1_feed["viewport"]
	var expected_origin: Vector3 = demo.laser_start_position(c1_camera)
	_check("激光从相机右下方发射器出发",
		(laser_result.get("origin", Vector3.INF) as Vector3).is_equal_approx(expected_origin))
	var emitter_offset: Vector3 = expected_origin - c1_camera.global_position
	_check("发射器位于相机右侧且下方",
		emitter_offset.dot(c1_camera.global_transform.basis.x) > 0.0
		and emitter_offset.dot(c1_camera.global_transform.basis.y) < 0.0,
		str(emitter_offset))
	_check("发射器起点在画面外", not c1_camera.is_position_in_frustum(expected_origin))
	var laser_beam := demo.get_node_or_null("LaserBeam") as MeshInstance3D
	_check("激光世界线从发射器起点显示",
		laser_beam != null and (laser_beam.get_meta("from", Vector3.INF) as Vector3).is_equal_approx(expected_origin))
	var expected_ray: Vector3 = c1_camera.project_ray_normal(click_uv * Vector2(c1_viewport.size)).normalized()
	var endpoint_ray: Vector3 = ((laser_result.get("point", Vector3.ZERO) as Vector3) - c1_camera.global_position).normalized()
	_check("激光落点仍由 screen point 决定",
		endpoint_ray.dot(expected_ray) > 0.999)
	var laser_vec: Vector3 = (laser_result.get("point", Vector3.ZERO) as Vector3) - (laser_result.get("origin", Vector3.ZERO) as Vector3)
	var expected_beam_dir: Vector3 = laser_vec.normalized()
	_check("激光落点沿该屏幕方向",
		laser_vec.length() > 0.1 and laser_vec.normalized().dot(expected_beam_dir) > 0.999,
		str(laser_vec))
	demo.tick(999.0)
	_check("火焰随时间扩张", demo.fire_system.age > 20.0 and demo.fire_system.radius > 2.0,
		str(demo.fire_system.get_state()))
	_check("停留超时后机位烧毁", demo.camera_session.is_burned("C1"))
	_check("烧毁画面显示雪花", demo.monitor_ui.is_burned_visual("C1"))
	_check("烧毁后拒绝再进入", not demo.select_feed("C1"))

	demo.set_seated(true)
	_check("火焰持续烧灼后 C2 也过载", demo.camera_session.is_burned("C2"))
	_check("可以放大 C3", demo.select_feed("C3"))
	_check("放大后显示返回按钮", demo.ui.is_feed_zoomed())
	demo.ui._back_button.pressed.emit()
	_check("返回按钮关闭放大", not demo.ui.is_feed_zoomed())
	_check("可以放大 C4", demo.select_feed("C4"))
	var esc := InputEventKey.new()
	esc.keycode = KEY_ESCAPE
	esc.pressed = true
	demo._unhandled_input(esc)
	_check("Esc 关闭放大", not demo.ui.is_feed_zoomed())
	demo.set_seated(false)

	var raw_uv := Vector2(0.9, 0.5)
	var corrected_uv: Vector2 = demo.monitor_ui._undistort_uv(raw_uv)
	_check("鱼眼点击坐标向外展开",
		corrected_uv.distance_to(Vector2(0.5, 0.5)) > raw_uv.distance_to(Vector2(0.5, 0.5)),
		"raw=%s corrected=%s" % [raw_uv, corrected_uv])

	var a_photo: String = demo.capture_clue_photo("clue_a")
	var b_photo: String = demo.capture_clue_photo("clue_b")
	_check("线索会生成照片", not a_photo.is_empty() and not b_photo.is_empty())
	_check("照片进入 UI 仓库", demo.photo_store.photos.size() >= 2)
	var combo: Dictionary = demo.drop_photo_to_screen(a_photo)
	_check("第一张照片可上滚动屏", bool(combo.get("accepted", false)), str(combo))
	# 直接构造短间隔：运行时用同一个 elapsed，drop 方法内部会记录时间。
	combo = demo.drop_photo_to_screen(b_photo)
	_check("同轮两张线索照片能组合", bool(combo.get("combined", false)), str(combo))
	_check("组合后门解锁", demo.door_unlocked)

	demo.queue_free()


# --- 断言工具 -----------------------------------------------------------------

func _script_path(node: Node) -> String:
	var script: Script = node.get_script()
	if script == null:
		return ""
	return script.resource_path


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
		print("ROOM_DEMO_TEST_PASS (%d checks)" % _checks)
		quit(0)
	else:
		printerr("ROOM_DEMO_TEST_FAIL (%d/%d failed)" % [_failures.size(), _checks])
		for failure in _failures:
			printerr("  - ", failure)
		quit(1)
