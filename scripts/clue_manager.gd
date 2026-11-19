extends Node
## 线索管理器（autoload）：线索是全局标志，不做「消耗/使用」流程。
##
## 线索的「元数据」（标题/来源/解锁目标/交互文案）来自 JSON 定义表
## `resources/data/clues.json`，代码里不再硬编码 clue_id 与取值；
## 运行时的「玩家是否已登记」仍然只在本节点的内存 Dictionary 里。

signal clue_registered(clue_id: String, value: Variant)
signal clues_changed()
signal definitions_loaded(count: int)
signal definition_error(message: String)
## 时间线线索（带 t / cause / source 的档案或实时事件）登记成功
signal timeline_clue_registered(clue: Dictionary)

const DEFAULT_DEFINITIONS_PATH := "res://resources/data/clues.json"

var _clues: Dictionary = {}
var _definitions: Dictionary = {}
var _definition_order: Array[String] = []


func _ready() -> void:
	load_definitions()


# --- 定义表（JSON） ----------------------------------------------------------

## 载入线索定义表。成功返回 true，失败发 definition_error。
func load_definitions(path: String = DEFAULT_DEFINITIONS_PATH) -> bool:
	_definitions.clear()
	_definition_order.clear()

	var parsed: Variant = _read_json(path)
	if parsed == null:
		definition_error.emit("线索定义读取或解析失败: %s" % path)
		return false
	if not parsed is Dictionary:
		definition_error.emit("线索定义根节点必须是对象: %s" % path)
		return false

	var entries: Variant = (parsed as Dictionary).get("clues", [])
	if not entries is Array:
		definition_error.emit("线索定义的 clues 字段必须是数组: %s" % path)
		return false

	for entry in entries:
		if not entry is Dictionary:
			definition_error.emit("跳过非对象的线索定义: %s" % str(entry))
			continue
		var clue_id := String((entry as Dictionary).get("id", ""))
		if clue_id.is_empty():
			definition_error.emit("线索定义缺少 id，已跳过: %s" % str(entry))
			continue
		_definitions[clue_id] = (entry as Dictionary).duplicate(true)
		_definition_order.append(clue_id)

	definitions_loaded.emit(_definitions.size())
	return true


func _read_json(path: String) -> Variant:
	# 开发/运行期直接读文件；导出后若裸文件不可用，退回 JSON 资源。
	if FileAccess.file_exists(path):
		var text := FileAccess.get_file_as_string(path)
		if not text.is_empty():
			return JSON.parse_string(text)
	if ResourceLoader.exists(path):
		var resource = load(path)
		if resource is JSON:
			return (resource as JSON).data
	return null


func get_definitions() -> Array:
	var result: Array = []
	for clue_id in _definition_order:
		result.append(_definitions[clue_id])
	return result


func get_definition(clue_id: String) -> Dictionary:
	return (_definitions.get(clue_id, {}) as Dictionary).duplicate(true)


func get_definitions_for_unlock(unlock_id: String) -> Array:
	var result: Array = []
	for clue_id in _definition_order:
		var definition: Dictionary = _definitions[clue_id]
		if String(definition.get("unlocks", "")) == unlock_id:
			result.append(definition.duplicate(true))
	return result


## 按定义表取线索的取值（没有定义时返回 true）。
func get_defined_value(clue_id: String) -> Variant:
	var definition: Dictionary = _definitions.get(clue_id, {})
	return definition.get("value", true)


# --- 已登记的线索（运行时状态） ----------------------------------------------

## 登记「全局标志」型线索（玩家是否已拿到某条线索）：
## register_flag("door_code_A") 会从 JSON 取默认值；也允许显式覆盖。
## 时间线线索（带时间/因果的 archive/live 事件）走 register_clue()。
func register_flag(clue_id: String, value: Variant = null) -> void:
	var resolved: Variant = value
	if resolved == null:
		resolved = get_defined_value(clue_id)
	_clues[clue_id] = resolved
	clue_registered.emit(clue_id, resolved)
	clues_changed.emit()


func has_clue(clue_id: String) -> bool:
	return _clues.has(clue_id)


func get_clue(clue_id: String, fallback: Variant = null) -> Variant:
	return _clues.get(clue_id, fallback)


func get_all() -> Dictionary:
	return _clues.duplicate(true)


func count() -> int:
	return _clues.size()


func clear() -> void:
	if _clues.is_empty():
		return
	_clues.clear()
	clues_changed.emit()


# --- 时间线线索（archive / live 的因果链） ------------------------------------

## 时间线线索的登记顺序即事件顺序；id 格式 type_target_t，cause 直接引用 id。
var _timeline_clues: Array[Dictionary] = []
var _timeline_ids: Dictionary = {}
var _timeline_keys: Dictionary = {}


## 登记一条带时间与因果的线索。
##
## 签名按 Issue #3 固定，第二阶段不得改动：
##     register_clue(t, type, actor, target, cause, source)
##
## 去重键 (t, type, actor, target)：回放来回 seek、实时反复靠近同一交互点
## 都只登记一次。返回线索 id；命中去重时返回空串（调用方可据此判断是否新事件）。
func register_clue(at: float, type_name: String, actor: String, target: String,
		cause: String = "", source: String = "archive") -> String:
	var time := snappedf(at, 0.1)
	var dedupe := "%.1f|%s|%s|%s" % [time, type_name, actor, target]
	if _timeline_keys.has(dedupe):
		return ""
	var id := "%s_%s_%.1f" % [type_name, target, time]
	var clue := {
		"id": id,
		"t": time,
		"type": type_name,
		"actor": actor,
		"target": target,
		"cause": cause,
		"source": source,
	}
	_timeline_clues.append(clue)
	_timeline_ids[id] = clue
	_timeline_keys[dedupe] = id
	timeline_clue_registered.emit(clue.duplicate(true))
	clues_changed.emit()
	return id


## 按时间升序返回时间线线索（同刻按 id 稳定排序）。
func get_timeline_clues() -> Array:
	var result: Array = []
	for clue in _timeline_clues:
		result.append((clue as Dictionary).duplicate(true))
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if not is_equal_approx(float(a["t"]), float(b["t"])):
			return float(a["t"]) < float(b["t"])
		return String(a["id"]) < String(b["id"]))
	return result


func get_timeline_clue(clue_id: String) -> Dictionary:
	var clue: Dictionary = _timeline_ids.get(clue_id, {})
	return clue.duplicate(true)


func has_timeline_clue(clue_id: String) -> bool:
	return _timeline_ids.has(clue_id)


## 时间线线索条数；传 type 则只数该类型（如 "pickup"）。
func timeline_clue_count(type_name: String = "") -> int:
	if type_name.is_empty():
		return _timeline_clues.size()
	var total := 0
	for clue in _timeline_clues:
		if String(clue["type"]) == type_name:
			total += 1
	return total


## 找某类型 + 目标的最新一条（可按 source 过滤），供实时因果链引用。
func find_latest_timeline_clue(type_name: String, target: String, source: String = "") -> Dictionary:
	var found: Dictionary = {}
	for clue in _timeline_clues:
		if String(clue["type"]) != type_name or String(clue["target"]) != target:
			continue
		if not source.is_empty() and String(clue["source"]) != source:
			continue
		if found.is_empty() or float(clue["t"]) >= float(found["t"]):
			found = clue
	return found.duplicate(true)


func clear_timeline_clues() -> void:
	if _timeline_clues.is_empty():
		return
	_timeline_clues.clear()
	_timeline_ids.clear()
	_timeline_keys.clear()
	clues_changed.emit()


## 展示用文字：有定义时用「标题 = 值」，否则回落到 id。
func describe(clue_id: String) -> String:
	var definition: Dictionary = _definitions.get(clue_id, {})
	var title := String(definition.get("title", clue_id))
	return "%s = %s" % [title, str(get_clue(clue_id, "?"))]


## 交互文案：从定义表的 action 模板取，{value} 会被替换。
func build_action_text(clue_id: String) -> String:
	var definition: Dictionary = _definitions.get(clue_id, {})
	var template := String(definition.get("action", ""))
	if template.is_empty():
		return ""
	return template.replace("{value}", str(get_clue(clue_id, get_defined_value(clue_id))))
