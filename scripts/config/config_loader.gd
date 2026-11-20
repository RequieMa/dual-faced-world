extends RefCounted
## 配置加载器：JSON 读取 + 轻量 schema 校验 + 兜底（W0 契约层）。
##
## 设计目标（见 docs/MECHANICS_CONTRACTS.md）：
## - 与 `clue_manager._read_json` 同样的兜底：先按文件读，失败再尝试 JSON 资源；
## - 校验失败**不返回半成品**：返回空字典并把原因写进 `last_errors`；
## - 只支持机制需要的子集：type / required / properties / additional_properties /
##   items / enum / min / max。未知关键字忽略（向前兼容）。

signal definition_error(message: String)

## 轻量 schema 支持的 type 集合；拼错（例如 integerr）会被判成 schema 错误，
## 而不是静默放宽校验。
const KNOWN_TYPES: Array[String] = ["any", "object", "array", "string", "number", "integer", "boolean"]

var last_errors: Array[String] = []


## 读取并校验一个 JSON 配置。失败返回空字典（原因见 last_errors）。
func load_json(path: String, schema_path: String = "") -> Dictionary:
	last_errors.clear()
	var data: Variant = _read_json(path)
	if data == null:
		_fail("读取或解析失败: %s" % path)
		return {}
	if not data is Dictionary:
		_fail("根节点必须是对象: %s" % path)
		return {}

	var dictionary: Dictionary = data
	if not schema_path.is_empty():
		var schema: Variant = _read_json(schema_path)
		if schema == null:
			_fail("schema 读取或解析失败: %s" % schema_path)
			return {}
		if not schema is Dictionary:
			_fail("schema 根节点必须是对象: %s" % schema_path)
			return {}
		var errors := validate(dictionary, schema)
		if not errors.is_empty():
			for error_text in errors:
				last_errors.append(String(error_text))
			definition_error.emit("配置校验失败: %s" % path)
			return {}
	return dictionary


## 按 schema 校验任意值，返回错误列表（空数组 = 通过）。
func validate(data: Variant, schema: Dictionary) -> Array:
	var errors: Array = []
	_validate_value(data, schema, "", errors)
	return errors


# --- 内部 ---------------------------------------------------------------------

func _read_json(path: String) -> Variant:
	if FileAccess.file_exists(path):
		var text := FileAccess.get_file_as_string(path)
		if not text.is_empty():
			# 用 JSON 实例而不是 JSON.parse_string：后者解析失败会往 stderr 打引擎级
			# ERROR，脏化跑测输出；这里把失败当普通返回值处理。
			var json := JSON.new()
			if json.parse(text) != OK:
				return null
			return json.data
	if ResourceLoader.exists(path):
		var resource = load(path)
		if resource is JSON:
			return (resource as JSON).data
	return null


func _validate_value(value: Variant, schema: Dictionary, path: String, errors: Array) -> void:
	if not schema is Dictionary:
		return

	var expected := String(schema.get("type", "any"))
	if not KNOWN_TYPES.has(expected):
		errors.append(_describe(path, "schema 使用了未知 type: %s" % expected))
		return
	if not _type_matches(value, expected):
		errors.append(_describe(path, "类型应为 %s，实际是 %s" % [expected, _type_name(value)]))
		return

	if value is Dictionary:
		var object: Dictionary = value
		for key in schema.get("required", []):
			if not object.has(String(key)):
				errors.append(_describe(_join(path, String(key)), "缺少必填字段"))
		var properties: Dictionary = schema.get("properties", {})
		for key in properties.keys():
			if object.has(key):
				_validate_value(object[key], properties[key], _join(path, String(key)), errors)
		var additional: Variant = schema.get("additional_properties")
		if additional is bool:
			if not additional:
				for key in object.keys():
					if not properties.has(key):
						errors.append(_describe(_join(path, String(key)), "不允许的额外字段"))
		elif additional is Dictionary:
			for key in object.keys():
				if properties.has(key):
					continue
				_validate_value(object[key], additional, _join(path, String(key)), errors)

	if value is Array:
		var items: Variant = schema.get("items")
		if items is Dictionary:
			var array: Array = value
			for index in range(array.size()):
				_validate_value(array[index], items, "%s[%d]" % [path, index], errors)

	if schema.has("enum"):
		var allowed: Array = schema["enum"]
		if not allowed.has(value):
			errors.append(_describe(path, "取值不在枚举内: %s" % str(value)))

	if typeof(value) == TYPE_FLOAT or typeof(value) == TYPE_INT:
		if schema.has("min") and float(value) < float(schema["min"]):
			errors.append(_describe(path, "小于最小值 %s" % str(schema["min"])))
		if schema.has("max") and float(value) > float(schema["max"]):
			errors.append(_describe(path, "大于最大值 %s" % str(schema["max"])))


func _type_matches(value: Variant, expected: String) -> bool:
	match expected:
		"any":
			return true
		"object":
			return value is Dictionary
		"array":
			return value is Array
		"string":
			return typeof(value) == TYPE_STRING
		"number":
			return typeof(value) == TYPE_FLOAT or typeof(value) == TYPE_INT
		"integer":
			# JSON 解析出的数字在 Godot 里统一是 float（3 也是 3.0），
			# 这里接受「整数值的 float」，否则 schema 写 integer 永远不通过。
			if typeof(value) == TYPE_INT:
				return true
			if typeof(value) == TYPE_FLOAT:
				return is_equal_approx(value, roundf(value))
			return false
		"boolean":
			return typeof(value) == TYPE_BOOL
		_:
			return false


func _type_name(value: Variant) -> String:
	match typeof(value):
		TYPE_NIL:
			return "null"
		TYPE_BOOL:
			return "boolean"
		TYPE_INT:
			return "integer"
		TYPE_FLOAT:
			return "number"
		TYPE_STRING:
			return "string"
		TYPE_ARRAY:
			return "array"
		TYPE_DICTIONARY:
			return "object"
		_:
			return str(typeof(value))


func _join(path: String, key: String) -> String:
	return key if path.is_empty() else "%s.%s" % [path, key]


func _describe(path: String, message: String) -> String:
	return "%s: %s" % [path if not path.is_empty() else "(root)", message]


func _fail(message: String) -> void:
	last_errors.append(message)
	definition_error.emit(message)
