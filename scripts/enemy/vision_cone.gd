extends Node
## W5 视锥（docs/MECHANICS_CONTRACTS.md §8）：敌人视野的纯几何判定。
##
## 所有权：EnemyPatrol 持有一个实例并通过 getter 把自身位置/朝向喂进来；
## W7 的 StealthModel/DetectionModel 只消费 `sees(point) -> bool` 鸭子类型。
##
## 约束：
## - `sees` 必须是纯函数（给定原点/朝向/点即可判定），不依赖帧、不碰物理引擎；
## - 遮挡判定由宿主注入回调（W12 可用射线/地图数据实现），
##   这样单测不需要真实场景，也避免把碰撞层约定写死在 W5 里；
## - 不新增 autoload。

const DEFAULT_HALF_ANGLE_DEG := 45.0
const DEFAULT_RANGE_M := 10.0
## 浮点累计误差：射程/角度边界允许一点点过冲，避免 45° 恰好被判成锥外。
const TIME_EPSILON := 0.000001
const ANGLE_EPSILON := 0.001

## 每帧读取，而不是 setup 时快照：巡逻移动后视锥必须跟着走。
var _origin_getter: Callable
var _direction_getter: Callable
## 可选：返回 true 表示该点被墙/障碍挡住。空 Callable = 不做遮挡判定。
var _occlusion_check: Callable
var _half_angle_deg := DEFAULT_HALF_ANGLE_DEG
var _range_m := DEFAULT_RANGE_M
var _configured := false


## 配置锥体。签名与 W0 §8 一致；参数非法时保留原值并 push_warning（运行时非法调用，非配置错误）。
func setup(origin_getter: Callable, direction_getter: Callable,
		half_angle_deg: float, range_m: float) -> void:
	_origin_getter = origin_getter
	_direction_getter = direction_getter
	_configured = true
	if not _origin_getter.is_valid() or not _direction_getter.is_valid():
		push_warning("VisionCone.setup: origin/direction getter 无效，视锥将始终不可见")
		return
	if half_angle_deg <= 0.0 or half_angle_deg > 180.0:
		push_warning("VisionCone.setup: half_angle_deg 必须在 (0, 180]，保留 %.1f"
			% _half_angle_deg)
		return
	if range_m <= 0.0:
		push_warning("VisionCone.setup: range_m 必须为正，保留 %.1f" % _range_m)
		return
	_half_angle_deg = half_angle_deg
	_range_m = range_m


## 注入/清除遮挡回调。回调形状：func(point: Vector3) -> bool（true = 被挡住）。
func set_occlusion_check(check: Callable) -> void:
	_occlusion_check = check


## 点是否在视锥内且未被遮挡。未 setup 时一律 false（安全默认）。
func sees(point: Vector3) -> bool:
	if not _configured:
		return false
	if not _origin_getter.is_valid() or not _direction_getter.is_valid():
		return false
	var origin_value: Variant = _origin_getter.call()
	var direction_value: Variant = _direction_getter.call()
	if not origin_value is Vector3 or not direction_value is Vector3:
		return false
	var origin: Vector3 = origin_value
	var direction: Vector3 = direction_value
	var offset := point - origin
	var distance := offset.length()
	if distance > _range_m + TIME_EPSILON:
		return false
	# 原点（敌人脚下）永远算可见，否则贴脸目标会被零向量判成锥外。
	if distance <= TIME_EPSILON:
		return not _is_occluded(point)
	if direction.length_squared() <= TIME_EPSILON:
		return false
	var angle := rad_to_deg(direction.normalized().angle_to(offset.normalized()))
	if angle > _half_angle_deg + ANGLE_EPSILON:
		return false
	return not _is_occluded(point)


## 调试/联调快照；无效 getter 时 origin/direction 返回零向量，便于宿主排查。
func get_debug_state() -> Dictionary:
	var origin := Vector3.ZERO
	var direction := Vector3.ZERO
	if _origin_getter.is_valid():
		var origin_value: Variant = _origin_getter.call()
		if origin_value is Vector3:
			origin = origin_value
	if _direction_getter.is_valid():
		var direction_value: Variant = _direction_getter.call()
		if direction_value is Vector3:
			direction = direction_value
	return {
		"origin": origin,
		"direction": direction,
		"half_angle_deg": _half_angle_deg,
		"range_m": _range_m,
		"configured": _configured,
	}


func _is_occluded(point: Vector3) -> bool:
	if not _occlusion_check.is_valid():
		return false
	return bool(_occlusion_check.call(point))
