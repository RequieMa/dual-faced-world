extends RefCounted
## 摄像头配置读取：surveillance.json → CameraSession.configure() 的字典。
##
## 统一走 W0 的 ConfigLoader（带 schema），不在模块里手写 FileAccess + JSON.parse_string。
## 失败返回 {} 且 last_errors 非空；调用方决定是否把错误显示到界面上。

const ConfigLoaderScript := preload("res://scripts/config/config_loader.gd")
## 默认值只在 CameraSession 登记一份，避免两处漂移（契约 §1）。
const CameraSessionScript := preload("res://scripts/camera/camera_session.gd")

const DEFAULT_PATH := "res://resources/data/surveillance.json"
const SCHEMA_PATH := "res://resources/data/schema/surveillance.schema.json"
const DEFAULT_DWELL := CameraSessionScript.DEFAULT_DWELL
const DEFAULT_COOLDOWN := CameraSessionScript.DEFAULT_COOLDOWN

signal definition_error(message: String)

var last_errors: Array[String] = []

## 最近一次成功加载的机位表（id -> {dwell, cooldown}）。
var _cameras: Dictionary = {}


## 读取并校验配置，返回 CameraSession.configure 可直接消费的字典；
## 失败返回 {}（原因见 last_errors），不会返回半成品。
func load_config(path: String = DEFAULT_PATH, schema_path: String = SCHEMA_PATH) -> Dictionary:
	last_errors.clear()
	_cameras.clear()

	var loader = ConfigLoaderScript.new()
	var data: Dictionary = loader.load_json(path, schema_path)
	if data.is_empty():
		for error_text in loader.last_errors:
			last_errors.append(String(error_text))
		if last_errors.is_empty():
			# 没有 schema、文件又是合法空对象 {} 时，ConfigLoader 不会报错；
			# 但返回值仍是 {}，这里补一条原因，保证「失败必有 last_errors」。
			last_errors.append("配置为空或解析失败: %s" % path)
		definition_error.emit("surveillance 配置加载失败: %s" % path)
		return {}

	var cameras: Variant = data.get("cameras")
	if not cameras is Dictionary:
		var message := "surveillance 配置缺少 cameras 对象: %s" % path
		last_errors.append(message)
		definition_error.emit(message)
		return {}

	_cameras = (cameras as Dictionary).duplicate(true)
	return {"cameras": _cameras.duplicate(true)}


## 读取配置并直接配置一个 CameraSession（鸭子类型：需要 configure(Dictionary)）。
## session 不标 Node：W6/W12 的存档适配器可能是 RefCounted。
func load_into(session, path: String = DEFAULT_PATH, schema_path: String = SCHEMA_PATH) -> bool:
	var config := load_config(path, schema_path)
	if config.is_empty():
		return false
	if session == null or not session is Object or not is_instance_valid(session) or not session.has_method("configure"):
		var message := "CameraConfig.load_into: 目标不是有效 Object 或没有 configure(Dictionary)"
		last_errors.append(message)
		definition_error.emit(message)
		push_warning(message)
		return false
	session.configure(config)
	return true


## 取某机位的计时；未配置时用契约默认值并 push_warning（Issue #11）。
## 注意：这是「未配置机位的计时兜底 / UI 查询」入口；CameraSession.enter()
## 仍按契约 §1 对未配置机位返回 false，两者语义不同，W12 不要用本方法
## 把 unknown 当成合法机位。
func timing_for(camera_id: String) -> Dictionary:
	var entry: Variant = _cameras.get(camera_id)
	if entry is Dictionary:
		var timing: Dictionary = entry
		return {
			"dwell": float(timing.get("dwell", DEFAULT_DWELL)),
			"cooldown": float(timing.get("cooldown", DEFAULT_COOLDOWN)),
		}
	push_warning("CameraConfig.timing_for: 机位 %s 未配置，使用默认停留/冷却" % camera_id)
	return {"dwell": DEFAULT_DWELL, "cooldown": DEFAULT_COOLDOWN}


func get_cameras() -> Dictionary:
	return _cameras.duplicate(true)
