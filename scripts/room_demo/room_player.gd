extends CharacterBody3D
## 第一人称玩家（占位 avatar）：控制室行走 → 椅子旁按 F 坐下 → 面对监控台。
## 坐下时交出移动/鼠标视角，由监控 UI 接管鼠标。

signal seat_changed(seated: bool)
signal interaction(action: String)
signal sit_hint_changed(visible: bool)

const AVATAR_LOADER := preload("res://scripts/room_demo/avatar_loader.gd")
const WALK_SPEED := 2.2
const WALK_ACCEL := 8.0
const WALK_DECEL := 12.0
const BOB_FREQUENCY := 9.0
const BOB_HEIGHT := 0.025
const BOB_SWAY := 0.012
const HEAD_HEIGHT := 1.58
const SEAT_HEAD_HEIGHT := 1.36
const MOUSE_SENSITIVITY := 0.0025
const PITCH_MIN := -1.15
const PITCH_MAX := 0.85
const SIT_DISTANCE := 2.8

var seated := false
var chair_position := Vector3(0, 0, 1.9)
var seat_eye := Vector3(0, 1.45, 1.45)
var screen_position := Vector3(0, 1.5, -3.8)
var door_position := Vector3(0, 1.2, 4.0)
var stand_position := Vector3(0, 0, 2.9)

var camera: Camera3D = null

var _head: Node3D = null
var _body_mesh: MeshInstance3D = null
var _head_mesh: MeshInstance3D = null
var _avatar: Node3D = null
var _yaw := 0.0
var _pitch := 0.0
var _can_sit := false
var _gravity := 18.0
var fire_protection_time := 0.0
var fire_protection_kind := ""
var _head_base_position := Vector3(0, HEAD_HEIGHT, 0)
var _seat_head_position := Vector3(0, SEAT_HEAD_HEIGHT, 0)
var _bob_time := 0.0
## 测试用：绕过真实键盘，直接给移动输入。
var use_test_input := false
var test_move_input := Vector2.ZERO


func _ready() -> void:
	_build_body()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func configure(chair: Vector3, stand: Vector3, screen: Vector3, door: Vector3) -> void:
	chair_position = chair
	stand_position = stand
	screen_position = screen
	door_position = door


## 替换 primitive avatar；第一人称相机在 1.66m，模型按 1.60m 归一化，避免相机埋进头里。
func attach_avatar(avatar: Node3D) -> void:
	if avatar == null:
		return
	_avatar = avatar
	add_child(avatar)
	# 第一人称相机在头部内部；把玩家自己的模型放到 layer 2，并让相机剔除该层，
	# 否则会看到头部/身体内壁（穿模）。
	AVATAR_LOADER.fit_in_parent(avatar, 1.60)
	_set_first_person_layers(avatar)
	if _body_mesh != null:
		_body_mesh.visible = false
	if _head_mesh != null:
		_head_mesh.visible = false


func _set_first_person_layers(node: Node) -> void:
	if node is MeshInstance3D:
		(node as MeshInstance3D).layers = 2
	for child in node.get_children():
		_set_first_person_layers(child)


func has_avatar() -> bool:
	return _avatar != null


func apply_wet(seconds: float) -> void:
	fire_protection_time = maxf(fire_protection_time, seconds)
	fire_protection_kind = "wet"


func apply_wet_blanket(seconds: float) -> void:
	fire_protection_time = maxf(fire_protection_time, seconds)
	fire_protection_kind = "blanket"


func tick_fire_protection(delta: float) -> void:
	fire_protection_time = maxf(fire_protection_time - delta, 0.0)
	if fire_protection_time <= 0.0:
		fire_protection_kind = ""


func is_fire_protected() -> bool:
	return fire_protection_time > 0.0


func _build_body() -> void:
	var shape := CollisionShape3D.new()
	var capsule_shape := CapsuleShape3D.new()
	capsule_shape.radius = 0.32
	capsule_shape.height = 1.6
	shape.shape = capsule_shape
	shape.position.y = 0.9
	add_child(shape)

	_body_mesh = MeshInstance3D.new()
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.32
	capsule.height = 1.45
	_body_mesh.mesh = capsule
	_body_mesh.position.y = 0.88
	_body_mesh.material_override = _material(Color(0.72, 0.74, 0.8))
	_body_mesh.layers = 2
	add_child(_body_mesh)

	_head_mesh = MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.22
	sphere.height = 0.44
	_head_mesh.mesh = sphere
	_head_mesh.position.y = 1.55
	_head_mesh.material_override = _material(Color(0.86, 0.72, 0.62))
	_head_mesh.layers = 2
	add_child(_head_mesh)

	_head = Node3D.new()
	_head.name = "Head"
	_head_base_position = Vector3(0, HEAD_HEIGHT, 0)
	_head.position = _head_base_position
	add_child(_head)
	camera = Camera3D.new()
	camera.name = "FirstPersonCamera"
	camera.current = true
	camera.fov = 75.0
	# layer 2 = 玩家自己的 avatar；第一人称相机不渲染它。
	camera.cull_mask = camera.cull_mask & ~(1 << 1)
	camera.position = Vector3(0, 0.08, 0)
	_head.add_child(camera)


func _unhandled_input(event: InputEvent) -> void:
	if seated:
		var key_event := event as InputEventKey
		if key_event != null and key_event.pressed and not key_event.echo \
				and key_event.keycode == KEY_F:
			stand()
			get_viewport().set_input_as_handled()
		return

	var mouse := event as InputEventMouseMotion
	if mouse != null and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_yaw = wrapf(_yaw - mouse.relative.x * MOUSE_SENSITIVITY, -PI, PI)
		_pitch = clampf(_pitch - mouse.relative.y * MOUSE_SENSITIVITY, PITCH_MIN, PITCH_MAX)
		rotation.y = _yaw
		_head.rotation.x = _pitch
		get_viewport().set_input_as_handled()
		return

	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	if key.keycode == KEY_F and _can_sit:
		try_sit()
		get_viewport().set_input_as_handled()
	elif key.keycode == KEY_E and global_position.distance_to(door_position) <= 2.4:
		interaction.emit("door")
		get_viewport().set_input_as_handled()


func _physics_process(delta: float) -> void:
	if seated:
		velocity = Vector3.ZERO
		_reset_head_bob()
		return
	var input_dir := _read_move_input()
	if input_dir.length_squared() > 1.0:
		input_dir = input_dir.normalized()
	var direction := (transform.basis * Vector3(input_dir.x, 0.0, input_dir.y)).normalized()
	var target := direction * WALK_SPEED
	var rate := WALK_ACCEL if input_dir.length_squared() > 0.0 else WALK_DECEL
	velocity.x = move_toward(velocity.x, target.x, rate * delta)
	velocity.z = move_toward(velocity.z, target.z, rate * delta)
	if not is_on_floor():
		velocity.y -= _gravity * delta
	else:
		velocity.y = -0.1
	move_and_slide()
	_update_head_bob(delta)

	var distance := Vector2(global_position.x - chair_position.x, global_position.z - chair_position.z).length()
	var can_now := distance <= SIT_DISTANCE
	if can_now != _can_sit:
		_can_sit = can_now
		sit_hint_changed.emit(_can_sit)


func _read_move_input() -> Vector2:
	if use_test_input:
		return test_move_input
	var input_dir := Vector2.ZERO
	if Input.is_key_pressed(KEY_W):
		input_dir.y -= 1.0
	if Input.is_key_pressed(KEY_S):
		input_dir.y += 1.0
	if Input.is_key_pressed(KEY_A):
		input_dir.x -= 1.0
	if Input.is_key_pressed(KEY_D):
		input_dir.x += 1.0
	return input_dir


## 走路时相机轻微上下起伏/左右摆，停下平滑回正；幅度远小于视线高度。
func _update_head_bob(delta: float) -> void:
	var speed := Vector2(velocity.x, velocity.z).length()
	if speed > 0.1:
		_bob_time += delta * BOB_FREQUENCY * clampf(speed / WALK_SPEED, 0.35, 1.2)
		var bob := sin(_bob_time) * BOB_HEIGHT
		var sway := cos(_bob_time * 0.5) * BOB_SWAY
		_head.position = Vector3(sway, _head_base_position.y + bob, 0.0)
	else:
		_bob_time = 0.0
		_head.position = _head.position.lerp(_head_base_position, clampf(delta * 10.0, 0.0, 1.0))


func _reset_head_bob() -> void:
	_bob_time = 0.0
	if _head != null:
		_head.position = _seat_head_position if seated else _head_base_position


func try_sit() -> bool:
	if seated:
		return true
	var distance := Vector2(global_position.x - chair_position.x, global_position.z - chair_position.z).length()
	_can_sit = distance <= SIT_DISTANCE
	if not _can_sit:
		return false
	seated = true
	velocity = Vector3.ZERO
	# 坐姿相机低于 avatar 头顶，隐藏第一人称模型避免相机埋进头部。
	if _avatar != null:
		_avatar.visible = false
	global_position = Vector3(chair_position.x, 0.0, chair_position.z)
	rotation.y = 0.0
	_yaw = 0.0
	_pitch = 0.02
	_head.rotation.x = _pitch
	_reset_head_bob()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	seat_changed.emit(true)
	return true


func stand() -> void:
	if not seated:
		return
	seated = false
	if _avatar != null:
		_avatar.visible = true
	global_position = stand_position
	_reset_head_bob()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	seat_changed.emit(false)


func can_sit() -> bool:
	return _can_sit


func get_state() -> Dictionary:
	return {
		"seated": seated,
		"position": global_position,
		"yaw": _yaw,
		"pitch": _pitch,
		"can_sit": _can_sit,
		"speed": Vector2(velocity.x, velocity.z).length(),
		"head_offset": _head.position - _head_base_position,
	}


func _material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.85
	return material
