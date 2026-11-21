extends Node
## W7 录像潜入（潜行规则）主模型。契约见 Issue #17 / docs/MECHANICS_CONTRACTS.md §0、§8。
##
## 职责：
##   1）持有敌人的 VisionCone（W5 契约形状，鸭子类型），每帧对每个潜入者做隐蔽判定；
##   2）维护一个纯数据噪音场：emit_noise / 蹲伏脚步 / tick 衰减，noise_at(position) 供
##      DetectionModel 的噪音修正和 W12 的联调查询；
##   3）在「隐蔽 ↔ 暴露」切换时发 detected / escaped（持续暴露不重复刷信号）。
##
## 设计约束：
##   - 不新增 autoload、不碰物理引擎；所有输入都是位置/朝向/布尔/响度数据；
##   - 不自己算锥形几何：锥内/锥外交给 W5 的 VisionCone.sees(point)，W7 只叠修正项；
##   - 由宿主每帧 tick(delta, actors) 推进，模块内部不用 _process。
##
## actors 形状（只有 position 必需；actor_id 每帧必须唯一，重复 id 会让同帧状态/信号
## 依赖数组顺序）：
##   {"id": String, "position": Vector3, "crouching": bool, "occluded": bool, "noise": float}
##   - occluded 由宿主/关卡提供（例如 W12 用地图数据判断视线是否被挡），本模块不查物理；
##   - noise 是这一帧持续发出的响度（脚步/道具），蹲伏时按
##     noise.crouch_noise_factor 打折。
##
## 生命周期：本模块不持有存档/循环状态；换局或重开时由宿主重建实例。
## 敌人被销毁前调用 remove_enemy()，避免 _enemies 里留下已释放的锥体实例。
##
## 典型装配（W12）：
##   var stealth = StealthModel.new()
##   stealth.configure({"detection": {"crouch_factor": 0.4}, "noise": {"range": 8.0}})
##   stealth.add_enemy("guard_a", vision_cone)
##   stealth.tick(delta, [{"id": "player", "position": p, "crouching": crouching}])
##
## 失败语义按契约 §0：configure 的非法值写 last_errors + definition_error（不在模块内
## push_warning）；运行时非法调用（坏 actor、未知 id、坏锥体）只 push_warning。

signal detected(actor_id: String, by_enemy: String)
signal escaped(actor_id: String)
signal definition_error(message: String)

const DetectionModel := preload("res://scripts/stealth/detection_model.gd")
const DEFAULT_NOISE := {
	"range": 8.0,
	"duration": 0.5,
	"crouch_noise_factor": 0.5,
}
const NOISE_KEYS: Array[String] = ["range", "duration", "crouch_noise_factor"]

## 最近一次 configure 的非法值原因（合法 configure 会清空）。
var last_errors: Array[String] = []

var _detection
## enemy_id -> VisionCone（只要求 sees(point)）
var _enemies: Dictionary = {}
## actor_id -> bool（true = 当前隐蔽）
var _hidden: Dictionary = {}
var _noise_config: Dictionary = {}
## source_id -> {position, loudness, remain, duration}
var _noise_sources: Dictionary = {}
var _next_noise_id := 0


func _init() -> void:
	_detection = DetectionModel.new()
	_noise_config = DEFAULT_NOISE.duplicate()


# --- 公开接口（Issue #17 契约） -----------------------------------------------

## 覆盖检测/噪音参数：
##   {"detection": {"crouch_factor": ...}, "noise": {"crouch_noise_factor": ...}}
## 检测参数也接受平铺写法（{"crouch_factor": ...}），与 DetectionModel 的习惯一致；
## 两处都写时 nested 的 detection 优先。非法值保留默认并记 last_errors，不抛错。
func configure(config: Dictionary) -> void:
	last_errors.clear()
	var detection_config: Dictionary = {}
	if config.has("detection"):
		var detection_value: Variant = config["detection"]
		if detection_value is Dictionary:
			detection_config = (detection_value as Dictionary).duplicate(true)
		else:
			_config_error("detection 配置必须是字典")
	# 平铺写法只补 nested 里没有的键，避免两种写法冲突时语义不明。
	for key in DetectionModel.CONFIG_KEYS:
		if config.has(key) and not detection_config.has(key):
			detection_config[key] = config[key]
	if not detection_config.is_empty():
		_detection.configure(detection_config)
		for message in _detection.last_errors:
			_config_error("[detection] " + String(message))

	if config.has("noise"):
		var noise_value: Variant = config["noise"]
		if noise_value is Dictionary:
			_configure_noise(noise_value)
		else:
			_config_error("noise 配置必须是字典")

	for key in config.keys():
		if key == "detection" or key == "noise" or DetectionModel.CONFIG_KEYS.has(key):
			continue
		_runtime_warning("未知配置键: %s" % key)


## 注册一个敌人的视锥；cone 只需实现 W5 契约里的 sees(point) -> bool。
func add_enemy(enemy_id: String, cone) -> bool:
	if enemy_id.strip_edges().is_empty():
		_runtime_warning("enemy_id 不能为空")
		return false
	if cone == null or not cone.has_method("sees"):
		_runtime_warning("敌人 %s 的锥体必须提供 sees(point) 方法" % enemy_id)
		return false
	_enemies[enemy_id] = cone
	return true


## 解除敌人注册（敌人节点销毁前调用，避免持有已释放实例）。
func remove_enemy(enemy_id: String) -> void:
	_enemies.erase(enemy_id)


## 注册一次性噪音（脚步/开门/道具/危险）。duration <= 0 时用噪音配置的默认时长。
func emit_noise(position: Vector3, loudness: float, duration: float = -1.0) -> void:
	if not is_finite(loudness) or loudness <= 0.0:
		return
	_add_noise_source("event:%d" % _next_noise_id, position, loudness, duration)
	_next_noise_id += 1


## 某位置的当前噪音响度：取各声源「距离衰减 × 时间衰减」后的最大值。
## 用 max 而不是 sum，避免同一声源每帧刷新导致数值累加爆掉。
func noise_at(position: Vector3) -> float:
	var best := 0.0
	var range_m := float(_noise_config["range"])
	for source in _noise_sources.values():
		var source_position: Vector3 = source["position"]
		var duration := maxf(float(source["duration"]), 0.000001)
		var remaining := maxf(float(source["remain"]), 0.0)
		var current := float(source["loudness"]) * (remaining / duration)
		var attenuation := 1.0
		if range_m > 0.0:
			attenuation = clampf(1.0 - position.distance_to(source_position) / range_m, 0.0, 1.0)
		best = maxf(best, current * attenuation)
	return best


## 推进一帧：先衰减噪音场，再登记所有 actor 噪音，最后统一判定。
## 分两遍是为了让同一帧里所有声源都对所有 actor 可见，结果不依赖 actors 数组顺序。
func tick(delta: float, actors: Array) -> void:
	if not is_finite(delta) or delta < 0.0:
		_runtime_warning("tick 的 delta 必须是非负有限数")
		delta = 0.0
	_decay_noise(delta)

	var pending: Array[Dictionary] = []
	for raw_actor in actors:
		if not raw_actor is Dictionary:
			_runtime_warning("actors 里的元素必须是字典")
			continue
		var actor: Dictionary = raw_actor
		if not actor.has("id") or not actor["id"] is String \
				or String(actor["id"]).strip_edges().is_empty():
			_runtime_warning("actor 缺少非空字符串 id")
			continue
		var actor_id := String(actor["id"])
		var position_variant: Variant = actor.get("position", null)
		if not position_variant is Vector3:
			_runtime_warning("actor %s 缺少 Vector3 position" % actor_id)
			continue
		var position: Vector3 = position_variant
		var crouching := bool(actor.get("crouching", false))
		var occluded := bool(actor.get("occluded", false))

		var noise := 0.0
		var noise_variant: Variant = actor.get("noise", 0.0)
		if noise_variant is float or noise_variant is int:
			noise = maxf(0.0, float(noise_variant))
		elif noise_variant != null:
			_runtime_warning("actor %s 的 noise 必须是数字" % actor_id)
		if noise > 0.0:
			var emitted := noise
			if crouching:
				emitted *= float(_noise_config["crouch_noise_factor"])
			_add_noise_source("actor:" + actor_id, position, emitted,
				float(_noise_config["duration"]))

		pending.append({
			"id": actor_id,
			"position": position,
			"crouching": crouching,
			"occluded": occluded,
		})

	for entry in pending:
		_evaluate_actor(String(entry["id"]), entry["position"],
			bool(entry["crouching"]), bool(entry["occluded"]))


## 该 actor 当前是否隐蔽。未 tick 登记过的 id 返回 false 并告警（契约 §0 失败语义）。
func is_hidden(actor_id: String) -> bool:
	if not _hidden.has(actor_id):
		_runtime_warning("未知 actor_id: %s（先调用 tick 登记）" % actor_id)
		return false
	return bool(_hidden[actor_id])


# --- 内部 ---------------------------------------------------------------------

func _configure_noise(config: Dictionary) -> void:
	for key in NOISE_KEYS:
		if not config.has(key):
			continue
		var raw: Variant = config[key]
		if not (raw is float or raw is int):
			_config_error("噪音配置 %s 必须是数字" % key)
			continue
		var value := float(raw)
		if not is_finite(value):
			_config_error("噪音配置 %s 必须是有限数" % key)
			continue
		if key == "crouch_noise_factor":
			if value < 0.0 or value > 1.0:
				_config_error("噪音配置 %s 必须在 0..1 之间" % key)
				continue
		elif value <= 0.0:
			_config_error("噪音配置 %s 必须大于 0" % key)
			continue
		_noise_config[key] = value
	# 未知键只告警不阻断，与 DetectionModel 的策略保持一致。
	for key in config.keys():
		if not NOISE_KEYS.has(key):
			_runtime_warning("未知噪音配置键: %s" % key)


func _evaluate_actor(actor_id: String, position: Vector3, crouching: bool, occluded: bool) -> void:
	var noise := noise_at(position)
	var by_enemy := ""
	for enemy_id in _enemies.keys():
		var cone = _enemies[enemy_id]
		var result: Dictionary = _detection.evaluate(cone, position, {
			"crouching": crouching,
			"occluded": occluded,
			"noise": noise,
		})
		if bool(result.get("seen", false)):
			by_enemy = String(enemy_id)
			break

	var was_hidden := bool(_hidden.get(actor_id, true))
	var now_hidden := by_enemy.is_empty()
	_hidden[actor_id] = now_hidden
	if not now_hidden:
		if was_hidden:
			detected.emit(actor_id, by_enemy)
	elif not was_hidden:
		escaped.emit(actor_id)


func _add_noise_source(source_id: String, position: Vector3, loudness: float,
		duration: float) -> void:
	if not is_finite(loudness) or loudness <= 0.0:
		return
	var actual_duration := duration
	if not is_finite(actual_duration) or actual_duration <= 0.0:
		actual_duration = float(_noise_config["duration"])
	_noise_sources[source_id] = {
		"position": position,
		"loudness": loudness,
		"remain": actual_duration,
		"duration": actual_duration,
	}


func _decay_noise(delta: float) -> void:
	for source_id in _noise_sources.keys():
		var source: Dictionary = _noise_sources[source_id]
		var remain := float(source["remain"]) - delta
		if remain <= 0.0:
			_noise_sources.erase(source_id)
		else:
			source["remain"] = remain


func _config_error(message: String) -> void:
	last_errors.append(message)
	definition_error.emit(message)


func _runtime_warning(message: String) -> void:
	push_warning("StealthModel: " + message)
