extends CharacterBody3D
## 观察房间里的两个 NPC（primitive 占位或 GLB avatar）。
##
## - 视觉：每台 NPC 用带阴影的 SpotLight3D 做视锥（阴影保证光只停在第一个面）；
## - 感知：3D 锥角 + 射线遮挡，墙/家具后的目标不可见；
## - 行为：走走停停，停下时视线偶尔左右/上下扫视；
## - 移动：加速/减速 + 身体轻微起伏，不是瞬间平移。
##
## 用 CharacterBody3D + move_and_slide 移动，墙体/家具的 StaticBody3D 会挡住 NPC。
## 宿主每帧 tick(delta)；测试可读 get_state() 的 look/moving 字段。

signal clue_collected(clue_id: String, position: Vector3)
signal state_changed(state: String)

const PERSONALITY_RECKLESS := "reckless"
const PERSONALITY_CAUTIOUS := "cautious"

const STATE_WANDER := "wander"
const STATE_PAUSE := "pause"
const STATE_SEEK := "seek"
const STATE_SEARCH := "search"

const ARRIVE_EPSILON := 0.08
const AUTO_SEEK_RADIUS := 2.0
const NPC_ACCEL := 5.0
const NPC_DECEL := 8.0
const EYE_HEIGHT := 1.45
const WALK_BOB_HEIGHT := 0.018
const WALK_BOB_FREQ := 7.0
# 只缩放 SpotLight 的照明范围/角度，不影响 vision_range / 视锥检测参数。
const SPOT_RANGE_SCALE := 0.6
const SPOT_ANGLE_SCALE := 0.6
const LOOK_YAW_DEG := 24.0
const LOOK_PITCH_DEG := 7.0

var npc_id := ""
var personality := PERSONALITY_CAUTIOUS
var state := STATE_WANDER
var speed := 1.2
var signal_range := 20.0
var vision_range := 6.0
var vision_half_angle := 30.0

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

var _visual_root: Node3D = null
var _vision_pivot: Node3D = null
var _spotlight: SpotLight3D = null
var _cone_visual: MeshInstance3D = null
var _vision_length := 0.0
var _body_mesh: MeshInstance3D = null
var _head_mesh: MeshInstance3D = null
var _avatar: Node3D = null
var _walk_phase := 0.0
var _look_yaw := 0.0
var _look_pitch := 0.0
var _look_target_yaw := 0.0
var _look_target_pitch := 0.0
var _look_timer := 0.0

var _signal_search_time := 1.2
var _waste_limit := 3
var _ignore_seconds := 12.0


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
	state = STATE_PAUSE
	_state_time = randf_range(0.8, 2.0)
	_search_remaining = 0.0
	_now = 0.0
	_ignore_until = 0.0
	_wasted = 0
	_signal_active = false
	_seeking_clue_id = ""
	_walk_phase = 0.0
	_look_yaw = 0.0
	_look_pitch = 0.0
	_look_target_yaw = 0.0
	_look_target_pitch = 0.0
	_look_timer = randf_range(1.0, 2.0)
	if personality == PERSONALITY_RECKLESS:
		speed = 1.65
		vision_range = 5.5
		vision_half_angle = 32.0
		signal_range = 12.0
		_signal_search_time = 1.2
		_waste_limit = 3
		_ignore_seconds = 12.0
	else:
		speed = 0.60
		vision_range = 6.5
		vision_half_angle = 34.0
		signal_range = 15.0
		_signal_search_time = 4.0
		_waste_limit = 0
		_ignore_seconds = 0.0
	_ensure_visual()
	_update_vision_visual()


func _ready() -> void:
	_ensure_visual()


func tick(delta: float, clues: Array) -> void:
	if delta <= 0.0:
		return
	_now += delta
	_update_vision_look(delta)
	_update_vision_visual()
	match state:
		STATE_WANDER:
			_tick_wander(delta, clues)
		STATE_PAUSE:
			_tick_pause(delta, clues)
		STATE_SEEK:
			_tick_seek(delta, clues)
		STATE_SEARCH:
			_tick_search(delta, clues)
	_update_walk_animation(delta)


## 收到玩家激光/截图信号。超出范围或仍在“忽略期”返回 false。
func receive_signal(point: Vector3, now: float = -1.0) -> bool:
	if global_position.distance_to(point) > signal_range:
		return false
	return _accept_signal(point, now)


## 激光射线与视锥相交才响应；不能只按落点距离判断。
func receive_laser(ray_origin: Vector3, ray_end: Vector3, now: float = -1.0) -> bool:
	if not _ray_intersects_vision_cone(ray_origin, ray_end):
		return false
	return _accept_signal(ray_end, now)


func _accept_signal(point: Vector3, now: float) -> bool:
	var at := _now if now < 0.0 else now
	if at < _ignore_until:
		return false
	_target = Vector3(point.x, global_position.y, point.z)
	_signal_active = true
	_seeking_clue_id = ""
	_set_state(STATE_SEEK)
	return true


## 有限线段与有限视锥（顶点在眼睛、轴为视向、半角 vision_half_angle）求交。
func _ray_intersects_vision_cone(ray_origin: Vector3, ray_end: Vector3) -> bool:
	var apex := _vision_origin()
	var axis := _vision_forward()
	if axis.length_squared() < 0.0001:
		return false
	var height := _vision_length
	if height <= 0.01:
		height = vision_range
	var k := tan(deg_to_rad(vision_half_angle))

	var v := ray_origin - apex
	var w := ray_end - ray_origin
	var dv := w.dot(axis)
	var c := v.dot(axis)
	var v_perp := v - axis * c
	var w_perp := w - axis * dv
	var a := w_perp.length_squared() - k * k * dv * dv
	var b := 2.0 * (v_perp.dot(w_perp) - k * k * c * dv)
	var d := v_perp.length_squared() - k * k * c * c

	if _point_in_vision_cone(ray_origin, apex, axis, height, k) 			or _point_in_vision_cone(ray_end, apex, axis, height, k):
		return true
	if absf(a) < 0.00001:
		if absf(b) < 0.00001:
			return false
		var t := -d / b
		return t >= 0.0 and t <= 1.0 and _point_in_vision_cone(ray_origin + w * t, apex, axis, height, k)
	var disc := b * b - 4.0 * a * d
	if disc < 0.0:
		return false
	var root := sqrt(disc)
	for t in [(-b - root) / (2.0 * a), (-b + root) / (2.0 * a)]:
		if t >= 0.0 and t <= 1.0 and _point_in_vision_cone(ray_origin + w * t, apex, axis, height, k):
			return true
	return false


func _point_in_vision_cone(point: Vector3, apex: Vector3, axis: Vector3,
		height: float, k: float) -> bool:
	var offset := point - apex
	var axial := offset.dot(axis)
	if axial < 0.0 or axial > height:
		return false
	return (offset - axis * axial).length() <= k * axial


## 目标点是否在视锥内，且到目标点的射线不被墙/家具挡住。
func sees_point(point: Vector3) -> bool:
	var origin := _vision_origin()
	var offset := point - origin
	var distance := offset.length()
	if distance > vision_range or distance <= 0.01:
		return false
	var forward := _vision_forward()
	var angle := rad_to_deg(forward.angle_to(offset.normalized()))
	if angle > vision_half_angle:
		return false
	return _has_line_of_sight(origin, point, distance)


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
		"moving_speed": Vector2(velocity.x, velocity.z).length(),
		"look_yaw": _look_yaw,
		"look_pitch": _look_pitch,
		"wasted_signals": _wasted,
		"ignoring": is_ignoring_signals(),
		"vision_range": vision_range,
		"vision_half_angle": vision_half_angle,
		"vision_length": _vision_length,
	}


# --- 内部状态机 ---------------------------------------------------------------

func _tick_wander(delta: float, clues: Array) -> void:
	if _try_seek_visible_clue(clues):
		return
	if _move_toward(_target, speed, delta):
		_state_time = randf_range(2.2, 4.5) if personality == PERSONALITY_RECKLESS \
			else randf_range(3.0, 5.5)
		_set_state(STATE_PAUSE)


func _tick_pause(delta: float, clues: Array) -> void:
	if _try_seek_visible_clue(clues):
		return
	_decelerate(delta)
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
	if not near.is_empty() and _can_reach_clue(near):
		_collect_clue(near)
		return
	_decelerate(delta)
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


func _can_reach_clue(clue: Dictionary) -> bool:
	var point: Vector3 = clue.get("position", Vector3.ZERO)
	var origin := _vision_origin()
	var distance := origin.distance_to(point)
	return distance > 0.01 and _has_line_of_sight(origin, point, distance)


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


## 带加速/减速的移动；被墙/家具挡住时返回 true，让状态机换目标。
func _move_toward(point: Vector3, move_speed: float, delta: float) -> bool:
	var offset := point - global_position
	offset.y = 0.0
	var distance := offset.length()
	if distance <= ARRIVE_EPSILON:
		_decelerate(delta)
		return true
	_face_toward(point)
	var direction := offset.normalized()
	velocity.x = move_toward(velocity.x, direction.x * move_speed, NPC_ACCEL * delta)
	velocity.z = move_toward(velocity.z, direction.z * move_speed, NPC_ACCEL * delta)
	var before := global_position
	move_and_slide()
	var moved := Vector2(global_position.x - before.x, global_position.z - before.z).length()
	if moved < 0.0001:
		velocity = Vector3.ZERO
		return true
	return distance - moved <= ARRIVE_EPSILON


func _decelerate(delta: float) -> void:
	velocity.x = move_toward(velocity.x, 0.0, NPC_DECEL * delta)
	velocity.z = move_toward(velocity.z, 0.0, NPC_DECEL * delta)
	move_and_slide()


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


# --- 视线/扫视 ---------------------------------------------------------------

func _vision_origin() -> Vector3:
	if _vision_pivot != null:
		return _vision_pivot.global_position
	return global_position + Vector3(0, EYE_HEIGHT, 0)


func _vision_forward() -> Vector3:
	if _vision_pivot != null:
		return -_vision_pivot.global_transform.basis.z.normalized()
	var flat := -global_transform.basis.z
	flat.y = 0.0
	return flat.normalized()


func _has_line_of_sight(origin: Vector3, point: Vector3, distance: float) -> bool:
	if not is_inside_tree():
		return true
	var world := get_world_3d()
	if world == null:
		return true
	var space := world.direct_space_state
	if space == null:
		return true
	var query := PhysicsRayQueryParameters3D.create(origin, point)
	query.exclude = [get_rid()]
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		return true
	# 命中点明显在目标之前 = 被挡住；贴脸的端点/地面不算遮挡。
	return origin.distance_to(hit["position"]) >= distance - 0.02


## 大部分时间看正前方，间歇性左右/上下扫视，幅度不大。
func _update_vision_look(delta: float) -> void:
	_look_timer -= delta
	if _look_timer <= 0.0:
		if randf() < 0.62:
			_look_target_yaw = 0.0
			_look_target_pitch = 0.0
			_look_timer = randf_range(2.0, 4.0)
		else:
			_look_target_yaw = deg_to_rad(randf_range(-LOOK_YAW_DEG, LOOK_YAW_DEG))
			_look_target_pitch = deg_to_rad(randf_range(-LOOK_PITCH_DEG, LOOK_PITCH_DEG))
			_look_timer = randf_range(0.9, 1.8)
	var weight := clampf(delta * 4.0, 0.0, 1.0)
	_look_yaw = lerp_angle(_look_yaw, _look_target_yaw, weight)
	_look_pitch = lerpf(_look_pitch, _look_target_pitch, weight)
	if _vision_pivot != null:
		_vision_pivot.rotation = Vector3(_look_pitch, _look_yaw, 0.0)


# --- 视觉 ---------------------------------------------------------------------

func _ensure_visual() -> void:
	if _visual_built or not is_inside_tree():
		return
	_visual_built = true
	var body_color := Color(0.9, 0.45, 0.2) if personality == PERSONALITY_RECKLESS \
		else Color(0.25, 0.65, 0.9)

	_visual_root = Node3D.new()
	_visual_root.name = "Visual"
	add_child(_visual_root)

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
	_body_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_visual_root.add_child(_body_mesh)

	_head_mesh = MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.28
	sphere.height = 0.56
	_head_mesh.mesh = sphere
	_head_mesh.position.y = 1.72
	_head_mesh.material_override = _material(body_color.lightened(0.2))
	_head_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_visual_root.add_child(_head_mesh)

	var label := Label3D.new()
	label.text = "%s（%s）" % [npc_id, "莽撞" if personality == PERSONALITY_RECKLESS else "谨慎"]
	label.position.y = 2.2
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.font_size = 36
	label.modulate = body_color
	_visual_root.add_child(label)

	_vision_pivot = Node3D.new()
	_vision_pivot.name = "VisionPivot"
	_vision_pivot.position = Vector3(0, EYE_HEIGHT, 0)
	add_child(_vision_pivot)

	_spotlight = SpotLight3D.new()
	_spotlight.name = "VisionSpot"
	_spotlight.light_color = body_color.lightened(0.25)
	_spotlight.light_energy = 2.0
	_spotlight.spot_range = vision_range * SPOT_RANGE_SCALE
	_spotlight.spot_angle = vision_half_angle * 2.0 * SPOT_ANGLE_SCALE
	_spotlight.spot_angle_attenuation = 1.0
	_spotlight.shadow_enabled = true
	_spotlight.shadow_bias = 0.02
	# 只要直接照射，不参与 GI/间接光。
	if "light_indirect_energy" in _spotlight:
		_spotlight.light_indirect_energy = 0.0
	if "light_volumetric_fog_energy" in _spotlight:
		_spotlight.light_volumetric_fog_energy = 0.0
	# 保持在眼位；依靠 body/head/avatar 关闭投影避免自遮挡，避免灯跑进墙里。
	_spotlight.position = Vector3.ZERO
	_vision_pivot.add_child(_spotlight)

	# 只画很短的一段锥体做方向提示，避免遮住监控画面；真实遮挡靠 spotlight 阴影。
	_cone_visual = MeshInstance3D.new()
	_cone_visual.name = "VisionCone"
	var cone_mesh := CylinderMesh.new()
	cone_mesh.height = 1.0
	cone_mesh.top_radius = 0.02
	cone_mesh.bottom_radius = tan(deg_to_rad(vision_half_angle))
	cone_mesh.radial_segments = 16
	cone_mesh.rings = 1
	cone_mesh.cap_top = false
	cone_mesh.cap_bottom = false
	_cone_visual.mesh = cone_mesh
	_cone_visual.rotation_degrees.x = 90.0
	_cone_visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var cone_material := StandardMaterial3D.new()
	cone_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	cone_material.albedo_color = Color(body_color.r, body_color.g, body_color.b, 0.8)
	cone_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	cone_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_cone_visual.material_override = cone_material
	_vision_pivot.add_child(_cone_visual)
	# 可见圆锥太干扰监控画面；只保留 spotlight 照明，圆锥 mesh 隐藏。
	_cone_visual.visible = false

	_update_vision_visual()


func _update_vision_visual() -> void:
	if _spotlight == null:
		return
	_spotlight.spot_range = vision_range * SPOT_RANGE_SCALE
	_spotlight.spot_angle = vision_half_angle * 2.0 * SPOT_ANGLE_SCALE
	_vision_length = _first_visible_distance()
	if _cone_visual != null and _cone_visual.mesh is CylinderMesh:
		var cone_mesh := _cone_visual.mesh as CylinderMesh
		cone_mesh.bottom_radius = tan(deg_to_rad(vision_half_angle))
		cone_mesh.top_radius = 0.02
	if _cone_visual != null:
		# 一直画到第一个遮挡物；没有遮挡就画满视距。
		var visual_length := maxf(_vision_length, 0.12)
		_cone_visual.scale = Vector3(visual_length, visual_length, visual_length)
		_cone_visual.position = Vector3(0, 0, -visual_length * 0.5)


## 从眼睛沿当前视线打一条射线，返回第一个遮挡物距离（没有就返回射程）。
func _first_visible_distance() -> float:
	if _vision_pivot == null or not is_inside_tree():
		return vision_range
	var world := get_world_3d()
	if world == null:
		return vision_range
	var origin := _vision_pivot.global_position
	var target := origin + _vision_forward() * vision_range
	var query := PhysicsRayQueryParameters3D.create(origin, target)
	query.exclude = [get_rid()]
	var hit := world.direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return vision_range
	return clampf(origin.distance_to(hit["position"]), 0.12, vision_range)


## 走路时身体/avatar 轻微起伏，停下回正；碰撞体不动。
func _update_walk_animation(delta: float) -> void:
	if _visual_root == null:
		return
	var horizontal := Vector2(velocity.x, velocity.z).length()
	if horizontal > 0.08:
		_walk_phase += delta * (WALK_BOB_FREQ + horizontal * 1.5)
		var bob := sin(_walk_phase) * WALK_BOB_HEIGHT
		_visual_root.position = Vector3(0, bob, 0)
	else:
		_visual_root.position = _visual_root.position.lerp(Vector3.ZERO, clampf(delta * 8.0, 0.0, 1.0))


## 替换 primitive avatar（GLB 模型由 room_demo 加载）；视锥和名字标签保留。
func attach_avatar(avatar: Node3D) -> void:
	if avatar == null:
		return
	_ensure_visual()
	if _visual_root == null:
		add_child(avatar)
	else:
		_visual_root.add_child(avatar)
	_avatar = avatar
	_disable_shadow_casting(avatar)
	if _body_mesh != null:
		_body_mesh.visible = false
	if _head_mesh != null:
		_head_mesh.visible = false


## avatar 的 GLB 网格也不投影，避免眼位 spotlight 被自身模型挡住。
func _disable_shadow_casting(node: Node) -> void:
	if node is MeshInstance3D:
		(node as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for child in node.get_children():
		_disable_shadow_casting(child)


func has_avatar() -> bool:
	return _avatar != null


func _material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.8
	return material
