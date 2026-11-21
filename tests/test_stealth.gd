extends SceneTree
## W7 录像潜入（潜行规则）的自动化测试。
## 运行：godot --headless --path . --script tests/test_stealth.gd
## 退出码 0 = 全绿，1 = 有用例失败。
##
## 覆盖：DetectionModel 的锥内/锥外 + 遮挡/噪音/蹲伏三个修正项、
## StealthModel 的隐蔽/暴露切换信号、noise_at 的距离衰减与时间衰减，
## 以及按 W0 契约 §8 形状手写的假 VisionCone（只吃位置/朝向数据，不碰物理）。
##
## 按 AGENTS.md §2：本文件先于实现写（红），实现后转绿。

const DETECTION_PATH := "res://scripts/stealth/detection_model.gd"
const STEALTH_PATH := "res://scripts/stealth/stealth_model.gd"

var _failures: Array[String] = []
var _checks := 0
var _started := false


func _initialize() -> void:
	_check("存在 scripts/stealth/detection_model.gd", ResourceLoader.exists(DETECTION_PATH))
	_check("存在 scripts/stealth/stealth_model.gd", ResourceLoader.exists(STEALTH_PATH))


func _process(_delta: float) -> bool:
	if _started:
		return false
	_started = true
	# 模块缺失时只报「文件不存在」，不往下跑（否则每个用例都会二次报错）。
	if not ResourceLoader.exists(DETECTION_PATH) or not ResourceLoader.exists(STEALTH_PATH):
		_report()
		return false
	_test_fake_cone_geometry()
	_test_detection_cone_gate()
	_test_detection_noise()
	_test_detection_crouch()
	_test_detection_occlusion()
	_test_detection_config()
	_test_detection_thresholds()
	_test_error_semantics()
	_test_stealth_transitions()
	_test_stealth_noise_reveals()
	_test_stealth_modifier_config()
	_test_stealth_flat_config()
	_test_config_precedence()
	_test_tick_order_independent()
	_test_remove_enemy()
	_test_noise_field()
	_report()
	return false


# --- 假 VisionCone（W0 §8 形状） ----------------------------------------------

class FakeVisionCone:
	## 手写假锥体：setup 收 origin/direction 的 getter（与 W5 契约一致），
	## sees 只在位置/朝向上做纯几何判定，便于在没有 W5 实现时单测 W7。
	var _origin_getter: Callable
	var _direction_getter: Callable
	var half_angle_deg := 45.0
	var range_m := 10.0
	## 非 null 时强制返回该布尔值（模拟 W5 的异常/特例，而不改本模块）。
	var forced: Variant = null

	func setup(origin_getter: Callable, direction_getter: Callable,
			half_angle_deg_value: float, range_m_value: float) -> void:
		_origin_getter = origin_getter
		_direction_getter = direction_getter
		half_angle_deg = half_angle_deg_value
		range_m = range_m_value

	func sees(point: Vector3) -> bool:
		if forced != null:
			return bool(forced)
		if not _origin_getter.is_valid() or not _direction_getter.is_valid():
			return false
		var origin: Vector3 = _origin_getter.call()
		var direction: Vector3 = _direction_getter.call()
		var to_point := point - origin
		if to_point.length() > range_m:
			return false
		if to_point.length_squared() <= 0.000001:
			return true
		if direction.length_squared() <= 0.000001:
			return false
		var angle := rad_to_deg(direction.normalized().angle_to(to_point.normalized()))
		return angle <= half_angle_deg

	func get_debug_state() -> Dictionary:
		return {"half_angle_deg": half_angle_deg, "range_m": range_m}


func _make_cone(origin: Vector3, direction: Vector3, half_angle := 45.0, range_m := 10.0):
	var cone := FakeVisionCone.new()
	cone.setup(func() -> Vector3: return origin, func() -> Vector3: return direction,
		half_angle, range_m)
	return cone


# --- DetectionModel -----------------------------------------------------------

func _test_fake_cone_geometry() -> void:
	var cone = _make_cone(Vector3.ZERO, Vector3(0, 0, -1))
	_check("假锥体：正前方 5m 在锥内", cone.sees(Vector3(0, 0, -5)))
	_check("假锥体：背后 5m 在锥外", not cone.sees(Vector3(0, 0, 5)))
	_check("假锥体：超出射程在锥外", not cone.sees(Vector3(0, 0, -11)))
	var turned = _make_cone(Vector3.ZERO, Vector3(1, 0, 0))
	_check("假锥体：朝向改变后原方向在锥外", not turned.sees(Vector3(0, 0, -5)))
	_check("假锥体：朝向改变后新方向在锥内", turned.sees(Vector3(5, 0, 0)))


func _test_detection_cone_gate() -> void:
	var model = load(DETECTION_PATH).new()
	var cone = _make_cone(Vector3.ZERO, Vector3(0, 0, -1))
	var inside: Dictionary = model.evaluate(cone, Vector3(0, 0, -5), {})
	_check("DetectionModel：锥内站立 → 暴露", bool(inside["seen"]))
	var outside: Dictionary = model.evaluate(cone, Vector3(0, 0, 5), {"noise": 99.0})
	_check("DetectionModel：锥外即便噪音爆表也不检测", not bool(outside["seen"]))
	_check("DetectionModel：锥外原因标记正确", String(outside["reason"]) == "outside_cone")
	_check("DetectionModel：锥外 in_cone=false", not bool(outside["in_cone"]))
	_check("DetectionModel：锥外 noise_seen=false", not bool(outside["noise_seen"]))
	_check("DetectionModel：锥外仍报告当前位置噪音",
		is_equal_approx(float(outside["noise"]), 99.0))


func _test_detection_noise() -> void:
	var model = load(DETECTION_PATH).new()
	var cone = _make_cone(Vector3.ZERO, Vector3(0, 0, -1))
	var point := Vector3(0, 0, -5)
	var quiet: Dictionary = model.evaluate(cone, point, {"crouching": true, "noise": 0.2})
	_check("DetectionModel：噪音低于阈值时蹲伏仍隐蔽", not bool(quiet["seen"]))
	var loud: Dictionary = model.evaluate(cone, point, {"crouching": true, "noise": 1.5})
	_check("DetectionModel：锥内 + 噪音超阈值 → 暴露", bool(loud["seen"]))
	_check("DetectionModel：噪音超阈值时 noise_seen=true", bool(loud["noise_seen"]))
	_check("DetectionModel：噪音超阈值时原因标记 noise", String(loud["reason"]) == "noise")


func _test_detection_crouch() -> void:
	var model = load(DETECTION_PATH).new()
	var cone = _make_cone(Vector3.ZERO, Vector3(0, 0, -1))
	var point := Vector3(0, 0, -5)
	var crouched: Dictionary = model.evaluate(cone, point, {"crouching": true})
	_check("DetectionModel：默认蹲伏修正 → 隐蔽", not bool(crouched["seen"]))
	_check("DetectionModel：蹲伏视觉分低于阈值", float(crouched["visual_score"]) < 1.0)
	model.configure({"crouch_factor": 1.0})
	var non_reducing: Dictionary = model.evaluate(cone, point, {"crouching": true})
	_check("DetectionModel：蹲伏修正可配（1.0 = 蹲伏不减）", bool(non_reducing["seen"]))


func _test_detection_occlusion() -> void:
	var model = load(DETECTION_PATH).new()
	var cone = _make_cone(Vector3.ZERO, Vector3(0, 0, -1))
	var point := Vector3(0, 0, -5)
	var blocked: Dictionary = model.evaluate(cone, point, {"occluded": true})
	_check("DetectionModel：默认遮挡修正 → 隐蔽", not bool(blocked["seen"]))
	_check("DetectionModel：遮挡时视觉分为 0", is_equal_approx(float(blocked["visual_score"]), 0.0))
	model.configure({"occlusion_factor": 1.0})
	_check("DetectionModel：遮挡修正可配（1.0 = 忽略遮挡）",
		bool(model.evaluate(cone, point, {"occluded": true})["seen"]))
	model.configure({"occlusion_factor": 0.6})
	_check("DetectionModel：遮挡修正可配（0.6 时视觉分 0.6 仍可见）",
		bool(model.evaluate(cone, point, {"occluded": true})["seen"]))
	model.configure({"occlusion_factor": 0.0})
	_check("DetectionModel：遮挡修正改回 0 后再次挡住",
		not bool(model.evaluate(cone, point, {"occluded": true})["seen"]))


func _test_detection_config() -> void:
	var model = load(DETECTION_PATH).new()
	var defaults: Dictionary = model.get_config()
	_check("DetectionModel：三个修正项默认存在",
		defaults.has("crouch_factor") and defaults.has("occlusion_factor")
		and defaults.has("noise_threshold"))
	model.configure({
		"detect_threshold": 0.2,
		"crouch_factor": 0.1,
		"occlusion_factor": 0.25,
		"noise_threshold": 0.5,
	})
	var configured: Dictionary = model.get_config()
	_check("DetectionModel：configure 写入 detect_threshold",
		is_equal_approx(float(configured["detect_threshold"]), 0.2))
	_check("DetectionModel：configure 写入 crouch_factor",
		is_equal_approx(float(configured["crouch_factor"]), 0.1))
	_check("DetectionModel：configure 写入 occlusion_factor",
		is_equal_approx(float(configured["occlusion_factor"]), 0.25))
	_check("DetectionModel：configure 写入 noise_threshold",
		is_equal_approx(float(configured["noise_threshold"]), 0.5))
	configured["crouch_factor"] = 0.9
	_check("DetectionModel：get_config 返回副本",
		is_equal_approx(float(model.get_config()["crouch_factor"]), 0.1))


func _test_detection_thresholds() -> void:
	# 不只断言 get_config，还要证明阈值真的参与判定（防「只写配置不生效」）。
	var model = load(DETECTION_PATH).new()
	var cone = _make_cone(Vector3.ZERO, Vector3(0, 0, -1))
	var point := Vector3(0, 0, -5)
	model.configure({"detect_threshold": 0.3})
	_check("DetectionModel：detect_threshold 参与判定（0.3 → 蹲伏可见）",
		bool(model.evaluate(cone, point, {"crouching": true})["seen"]))
	model.configure({"detect_threshold": 1.1})
	_check("DetectionModel：detect_threshold 参与判定（1.1 → 站立不可见）",
		not bool(model.evaluate(cone, point, {})["seen"]))

	model = load(DETECTION_PATH).new()
	model.configure({"detect_threshold": 0.4})
	_check("DetectionModel：detect_threshold 等值边界（0.4 = 蹲伏视觉分 → 可见）",
		bool(model.evaluate(cone, point, {"crouching": true})["seen"]))

	model = load(DETECTION_PATH).new()
	model.configure({"noise_threshold": 0.4})
	_check("DetectionModel：noise_threshold 参与判定（0.4 → 0.5 暴露）",
		bool(model.evaluate(cone, point, {"crouching": true, "noise": 0.5})["seen"]))
	_check("DetectionModel：noise_threshold 参与判定（0.4 → 0.3 仍隐蔽）",
		not bool(model.evaluate(cone, point, {"crouching": true, "noise": 0.3})["seen"]))


func _test_error_semantics() -> void:
	# 契约 §0：配置错误写 last_errors + definition_error，不抛错、不 push_warning。
	var detection = load(DETECTION_PATH).new()
	var detection_errors: Array = []
	detection.definition_error.connect(func(message: String) -> void:
		detection_errors.append(message)
	)
	detection.configure({"crouch_factor": 2.0})
	_check("DetectionModel：非法配置写入 last_errors", detection.last_errors.size() == 1)
	_check("DetectionModel：非法配置发 definition_error", detection_errors.size() == 1)
	_check("DetectionModel：非法配置保留默认值",
		is_equal_approx(float(detection.get_config()["crouch_factor"]), 0.4))
	detection.configure({"crouch_factor": 0.3})
	_check("DetectionModel：合法 configure 清空 last_errors", detection.last_errors.is_empty())

	var stealth = load(STEALTH_PATH).new()
	root.add_child(stealth)
	var stealth_errors: Array = []
	stealth.definition_error.connect(func(message: String) -> void:
		stealth_errors.append(message)
	)
	stealth.configure({"noise": {"range": -1.0}})
	_check("StealthModel：非法噪音配置写入 last_errors", stealth.last_errors.size() == 1)
	_check("StealthModel：非法噪音配置发 definition_error", stealth_errors.size() == 1)
	stealth.configure({"noise": {"range": 4.0}})
	_check("StealthModel：合法 configure 清空 last_errors", stealth.last_errors.is_empty())
	stealth.free()

	# StealthModel 必须把 DetectionModel 的配置错误转发到自己的 §0 错误接口（不重不漏）。
	var forwarding = load(STEALTH_PATH).new()
	root.add_child(forwarding)
	var forwarded_errors: Array = []
	forwarding.definition_error.connect(func(message: String) -> void:
		forwarded_errors.append(message)
	)
	forwarding.configure({"detection": {"crouch_factor": 2.0}})
	_check("StealthModel：转发 detection 配置错误到 last_errors（带前缀）",
		forwarding.last_errors.size() == 1
		and String(forwarding.last_errors[0]).begins_with("[detection] "))
	_check("StealthModel：转发 detection 配置错误只发一次 definition_error",
		forwarded_errors.size() == 1)
	forwarding.configure({"detection": {"crouch_factor": 2.0, "occlusion_factor": 2.0}})
	_check("StealthModel：多条 detection 错误逐条转发（2/2）",
		forwarding.last_errors.size() == 2 and forwarded_errors.size() == 3)
	forwarding.configure({"detection": {"crouch_factor": 1.0}})
	_check("StealthModel：合法 configure 清空转发错误且不再发信号",
		forwarding.last_errors.is_empty() and forwarded_errors.size() == 3)
	forwarding.free()


# --- StealthModel -------------------------------------------------------------

func _test_stealth_transitions() -> void:
	var model = load(STEALTH_PATH).new()
	root.add_child(model)
	_check("StealthModel：注册敌人锥体", model.add_enemy("guard", _make_cone(Vector3.ZERO, Vector3(0, 0, -1))))
	var events: Array = []
	model.detected.connect(func(actor_id: String, by_enemy: String) -> void:
		events.append({"kind": "detected", "actor": actor_id, "enemy": by_enemy})
	)
	model.escaped.connect(func(actor_id: String) -> void:
		events.append({"kind": "escaped", "actor": actor_id})
	)

	model.tick(0.1, [{"id": "P1", "position": Vector3(0, 0, 5)}])
	_check("StealthModel：锥外保持隐蔽", model.is_hidden("P1"))
	_check("StealthModel：锥外不发 detected", events.is_empty())

	model.tick(0.1, [{"id": "P1", "position": Vector3(0, 0, -5)}])
	_check("StealthModel：锥内暴露", not model.is_hidden("P1"))
	_check("StealthModel：进入暴露时发一次 detected 且带敌人 id",
		events.size() == 1 and String(events[0]["kind"]) == "detected"
		and String(events[0]["enemy"]) == "guard" and String(events[0]["actor"]) == "P1")

	model.tick(0.1, [{"id": "P1", "position": Vector3(0, 0, -5)}])
	_check("StealthModel：持续暴露不重复发 detected", events.size() == 1)

	model.tick(0.1, [{"id": "P1", "position": Vector3(0, 0, 5)}])
	_check("StealthModel：离开视锥后重新隐蔽", model.is_hidden("P1"))
	_check("StealthModel：重新隐蔽时发一次 escaped",
		events.size() == 2 and String(events[1]["kind"]) == "escaped"
		and String(events[1]["actor"]) == "P1")
	model.free()


func _test_stealth_noise_reveals() -> void:
	# 锥外即使噪音爆表也不检测（验收：锥外不检测）。
	var outside_model = load(STEALTH_PATH).new()
	root.add_child(outside_model)
	outside_model.add_enemy("guard", _make_cone(Vector3.ZERO, Vector3(0, 0, -1)))
	outside_model.tick(0.1, [{"id": "P1", "position": Vector3(0, 0, 5), "noise": 99.0}])
	_check("StealthModel：锥外 + 噪音仍不检测", outside_model.is_hidden("P1"))
	outside_model.free()

	# 锥内蹲伏本来隐蔽；噪音超过阈值后按声音暴露。
	var model = load(STEALTH_PATH).new()
	root.add_child(model)
	model.add_enemy("guard", _make_cone(Vector3.ZERO, Vector3(0, 0, -1)))
	var events: Array = []
	model.detected.connect(func(actor_id: String, by_enemy: String) -> void:
		events.append({"kind": "detected", "actor": actor_id, "enemy": by_enemy})
	)
	model.tick(0.1, [{"id": "P1", "position": Vector3(0, 0, -5), "crouching": true}])
	_check("StealthModel：锥内蹲伏 + 安静 → 隐蔽", model.is_hidden("P1"))
	# 蹲伏会把自身噪音打 5 折（默认 0.5），2.0 → 1.0 刚好到阈值。
	model.tick(0.1, [{"id": "P1", "position": Vector3(0, 0, -5), "crouching": true, "noise": 2.0}])
	_check("StealthModel：锥内 + 噪音超阈值 → detected",
		not model.is_hidden("P1") and events.size() == 1
		and String(events[0]["enemy"]) == "guard")
	_check("StealthModel：蹲伏降低自身噪音（2.0 → 1.0）",
		is_equal_approx(model.noise_at(Vector3(0, 0, -5)), 1.0))
	model.free()


func _test_stealth_modifier_config() -> void:
	# 蹲伏修正透传给 DetectionModel。
	var crouch_model = load(STEALTH_PATH).new()
	root.add_child(crouch_model)
	crouch_model.add_enemy("guard", _make_cone(Vector3.ZERO, Vector3(0, 0, -1)))
	crouch_model.configure({"detection": {"crouch_factor": 1.0}})
	crouch_model.tick(0.1, [{"id": "P1", "position": Vector3(0, 0, -5), "crouching": true}])
	_check("StealthModel：蹲伏修正可配（1.0 → 蹲伏也暴露）", not crouch_model.is_hidden("P1"))
	crouch_model.free()

	# 遮挡修正透传给 DetectionModel。
	var occlusion_model = load(STEALTH_PATH).new()
	root.add_child(occlusion_model)
	occlusion_model.add_enemy("guard", _make_cone(Vector3.ZERO, Vector3(0, 0, -1)))
	occlusion_model.tick(0.1, [{"id": "P1", "position": Vector3(0, 0, -5), "occluded": true}])
	_check("StealthModel：默认遮挡 → 隐蔽", occlusion_model.is_hidden("P1"))
	occlusion_model.configure({"detection": {"occlusion_factor": 1.0}})
	occlusion_model.tick(0.1, [{"id": "P1", "position": Vector3(0, 0, -5), "occluded": true}])
	_check("StealthModel：遮挡修正可配（1.0 → 忽略遮挡）",
		not occlusion_model.is_hidden("P1"))
	occlusion_model.free()


func _test_stealth_flat_config() -> void:
	# W12 若按 DetectionModel 的习惯平铺传检测参数，StealthModel 也应生效。
	var model = load(STEALTH_PATH).new()
	root.add_child(model)
	model.add_enemy("guard", _make_cone(Vector3.ZERO, Vector3(0, 0, -1)))
	model.configure({"crouch_factor": 1.0})
	model.tick(0.1, [{"id": "P1", "position": Vector3(0, 0, -5), "crouching": true}])
	_check("StealthModel：平铺检测参数也生效（crouch_factor=1.0）",
		not model.is_hidden("P1"))
	model.free()

	# 噪音蹲伏折扣可配（默认 0.5，这里改 1.0）。
	var noise_model = load(STEALTH_PATH).new()
	root.add_child(noise_model)
	noise_model.configure({"noise": {"crouch_noise_factor": 1.0}})
	noise_model.tick(0.1, [{"id": "P1", "position": Vector3(0, 0, -5),
		"crouching": true, "noise": 2.0}])
	_check("StealthModel：噪音蹲伏折扣可配（1.0 → 2.0）",
		is_equal_approx(noise_model.noise_at(Vector3(0, 0, -5)), 2.0))
	noise_model.free()


func _test_config_precedence() -> void:
	# nested detection 优先于平铺写法（0.9 生效，而不是 0.1）。
	var model = load(STEALTH_PATH).new()
	root.add_child(model)
	model.add_enemy("guard", _make_cone(Vector3.ZERO, Vector3(0, 0, -1)))
	model.configure({"detection": {"crouch_factor": 0.9}, "crouch_factor": 0.1})
	model.tick(0.1, [{"id": "P1", "position": Vector3(0, 0, -5), "crouching": true}])
	_check("StealthModel：nested detection 优先于平铺（0.9 而非 0.1）",
		not model.is_hidden("P1"))
	model.free()

	# detection 不是字典时报 1 条配置错误，但平铺参数仍然生效。
	var bad_shape = load(STEALTH_PATH).new()
	root.add_child(bad_shape)
	bad_shape.add_enemy("guard", _make_cone(Vector3.ZERO, Vector3(0, 0, -1)))
	bad_shape.configure({"detection": 42, "crouch_factor": 1.0})
	_check("StealthModel：detection 非字典报 1 条配置错误", bad_shape.last_errors.size() == 1)
	bad_shape.tick(0.1, [{"id": "P1", "position": Vector3(0, 0, -5), "crouching": true}])
	_check("StealthModel：detection 非字典时平铺参数仍生效", not bad_shape.is_hidden("P1"))
	bad_shape.free()

	# 平铺的非法值也走 §0 配置错误（带 [detection] 前缀）。
	var flat_bad = load(STEALTH_PATH).new()
	root.add_child(flat_bad)
	flat_bad.configure({"crouch_factor": 2.0})
	_check("StealthModel：平铺非法值报 1 条配置错误（带前缀）",
		flat_bad.last_errors.size() == 1
		and String(flat_bad.last_errors[0]).begins_with("[detection] "))
	flat_bad.free()


func _test_tick_order_independent() -> void:
	# 同一帧里后面的 actor 发出的噪音也应对前面的 actor 可见，结果不依赖数组顺序。
	var loud := {"id": "loud", "position": Vector3(0, 0, -5), "noise": 3.0}
	var sneak := {"id": "sneak", "position": Vector3(0, 0, -5), "crouching": true}
	var results: Array[bool] = []
	for pair in [[loud, sneak], [sneak, loud]]:
		var model = load(STEALTH_PATH).new()
		root.add_child(model)
		model.add_enemy("guard", _make_cone(Vector3.ZERO, Vector3(0, 0, -1)))
		model.tick(0.1, pair)
		results.append(model.is_hidden("sneak"))
		model.free()
	_check("StealthModel：同帧 actor 顺序不影响噪音判定",
		results.size() == 2 and results[0] == false and results[1] == false)


func _test_remove_enemy() -> void:
	var model = load(STEALTH_PATH).new()
	root.add_child(model)
	var escapes: Array = []
	model.escaped.connect(func(actor_id: String) -> void:
		escapes.append(actor_id)
	)
	model.add_enemy("guard", _make_cone(Vector3.ZERO, Vector3(0, 0, -1)))
	model.tick(0.1, [{"id": "P1", "position": Vector3(0, 0, -5)}])
	_check("StealthModel：解除敌人前处于暴露", not model.is_hidden("P1"))
	model.remove_enemy("guard")
	model.tick(0.1, [{"id": "P1", "position": Vector3(0, 0, -5)}])
	_check("StealthModel：remove_enemy 后不再被该锥体发现", model.is_hidden("P1"))
	_check("StealthModel：remove_enemy 后暴露转隐蔽会发 escaped",
		escapes.size() == 1 and String(escapes[0]) == "P1")
	model.free()


func _test_noise_field() -> void:
	var model = load(STEALTH_PATH).new()
	root.add_child(model)
	model.emit_noise(Vector3(2, 0, 0), 2.0, 0.5)
	_check("noise_at：声源处等于响度", is_equal_approx(model.noise_at(Vector3(2, 0, 0)), 2.0))
	_check("noise_at：半射程处线性衰减到一半",
		is_equal_approx(model.noise_at(Vector3(6, 0, 0)), 1.0))
	_check("noise_at：射程外为 0", is_equal_approx(model.noise_at(Vector3(12, 0, 0)), 0.0))
	model.tick(0.25, [])
	_check("noise_at：0.25s 后（时长一半）衰减到一半",
		is_equal_approx(model.noise_at(Vector3(2, 0, 0)), 1.0))
	model.tick(0.25, [])
	_check("noise_at：到时归零", is_equal_approx(model.noise_at(Vector3(2, 0, 0)), 0.0))

	# 噪音射程可配。
	model.configure({"noise": {"range": 2.0}})
	model.emit_noise(Vector3.ZERO, 1.0, 0.5)
	_check("noise_at：射程可配（1m 处 0.5）",
		is_equal_approx(model.noise_at(Vector3(1, 0, 0)), 0.5))
	_check("noise_at：射程可配（3m 处 0）",
		is_equal_approx(model.noise_at(Vector3(3, 0, 0)), 0.0))
	model.free()

	# 多声源取最大值（不累加）。
	var aggregation_model = load(STEALTH_PATH).new()
	root.add_child(aggregation_model)
	aggregation_model.emit_noise(Vector3.ZERO, 2.0, 0.5)
	aggregation_model.emit_noise(Vector3.ZERO, 1.0, 0.5)
	_check("noise_at：多声源取最大值（2.0，不累加成 3.0）",
		is_equal_approx(aggregation_model.noise_at(Vector3.ZERO), 2.0))

	# 没显式传 duration 时用配置的默认时长（默认 0.5，这里改 2.0）。
	aggregation_model.configure({"noise": {"duration": 2.0}})
	aggregation_model.emit_noise(Vector3.ZERO, 2.0)
	aggregation_model.tick(1.0, [])
	_check("noise_at：默认时长可配（2s 的一半 = 1.0）",
		is_equal_approx(aggregation_model.noise_at(Vector3.ZERO), 1.0))
	aggregation_model.free()


# --- 断言与汇总 ---------------------------------------------------------------

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
		print("STEALTH_TEST_PASS (%d checks)" % _checks)
		quit(0)
	else:
		printerr("STEALTH_TEST_FAIL (%d/%d failed)" % [_failures.size(), _checks])
		for failure in _failures:
			printerr("  - ", failure)
		quit(1)
