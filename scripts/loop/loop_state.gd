extends RefCounted
## W6：轮次状态与 summary 结构（只放数据，不接触参与者）。
##
## 契约见 docs/MECHANICS_CONTRACTS.md §3：LoopManager 的轮次与 history 存在这里，
## 世界重置 / 知识保留都不经过本类，避免把「记录」和「重置副作用」混在一起。
##
## summary 固定字段：`{round, time, outcome, clues, solved}`，可以带额外字段（字段可扩展）；
## 缺省字段补默认值，已知字段类型不符时用默认值并 push_warning（契约 §0 的序列化规则）。

const SUMMARY_DEFAULTS: Dictionary = {
	"round": 0,
	"time": 0.0,
	"outcome": "",
	"clues": 0,
	"solved": 0,
}

var _round: int = 0
var _history: Array[Dictionary] = []


## start_round 推进轮次时调用；首轮从 1 开始（由 LoopManager 决定）。
func begin_round(index: int) -> void:
	_round = index


func get_round() -> int:
	return _round


## 记录一轮的 summary：补齐固定字段、按当前轮次覆盖 round，返回写入的副本。
## round_number >= 0 时用它覆盖 round（LoopState 单测 / 导入历史时使用）。
func record(summary: Dictionary, round_number: int = -1) -> Dictionary:
	var recorded: Dictionary = SUMMARY_DEFAULTS.duplicate(true)
	recorded.merge(summary, true)
	recorded["round"] = round_number if round_number >= 0 else _round
	_normalize(recorded)
	_history.append(recorded.duplicate(true))
	return recorded


## 返回 history 的深拷贝；外部修改不会影响内部记录。
func get_history() -> Array:
	return _history.duplicate(true)


func to_dict() -> Dictionary:
	return {
		"round": _round,
		"history": get_history(),
	}


## 只恢复本类状态；缺失字段回到默认值，类型不符忽略该字段并 push_warning。
func from_dict(data: Dictionary) -> void:
	_round = _as_int(data.get("round"), 0, "round")
	_history.clear()
	var raw_history: Variant = data.get("history", [])
	if not raw_history is Array:
		if raw_history != null:
			push_warning("LoopState: history 应为数组，已忽略: %s" % str(raw_history))
		return
	for entry in raw_history:
		if not entry is Dictionary:
			push_warning("LoopState: 跳过非对象的 history 条目: %s" % str(entry))
			continue
		var copy: Dictionary = (entry as Dictionary).duplicate(true)
		_normalize(copy)
		_history.append(copy)


# --- 内部 ---------------------------------------------------------------------

func _normalize(summary: Dictionary) -> void:
	summary["round"] = _as_int(summary.get("round"), 0, "round")
	summary["time"] = _as_float(summary.get("time"), 0.0, "time")
	summary["outcome"] = _as_string(summary.get("outcome"), "", "outcome")
	summary["clues"] = _as_int(summary.get("clues"), 0, "clues")
	summary["solved"] = _as_int(summary.get("solved"), 0, "solved")


func _as_int(value: Variant, fallback: int, field: String) -> int:
	match typeof(value):
		TYPE_INT:
			return int(value)
		TYPE_FLOAT:
			return int(value)
		TYPE_NIL:
			return fallback
		_:
			push_warning("LoopState: %s 应为整数，已用默认值 %d" % [field, fallback])
			return fallback


func _as_float(value: Variant, fallback: float, field: String) -> float:
	match typeof(value):
		TYPE_INT:
			return float(value)
		TYPE_FLOAT:
			return float(value)
		TYPE_NIL:
			return fallback
		_:
			push_warning("LoopState: %s 应为数值，已用默认值 %s" % [field, str(fallback)])
			return fallback


func _as_string(value: Variant, fallback: String, field: String) -> String:
	match typeof(value):
		TYPE_STRING:
			return String(value)
		TYPE_STRING_NAME:
			return String(value)
		TYPE_NIL:
			return fallback
		_:
			push_warning("LoopState: %s 应为字符串，已用默认值 %s" % [field, fallback])
			return fallback
