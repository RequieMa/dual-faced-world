extends SceneTree
## 状态图编辑器（设计工具）回归：模型（节点／切换边／结局规则）的增删改与判定、
## JSON 存取，以及编辑器场景真的能装配成一张可编辑的图。
## 运行：godot --headless --path . --script tests/test_state_graph.gd

const MODEL_PATH := "res://scripts/state_graph/state_graph_model.gd"
const SCENE_PATH := "res://scenes/state_graph_editor.tscn"
const DATA_PATH := "res://resources/data/state_graph.json"
const CANVAS_PATH := "res://scripts/state_graph/state_graph_canvas.gd"
const PALETTE_PATH := "res://scripts/state_graph/state_node_button.gd"

const TMP_SAVE := "user://state_graph_save_test.json"
const TMP_MOVE := "user://state_graph_move_test.json"

var _failures: Array[String] = []
var _checks: int = 0
var _started := false


func _initialize() -> void:
	_check("模型脚本存在", ResourceLoader.exists(MODEL_PATH))
	_check("画布脚本存在", ResourceLoader.exists(CANVAS_PATH))
	_check("节点面板按钮脚本存在", ResourceLoader.exists(PALETTE_PATH))
	_check("编辑器场景存在", ResourceLoader.exists(SCENE_PATH))
	_check("默认状态图数据存在", FileAccess.file_exists(DATA_PATH))


func _process(_delta: float) -> bool:
	if _started:
		return false
	_started = true
	_run_model_tests()
	_run_editor_tests()
	_report()
	return false


# --- 模型 ---------------------------------------------------------------------

func _run_model_tests() -> void:
	var model = load(MODEL_PATH).new()
	_check("默认图能载入", model.load_from(DATA_PATH), str(model.last_errors))
	_check("默认图节点数 ≥ 10", model.nodes.size() >= 10, str(model.nodes.size()))

	var entity_list: Array = model.entities()
	for expected in ["敌人", "摄像头", "朋友", "门", "线索", "回合"]:
		_check("默认图含实体 %s" % expected, entity_list.has(expected), str(entity_list))

	# 增：同一对 实体/状态 可以重复拖入，但 id 必须唯一
	var enemy_watch: String = model.add_node("敌人", "发现", Vector2(10, 20))
	_check("新增节点返回 id", not enemy_watch.is_empty())
	_check("新增节点可查到", String(model.find_node(enemy_watch).get("state", "")) == "发现",
		str(model.find_node(enemy_watch)))
	var second_watch: String = model.add_node("敌人", "发现", Vector2(30, 40))
	_check("同实体同状态可重复拖入且 id 不同", second_watch != enemy_watch)
	_check("节点标签是「实体 · 状态」",
		model.node_label(enemy_watch) == "敌人 · 发现", model.node_label(enemy_watch))

	# 边：只接受已存在的两端，且拒绝自环
	var clue_nodes: Array = model.nodes_of("线索")
	_check("默认图有线索节点", not clue_nodes.is_empty())
	if not clue_nodes.is_empty():
		var edge_id: String = model.add_edge(clue_nodes[0], clue_nodes[-1], "E 拾取")
		_check("连线成功", not edge_id.is_empty())
		_check("连线记录触发词", String(model.find_edge(edge_id).get("label", "")) == "E 拾取")
		_check("未知端点被拒", model.add_edge(clue_nodes[0], "no_such_node", "") == "")
		_check("自环被拒", model.add_edge(clue_nodes[0], clue_nodes[0], "") == "")

	# 判定：两个节点两种状态 → 一个结局
	var matched: Array = model.evaluate(["clue_none", "clue_has"])
	_check("evaluate 接受不存在的节点 id 不崩", matched is Array)
	var win_pair := _find_pair_nodes(model)
	_check("默认图里能找到「敌人·巡逻」与「朋友·跟随」这类组合", not win_pair.is_empty(), str(win_pair))
	if win_pair.size() == 2:
		var only_one: Array = model.evaluate([win_pair[0]])
		var both: Array = model.evaluate([win_pair[0], win_pair[1]])
		_check("缺一个条件不触发双条件结局", _outcome_ids(only_one).find("caught") == -1,
			str(_outcome_ids(only_one)))
		_check("两个条件齐了触发结局", _outcome_ids(both).has("caught"), str(_outcome_ids(both)))
		_check("命中的结局带 nodes 列表",
			int((_find_outcome(both, "caught").get("nodes", []) as Array).size()) == 2)
	_check("空选择不判定出结局", model.evaluate([]).is_empty())

	# 删：删节点要带走相关连线与结局条件
	var before_edges: int = model.edges.size()
	model.remove_node(enemy_watch)
	_check("删除节点后查不到", not model.has_node(enemy_watch))
	_check("删除节点不波及其它节点的连线计数", model.edges.size() <= before_edges)
	for edge in model.edges:
		_check("删除后没有悬空连线", model.has_node(String(edge["from"])) and model.has_node(String(edge["to"])),
			str(edge))

	# 结局规则的增删
	var triple: Array = [second_watch]
	if win_pair.size() == 2:
		triple = [win_pair[0], win_pair[1], second_watch]
	var rule_id: String = model.add_outcome(triple, "自定义结局", "win")
	_check("新增结局规则", not rule_id.is_empty())
	var triple_hits: Array = model.evaluate(triple)
	_check("三条件结局能被判定命中", _outcome_ids(triple_hits).has(rule_id), str(_outcome_ids(triple_hits)))
	_check("条件多的结局排在前面",
		not triple_hits.is_empty() and int((triple_hits[0] as Dictionary).get("nodes", []).size()) >= 2)
	_check("删除结局规则", model.remove_outcome(rule_id))

	# 存取
	_check("保存到文件", model.save_to(TMP_SAVE), str(model.last_errors))
	var reloaded = load(MODEL_PATH).new()
	_check("从文件载入", reloaded.load_from(TMP_SAVE), str(reloaded.last_errors))
	_check("存取后节点数一致", reloaded.nodes.size() == model.nodes.size(),
		"%d vs %d" % [reloaded.nodes.size(), model.nodes.size()])
	_check("存取后结局数量一致", reloaded.outcomes.size() == model.outcomes.size())
	_check("载入不存在的文件返回 false", not reloaded.load_from("res://no_such_graph.json"))
	_check("载入失败有 last_errors", not reloaded.last_errors.is_empty())
	_check("坏数据不炸且被拒", not reloaded.from_dict({"nodes": "not an array"}))


# --- 编辑器场景 -----------------------------------------------------------------

func _run_editor_tests() -> void:
	var packed := ResourceLoader.load(SCENE_PATH) as PackedScene
	_check("场景可实例化", packed != null)
	if packed == null:
		return
	var editor := packed.instantiate()
	root.add_child(editor)
	_check("编辑器有 GraphEdit 画布", editor.canvas is GraphEdit)
	_check("编辑器有状态节点面板", editor.palette != null)
	_check("画布节点数与模型一致",
		editor.get_graph_node_count() == editor.model.nodes.size(),
		"%d vs %d" % [editor.get_graph_node_count(), editor.model.nodes.size()])

	var new_id: String = editor.add_state_node("朋友", "被挡住", Vector2(240, 160))
	_check("代码拖入节点成功", not new_id.is_empty())
	_check("画布同步出现新节点", editor.get_graph_node_count() == editor.model.nodes.size())
	_check("拖入的节点在模型里", editor.model.has_node(new_id))

	var follow_nodes: Array = editor.model.nodes_of("朋友")
	var other_id := ""
	for node in follow_nodes:
		if String(node["id"]) != new_id:
			other_id = String(node["id"])
			break
	_check("能拿到第二个节点用于连线", not other_id.is_empty())
	_check("代码连线成功", editor.connect_nodes(other_id, new_id, "测试切换"))
	_check("连线写进模型", _edge_exists(editor.model, other_id, new_id))

	_check("编辑器能保存", editor.save_to(TMP_MOVE), str(editor.model.last_errors))
	_check("编辑器能载入", editor.load_from(TMP_MOVE), str(editor.model.last_errors))

	editor.queue_free()


# --- 断言工具 -----------------------------------------------------------------

func _outcome_ids(list: Array) -> Array:
	var ids: Array = []
	for entry in list:
		ids.append(String(entry.get("id", "")))
	return ids


func _find_outcome(list: Array, outcome_id: String) -> Dictionary:
	for entry in list:
		if String(entry.get("id", "")) == outcome_id:
			return entry
	return {}


func _edge_exists(model, from_id: String, to_id: String) -> bool:
	for edge in model.edges:
		if String(edge["from"]) == from_id and String(edge["to"]) == to_id:
			return true
	return false


## 默认图里必须存在「敌人·巡逻 + 朋友·跟随 → 被抓」这条组合用例。
func _find_pair_nodes(model) -> Array:
	var enemy: String = ""
	var friend_id: String = ""
	for node in model.nodes:
		var entity := String(node["entity"])
		var state := String(node["state"])
		if entity == "敌人" and state == "巡逻":
			enemy = String(node["id"])
		elif entity == "朋友" and state == "跟随":
			friend_id = String(node["id"])
	if enemy.is_empty() or friend_id.is_empty():
		return []
	return [enemy, friend_id]


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
		print("STATE_GRAPH_TEST_PASS (%d checks)" % _checks)
		quit(0)
	else:
		printerr("STATE_GRAPH_TEST_FAIL (%d/%d failed)" % [_failures.size(), _checks])
		for failure in _failures:
			printerr("  - ", failure)
		quit(1)
