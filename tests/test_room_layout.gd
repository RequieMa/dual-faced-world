extends SceneTree
## 房间布局/坐向/移动手感回归。
## 运行：godot --headless --path . --script tests/test_room_layout.gd
##
## 覆盖：控制室精确尺寸/净高/门楣、结构碰撞体、椅背朝向与胶囊间隙、
## 坐下/站起复位、起步加速/持续速度/松键减速/头部起伏。

const MAIN_SCENE := "res://scenes/main.tscn"
const EXPECTED_CHECKS := 35

var _failures: Array[String] = []
var _checks: int = 0
var _started := false


func _initialize() -> void:
	_check("存在 scenes/main.tscn", ResourceLoader.exists(MAIN_SCENE))


func _process(_delta: float) -> bool:
	if _started:
		return false
	_started = true
	_run_tests()
	return false


func _run_tests() -> void:
	var packed := ResourceLoader.load(MAIN_SCENE) as PackedScene
	var demo = packed.instantiate()
	root.add_child(demo)

	var floor_node := demo.find_child("ControlFloor", true, false) as MeshInstance3D
	var floor_mesh := floor_node.mesh as BoxMesh if floor_node != null else null
	_check("控制室地面正好 16×12", floor_mesh != null
		and is_equal_approx(floor_mesh.size.x, 16.0) and is_equal_approx(floor_mesh.size.z, 12.0),
		"" if floor_mesh == null else str(floor_mesh.size))

	var ceiling := demo.find_child("ControlCeiling", true, false) as MeshInstance3D
	var ceiling_mesh := ceiling.mesh as BoxMesh if ceiling != null else null
	var net_height := 0.0
	if ceiling != null and ceiling_mesh != null:
		net_height = ceiling.position.y - ceiling_mesh.size.y * 0.5
	_check("净高 3.4m（天花底面）", is_equal_approx(net_height, 3.4), "net=%.3f" % net_height)

	var lintel := demo.find_child("ControlDoorLintel", true, false) as MeshInstance3D
	var lintel_mesh := lintel.mesh as BoxMesh if lintel != null else null
	var lintel_top := 0.0
	if lintel != null and lintel_mesh != null:
		lintel_top = lintel.position.y + lintel_mesh.size.y * 0.5
	_check("门楣顶到天花（无通缝）", is_equal_approx(lintel_top, 3.4), "top=%.3f" % lintel_top)

	var seat := demo.find_child("ChairSeat", true, false) as MeshInstance3D
	var back := demo.find_child("ChairBack", true, false) as MeshInstance3D
	_check("椅背在座位靠门一侧（椅子面向屏幕）",
		seat != null and back != null and back.position.z > seat.position.z,
		"" if seat == null or back == null else "%s vs %s" % [back.position.z, seat.position.z])
	var back_front := 0.0
	if back != null and back.mesh is BoxMesh:
		back_front = back.position.z - (back.mesh as BoxMesh).size.z * 0.5
	_check("椅背不会压进玩家胶囊",
		back_front - demo.player.chair_position.z >= 0.32,
		"gap=%.3f" % (back_front - demo.player.chair_position.z))

	for node_name in [
		"ConsoleDesk", "ServerRackL", "ServerRackR", "CeilingBeamA", "CeilingBeamB",
		"FloorInlay", "WallPanelL", "WallPanelR",
	]:
		_check("有结构节点 %s" % node_name, demo.find_child(node_name, true, false) != null)
	for body_name in [
		"ConsoleDeskBody", "ServerRackLBody", "ServerRackRBody", "PillarLBody", "PillarRBody",
	]:
		_check("结构有碰撞体 %s" % body_name, demo.find_child(body_name, true, false) != null)

	var player = demo.player
	# 挂一个假 avatar，验证坐下会隐藏第一人称模型（相机低于模型头顶）。
	var dummy_avatar := Node3D.new()
	dummy_avatar.name = "DummyAvatar"
	player.attach_avatar(dummy_avatar)
	# 先把朝向拧歪，验证 try_sit 会重置，而不是“出生点本来就朝屏幕”。
	player.rotation.y = 1.2
	_check("能坐下", demo.set_seated(true))
	_check("坐下后 player.seated", player.seated)
	_check("坐下后隐藏第一人称 avatar", not dummy_avatar.visible)
	_check("坐下后朝向复位", abs(player.rotation.y) < 0.01, "yaw=%.3f" % player.rotation.y)
	var camera: Camera3D = player.camera
	var forward := -camera.global_transform.basis.z
	var to_screen: Vector3 = (player.screen_position - camera.global_position).normalized()
	_check("坐下后面向屏幕", forward.dot(to_screen) > 0.9,
		"dot=%.3f" % forward.dot(to_screen))
	_check("坐下后视高降低", camera.global_position.y < 1.5,
		"y=%.3f" % camera.global_position.y)
	_check("能站起", demo.set_seated(false))
	_check("站起后不 seated", not player.seated)
	_check("站起后恢复 avatar", dummy_avatar.visible)
	_check("站起后回到站立点",
		player.global_position.distance_to(player.stand_position) < 0.05,
		str(player.global_position))
	_check("站起后头部回正", player._head.position.is_equal_approx(player._head_base_position),
		str(player._head.position))

	# 移动手感：用测试输入驱动，不依赖真实键盘。
	player.set_physics_process(false)
	player.global_position = Vector3(3.5, 0.0, 3.0)
	player.use_test_input = true
	player.test_move_input = Vector2(0, -1)
	player._physics_process(0.1)
	var speed_first := Vector2(player.velocity.x, player.velocity.z).length()
	_check("起步不是瞬时满速", speed_first > 0.1 and speed_first < player.WALK_SPEED * 0.95,
		"speed=%.3f" % speed_first)
	for i in 12:
		player._physics_process(0.1)
	var speed_full := Vector2(player.velocity.x, player.velocity.z).length()
	_check("持续移动接近步行速度", speed_full >= player.WALK_SPEED * 0.9,
		"speed=%.3f" % speed_full)
	_check("移动中有头部起伏", abs(player._head.position.y - 1.58) > 0.003,
		"head_y=%.4f" % player._head.position.y)
	player.test_move_input = Vector2.ZERO
	for i in 12:
		player._physics_process(0.1)
	var speed_stop := Vector2(player.velocity.x, player.velocity.z).length()
	_check("松键后减速到停", speed_stop < 0.3, "speed=%.3f" % speed_stop)
	_check("停下后头部回正", abs(player._head.position.y - 1.58) < 0.01,
		"head_y=%.4f" % player._head.position.y)
	player.use_test_input = false

	demo.free()
	_report()


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
		print("ROOM_LAYOUT_TEST_PASS (%d checks)" % _checks)
		quit(0)
	else:
		printerr("ROOM_LAYOUT_TEST_FAIL (%d/%d failed)" % [_failures.size(), _checks])
		for failure in _failures:
			printerr("  - ", failure)
		quit(1)
