extends Node3D
## 场景里的两只飞鼠：程序化低多边形小动物，尺寸与线索/钥匙 primitive 一致。
##
## 行为：
## - 在地面/空中/墙面之间随机巡游，滑翔时展开翼膜；
## - 碰到可叼走的道具会叼起来，飞一段后换位置放下；
## - 预留火焰敏感接口：有火源进入警戒半径时立即转向、加速并逃离。

signal item_picked(item: Node3D)
signal item_dropped(item: Node3D, position: Vector3)

const SIZE := 0.34
const WANDER_SPEED := 0.38
const GLIDE_SPEED := 1.15
const CLIMB_SPEED := 0.55
const FLEE_SPEED := 2.1
const FIRE_WARNING_RADIUS := 3.5
const FIRE_PANIC_RADIUS := 2.2
const CARRY_RADIUS := 0.34
const CARRY_TIME_MIN := 3.0
const CARRY_TIME_MAX := 6.0
const FLOOR_Y := 0.18

const FUR := Color(0.93, 0.81, 0.65)
const SHADE := Color(0.83, 0.66, 0.49)
const PINK := Color(0.91, 0.63, 0.57)
const LINE := Color(0.23, 0.16, 0.13)

var room_min := Vector3(-9.2, 0, -21.2)
var room_max := Vector3(-2.4, 2.7, -14.4)
var carryables: Array[Node3D] = []
var fire_points: Array[Vector3] = []

var _rng := RandomNumberGenerator.new()
var _target := Vector3.ZERO
var _state := "wander"
var _state_time := 0.0
var _speed := WANDER_SPEED
var _carried: Node3D = null
var _carry_time := 0.0
var _panic := false
var _panic_near := false
var _visual: Node3D = null
var _membrane_l: MeshInstance3D = null
var _membrane_r: MeshInstance3D = null
var _tail: Node3D = null
var _time := 0.0


func setup(bounds_min: Vector3, bounds_max: Vector3, seed_value: int,
		carryable_items: Array[Node3D] = []) -> void:
	room_min = bounds_min
	room_max = bounds_max
	carryables = carryable_items
	_rng.seed = seed_value
	position = Vector3(
		_rng.randf_range(room_min.x + 0.4, room_max.x - 0.4),
		FLOOR_Y,
		_rng.randf_range(room_min.z + 0.4, room_max.z - 0.4))
	_build_visual()
	_pick_target()


func tick(delta: float) -> void:
	if delta <= 0.0:
		return
	_time += delta
	_state_time -= delta
	_update_fire_panic()
	_update_carry(delta)

	if _state_time <= 0.0:
		_pick_target()
	var target := _target
	var move_speed := _speed
	if _panic:
		target = global_position + _away_from_fire() * 2.2
		target.y = 0.9
		move_speed = FLEE_SPEED * (1.35 if _panic_near else 1.0)
	elif _state == "wander":
		target.y = FLOOR_Y
		move_speed = WANDER_SPEED
	elif _state == "glide":
		move_speed = GLIDE_SPEED
	elif _state == "climb":
		move_speed = CLIMB_SPEED

	var next := global_position.move_toward(target, move_speed * delta)
	next.x = clampf(next.x, room_min.x + 0.22, room_max.x - 0.22)
	next.z = clampf(next.z, room_min.z + 0.22, room_max.z - 0.22)
	next.y = clampf(next.y, FLOOR_Y, room_max.y)
	global_position = next

	var flat := Vector3(target.x, global_position.y, target.z)
	if flat.distance_to(global_position) > 0.03:
		look_at(flat, Vector3.UP)
	if _state == "glide" and not _panic:
		rotation.x = lerpf(rotation.x, -0.18, clampf(delta * 4.0, 0.0, 1.0))
	else:
		rotation.x = lerpf(rotation.x, 0.0, clampf(delta * 5.0, 0.0, 1.0))

	if global_position.distance_to(_target) < 0.12:
		_state_time = 0.0
	_update_visual(delta)
	_try_pickup()


func set_fire_sources(points: Array[Vector3]) -> void:
	fire_points = points.duplicate()


func add_fire_source(point: Vector3) -> void:
	fire_points.append(point)


func is_panicking() -> bool:
	return _panic


func get_state() -> Dictionary:
	return {
		"state": _state,
		"position": global_position,
		"target": _target,
		"squirrel_panic": _panic,
		"panic_near": _panic_near,
		"carrying": _carried != null,
	}


# --- 视觉 ---------------------------------------------------------------------

func _build_visual() -> void:
	_visual = Node3D.new()
	_visual.name = "SquirrelVisual"
	# 本地模型最大尺寸约 .5m；缩到钥匙/线索 primitive 的 .34m。
	_visual.scale = Vector3.ONE * (SIZE / 0.5)
	add_child(_visual)

	var body := _mesh_instance("Body", _capsule(0.062, 0.28), FUR,
		Vector3(0, 0.065, 0), Vector3(90, 0, 0))
	body.scale = Vector3(1.0, 1.0, 1.18)
	_visual.add_child(body)

	var head := _mesh_instance("Head", _sphere(0.072), FUR,
		Vector3(0, 0.085, -0.145), Vector3.ZERO)
	head.scale = Vector3(1.0, 0.88, 1.08)
	_visual.add_child(head)
	var muzzle := _mesh_instance("Muzzle", _sphere(0.040), SHADE.lerp(FUR, 0.55),
		Vector3(0, 0.060, -0.200), Vector3.ZERO)
	muzzle.scale = Vector3(1.0, 0.72, 1.15)
	_visual.add_child(muzzle)
	var nose := _mesh_instance("Nose", _sphere(0.018), PINK,
		Vector3(0, 0.065, -0.235), Vector3.ZERO)
	_visual.add_child(nose)

	for side in [-1, 1]:
		var ear := _mesh_instance("Ear", _sphere(0.030), SHADE,
			Vector3(side * 0.040, 0.155, -0.135), Vector3.ZERO)
		ear.scale = Vector3(0.65, 1.45, 0.55)
		_visual.add_child(ear)
		var ear_inner := _mesh_instance("EarInner", _sphere(0.018), PINK,
			Vector3(side * 0.040, 0.158, -0.155), Vector3.ZERO)
		ear_inner.scale = Vector3(0.60, 1.15, 0.35)
		_visual.add_child(ear_inner)
		var eye := _mesh_instance("Eye", _sphere(0.014), LINE,
			Vector3(side * 0.038, 0.095, -0.205), Vector3.ZERO)
		_visual.add_child(eye)
		var shine := _mesh_instance("EyeShine", _sphere(0.0045), Color(1, 1, 1),
			Vector3(side * 0.041, 0.099, -0.218), Vector3.ZERO)
		_visual.add_child(shine)
		# 前后肢，增加参考图里的四肢轮廓。
		var foreleg := _mesh_instance("Foreleg", _capsule(0.014, 0.09), SHADE,
			Vector3(side * 0.050, 0.040, -0.060), Vector3(0, 0, side * 24))
		_visual.add_child(foreleg)
		var hindleg := _mesh_instance("Hindleg", _capsule(0.018, 0.11), SHADE,
			Vector3(side * 0.055, 0.045, 0.070), Vector3(0, 0, side * 28))
		_visual.add_child(hindleg)

	_tail = Node3D.new()
	_tail.name = "Tail"
	_tail.position = Vector3(0, 0.075, 0.135)
	_visual.add_child(_tail)
	# 向上卷起的分段尾巴，尾端逐渐变宽再收尖。
	for index in 6:
		var t := float(index) / 5.0
		var tuft := _mesh_instance("TailTuft", _sphere(0.040 + sin(t * PI) * 0.020), SHADE.lerp(PINK, t * 0.35),
			Vector3(0, 0.02 + t * 0.22, 0.02 + t * 0.08), Vector3.ZERO)
		tuft.scale = Vector3(1.0, 0.95, 1.25)
		_tail.add_child(tuft)

	for side in [-1, 1]:
		var membrane := MeshInstance3D.new()
		membrane.name = "Membrane"
		# 三角形翼膜：肩 → 翼尖 → 胯，比矩形 PlaneMesh 更接近参考。
		var mesh := ArrayMesh.new()
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
			Vector3(0.0, 0.075, -0.08),
			Vector3(side * 0.22, 0.055, -0.02),
			Vector3(0.0, 0.055, 0.13),
		])
		arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2])
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		membrane.mesh = mesh
		var material := _material(SHADE.lerp(FUR, 0.25), true)
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.albedo_color.a = 0.82
		membrane.material_override = material
		_visual.add_child(membrane)
		if side < 0:
			_membrane_l = membrane
		else:
			_membrane_r = membrane


func _update_visual(delta: float) -> void:
	if _visual == null:
		return
	var gliding := _state == "glide" or _panic
	var spread := 1.0 if gliding else 0.12
	for membrane in [_membrane_l, _membrane_r]:
		if membrane == null:
			continue
		membrane.visible = true
		membrane.scale.x = lerpf(membrane.scale.x, spread, clampf(delta * 8.0, 0.0, 1.0))
		membrane.scale.z = 1.0
	if _tail != null:
		_tail.rotation.y = sin(_time * 2.4) * 0.28
		_tail.rotation.x = sin(_time * 1.7) * 0.12
	_visual.position.y = 0.03 + sin(_time * (6.0 if gliding else 3.0)) * (0.012 if gliding else 0.006)


func _material(color: Color, unshaded: bool = false) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.82
	# 0.34m 的小目标在暗色观察室里必须保持可辨认，统一用 unshaded 卡通色块。
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	if unshaded:
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return material


func _mesh_instance(node_name: String, mesh: PrimitiveMesh, color: Color,
		pos: Vector3, rot_degrees: Vector3) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = mesh
	instance.position = pos
	instance.rotation_degrees = rot_degrees
	instance.material_override = _material(color)
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return instance


func _capsule(radius: float, height: float) -> CapsuleMesh:
	var mesh := CapsuleMesh.new()
	mesh.radius = radius
	mesh.height = height
	return mesh


func _sphere(radius: float) -> SphereMesh:
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	return mesh


# --- 巡游/叼取/火焰 -----------------------------------------------------------

func _pick_target() -> void:
	var roll := _rng.randf()
	if roll < 0.52:
		_state = "wander"
		_target = Vector3(
			_rng.randf_range(room_min.x + 0.5, room_max.x - 0.5),
			FLOOR_Y,
			_rng.randf_range(room_min.z + 0.5, room_max.z - 0.5))
		_state_time = _rng.randf_range(1.6, 3.2)
	elif roll < 0.82:
		_state = "glide"
		_target = Vector3(
			_rng.randf_range(room_min.x + 0.6, room_max.x - 0.6),
			_rng.randf_range(1.2, 2.55),
			_rng.randf_range(room_min.z + 0.6, room_max.z - 0.6))
		_state_time = _rng.randf_range(2.0, 4.0)
	else:
		_state = "climb"
		var side := _rng.randi_range(0, 3)
		_target = Vector3(
			room_min.x + 0.3 if side == 0 else room_max.x - 0.3 if side == 1
				else _rng.randf_range(room_min.x + 0.4, room_max.x - 0.4),
			_rng.randf_range(1.4, 2.5),
			room_min.z + 0.3 if side == 2 else room_max.z - 0.3 if side == 3
				else _rng.randf_range(room_min.z + 0.4, room_max.z - 0.4))
		_state_time = _rng.randf_range(2.0, 4.0)


func _update_fire_panic() -> void:
	_panic = false
	_panic_near = false
	for point in fire_points:
		var distance := global_position.distance_to(point)
		if distance < FIRE_WARNING_RADIUS:
			_panic = true
			_panic_near = distance < FIRE_PANIC_RADIUS
			return


func _away_from_fire() -> Vector3:
	var away := Vector3.ZERO
	for point in fire_points:
		var offset := global_position - point
		offset.y = 0.0
		if offset.length_squared() > 0.001:
			away += offset.normalized()
	if away.length_squared() < 0.001:
		return Vector3(-1, 0, -1).normalized()
	return away.normalized()


func _update_carry(delta: float) -> void:
	if _carried == null:
		return
	_carry_time -= delta
	var item := _carried
	if not is_instance_valid(item) or not item.visible:
		# NPC 可能已经把线索收走；不要让它被飞鼠重新“复活”。
		_carried = null
		return
	item.global_position = global_position + Vector3(0, 0.12, -0.08)
	if _carry_time <= 0.0:
		var drop_position := Vector3(
			_rng.randf_range(room_min.x + 0.5, room_max.x - 0.5),
			0.38,
			_rng.randf_range(room_min.z + 0.5, room_max.z - 0.5))
		item.global_position = drop_position
		item.visible = true
		item_dropped.emit(item, drop_position)
		_carried = null


func _try_pickup() -> void:
	if _carried != null or _panic:
		return
	for item in carryables:
		if not is_instance_valid(item) or not item.visible:
			continue
		if global_position.distance_to(item.global_position) <= CARRY_RADIUS:
			_carried = item
			_carry_time = _rng.randf_range(CARRY_TIME_MIN, CARRY_TIME_MAX)
			item_picked.emit(item)
			return
