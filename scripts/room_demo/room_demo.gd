extends Node3D
## 主 demo：第一人称控制室 + 两个小观察房间 + 4 路监控。
##
## 时间紧的 Scope 缩小版：
## - 控制室只做一间，椅子/监控台/滚动屏/锁门是占位 primitive；
## - 两个观察房间各 2 个摄像头（面对面），NPC 用 primitive + 视锥；
## - 摄像头停留 18s 过载、7s 冷却（把“几分钟”缩成 demo 可玩的秒数）；
## - 线索照片组合后给出固定门禁码 A-317，回到门口按 E 离开即 demo 完成。
##
## 纯逻辑（照片组合）在 photo_store.gd，NPC 行为在 npc_actor.gd，UI 在 room_ui.gd；
## 本脚本只负责装配 3D 场景、输入接线和 demo 流程。

const PHOTO_STORE_SCRIPT := preload("res://scripts/room_demo/photo_store.gd")
const NPC_SCRIPT := preload("res://scripts/room_demo/npc_actor.gd")
const PLAYER_SCRIPT := preload("res://scripts/room_demo/room_player.gd")
const UI_SCRIPT := preload("res://scripts/room_demo/room_ui.gd")
const MONITOR_UI_SCRIPT := preload("res://scripts/room_demo/monitor_ui.gd")
const SCROLL_UI_SCRIPT := preload("res://scripts/room_demo/scroll_screen_ui.gd")
const AVATAR_LOADER := preload("res://scripts/room_demo/avatar_loader.gd")
const CAMERA_SESSION_SCRIPT := preload("res://scripts/camera/camera_session.gd")

const SOYO_GLB := "res://external-assets/generated/soyo.glb"
const LUMINE_GLB := "res://external-assets/generated/lumine.glb"
const FONTAINE_GLB := "res://external-assets/generated/fontaine.glb"

const CHAIR_POS := Vector3(0, 0, 1.5)
const STAND_POS := Vector3(0, 0, 2.6)
const SCREEN_POS := Vector3(0, 1.5, -3.8)
const DOOR_POS := Vector3(0, 0, 4.0)
const DOOR_CODE := "A-317"
const CAMERA_DWELL := 45.0
const CAMERA_COOLDOWN := 8.0
const SIGNAL_RANGE := 22.0

## 墙上的物理屏幕（内容来自 SubViewport，不是 2D 覆盖层）。
const MONITOR_CENTER := Vector3(0, 1.7, -3.84)
const MONITOR_SIZE := Vector2(3.6, 2.25)
const SCROLL_CENTER := Vector3(3.2, 1.7, -3.84)
const SCROLL_SIZE := Vector2(1.6, 1.0)

const CAMERA_DEFS: Array[Dictionary] = [
	{"id": "C1", "pos": Vector3(-8.4, 2.55, -21.2), "look": Vector3(-1.2, 1.2, -14.8), "room": "A"},
	{"id": "C2", "pos": Vector3(-1.2, 2.55, -14.8), "look": Vector3(-8.4, 1.2, -21.2), "room": "A"},
	{"id": "C3", "pos": Vector3(8.4, 2.55, -21.2), "look": Vector3(1.2, 1.2, -14.8), "room": "B"},
	{"id": "C4", "pos": Vector3(1.2, 2.55, -14.8), "look": Vector3(8.4, 1.2, -21.2), "room": "B"},
]

const CLUE_DEFS: Array[Dictionary] = [
	{"id": "clue_a", "label": "半张门禁码", "position": Vector3(-8.2, 0.38, -21.2)},
	{"id": "clue_b", "label": "另半张门禁码", "position": Vector3(8.2, 0.38, -21.2)},
]

var player: CharacterBody3D = null
var npcs: Array[Node] = []
var feeds: Array[Dictionary] = []
var ui: CanvasLayer = null
var camera_session: Node = null
var photo_store = null
var monitor_viewport: SubViewport = null
var monitor_ui: Control = null
var scroll_viewport: SubViewport = null
var scroll_ui: Control = null
var monitor_mesh: MeshInstance3D = null
var scroll_mesh: MeshInstance3D = null

var selected_feed := ""
var door_unlocked := false
var demo_complete := false
var elapsed := 0.0
var last_laser: Dictionary = {}

var _world: Node3D = null
var _clues: Array[Dictionary] = []
var _clue_by_id: Dictionary = {}
var _door: Node3D = null
var _door_body: StaticBody3D = null
var _door_material: StandardMaterial3D = null


func _ready() -> void:
	_build_environment()
	_world = Node3D.new()
	_world.name = "World"
	add_child(_world)
	_build_control_room()
	_build_observation_rooms()
	_build_clues()
	_build_camera_models()
	_build_player()
	_build_npcs()
	_build_feed_viewports()
	_build_screens()
	_build_camera_session()
	_build_photo_store()
	_build_ui()
	_refresh_all_ui()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	ui.set_objective("坐上监控椅（F），用 4 路摄像头引导两个 NPC 找到线索")
	ui.set_prompt("WASD 走动 · 鼠标看 · 走到椅子旁按 F 坐下")


func _process(delta: float) -> void:
	tick(delta)


func tick(delta: float) -> void:
	if delta <= 0.0:
		return
	elapsed += delta
	if camera_session != null:
		camera_session.tick(delta)
	var npc_delta := minf(delta, 0.2)
	for npc in npcs:
		if is_instance_valid(npc):
			npc.tick(npc_delta, _clues)
	if monitor_ui != null and camera_session != null:
		monitor_ui.refresh_feed_states(camera_session)
		_update_dwell_ui()
	_update_scroll_drop_overlay()
	if not demo_complete and door_unlocked and player != null and player.global_position.z > DOOR_POS.z + 0.8:
		_complete()
	if player != null and not player.seated:
		ui.set_prompt("靠近椅子按 F 坐下" if player.can_sit() else "")


# --- 玩家 / 坐下 ---------------------------------------------------------------

func set_seated(value: bool) -> bool:
	if player == null:
		return false
	if value:
		if not player.try_sit():
			return false
		ui.set_prompt("")
		return true
	player.stand()
	return true


func _on_seat_changed(seated: bool) -> void:
	if seated:
		ui.show_seat()
		ui.set_objective("监控两个 NPC：右键激光 / S 截图 / 拖照片到滚动屏")
		ui.set_prompt("")
		if monitor_ui != null:
			monitor_ui.set_notice("已坐下：点画面放大 / 右键发激光")
	else:
		ui.hide_seat()
		close_feed()
		ui.set_objective("回到门口按 E 离开（需要先组合出门禁码）")
		ui.set_prompt("")
		if monitor_ui != null:
			monitor_ui.refresh_feed_states(camera_session)


func _on_interaction(action: String) -> void:
	if action != "door":
		return
	if door_unlocked:
		_complete()
	else:
		ui.set_notification("门锁着：把两张门禁码照片拖到滚动屏组合")


# --- 摄像头 -------------------------------------------------------------------

func select_feed(feed_id: String) -> bool:
	if camera_session == null:
		return false
	if not camera_session.enter(feed_id):
		ui.set_notification("%s 不可用（冷却 / 烧毁 / 未知机位）" % feed_id)
		return false
	selected_feed = feed_id
	monitor_ui.set_selected(feed_id)
	monitor_ui.refresh_feed_states(camera_session)
	monitor_ui.set_notice("正在看 %s" % feed_id)
	ui.set_notification("正在看 %s" % feed_id)
	return true


func close_feed() -> void:
	if selected_feed.is_empty():
		return
	camera_session.leave(selected_feed)
	selected_feed = ""
	if monitor_ui != null:
		monitor_ui.set_selected("")
		monitor_ui.refresh_feed_states(camera_session)
		monitor_ui.set_notice("已退出放大画面")


func _build_camera_session() -> void:
	camera_session = CAMERA_SESSION_SCRIPT.new()
	camera_session.name = "CameraSession"
	add_child(camera_session)
	var cameras := {}
	for def in CAMERA_DEFS:
		cameras[String(def["id"])] = {"dwell": CAMERA_DWELL, "cooldown": CAMERA_COOLDOWN}
	camera_session.configure({"cameras": cameras})
	camera_session.overload_started.connect(_on_camera_overloaded)


func _on_camera_overloaded(camera_id: String) -> void:
	if selected_feed == camera_id:
		selected_feed = ""
		monitor_ui.set_selected("")
	monitor_ui.set_notice("%s 停留过久，过载烧毁" % camera_id)
	ui.set_notification("%s 停留过久，过载烧毁" % camera_id)
	var feed := _feed_by_id(camera_id)
	if not feed.is_empty():
		_spawn_explosion(feed.get("camera").global_position)
	monitor_ui.refresh_feed_states(camera_session)


func _update_dwell_ui() -> void:
	if selected_feed.is_empty() or camera_session == null:
		return
	var state: Dictionary = camera_session.get_state()
	if String(state.get("current", "")) == selected_feed:
		monitor_ui.update_dwell(float(state.get("remain", 0.0)), CAMERA_DWELL)


# --- 激光 ---------------------------------------------------------------------

func fire_laser(feed_id: String, normalized: Vector2) -> Dictionary:
	last_laser = {}
	var feed := _feed_by_id(feed_id)
	if feed.is_empty():
		ui.set_notification("没有这个机位")
		return {}
	if camera_session == null or String(camera_session.get_state().get("current", "")) != feed_id:
		ui.set_notification("先放大 %s 才能发激光" % feed_id)
		return {}
	var camera: Camera3D = feed["camera"]
	var viewport: SubViewport = feed["viewport"]
	var screen_point := normalized * Vector2(viewport.size)
	var origin := camera.project_ray_origin(screen_point)
	var direction := camera.project_ray_normal(screen_point)
	var point := origin + direction * 14.0
	var query := PhysicsRayQueryParameters3D.create(origin, origin + direction * 40.0)
	query.collision_mask = 0xFFFFFFFF
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if not hit.is_empty():
		point = hit.position
	_spawn_beam(origin, point)
	var accepted: Array[String] = []
	for npc in npcs:
		if is_instance_valid(npc) and npc.receive_signal(point):
			accepted.append(npc.npc_id)
	last_laser = {"point": point, "accepted": accepted, "feed": feed_id}
	var message := "激光没有引起注意（超出范围或莽撞 NPC 暂时不信了）"
	if not accepted.is_empty():
		message = "激光信号：%s 响应" % "、".join(accepted)
	monitor_ui.set_notice(message)
	ui.set_notification(message)
	return last_laser


func _spawn_beam(from: Vector3, to: Vector3) -> void:
	var length := from.distance_to(to)
	if length <= 0.05:
		return
	var beam := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.035, 0.035, length)
	beam.mesh = box
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(1.0, 0.25, 0.2)
	material.emission_enabled = true
	material.emission = Color(1.0, 0.15, 0.1)
	material.emission_energy_multiplier = 4.0
	beam.material_override = material
	beam.position = (from + to) * 0.5
	beam.look_at(to, Vector3.UP)
	add_child(beam)
	get_tree().create_timer(1.6).timeout.connect(beam.queue_free)


func _spawn_explosion(position: Vector3) -> void:
	var light := OmniLight3D.new()
	light.light_color = Color(1.0, 0.45, 0.15)
	light.light_energy = 8.0
	light.omni_range = 7.0
	light.position = position
	add_child(light)
	var flash := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.6
	sphere.height = 1.2
	flash.mesh = sphere
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(1.0, 0.4, 0.1, 0.7)
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.emission_enabled = true
	material.emission = Color(1.0, 0.3, 0.05)
	flash.material_override = material
	flash.position = position
	add_child(flash)
	var tween := create_tween().set_parallel(true)
	tween.tween_property(flash, "scale", Vector3(3.5, 3.5, 3.5), 0.5)
	tween.tween_property(light, "light_energy", 0.0, 0.6)
	tween.finished.connect(func():
		flash.queue_free()
		light.queue_free()
	)


# --- 照片 / 滚动屏 -------------------------------------------------------------

func _build_photo_store() -> void:
	photo_store = PHOTO_STORE_SCRIPT.new()
	photo_store.photos_changed.connect(_refresh_photos)


func _on_clue_collected(clue_id: String, clue_position: Vector3) -> void:
	if photo_store == null or photo_store.has_clue(clue_id):
		return
	var def: Dictionary = _clue_by_id.get(clue_id, {})
	var label := String(def.get("label", clue_id))
	var feed := _camera_that_sees(clue_position)
	var camera_id := String(feed.get("id", "C1"))
	var texture := _capture_feed_texture(feed)
	var photo_id: String = photo_store.add_photo("clue", label, camera_id, elapsed, {
		"clue_id": clue_id,
		"position": clue_position,
		"texture": texture,
	})
	_notify("NPC 拍到照片：%s" % label)
	_refresh_photos()
	_refresh_scroll_screen("照片已放入底部仓库，可拖到滚动屏。")
	if photo_id.is_empty():
		push_warning("线索照片创建失败: %s" % clue_id)


func capture_clue_photo(clue_id: String) -> String:
	var existing: Dictionary = photo_store.find_by_clue(clue_id)
	if not existing.is_empty():
		return String(existing["id"])
	var def: Dictionary = _clue_by_id.get(clue_id, {})
	if def.is_empty():
		return ""
	var clue_position: Vector3 = def.get("position", Vector3.ZERO)
	_on_clue_collected(clue_id, clue_position)
	return String(photo_store.find_by_clue(clue_id).get("id", ""))


func take_screenshot() -> String:
	if selected_feed.is_empty() or camera_session == null:
		_notify("先放大一路画面再按 S")
		return ""
	if String(camera_session.get_state().get("current", "")) != selected_feed:
		_notify("当前机位不在监控中")
		return ""
	var feed := _feed_by_id(selected_feed)
	if feed.is_empty():
		return ""
	var point := _raycast_feed_center(feed)
	var texture := _capture_feed_texture(feed)
	var photo_id: String = photo_store.add_photo("screenshot", "截图 %s" % selected_feed,
		selected_feed, elapsed, {
			"focus_point": point,
			"texture": texture,
		})
	_notify("已截图 %s，拖到滚动屏可让 NPC 去查看" % selected_feed)
	_refresh_scroll_screen("截图已放入底部仓库。")
	return photo_id


func drop_photo_to_screen(photo_id: String) -> Dictionary:
	if photo_store == null:
		return {}
	var result: Dictionary = photo_store.drop_to_screen(photo_id, elapsed)
	if not bool(result.get("accepted", false)):
		_notify(String(result.get("reason", "照片无法使用")))
		return result
	if bool(result.get("combined", false)):
		_refresh_scroll_screen("组合成功：门禁码 %s" % String(result.get("code", "")))
		unlock_door()
	elif bool(result.get("screenshot", false)):
		var point: Vector3 = result.get("focus_point", Vector3.ZERO)
		var accepted: Array[String] = []
		for npc in npcs:
			if is_instance_valid(npc) and npc.receive_signal(point):
				accepted.append(npc.npc_id)
		_refresh_scroll_screen("截图已上屏：%s 前往查看" % ("、".join(accepted) if not accepted.is_empty() else "没人响应"))
	else:
		_refresh_scroll_screen(String(result.get("reason", "已放上滚动屏")))
	return result


func _refresh_scroll_screen(result_text: String = "") -> void:
	if scroll_ui == null or photo_store == null:
		return
	var text := result_text
	if text.is_empty() and not photo_store.last_result.is_empty():
		text = String(photo_store.last_result.get("reason", ""))
	scroll_ui.refresh(photo_store.photos, photo_store.screen_photo_ids, text)


func _notify(message: String) -> void:
	ui.set_notification(message)
	if monitor_ui != null:
		monitor_ui.set_notice(message)


func _refresh_photos() -> void:
	if ui != null and photo_store != null:
		ui.refresh_photos(photo_store.photos)


# --- 门 / 结束 ----------------------------------------------------------------

func unlock_door() -> void:
	if door_unlocked:
		return
	door_unlocked = true
	if _door_material != null:
		_door_material.albedo_color = Color(0.3, 0.9, 0.55)
		_door_material.emission_enabled = true
		_door_material.emission = Color(0.2, 0.9, 0.45)
	if _door_body != null:
		_door_body.collision_layer = 0
		_door_body.collision_mask = 0
	if _door != null:
		var tween := create_tween()
		tween.tween_property(_door, "position:x", _door.position.x + 1.8, 0.6)
	ui.set_objective("门已解锁：走回门口按 E 离开")
	ui.set_notification("门禁码正确，门开了")
	demo_complete = false


func _complete() -> void:
	if demo_complete:
		return
	demo_complete = true
	ui.show_complete("你逃出去了。")
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _unhandled_input(event: InputEvent) -> void:
	if player != null and player.seated and not demo_complete:
		if _forward_mouse_to_monitor(event):
			get_viewport().set_input_as_handled()
			return
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	if key.keycode == KEY_S and player != null and player.seated:
		take_screenshot()
		get_viewport().set_input_as_handled()
	elif key.keycode == KEY_R and demo_complete:
		get_tree().reload_current_scene()


## 把鼠标事件按 3D 大屏的命中点换算成 SubViewport 像素，转发给屏幕里的 UI。
func _forward_mouse_to_monitor(event: InputEvent) -> bool:
	if monitor_viewport == null or player == null or player.camera == null:
		return false
	var mouse_position := Vector2.ZERO
	var motion := event as InputEventMouseMotion
	var button := event as InputEventMouseButton
	if motion != null:
		mouse_position = motion.position
	elif button != null:
		mouse_position = button.position
	else:
		return false
	var camera: Camera3D = player.camera
	var from: Vector3 = camera.project_ray_origin(mouse_position)
	var direction: Vector3 = camera.project_ray_normal(mouse_position)
	var plane := Plane(Vector3(0, 0, 1), MONITOR_CENTER.z)
	var hit: Variant = plane.intersects_ray(from, direction)
	if not (hit is Vector3):
		return false
	var local: Vector3 = (hit as Vector3) - MONITOR_CENTER
	if absf(local.x) > MONITOR_SIZE.x * 0.5 or absf(local.y) > MONITOR_SIZE.y * 0.5:
		return false
	var uv := Vector2(local.x / MONITOR_SIZE.x + 0.5, 0.5 - local.y / MONITOR_SIZE.y)
	var pixel := Vector2(uv.x * float(monitor_viewport.size.x), uv.y * float(monitor_viewport.size.y))
	if motion != null:
		var forwarded := InputEventMouseMotion.new()
		forwarded.position = pixel
		forwarded.global_position = pixel
		forwarded.relative = motion.relative
		forwarded.button_mask = motion.button_mask
		monitor_viewport.push_input(forwarded, true)
	elif button != null:
		var forwarded := InputEventMouseButton.new()
		forwarded.position = pixel
		forwarded.global_position = pixel
		forwarded.button_index = button.button_index
		forwarded.pressed = button.pressed
		forwarded.double_click = button.double_click
		monitor_viewport.push_input(forwarded, true)
	return true


## 把 3D 滚动屏投影到屏幕坐标，给 HUD 上的透明拖放接收区对齐。
func _update_scroll_drop_overlay() -> void:
	if ui == null:
		return
	if player == null or not player.seated or player.camera == null or demo_complete:
		ui.set_scroll_drop_visible(false)
		return
	var camera: Camera3D = player.camera
	if camera.is_position_behind(SCROLL_CENTER):
		ui.set_scroll_drop_visible(false)
		return
	var half := SCROLL_SIZE * 0.5
	var corners := [
		SCROLL_CENTER + Vector3(-half.x, half.y, 0),
		SCROLL_CENTER + Vector3(half.x, half.y, 0),
		SCROLL_CENTER + Vector3(-half.x, -half.y, 0),
		SCROLL_CENTER + Vector3(half.x, -half.y, 0),
	]
	var min_point := Vector2(INF, INF)
	var max_point := Vector2(-INF, -INF)
	for corner in corners:
		var screen_point: Vector2 = camera.unproject_position(corner)
		min_point.x = minf(min_point.x, screen_point.x)
		min_point.y = minf(min_point.y, screen_point.y)
		max_point.x = maxf(max_point.x, screen_point.x)
		max_point.y = maxf(max_point.y, screen_point.y)
	var rect := Rect2(min_point, max_point - min_point)
	if rect.size.x < 10.0 or rect.size.y < 10.0:
		ui.set_scroll_drop_visible(false)
		return
	ui.set_scroll_drop_rect(rect)
	ui.set_scroll_drop_visible(true)


# --- 3D 装配 -----------------------------------------------------------------

func _build_environment() -> void:
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.035, 0.04, 0.055)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.32, 0.36, 0.46)
	environment.ambient_light_energy = 0.85
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var world_env := WorldEnvironment.new()
	world_env.environment = environment
	add_child(world_env)

	var key_light := DirectionalLight3D.new()
	key_light.rotation_degrees = Vector3(-55, -35, 0)
	key_light.light_energy = 1.1
	key_light.shadow_enabled = true
	add_child(key_light)

	_add_omni(Vector3(0, 2.6, 0), Color(0.75, 0.82, 1.0), 1.6, 9.0)
	_add_omni(Vector3(0, 2.3, 2.4), Color(0.8, 0.86, 1.0), 1.4, 8.0)
	_add_omni(Vector3(-5, 2.6, -18), Color(1.0, 0.82, 0.55), 1.4, 9.0)
	_add_omni(Vector3(5, 2.6, -18), Color(1.0, 0.82, 0.55), 1.4, 9.0)


func _add_omni(position: Vector3, color: Color, energy: float, range_m: float) -> void:
	var light := OmniLight3D.new()
	light.position = position
	light.light_color = color
	light.light_energy = energy
	light.omni_range = range_m
	add_child(light)


func _build_control_room() -> void:
	var wall := Color(0.3, 0.33, 0.4)
	var floor_color := Color(0.14, 0.16, 0.21)
	_add_box(_world, "ControlFloor", Vector3(10, 0.12, 8), Vector3(0, -0.06, 0), floor_color)
	_add_box(_world, "ControlCeiling", Vector3(10, 0.12, 8), Vector3(0, 3.06, 0), Color(0.16, 0.18, 0.23))
	_add_box(_world, "ControlWallL", Vector3(0.16, 3, 8), Vector3(-5, 1.5, 0), wall)
	_add_box(_world, "ControlWallR", Vector3(0.16, 3, 8), Vector3(5, 1.5, 0), wall)
	_add_box(_world, "ControlWallBack", Vector3(10, 3, 0.16), Vector3(0, 1.5, -4), wall)
	_add_box(_world, "ControlWallFrontL", Vector3(4.1, 3, 0.16), Vector3(-2.95, 1.5, 4), wall)
	_add_box(_world, "ControlWallFrontR", Vector3(4.1, 3, 0.16), Vector3(2.95, 1.5, 4), wall)
	_add_box(_world, "ControlDoorLintel", Vector3(1.8, 0.5, 0.16), Vector3(0, 2.75, 4), wall)

	_add_box(_world, "MonitorBacking", Vector3(3.8, 2.45, 0.08), Vector3(0, 1.7, -3.92),
		Color(0.03, 0.04, 0.06), false)
	_add_label3d(_world, "监控台", Vector3(0, 2.98, -3.82), 40, Color(0.45, 0.78, 1.0))
	_add_box(_world, "ScrollBacking", Vector3(1.8, 1.2, 0.08), Vector3(3.2, 1.7, -3.92),
		Color(0.03, 0.04, 0.06), false)
	_add_label3d(_world, "滚动屏", Vector3(3.2, 2.42, -3.82), 30, Color(0.4, 0.9, 0.85))

	# 椅子
	_add_box(_world, "ChairSeat", Vector3(0.8, 0.12, 0.8), Vector3(0, 0.55, CHAIR_POS.z), Color(0.18, 0.2, 0.26))
	_add_box(_world, "ChairBack", Vector3(0.8, 0.8, 0.12), Vector3(0, 0.95, CHAIR_POS.z - 0.34), Color(0.18, 0.2, 0.26))
	_add_box(_world, "ChairBase", Vector3(0.22, 0.55, 0.22), Vector3(0, 0.27, CHAIR_POS.z), Color(0.1, 0.11, 0.15))

	# 锁着的门
	_door = Node3D.new()
	_door.name = "Door"
	_door.position = DOOR_POS
	_world.add_child(_door)
	var door_mesh := _add_box(_door, "DoorMesh", Vector3(1.7, 2.4, 0.14), Vector3(0, 1.2, 0),
		Color(0.42, 0.22, 0.18), false)
	_door_material = door_mesh.material_override as StandardMaterial3D
	_door_body = StaticBody3D.new()
	var door_shape := CollisionShape3D.new()
	var door_box := BoxShape3D.new()
	door_box.size = Vector3(1.7, 2.4, 0.14)
	door_shape.shape = door_box
	door_shape.position = Vector3(0, 1.2, 0)
	_door_body.add_child(door_shape)
	_door.add_child(_door_body)
	_add_label3d(_world, "LOCKED", Vector3(0, 2.55, 3.9), 24, Color(0.95, 0.5, 0.4))


func _build_observation_rooms() -> void:
	var wall := Color(0.26, 0.29, 0.36)
	var floor := Color(0.12, 0.14, 0.18)
	for room in ["A", "B"]:
		var center_x := -5.0 if room == "A" else 5.0
		var wall_center_x := -4.5 if room == "A" else 4.5
		var name := "Room%s" % room
		_add_box(_world, name + "Floor", Vector3(8, 0.12, 8), Vector3(center_x, -0.06, -18), floor)
		_add_box(_world, name + "Ceiling", Vector3(8, 0.12, 8), Vector3(center_x, 3.06, -18), Color(0.14, 0.16, 0.2))
		_add_box(_world, name + "Back", Vector3(9, 3, 0.16), Vector3(wall_center_x, 1.5, -22), wall)
		_add_box(_world, name + "Front", Vector3(9, 3, 0.16), Vector3(wall_center_x, 1.5, -14), wall)
		_add_box(_world, name + "Side", Vector3(0.16, 3, 8), Vector3(center_x + (-4.0 if room == "A" else 4.0), 1.5, -18), wall)
	# 两个房间之间的地板/天花补缝（门洞在 x=0 附近）
	_add_box(_world, "RoomConnectorFloor", Vector3(2, 0.12, 8), Vector3(0, -0.06, -18), floor)
	_add_box(_world, "RoomConnectorCeiling", Vector3(2, 0.12, 8), Vector3(0, 3.06, -18), Color(0.14, 0.16, 0.2))
	# 中间隔墙 + 门洞
	_add_box(_world, "DividerBack", Vector3(0.16, 3, 3.5), Vector3(0, 1.5, -20.25), wall)
	_add_box(_world, "DividerFront", Vector3(0.16, 3, 1.5), Vector3(0, 1.5, -14.75), wall)
	_add_box(_world, "DividerLintel", Vector3(0.16, 0.6, 3.0), Vector3(0, 2.7, -17.5), wall)

	# 房间里挡线索的家具
	_add_box(_world, "CrateA", Vector3(1.3, 1.0, 1.3), Vector3(-8.2, 0.5, -20.2), Color(0.28, 0.25, 0.22))
	_add_box(_world, "DeskB", Vector3(1.6, 0.9, 1.0), Vector3(8.1, 0.45, -20.1), Color(0.24, 0.27, 0.33))
	_add_box(_world, "TableA", Vector3(2.4, 0.8, 1.2), Vector3(-2.4, 0.4, -15.2), Color(0.25, 0.23, 0.27))


func _build_clues() -> void:
	for def in CLUE_DEFS:
		var clue_id := String(def["id"])
		var position: Vector3 = def["position"]
		var node := Node3D.new()
		node.name = "Clue_" + clue_id
		node.position = position
		_world.add_child(node)
		var mesh := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(0.34, 0.3, 0.34)
		mesh.mesh = box
		var material := StandardMaterial3D.new()
		material.albedo_color = Color(0.95, 0.75, 0.25)
		material.emission_enabled = true
		material.emission = Color(0.8, 0.55, 0.1)
		material.emission_energy_multiplier = 1.6
		mesh.material_override = material
		node.add_child(mesh)
		var label := Label3D.new()
		label.text = "?"
		label.font_size = 42
		label.position.y = 0.55
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.modulate = Color(1.0, 0.9, 0.45)
		node.add_child(label)

		var body := StaticBody3D.new()
		var shape := CollisionShape3D.new()
		var box_shape := BoxShape3D.new()
		box_shape.size = Vector3(0.5, 0.5, 0.5)
		shape.shape = box_shape
		body.add_child(shape)
		node.add_child(body)

		var clue := {
			"id": clue_id,
			"label": String(def["label"]),
			"position": position,
			"collected": false,
			"node": node,
		}
		_clues.append(clue)
		_clue_by_id[clue_id] = clue


func _build_camera_models() -> void:
	for def in CAMERA_DEFS:
		var camera_id := String(def["id"])
		var position: Vector3 = def["pos"]
		var look: Vector3 = def["look"]
		var holder := Node3D.new()
		holder.name = "CameraModel_" + camera_id
		holder.position = position
		_world.add_child(holder)
		holder.look_at(look, Vector3.UP)
		var body := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(0.34, 0.24, 0.5)
		body.mesh = box
		var material := StandardMaterial3D.new()
		material.albedo_color = Color(0.12, 0.15, 0.18)
		material.metallic = 0.7
		material.roughness = 0.35
		body.material_override = material
		holder.add_child(body)
		var lens := MeshInstance3D.new()
		var cylinder := CylinderMesh.new()
		cylinder.top_radius = 0.11
		cylinder.bottom_radius = 0.11
		cylinder.height = 0.16
		lens.mesh = cylinder
		lens.rotation_degrees.x = 90
		lens.position = Vector3(0, 0, -0.32)
		var lens_mat := StandardMaterial3D.new()
		lens_mat.albedo_color = Color(0.1, 0.75, 0.9)
		lens_mat.emission_enabled = true
		lens_mat.emission = Color(0.1, 0.7, 0.9)
		lens.material_override = lens_mat
		holder.add_child(lens)
		_add_label3d(_world, camera_id, position + Vector3(0, 0.35, 0), 26, Color(0.4, 0.85, 1.0))


func _build_feed_viewports() -> void:
	for def in CAMERA_DEFS:
		var camera_id := String(def["id"])
		var viewport := SubViewport.new()
		viewport.name = "Feed_" + camera_id
		viewport.size = Vector2i(480, 270)
		viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		viewport.own_world_3d = false
		add_child(viewport)
		var camera := Camera3D.new()
		camera.name = "FeedCamera_" + camera_id
		camera.fov = 68.0
		camera.current = true
		var position: Vector3 = def["pos"]
		var look: Vector3 = def["look"]
		# 机位稍微探出摄像头模型，避免画面里塞满自己的镜头。
		camera.position = position + (look - position).normalized() * 0.9
		viewport.add_child(camera)
		camera.look_at(look, Vector3.UP)
		feeds.append({
			"id": camera_id,
			"viewport": viewport,
			"camera": camera,
			"room": String(def["room"]),
		})


func _build_screens() -> void:
	monitor_viewport = SubViewport.new()
	monitor_viewport.name = "MonitorViewport"
	monitor_viewport.size = Vector2i(1280, 800)
	monitor_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(monitor_viewport)
	monitor_ui = MONITOR_UI_SCRIPT.new()
	monitor_viewport.add_child(monitor_ui)
	monitor_ui.setup()
	monitor_ui.refresh_feeds(feeds)
	monitor_ui.feed_clicked.connect(select_feed)
	monitor_ui.close_feed_requested.connect(close_feed)
	monitor_ui.laser_requested.connect(fire_laser)
	monitor_mesh = _make_screen_mesh("MonitorScreen", MONITOR_CENTER, MONITOR_SIZE,
		monitor_viewport.get_texture())

	scroll_viewport = SubViewport.new()
	scroll_viewport.name = "ScrollViewport"
	scroll_viewport.size = Vector2i(640, 400)
	scroll_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(scroll_viewport)
	scroll_ui = SCROLL_UI_SCRIPT.new()
	scroll_viewport.add_child(scroll_ui)
	scroll_ui.setup()
	scroll_mesh = _make_screen_mesh("ScrollScreen", SCROLL_CENTER, SCROLL_SIZE,
		scroll_viewport.get_texture())
	_refresh_scroll_screen()


func _make_screen_mesh(screen_name: String, center: Vector3, screen_size: Vector2,
		texture: Texture2D) -> MeshInstance3D:
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = screen_name
	var quad := QuadMesh.new()
	quad.size = screen_size
	mesh_instance.mesh = quad
	var material := StandardMaterial3D.new()
	material.albedo_texture = texture
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	mesh_instance.material_override = material
	mesh_instance.position = center
	_world.add_child(mesh_instance)
	return mesh_instance


func _build_player() -> void:
	player = PLAYER_SCRIPT.new()
	player.name = "Player"
	_world.add_child(player)
	player.global_position = Vector3(1.7, 0, 3.0)
	player.configure(CHAIR_POS, STAND_POS, SCREEN_POS, DOOR_POS)
	player.seat_changed.connect(_on_seat_changed)
	player.interaction.connect(_on_interaction)
	var lumine := AVATAR_LOADER.load_avatar(LUMINE_GLB, 1.60, 180.0)
	if lumine != null:
		player.attach_avatar(lumine)


func _build_npcs() -> void:
	var waypoints := [
		Vector3(-5, 0, -16.5), Vector3(-7, 0, -19), Vector3(-3, 0, -20.5),
		Vector3(0, 0, -18), Vector3(3, 0, -20.5), Vector3(7, 0, -19),
		Vector3(5, 0, -16.5), Vector3(0, 0, -16.5),
	]
	var reckless = NPC_SCRIPT.new()
	reckless.name = "NpcReckless"
	reckless.configure("reckless", "reckless", Vector3(-6, 0, -19), waypoints)
	_world.add_child(reckless)
	reckless.clue_collected.connect(_on_clue_collected)
	var soyo := AVATAR_LOADER.load_avatar(SOYO_GLB, 1.72, 180.0)
	if soyo != null:
		reckless.attach_avatar(soyo)
	npcs.append(reckless)
	var cautious = NPC_SCRIPT.new()
	cautious.name = "NpcCautious"
	cautious.configure("cautious", "cautious", Vector3(6, 0, -19), waypoints)
	_world.add_child(cautious)
	cautious.clue_collected.connect(_on_clue_collected)
	# 枫丹 zip 目前只有材质预设、没有 mesh；如果以后放入 fontaine.glb，这里会自动接管。
	var fontaine := AVATAR_LOADER.load_avatar(FONTAINE_GLB, 1.72, 180.0)
	if fontaine != null:
		cautious.attach_avatar(fontaine)
	npcs.append(cautious)


func _build_ui() -> void:
	ui = UI_SCRIPT.new()
	ui.name = "RoomUI"
	add_child(ui)
	ui.setup()
	ui.photo_dropped.connect(drop_photo_to_screen)


func _refresh_all_ui() -> void:
	if ui == null:
		return
	if monitor_ui != null:
		monitor_ui.refresh_feeds(feeds)
		if camera_session != null:
			monitor_ui.refresh_feed_states(camera_session)
	if photo_store != null:
		ui.refresh_photos(photo_store.photos)
		_refresh_scroll_screen()


# --- 工具 ---------------------------------------------------------------------

func _add_box(parent: Node3D, box_name: String, size: Vector3, position: Vector3,
		color: Color, collision: bool = true, emission: Color = Color.TRANSPARENT) -> MeshInstance3D:
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = box_name
	var box := BoxMesh.new()
	box.size = size
	mesh_instance.mesh = box
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.82
	if emission.a > 0.0:
		material.emission_enabled = true
		material.emission = emission
		material.emission_energy_multiplier = 1.4
	mesh_instance.material_override = material
	mesh_instance.position = position
	parent.add_child(mesh_instance)
	if collision:
		var body := StaticBody3D.new()
		body.position = position
		var shape := CollisionShape3D.new()
		var box_shape := BoxShape3D.new()
		box_shape.size = size
		shape.shape = box_shape
		body.add_child(shape)
		parent.add_child(body)
	return mesh_instance


func _add_label3d(parent: Node3D, text: String, position: Vector3, size: int, color: Color) -> Label3D:
	var label := Label3D.new()
	label.text = text
	label.font_size = size
	label.position = position
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.modulate = color
	parent.add_child(label)
	return label


func _feed_by_id(feed_id: String) -> Dictionary:
	for feed in feeds:
		if String(feed.get("id", "")) == feed_id:
			return feed
	return {}


func _camera_that_sees(point: Vector3) -> Dictionary:
	for feed in feeds:
		var camera: Camera3D = feed["camera"]
		if camera.is_position_in_frustum(point):
			return feed
	return feeds[0] if not feeds.is_empty() else {}


func _capture_feed_texture(feed: Dictionary) -> Texture2D:
	if feed.is_empty():
		return _placeholder_texture("无画面", Color(0.1, 0.12, 0.16))
	if DisplayServer.get_name() == "headless":
		return _placeholder_texture(String(feed.get("id", "截图")), Color(0.15, 0.25, 0.35))
	var viewport: SubViewport = feed["viewport"]
	var viewport_texture: Texture2D = viewport.get_texture()
	if viewport_texture == null:
		return _placeholder_texture(String(feed.get("id", "截图")), Color(0.15, 0.25, 0.35))
	var image: Image = viewport_texture.get_image()
	if image == null or image.is_empty():
		return _placeholder_texture(String(feed.get("id", "截图")), Color(0.15, 0.25, 0.35))
	image.resize(320, 180, Image.INTERPOLATE_BILINEAR)
	return ImageTexture.create_from_image(image)


func _placeholder_texture(text: String, color: Color) -> Texture2D:
	var image := Image.create(320, 180, false, Image.FORMAT_RGBA8)
	image.fill(color)
	return ImageTexture.create_from_image(image)


func _raycast_feed_center(feed: Dictionary) -> Vector3:
	if feed.is_empty():
		return Vector3.ZERO
	var camera: Camera3D = feed["camera"]
	var viewport: SubViewport = feed["viewport"]
	var center := Vector2(viewport.size) * 0.5
	var origin := camera.project_ray_origin(center)
	var direction := camera.project_ray_normal(center)
	var query := PhysicsRayQueryParameters3D.create(origin, origin + direction * 40.0)
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return origin + direction * 14.0
	return hit.position


func get_state() -> Dictionary:
	return {
		"seated": player.seated if player != null else false,
		"selected_feed": selected_feed,
		"camera": camera_session.get_state() if camera_session != null else {},
		"photos": photo_store.photos.size() if photo_store != null else 0,
		"door_unlocked": door_unlocked,
		"complete": demo_complete,
		"npcs": npcs.map(func(npc): return npc.get_state()),
	}
