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
	_check("场景有 3D 滚动屏 SubViewport", demo.scroll_viewport != null)
	_check("3D 滚动屏有屏幕 UI", demo.scroll_ui != null)
	_check("墙上监控屏有 3D 网格", demo.monitor_mesh != null)
	var loader = load(AVATAR_LOADER)
	_check("模型文件缺失时 avatar loader 安全返回 null",
		loader.load_avatar("res://external-assets/generated/missing.glb") == null)
	if FileAccess.file_exists(LUMINE_GLB):
		_check("玩家成功挂上 Lumine avatar", demo.player.has_avatar())
	if FileAccess.file_exists(SOYO_GLB):
		_check("莽撞 NPC 成功挂上 Soyo avatar", demo.npcs[0].has_avatar())
	if FileAccess.file_exists("res://external-assets/generated/fontaine.glb"):
		_check("谨慎 NPC 成功挂上枫丹 avatar", demo.npcs[1].has_avatar())

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
	demo.tick(999.0)
	_check("停留超时后机位烧毁", demo.camera_session.is_burned("C1"))
	_check("烧毁后拒绝再进入", not demo.select_feed("C1"))

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
