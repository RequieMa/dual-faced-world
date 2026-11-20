extends RefCounted
## W7 录像潜入的检测子模型（契约见 Issue #17 / docs/MECHANICS_CONTRACTS.md §8）。
##
## 只消费 W5 的 VisionCone 鸭子类型接口（`sees(point) -> bool`），在锥形判定之上
## 叠加三个**全部可配**的修正项：
##   - 遮挡 occlusion_factor：0 = 完全挡住（默认），1 = 忽略遮挡；
##   - 蹲伏 crouch_factor：1 = 蹲下不减暴露度，默认 0.4 会让蹲伏落到阈值以下；
##   - 噪音 noise_threshold：锥内噪音达到阈值时按声音暴露（隔墙也能听见）。
##
## 判定规则：
##   1）锥外一律不检测（验收：锥外不检测，噪音再大也不越过锥形硬门槛）；
##   2）锥内视觉分 = 1 × 蹲伏修正 × 遮挡修正，≥ detect_threshold 即暴露；
##   3）锥内噪音 ≥ noise_threshold 也暴露（给「蹲伏/找掩体但弄出动静」用）。
##
## 不做任何物理查询：输入只有位置/朝向数据（锥体内部按位置/朝向计算），所以 W7
## 可以用假 VisionCone 单测，真实 W5 锥体联调放 W12。
##
## 失败语义按契约 §0：配置错误写 last_errors 并发 definition_error（不在此 push_warning，
## 是否记日志由调用方决定）；运行时非法调用只 push_warning，不污染配置错误列表。

signal definition_error(message: String)

const DEFAULT_CONFIG := {
	"detect_threshold": 0.5,
	"crouch_factor": 0.4,
	"occlusion_factor": 0.0,
	"noise_threshold": 1.0,
}
const CONFIG_KEYS: Array[String] = [
	"detect_threshold",
	"crouch_factor",
	"occlusion_factor",
	"noise_threshold",
]

## 最近一次 configure 的非法值原因（合法 configure 会清空）。
var last_errors: Array[String] = []

var _config: Dictionary = {}


func _init() -> void:
	_config = DEFAULT_CONFIG.duplicate()


## 覆盖检测参数；非法值保留默认值并记 last_errors + definition_error，不抛错。
func configure(config: Dictionary) -> void:
	last_errors.clear()
	for key in CONFIG_KEYS:
		if not config.has(key):
			continue
		var raw: Variant = config[key]
		if not (raw is float or raw is int):
			_config_error("配置 %s 必须是数字" % key)
			continue
		var value := float(raw)
		if not is_finite(value):
			_config_error("配置 %s 必须是有限数" % key)
			continue
		if key == "crouch_factor" or key == "occlusion_factor":
			if value < 0.0 or value > 1.0:
				_config_error("配置 %s 必须在 0..1 之间" % key)
				continue
		elif value <= 0.0:
			_config_error("配置 %s 必须大于 0" % key)
			continue
		_config[key] = value
	# 未知键只告警不阻断，保持对更新版本配置的向前兼容。
	for key in config.keys():
		if not CONFIG_KEYS.has(key):
			_runtime_warning("未知配置键: %s" % key)


## 返回当前检测参数的副本（外部改动不会污染模型）。
func get_config() -> Dictionary:
	return _config.duplicate()


## 对单个 actor 位置做一次检测。context 可含：
##   {"crouching": bool, "occluded": bool, "noise": float}
## 返回 {"seen", "in_cone", "visual_score", "visual_seen", "noise_seen", "noise", "reason"}。
func evaluate(cone, point: Vector3, context: Dictionary = {}) -> Dictionary:
	if cone == null or not cone.has_method("sees"):
		_runtime_warning("VisionCone 必须提供 sees(point) 方法")
		return _result(false, false, 0.0, false, false, 0.0, "invalid_cone")

	if not bool(cone.sees(point)):
		return _result(false, false, 0.0, false, false, _read_noise(context), "outside_cone")

	var crouching := bool(context.get("crouching", false))
	var occluded := bool(context.get("occluded", false))
	var noise := _read_noise(context)

	var visual_score := 1.0
	if crouching:
		visual_score *= float(_config["crouch_factor"])
	if occluded:
		visual_score *= float(_config["occlusion_factor"])

	var visual_seen := visual_score >= float(_config["detect_threshold"])
	var noise_seen := noise >= float(_config["noise_threshold"])
	var reason := "concealed"
	if visual_seen:
		reason = "visual"
	elif noise_seen:
		reason = "noise"
	return _result(visual_seen or noise_seen, true, visual_score, visual_seen, noise_seen, noise, reason)


# --- 内部 ---------------------------------------------------------------------

func _result(seen: bool, in_cone: bool, visual_score: float, visual_seen: bool,
		noise_seen: bool, noise: float, reason: String) -> Dictionary:
	return {
		"seen": seen,
		"in_cone": in_cone,
		"visual_score": visual_score,
		"visual_seen": visual_seen,
		"noise_seen": noise_seen,
		"noise": noise,
		"reason": reason,
	}


func _read_noise(context: Dictionary) -> float:
	var raw: Variant = context.get("noise", 0.0)
	if raw is float or raw is int:
		return maxf(0.0, float(raw))
	return 0.0


func _config_error(message: String) -> void:
	last_errors.append(message)
	definition_error.emit(message)


func _runtime_warning(message: String) -> void:
	push_warning("DetectionModel: " + message)
