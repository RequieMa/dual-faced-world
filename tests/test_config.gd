extends SceneTree
## W0 契约层测试：ConfigLoader（JSON 读取 + schema 校验 + 兜底）与 schema 文件存在性。
## 运行：godot --headless --path . --script tests/test_config.gd
## 退出码 0 = 全绿，1 = 有用例失败。

const CONFIG_LOADER := "res://scripts/config/config_loader.gd"
const SCHEMA_DIR := "res://resources/data/schema/"
const SCHEMAS := ["surveillance", "dialogues", "level"]

const TEMP_DIR := "user://cfg_test"

var _failures: Array[String] = []
var _checks: int = 0


func _initialize() -> void:
	_check("存在 scripts/config/config_loader.gd", ResourceLoader.exists(CONFIG_LOADER))
	for name in SCHEMAS:
		_check("存在 schema：%s" % name, ResourceLoader.exists(SCHEMA_DIR + String(name) + ".schema.json"))
	if not ResourceLoader.exists(CONFIG_LOADER):
		_report()
		return
	_ensure_temp_dir()
	_test_read_valid()
	_test_read_errors()
	_test_schema_valid()
	_test_schema_errors()
	_test_schema_types()
	_test_enum_and_bounds()
	_test_definition_error_signal()
	_test_errors_are_reset()
	_cleanup()
	_report()


# --- 断言 ---------------------------------------------------------------------

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
		print("CONFIG_TEST_PASS (%d checks)" % _checks)
		quit(0)
	else:
		printerr("CONFIG_TEST_FAIL (%d/%d failed)" % [_failures.size(), _checks])
		for failure in _failures:
			printerr("  - ", failure)
		quit(1)


# --- 工具 ---------------------------------------------------------------------

func _loader():
	var script = load(CONFIG_LOADER)
	if script == null:
		return null
	return script.new()


func _ensure_temp_dir() -> void:
	var absolute := ProjectSettings.globalize_path(TEMP_DIR)
	if not DirAccess.dir_exists_absolute(absolute):
		DirAccess.make_dir_recursive_absolute(absolute)


func _write(name: String, content: String) -> String:
	var path := TEMP_DIR + "/" + name
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(content)
	file.close()
	return path


func _remove(path: String) -> void:
	var absolute := ProjectSettings.globalize_path(path)
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(absolute)


func _cleanup() -> void:
	var absolute := ProjectSettings.globalize_path(TEMP_DIR)
	if DirAccess.dir_exists_absolute(absolute):
		for file_name in DirAccess.get_files_at(absolute):
			DirAccess.remove_absolute(absolute + "/" + file_name)
		DirAccess.remove_absolute(absolute)


func _write_surveillance(valid: bool) -> String:
	var camera := "{\"dwell\": 6.0, \"cooldown\": 4.0}"
	if not valid:
		camera = "{\"dwell\": 6.0}"
	var content := "{\"cameras\": {\"C1\": %s}}" % camera
	return _write("surveillance_%s.json" % ("ok" if valid else "bad"), content)


# --- 用例 ---------------------------------------------------------------------

func _test_read_valid() -> void:
	var loader = _loader()
	if loader == null:
		_check("ConfigLoader 可实例化", false)
		return
	var path := _write("plain.json", "{\"name\": \"puzzle_lab\", \"count\": 8}")
	var data: Dictionary = loader.load_json(path)
	_check("读取合法 JSON 返回 Dictionary", data.get("name", "") == "puzzle_lab" and int(data.get("count", 0)) == 8,
		str(data))
	_check("无 schema 时不报错", loader.last_errors.is_empty(), str(loader.last_errors))


func _test_read_errors() -> void:
	var loader = _loader()
	var bad_json := _write("bad.json", "{not json")
	_check("坏 JSON 返回空字典", loader.load_json(bad_json).is_empty())
	_check("坏 JSON 记录错误", not loader.last_errors.is_empty(), str(loader.last_errors))

	var array_root := _write("array.json", "[1, 2, 3]")
	_check("根节点不是对象返回空字典", loader.load_json(array_root).is_empty())
	_check("根节点错误被记录", not loader.last_errors.is_empty())

	var missing = load(CONFIG_LOADER).new()
	_check("文件不存在返回空字典", missing.load_json(TEMP_DIR + "/does_not_exist.json").is_empty())
	_check("文件不存在记录错误", not missing.last_errors.is_empty())


func _test_schema_valid() -> void:
	var loader = _loader()
	var path := _write_surveillance(true)
	var data: Dictionary = loader.load_json(path, SCHEMA_DIR + "surveillance.schema.json")
	_check("合法配置通过 schema 校验", not data.is_empty() and loader.last_errors.is_empty(),
		str(loader.last_errors))
	_check("返回的相机配置可读", data.has("cameras") and (data["cameras"] as Dictionary).has("C1"))

	var dialogues := _write("dialogues.json",
		"{\"dialogues\": [{\"id\": \"d1\", \"group\": \"imaginary\", \"lines\": [{\"speaker\": \"甲\", \"text\": \"你好\"}]}]}")
	var dialogue_data: Dictionary = loader.load_json(dialogues, SCHEMA_DIR + "dialogues.schema.json")
	_check("对话配置通过 schema 校验（嵌套数组/对象）",
		not dialogue_data.is_empty() and loader.last_errors.is_empty(), str(loader.last_errors))

	var level := _write("level.json",
		"{\"id\": \"theater\", \"rooms\": [{\"id\": \"lobby\", \"name\": \"大厅\"}]}")
	var level_data: Dictionary = loader.load_json(level, SCHEMA_DIR + "level.schema.json")
	_check("关卡配置通过 schema 校验", not level_data.is_empty() and loader.last_errors.is_empty(),
		str(loader.last_errors))


func _test_schema_errors() -> void:
	var loader = _loader()
	var bad_camera := _write_surveillance(false)
	var bad_data: Dictionary = loader.load_json(bad_camera, SCHEMA_DIR + "surveillance.schema.json")
	_check("缺必填字段时返回空字典", bad_data.is_empty())
	_check("缺必填字段的错误里带路径", _has_error_containing(loader, "cooldown"), str(loader.last_errors))

	var wrong_type := _write("surveillance_type.json", "{\"cameras\": {\"C1\": {\"dwell\": \"六秒\", \"cooldown\": 4.0}}}")
	var wrong_data: Dictionary = loader.load_json(wrong_type, SCHEMA_DIR + "surveillance.schema.json")
	_check("字段类型错误时返回空字典", wrong_data.is_empty())
	_check("类型错误里带字段路径", _has_error_containing(loader, "dwell"), str(loader.last_errors))

	var bad_dialogue := _write("dialogues_bad.json",
		"{\"dialogues\": [{\"id\": \"d1\", \"group\": \"friend\", \"lines\": \"不是数组\"}]}")
	var bad_dialogue_data: Dictionary = loader.load_json(bad_dialogue, SCHEMA_DIR + "dialogues.schema.json")
	_check("嵌套字段类型错误时返回空字典", bad_dialogue_data.is_empty())
	_check("嵌套错误里带路径", _has_error_containing(loader, "lines"), str(loader.last_errors))

	var missing_schema_loader = _loader()
	var data_with_missing_schema: Dictionary = missing_schema_loader.load_json(
		_write_surveillance(true), SCHEMA_DIR + "no_such.schema.json")
	_check("schema 文件不存在时返回空字典", data_with_missing_schema.is_empty())
	_check("schema 缺失记录错误", not missing_schema_loader.last_errors.is_empty())


func _test_schema_types() -> void:
	var loader = _loader()
	var int_schema := _write("schema_int.json",
		"{\"type\": \"object\", \"required\": [\"n\"], \"properties\": {\"n\": {\"type\": \"integer\"}}}")
	var int_ok := _write("int_ok.json", "{\"n\": 3}")
	_check("integer 接受 JSON 里的整数值（解析为 float）",
		not loader.load_json(int_ok, int_schema).is_empty() and loader.last_errors.is_empty(),
		str(loader.last_errors))
	_check("integer 拒绝小数", loader.load_json(_write("int_bad.json", "{\"n\": 3.5}"), int_schema).is_empty())

	var bool_schema := _write("schema_bool.json",
		"{\"type\": \"object\", \"properties\": {\"flag\": {\"type\": \"boolean\"}}}")
	_check("boolean 接受 true",
		not loader.load_json(_write("bool_ok.json", "{\"flag\": true}"), bool_schema).is_empty())
	_check("boolean 拒绝字符串",
		loader.load_json(_write("bool_bad.json", "{\"flag\": \"yes\"}"), bool_schema).is_empty())

	var any_schema := _write("schema_any.json",
		"{\"type\": \"object\", \"properties\": {\"x\": {\"type\": \"any\"}}}")
	_check("any 接受任意类型",
		not loader.load_json(_write("any_ok.json", "{\"x\": [1, 2]}"), any_schema).is_empty())

	var closed_schema := _write("schema_closed.json",
		"{\"type\": \"object\", \"additional_properties\": false}")
	_check("additional_properties=false 拒绝未知字段",
		loader.load_json(_write("closed_bad.json", "{\"extra\": 1}"), closed_schema).is_empty())
	var open_schema := _write("schema_open.json",
		"{\"type\": \"object\", \"additional_properties\": true}")
	_check("additional_properties=true 允许未知字段",
		not loader.load_json(_write("open_ok.json", "{\"extra\": 1}"), open_schema).is_empty())

	var typo_schema := _write("schema_typo.json",
		"{\"type\": \"object\", \"properties\": {\"x\": {\"type\": \"integerr\"}}}")
	var typo_data: Dictionary = loader.load_json(_write("typo.json", "{\"x\": 1}"), typo_schema)
	_check("schema 里的未知 type 会被判错（防拼写失效）",
		typo_data.is_empty() and _has_error_containing(loader, "integerr"), str(loader.last_errors))


func _test_enum_and_bounds() -> void:
	var loader = _loader()
	var schema := _write("schema_enum.json",
		"{\"type\": \"object\", \"properties\": {" +
		"\"g\": {\"type\": \"string\", \"enum\": [\"real\", \"imaginary\"]}, " +
		"\"n\": {\"type\": \"number\", \"min\": 1, \"max\": 4}}}")
	_check("enum 接受合法值",
		not loader.load_json(_write("enum_ok.json", "{\"g\": \"real\", \"n\": 2}"), schema).is_empty())
	_check("enum 拒绝非法值",
		loader.load_json(_write("enum_bad.json", "{\"g\": \"friend\", \"n\": 2}"), schema).is_empty())
	_check("min 拒绝过小值",
		loader.load_json(_write("min_bad.json", "{\"g\": \"real\", \"n\": 0}"), schema).is_empty())
	_check("max 拒绝过大值",
		loader.load_json(_write("max_bad.json", "{\"g\": \"real\", \"n\": 5}"), schema).is_empty())
	_check("边界值通过",
		not loader.load_json(_write("bound_ok.json", "{\"g\": \"real\", \"n\": 4}"), schema).is_empty())


func _test_definition_error_signal() -> void:
	var loader = _loader()
	var signals: Array = []
	loader.definition_error.connect(func(message: String) -> void: signals.append(message))
	loader.load_json(_write("bad_signal.json", "{oops"))
	_check("失败时发出 definition_error", signals.size() == 1, str(signals))
	loader.load_json(_write("ok_signal.json", "{\"ok\": true}"))
	_check("成功时不发 definition_error", signals.size() == 1, str(signals))


func _test_errors_are_reset() -> void:
	var loader = _loader()
	loader.load_json(_write("bad2.json", "{broken"))
	_check("第一次失败后有错误", not loader.last_errors.is_empty())
	loader.load_json(_write("good2.json", "{\"ok\": true}"))
	_check("成功后错误被清空", loader.last_errors.is_empty(), str(loader.last_errors))


func _has_error_containing(loader, needle: String) -> bool:
	for error_text in loader.last_errors:
		if String(error_text).contains(needle):
			return true
	return false
