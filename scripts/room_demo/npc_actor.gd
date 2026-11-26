extends CharacterBody3D
## 观察房间里的两个 NPC（primitive 占位或 GLB avatar）：
## - `reckless`（莽撞）：跑得比谨慎快、视锥短；收到激光会冲过去，找不到线索就跑开，连续跑空后会短时间无视信号；
## - `cautious`（谨慎）：走得慢、视锥长；会顺着激光慢慢走过去并四处翻找，不会因为跑空而忽略信号。
##
## 用 CharacterBody3D + move_and_slide 移动，墙体/家具的 StaticBody3D 会挡住 NPC；
## 不再直接改 global_position，因此不会穿墙。宿主每帧 tick(delta)。

signal clue_collected(clue_id: String, position: Vector3)
signal state_changed(state: String)

const PERSONALITY_RECKLESS := "reckless"
const PERSONALITY_CAUTIOUS := "cautious"

const STATE_WANDER := "wander"
const STATE_PAUSE := "pause"
const STATE_SEEK := "seek"
const STATE_SEARCH := "search"

const ARRIVE_EPSILON := 0.08
## NPC 只会主动去捡「自己走到很近、且看得到」的线索；远处的要靠玩家用激光/截图引导。
const AUTO_SEEK_RADIUS := 2.0

var npc_id := ""
var personality := PERSONALITY_CAUTIOUS
var state := STATE_WANDER
var speed := 1.2
var signal_range := 20.0
var vision_range := 8.0
var vision_half_angle := 45.0

var _waypoints: Array[Vector3] = []
var _target := Vector3.ZERO
var _state_time := 0.0
var _search_remaining := 0.0
var _now := 0.0
var _ignore_until := 0.0
var _wasted := 0
var _signal_active := false
var _seeking_clue_id := ""
var _visual_built := false
var _cone: MeshInstance3D = null
var _body_mesh: MeshInstance3D = null
var _head_mesh: MeshInstance3D = null
var _avatar: Node3D = null


func configure(id: String, personality_name: String, start_pos: Vector3,
		waypoints: Array) -> void:
	npc_id = id
	personality = personality_name if personality_name in [PERSONALITY_RECKLESS, PERSONALITY_CAUTIOUS] \
		else PERSONALITY_CAUTIOUS
	position = start_pos
	_waypoints.clear()
	for point in waypoints:
		if point is Vector3:
			_waypoints.append(point)
	if _waypoints.is_empty():
		_waypoints.append(start_pos)
	_target = _waypoints[0]
	state = STATE_WANDER
	_state_time = 0.0
	_search_remaining = 0.0
	_now = 0.0
	_ignore_until = 0.0
	_wasted = 0
	_signal_active = false
	_seeking_clue_id = ""
	if personality == PERSONALITY_RECKLESS:
		speed = 1.65
		vision_range = 6.0
		vision_half_angle = 50.0
		signal_range = 12.0
		_signal_search_time = 1.2
		_waste_limit = 3
		_ignore_seconds = 12.0
	else:
		speed = 0.60
		vision_range = 8.5
		vision_half_angle = 55.0
		signal_range = 15.0
		_signal_search_time = 4.0
		_waste_limit = 0
		_ignore_seconds = 0.0
	_ensure_visual()
	_update_cone_visual()


var _signal_search_time := 1.2
var _waste_limit := 3
var _ignore_seconds := 12.0


func _ready() -> void:
	_ensure_visual()


func tick(delta: float, clues: Array) -> void:
	if delta <= 0.0:
		return
	_now += delta
	_update_cone_visual()
	match state:
		STATE_WANDER:
			_tick_wander(delta, clues)
		STATE_PAUSE:
			_tick_pause(delta, clues)
		STATE_SEEK:
			_tick_seek(delta, clues)
		STATE_SEARCH:
			_tick_search(delta, clues)


## 收到玩家激光/截图信号。超出范围或仍在“忽略期”返回 false。
func receive_signal(point: Vector3, now: float = -1.0) -> bool:
	var at := _now if now < 0.0 else now
	if at < _ignore_until:
		return false
	if global_position.distance_to(point) > signal_range:
		return false
	_target = Vector3(point.x, global_position.y, point.z)
	_signal_active = true
	_seeking_clue_id = ""
	_set_state(STATE_SEEK)
	return true


func sees_point(point: Vector3) -> bool:
	var origin := global_position + Vector3(0, 1.4, 0)
	var offset := point - origin
	var distance := offset.length()
	if distance > vision_range or distance <= 0.01:
		return false
	var forward := -global_transform.basis.z
	forward.y = 0.0
	if forward.length_squared() <= 0.001:
		return false
	var angle := rad_to_deg(forward.normalized().angle_to(Vector3(offset.x, 0.0, offset.z).normalized()))
	return angle <= vision_half_angle


func is_ignoring_signals() -> bool:
	return _now < _ignore_until


func get_state() -> Dictionary:
	return {
		"id": npc_id,
		"personality": personality,
		"state": state,
		"position": global_position,
		"target": _target,
		"speed": speed,
		"wasted_signals": _wasted,
		"ignoring": is_ignoring_signals(),
	}


# --- 内部状态机 ---------------------------------------------------------------

func _tick_wander(delta: float, clues: Array) -> void:
	if _try_seek_visible_clue(clues):
		return
	if _move_toward(_target, speed, delta):
		_state_time = randf_range(0.6, 1.8) if personality == PERSONALITY_RECKLESS else randf_range(1.0, 2.5)
		_set_state(STATE_PAUSE)


func _tick_pause(delta: float, clues: Array) -> void:
	if _try_seek_visible_clue(clues):
		return
	rotation.y += delta * (0.4 if personality == PERSONALITY_CAUTIOUS else 0.8)
	_state_time -= delta
	if _state_time <= 0.0:
		_pick_waypoint()
		_set_state(STATE_WANDER)


func _tick_seek(delta: float, clues: Array) -> void:
	if _move_toward(_target, speed, delta):
		_search_remaining = _signal_search_time if _signal_active else 2.0
		_set_state(STATE_SEARCH)


func _tick_search(delta: float, clues: Array) -> void:
	var near := _nearby_clue(clues, 2.2)
	if not near.is_empty():
		_collect_clue(near)
		return
	rotation.y += delta * 1.6
	_search_remaining -= delta
	if _search_remaining > 0.0:
		return
	if _signal_active:
		_signal_active = false
		if personality == PERSONALITY_RECKLESS:
			_wasted += 1
			if _waste_limit > 0 and _wasted >= _waste_limit:
				_ignore_until = _now + _ignore_seconds
	_pick_waypoint()
	_set_state(STATE_WANDER)


func _try_seek_visible_clue(clues: Array) -> bool:
	for clue in clues:
		if bool(clue.get("collected", false)):
			continue
		var point: Vector3 = clue.get("position", Vector3.ZERO)
		if global_position.distance_to(point) > AUTO_SEEK_RADIUS:
			continue
		if sees_point(point):
			_target = Vector3(point.x, global_position.y, point.z)
			_seeking_clue_id = String(clue.get("id", ""))
			_signal_active = false
			_set_state(STATE_SEEK)
			return true
	return false


func _nearby_clue(clues: Array, radius: float) -> Dictionary:
	for clue in clues:
		if bool(clue.get("collected", false)):
			continue
		var point: Vector3 = clue.get("position", Vector3.ZERO)
		if global_position.distance_to(point) <= radius:
			return clue
	return {}


func _collect_clue(clue: Dictionary) -> void:
	clue["collected"] = true
	var clue_id := String(clue.get("id", ""))
	var point: Vector3 = clue.get("position", Vector3.ZERO)
	var node = clue.get("node")
	if node is Node3D and is_instance_valid(node):
		node.visible = false
	_state_time = 0.8
	_set_state(STATE_PAUSE)
	clue_collected.emit(clue_id, point)


func _move_toward(point: Vector3, move_speed: float, delta: float) -> bool:
	var offset := point - global_position
	offset.y = 0.0
	var distance := offset.length()
	if distance <= ARRIVE_EPSILON:
		velocity = Vector3.ZERO
		return true
	_face_toward(point)
	var direction := offset.normalized()
	velocity = Vector3(direction.x * move_speed, 0.0, direction.z * move_speed)
	var before := global_position
	move_and_slide()
	var moved := Vector2(global_position.x - before.x, global_position.z - before.z).length()
	if moved < 0.0001:
		# 墙体/家具挡住去路：当作“到不了”，让状态机进入搜索/换路，避免永远贴着墙。
		velocity = Vector3.ZERO
		return true
	return distance - moved <= ARRIVE_EPSILON


func _face_toward(point: Vector3) -> void:
	var flat := Vector3(point.x, global_position.y, point.z)
	if flat.distance_to(global_position) > 0.01:
		look_at(flat, Vector3.UP)


func _pick_waypoint() -> void:
	if _waypoints.is_empty():
		_target = global_position
		return
	var index := randi() % _waypoints.size()
	_target = _waypoints[index]
	if _target.is_equal_approx(global_position) and _waypoints.size() > 1:
		_target = _waypoints[(index + 1) % _waypoints.size()]


func _set_state(next_state: String) -> void:
	if state == next_state:
		return
	state = next_state
	state_changed.emit(state)


# --- 视觉 ---------------------------------------------------------------------

func _ensure_visual() -> void:
	if _visual_built or not is_inside_tree():
		return
	_visual_built = true
	var body_color := Color(0.9, 0.45, 0.2) if personality == PERSONALITY_RECKLESS \
		else Color(0.25, 0.65, 0.9)
	var collision := CollisionShape3D.new()
	collision.name = "NpcCollision"
	var capsule_shape := CapsuleShape3D.new()
	capsule_shape.radius = 0.3
	capsule_shape.height = 1.55
	collision.shape = capsule_shape
	collision.position.y = 0.85
	add_child(collision)

	_body_mesh = MeshInstance3D.new()
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.35
	capsule.height = 1.4
	_body_mesh.mesh = capsule
	_body_mesh.position.y = 0.9
	_body_mesh.material_override = _material(body_color)
	add_child(_body_mesh)

	_head_mesh = MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.28
	sphere.height = 0.56
	_head_mesh.mesh = sphere
	_head_mesh.position.y = 1.72
	_head_mesh.material_override = _material(body_color.lightened(0.2))
	add_child(_head_mesh)

	var label := Label3D.new()
	label.text = "%s（%s）" % [npc_id, "莽撞" if personality == PERSONALITY_RECKLESS else "谨慎"]
	label.position.y = 2.2
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.font_size = 36
	label.modulate = body_color
	add_child(label)

	_cone = MeshInstance3D.new()
	var cone_mesh := CylinderMesh.new()
	cone_mesh.radial_segments = 20
	cone_mesh.rings = 1
	cone_mesh.height = vision_range
	cone_mesh.top_radius = tan(deg_to_rad(vision_half_angle)) * vision_range
	cone_mesh.bottom_radius = 0.05
	_cone.mesh = cone_mesh
	_cone.rotation_degrees.x = 90.0
	_cone.position = Vector3(0, 1.4, -vision_range * 0.5)
	_cone.material_override = _cone_material(body_color)
	add_child(_cone)


func _update_cone_visual() -> void:
	if _cone == null:
		return
	_cone.visible = true


## 替换 primitive avatar（GLB 模型由 room_demo 加载）；视锥和名字标签保留。
func attach_avatar(avatar: Node3D) -> void:
	if avatar == null:
		return
	_avatar = avatar
	add_child(avatar)
	if _body_mesh != null:
		_body_mesh.visible = false
	if _head_mesh != null:
		_head_mesh.visible = false


func has_avatar() -> bool:
	return _avatar != null


func _material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.8
	return material


func _cone_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = Color(color.r, color.g, color.b, 0.16)
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.no_depth_test = false
	return material
