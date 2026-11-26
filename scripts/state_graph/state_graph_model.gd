class_name StateGraphModel
extends RefCounted
## 状态图数据模型（纯逻辑，不碰 UI）。
##
## 节点有两种：
## - `kind = "state"`：一个「实体 · 状态」，如「敌人 · 巡逻」「摄像头 · 烧毁+闪光」；
## - `kind = "outcome"`：一个结局，`requires` 列出触发它需要的状态节点 id。
## 边 `edges` 表示状态切换（带触发词），结局节点也可以被边指过去，纯粹为了看图方便。
##
## 编辑器（scenes/state_graph_editor.tscn）与测试共用这套模型；JSON 见
## resources/data/state_graph.json。

signal changed

const DEFAULT_PATH := "res://resources/data/state_graph.json"

const KIND_STATE := "state"
const KIND_OUTCOME := "outcome"

const TONE_NEUTRAL := "neutral"
const TONE_WIN := "win"
const TONE_FAIL := "fail"
const TONES := [TONE_NEUTRAL, TONE_WIN, TONE_FAIL]

## {id, kind, entity, state, label, tone, requires: Array[String], pos: Vector2}
var nodes: Array[Dictionary] = []
## {id, from, to, label}
var edges: Array[Dictionary] = []
var last_errors: Array[String] = []

var _seq := 1


func clear() -> void:
	nodes.clear()
	edges.clear()
	last_errors.clear()
	_seq = 1
	changed.emit()


# --- 节点 ---------------------------------------------------------------------

## 拖入一个「实体 · 状态」。同实体同状态可以重复拖入，id 会加序号区分。
func add_node(entity: String, state: String, pos: Vector2 = Vector2.ZERO) -> String:
	var clean_entity := entity.strip_edges()
	var clean_state := state.strip_edges()
	if clean_entity.is_empty() or clean_state.is_empty():
		_report("节点需要实体名和状态名")
		return ""
	var node := {
		"id": _make_id(clean_entity + "_" + clean_state),
		"kind": KIND_STATE,
		"entity": clean_entity,
		"state": clean_state,
		"label": "%s · %s" % [clean_entity, clean_state],
		"tone": TONE_NEUTRAL,
		"requires": [],
		"pos": pos,
	}
	nodes.append(node)
	changed.emit()
	return String(node["id"])


## 把选中的状态节点合成一个结局：`requires` 全部命中时触发。
func add_outcome(condition_ids: Array, label: String, tone: String = TONE_NEUTRAL,
		pos: Vector2 = Vector2.ZERO) -> String:
	var clean_label := label.strip_edges()
	if clean_label.is_empty():
		_report("结局需要一个名字")
		return ""
	var requires: Array = []
	for raw in condition_ids:
		var node_id := String(raw)
		if not has_node(node_id):
			_report("结局条件里有不存在的节点：%s" % node_id)
			return ""
		if _node_kind(node_id) != KIND_STATE:
			_report("结局条件只能是状态节点，不能是结局节点")
			return ""
		if not requires.has(node_id):
			requires.append(node_id)
	if requires.is_empty():
		_report("结局至少需要一个状态条件")
		return ""
	var node := {
		"id": _make_id("outcome"),
		"kind": KIND_OUTCOME,
		"entity": "",
		"state": "",
		"label": clean_label,
		"tone": tone if TONES.has(tone) else TONE_NEUTRAL,
		"requires": requires,
		"pos": pos,
	}
	nodes.append(node)
	changed.emit()
	return String(node["id"])


func find_node(node_id: String) -> Dictionary:
	for node in nodes:
		if String(node["id"]) == node_id:
			return node
	return {}


func has_node(node_id: String) -> bool:
	return not find_node(node_id).is_empty()


## 图里显示的名字：状态节点是「实体 · 状态」，结局节点是「结局：xxx」。
func node_label(node_id: String) -> String:
	var node := find_node(node_id)
	if node.is_empty():
		return node_id
	if String(node["kind"]) == KIND_OUTCOME:
		return "结局：%s" % String(node["label"])
	return "%s · %s" % [String(node["entity"]), String(node["state"])]


func nodes_of(entity: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for node in nodes:
		if _is_state(node) and String(node["entity"]) == entity:
			result.append(node)
	return result


## 出现过的实体（按首次出现顺序），结局节点不算。
func entities() -> Array[String]:
	var result: Array[String] = []
	for node in nodes:
		if not _is_state(node):
			continue
		var entity := String(node["entity"])
		if not result.has(entity):
			result.append(entity)
	return result


func states_of(entity: String) -> Array[String]:
	var result: Array[String] = []
	for node in nodes_of(entity):
		var state := String(node["state"])
		if not result.has(state):
			result.append(state)
	return result


## 删节点会连带删掉相关连线和「把它当条件的结局」，不留悬空引用。
func remove_node(node_id: String) -> bool:
	var removed := false
	var kept: Array[Dictionary] = []
	for node in nodes:
		if String(node["id"]) == node_id:
			removed = true
			continue
		if _node_kind_of(node) == KIND_OUTCOME:
			var requires: Array = node.get("requires", [])
			if requires.has(node_id):
				var trimmed: Array = []
				for raw in requires:
					if String(raw) != node_id:
						trimmed.append(String(raw))
				node["requires"] = trimmed
				if trimmed.is_empty():
					# 条件被删光的结局没有意义，一起删掉
					removed = true
					continue
		kept.append(node)
	if not removed:
		return false
	nodes = kept
	var kept_edges: Array[Dictionary] = []
	for edge in edges:
		if String(edge["from"]) == node_id or String(edge["to"]) == node_id:
			continue
		kept_edges.append(edge)
	edges = kept_edges
	changed.emit()
	return true


## 拖动节点时由画布高频调用；通知可以关掉，避免每帧重建整张图。
func move_node(node_id: String, pos: Vector2, notify: bool = true) -> bool:
	var node := find_node(node_id)
	if node.is_empty():
		return false
	node["pos"] = pos
	if notify:
		changed.emit()
	return true


## 只改「实体/状态」，结局节点请走 set_outcome_label。
func set_node_label(node_id: String, entity: String, state: String) -> bool:
	var node := find_node(node_id)
	if node.is_empty() or not _is_state(node):
		return false
	var clean_entity := entity.strip_edges()
	var clean_state := state.strip_edges()
	if clean_entity.is_empty() or clean_state.is_empty():
		return false
	node["entity"] = clean_entity
	node["state"] = clean_state
	node["label"] = "%s · %s" % [clean_entity, clean_state]
	changed.emit()
	return true


# --- 边 -----------------------------------------------------------------------

## 状态切换。两端都必须是已存在的状态节点，不能自环；同一对两端只保留一条。
func add_edge(from_id: String, to_id: String, label: String = "") -> String:
	if from_id == to_id:
		_report("不能把节点连到自己")
		return ""
	if not has_node(from_id) or not has_node(to_id):
		_report("连线的两端必须都存在")
		return ""
	if _node_kind(from_id) != KIND_STATE or _node_kind(to_id) != KIND_STATE:
		_report("切换连线的两端都必须是状态节点")
		return ""
	if not find_edge_between(from_id, to_id).is_empty():
		_report("这两个状态之间已经有切换了")
		return ""
	var edge := {
		"id": _make_id("edge"),
		"from": from_id,
		"to": to_id,
		"label": label.strip_edges(),
	}
	edges.append(edge)
	changed.emit()
	return String(edge["id"])


func find_edge(edge_id: String) -> Dictionary:
	for edge in edges:
		if String(edge["id"]) == edge_id:
			return edge
	return {}


func find_edge_between(from_id: String, to_id: String) -> Dictionary:
	for edge in edges:
		if String(edge["from"]) == from_id and String(edge["to"]) == to_id:
			return edge
	return {}


func remove_edge(edge_id: String) -> bool:
	var kept: Array[Dictionary] = []
	for edge in edges:
		if String(edge["id"]) != edge_id:
			kept.append(edge)
	if kept.size() == edges.size():
		return false
	edges = kept
	changed.emit()
	return true


func set_edge_label(edge_id: String, label: String) -> bool:
	var edge := find_edge(edge_id)
	if edge.is_empty():
		return false
	edge["label"] = label.strip_edges()
	changed.emit()
	return true


# --- 判定 ---------------------------------------------------------------------

## 给定「当前处于哪些状态节点」，返回命中的结局（条件多的排前面）。
## 只认状态节点；传球局节点 / 不存在的 id 都会被忽略。
func evaluate(active: Array) -> Array[Dictionary]:
	var active_set := {}
	for raw in active:
		var node_id := String(raw)
		if _node_kind(node_id) == KIND_STATE:
			active_set[node_id] = true
	var hits: Array[Dictionary] = []
	for node in nodes:
		if _node_kind_of(node) != KIND_OUTCOME:
			continue
		var requires: Array = node.get("requires", [])
		if requires.is_empty():
			continue
		var matched := true
		for raw in requires:
			if not active_set.has(String(raw)):
				matched = false
				break
		if matched:
			# `requires` 是模型内部字段；`nodes` 是给 UI/测试用的同义列表（触发结局的状态节点 id）。
			var hit: Dictionary = node.duplicate(true)
			hit["nodes"] = (requires as Array).duplicate()
			hits.append(hit)
	hits.sort_custom(func(a, b): return (a["requires"] as Array).size() > (b["requires"] as Array).size())
	return hits


## 所有结局节点（按图里的顺序）。只读属性，方便 UI 与测试直接取。
var outcomes: Array[Dictionary]:
	get:
		var result: Array[Dictionary] = []
		for node in nodes:
			if _node_kind_of(node) == KIND_OUTCOME:
				result.append(node)
		return result


## 删掉一个结局节点；只认结局节点（状态节点请走 remove_node）。
func remove_outcome(outcome_id: String) -> bool:
	if _node_kind(outcome_id) != KIND_OUTCOME:
		return false
	return remove_node(outcome_id)


## 给已存在的结局追加一个触发条件（状态节点）。
func add_requirement(outcome_id: String, state_id: String) -> bool:
	var outcome := find_node(outcome_id)
	if outcome.is_empty() or _node_kind_of(outcome) != KIND_OUTCOME:
		return false
	if _node_kind(state_id) != KIND_STATE:
		_report("结局条件只能是状态节点")
		return false
	var requires: Array = outcome.get("requires", [])
	if requires.has(state_id):
		return false
	requires.append(state_id)
	outcome["requires"] = requires
	changed.emit()
	return true


## 从结局移除一个触发条件；条件删空后结局也一起删掉（无条件结局永远不会命中）。
func remove_requirement(outcome_id: String, state_id: String) -> bool:
	var outcome := find_node(outcome_id)
	if outcome.is_empty() or _node_kind_of(outcome) != KIND_OUTCOME:
		return false
	var requires: Array = outcome.get("requires", [])
	if not requires.has(state_id):
		return false
	var kept: Array = []
	for raw in requires:
		if String(raw) != state_id:
			kept.append(String(raw))
	outcome["requires"] = kept
	if kept.is_empty():
		return remove_node(outcome_id)
	changed.emit()
	return true


func set_outcome_label(outcome_id: String, label: String) -> bool:
	var outcome := find_node(outcome_id)
	if outcome.is_empty() or _node_kind_of(outcome) != KIND_OUTCOME:
		return false
	var clean := label.strip_edges()
	if clean.is_empty():
		_report("结局名称不能为空")
		return false
	outcome["label"] = clean
	changed.emit()
	return true


func set_outcome_tone(outcome_id: String, tone: String) -> bool:
	var outcome := find_node(outcome_id)
	if outcome.is_empty() or _node_kind_of(outcome) != KIND_OUTCOME:
		return false
	if not TONES.has(tone):
		_report("未知结局色调：%s" % tone)
		return false
	outcome["tone"] = tone
	changed.emit()
	return true


## 节点的类型（"state" / "outcome" / ""），给画布/编辑器判断用。
func node_kind(node_id: String) -> String:
	return _node_kind(node_id)


# --- 序列化 -------------------------------------------------------------------

func to_dict() -> Dictionary:
	var raw_nodes: Array = []
	for node in nodes:
		var pos: Vector2 = node.get("pos", Vector2.ZERO)
		raw_nodes.append({
			"id": String(node["id"]),
			"kind": _node_kind_of(node),
			"entity": String(node.get("entity", "")),
			"state": String(node.get("state", "")),
			"label": String(node.get("label", "")),
			"tone": String(node.get("tone", TONE_NEUTRAL)),
			"requires": Array(node.get("requires", [])).duplicate(),
			"pos": [pos.x, pos.y],
		})
	var raw_edges: Array = []
	for edge in edges:
		raw_edges.append({
			"id": String(edge["id"]),
			"from": String(edge["from"]),
			"to": String(edge["to"]),
			"label": String(edge.get("label", "")),
		})
	return {"version": 1, "nodes": raw_nodes, "edges": raw_edges}


## 解析 JSON 对象。失败时保持原图不变，并写入 last_errors。
func from_dict(data: Variant) -> bool:
	last_errors.clear()
	if not data is Dictionary:
		_report("状态图数据必须是 JSON 对象")
		return false
	var raw_nodes: Variant = (data as Dictionary).get("nodes", null)
	if not raw_nodes is Array:
		_report("状态图缺少 nodes 数组")
		return false
	var raw_edges: Variant = (data as Dictionary).get("edges", [])
	if not raw_edges is Array:
		_report("edges 必须是数组")
		return false

	# 先全部解析到临时结构，避免半截数据污染现有图。
	var parsed_nodes: Array[Dictionary] = []
	var seen: Array[String] = []
	for entry in (raw_nodes as Array):
		if not entry is Dictionary:
			_report("nodes 里有非对象元素，已跳过")
			continue
		var dict: Dictionary = entry
		var node_id := String(dict.get("id", "")).strip_edges()
		if node_id.is_empty() or seen.has(node_id):
			_report("节点 id 为空或重复，已跳过：%s" % node_id)
			continue
		var kind := String(dict.get("kind", KIND_STATE))
		if kind != KIND_STATE and kind != KIND_OUTCOME:
			_report("未知节点类型 %s，按状态节点处理" % kind)
			kind = KIND_STATE
		var parsed := {
			"id": node_id,
			"kind": kind,
			"entity": String(dict.get("entity", "")),
			"state": String(dict.get("state", "")),
			"label": String(dict.get("label", "")),
			"tone": String(dict.get("tone", TONE_NEUTRAL)),
			"requires": _to_string_array(dict.get("requires", [])),
			"pos": _to_vector2(dict.get("pos", null)),
		}
		if kind == KIND_STATE and (String(parsed["entity"]).is_empty() or String(parsed["state"]).is_empty()):
			_report("状态节点缺少 entity/state，已跳过：%s" % node_id)
			continue
		if String(parsed["label"]).is_empty():
			parsed["label"] = "%s · %s" % [parsed["entity"], parsed["state"]] if kind == KIND_STATE \
				else "结局"
		if not TONES.has(String(parsed["tone"])):
			parsed["tone"] = TONE_NEUTRAL
		parsed_nodes.append(parsed)
		seen.append(node_id)

	if parsed_nodes.is_empty():
		_report("状态图没有任何有效节点")
		return false

	var kinds := {}
	for node in parsed_nodes:
		kinds[String(node["id"])] = _node_kind_of(node)

	var parsed_edges: Array[Dictionary] = []
	var seen_pairs := {}
	for entry in (raw_edges as Array):
		if not entry is Dictionary:
			continue
		var dict: Dictionary = entry
		var from_id := String(dict.get("from", ""))
		var to_id := String(dict.get("to", ""))
		if not seen.has(from_id) or not seen.has(to_id):
			_report("连线端点不存在，已跳过：%s -> %s" % [from_id, to_id])
			continue
		if from_id == to_id:
			continue
		if kinds.get(from_id, "") != KIND_STATE or kinds.get(to_id, "") != KIND_STATE:
			_report("连线端点不是状态节点，已跳过：%s -> %s" % [from_id, to_id])
			continue
		var pair_key := from_id + ">" + to_id
		if seen_pairs.has(pair_key):
			_report("重复连线已合并：%s -> %s" % [from_id, to_id])
			continue
		seen_pairs[pair_key] = true
		parsed_edges.append({
			"id": String(dict.get("id", "")).strip_edges() if not String(dict.get("id", "")).is_empty()
				else "edge_%d" % (parsed_edges.size() + 1),
			"from": from_id,
			"to": to_id,
			"label": String(dict.get("label", "")),
		})

	# 结局的 requires 只保留存在的状态节点（不允许引用结局、也不允许重复）；
	# 条件删空的结局没有意义，直接丢弃。
	var final_nodes: Array[Dictionary] = []
	for node in parsed_nodes:
		if _node_kind_of(node) != KIND_OUTCOME:
			final_nodes.append(node)
			continue
		var kept: Array = []
		for raw in node["requires"]:
			var ref_id := String(raw)
			if kinds.get(ref_id, "") == KIND_STATE and not kept.has(ref_id):
				kept.append(ref_id)
		node["requires"] = kept
		if kept.is_empty():
			_report("结局没有条件，已跳过：%s" % String(node["id"]))
			continue
		final_nodes.append(node)
	if final_nodes.is_empty():
		_report("状态图没有任何有效节点")
		return false

	nodes = final_nodes
	edges = parsed_edges
	_seq = nodes.size() + edges.size() + 1
	changed.emit()
	return true


func load_from(path: String) -> bool:
	last_errors.clear()
	if not FileAccess.file_exists(path):
		_report("找不到状态图文件：%s" % path)
		return false
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		_report("打不开状态图文件：%s" % path)
		return false
	var text := file.get_as_text()
	file.close()
	var parsed: Variant = JSON.parse_string(text)
	if parsed == null:
		_report("状态图 JSON 解析失败：%s" % path)
		return false
	return from_dict(parsed)


func save_to(path: String) -> bool:
	last_errors.clear()
	var dir_path := path.get_base_dir()
	if not dir_path.is_empty() and not DirAccess.dir_exists_absolute(dir_path):
		if DirAccess.make_dir_recursive_absolute(dir_path) != OK:
			_report("创建目录失败：%s" % dir_path)
			return false
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_report("写不了状态图文件：%s" % path)
		return false
	file.store_string(JSON.stringify(to_dict(), "\t", false))
	file.close()
	return true


# --- 内部 ---------------------------------------------------------------------

func _is_state(node: Dictionary) -> bool:
	return _node_kind_of(node) == KIND_STATE


func _node_kind_of(node: Dictionary) -> String:
	var kind := String(node.get("kind", KIND_STATE))
	return kind if kind == KIND_OUTCOME else KIND_STATE


func _node_kind(node_id: String) -> String:
	var node := find_node(node_id)
	return "" if node.is_empty() else _node_kind_of(node)


## id 用「实体_状态」的可读形式：只保留合法标识符字符，空格/连字符换成下划线；
## 中文在 Godot 里算合法标识符，所以也会原样保留；太短时兜底成 "n"。
func _make_id(seed: String) -> String:
	var base := ""
	for index in seed.length():
		var ch := seed.substr(index, 1)
		if ch.is_valid_identifier() or ch.is_valid_int():
			base += ch.to_lower()
		elif ch == "_" or ch == "-" or ch == " ":
			base += "_"
	base = base.strip_edges()
	while base.begins_with("_"):
		base = base.substr(1)
	if base.length() < 2:
		base = "n"
	var candidate := base
	while has_node(candidate) or _edge_id_taken(candidate):
		candidate = "%s_%d" % [base, _seq]
		_seq += 1
	return candidate


func _edge_id_taken(edge_id: String) -> bool:
	return not find_edge(edge_id).is_empty()


func _to_string_array(value: Variant) -> Array:
	var result: Array = []
	if value is Array:
		for raw in value:
			var text := String(raw)
			if not text.is_empty():
				result.append(text)
	return result


func _to_vector2(value: Variant) -> Vector2:
	if value is Vector2:
		return value
	if value is Array and (value as Array).size() >= 2:
		return Vector2(float((value as Array)[0]), float((value as Array)[1]))
	return Vector2.ZERO


func _report(message: String) -> void:
	last_errors.append(message)
