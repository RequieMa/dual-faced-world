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
const TMP_REQ := "user://state_graph_requirement_test.json"

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
		var clue_first := String((clue_nodes[0] as Dictionary)["id"])
		var clue_last := String((clue_nodes[-1] as Dictionary)["id"])
		# 默认图里 clue_first -> clue_last 已经有边，这里反过来建一条验证新增。
		var edge_id: String = model.add_edge(clue_last, clue_first, "倒带回未拾取")
		_check("连线成功", not edge_id.is_empty(), str(model.last_errors))
		_check("连线记录触发词",
			String(model.find_edge(edge_id).get("label", "")) == "倒带回未拾取")
		_check("重复切换被拒", model.add_edge(clue_last, clue_first, "重复") == "")
		_check("未知端点被拒", model.add_edge(clue_first, "no_such_node", "") == "")
		_check("自环被拒", model.add_edge(clue_first, clue_first, "") == "")
		_check("结局不能当切换端点", model.add_edge(clue_first, "caught", "") == "")

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

	# 用户例子：敌人·巡逻 + 摄像头·过载烧毁 → 成功逃脱
	var enemy_patrol := _find_node_id(model, "敌人", "巡逻")
	var cam_burn := _find_node_id(model, "摄像头", "过载烧毁")
	_check("默认图有敌人·巡逻", not enemy_patrol.is_empty())
	_check("默认图有摄像头·过载烧毁", not cam_burn.is_empty())
	var escape_hits: Array = model.evaluate([enemy_patrol, cam_burn])
	_check("敌人巡逻 + 摄像头烧毁命中「成功逃脱」",
		_outcome_ids(escape_hits).has("escape"), str(_outcome_ids(escape_hits)))
	_check("命中结局的 nodes 正好是两个条件",
		int((_find_outcome(escape_hits, "escape").get("nodes", []) as Array).size()) == 2)

	# 结局条件 API：追加 / 去重 / 移除 / 条件删空自动删结局
	_check("空条件结局被拒", model.add_outcome([], "空结局", "neutral") == "")
	var req_outcome: String = model.add_outcome([enemy_patrol], "临时单条件", "neutral")
	_check("单条件结局可创建", not req_outcome.is_empty())
	_check("追加第二个条件", model.add_requirement(req_outcome, cam_burn))
	_check("requires 记录两个条件",
		int((model.find_node(req_outcome).get("requires", []) as Array).size()) == 2)
	_check("重复追加同一条件被拒", not model.add_requirement(req_outcome, cam_burn))
	_check("结局不能拿另一个结局当条件", not model.add_requirement(req_outcome, "caught"))
	_check("移除一个条件", model.remove_requirement(req_outcome, enemy_patrol))
	_check("条件减少到 1 个",
		int((model.find_node(req_outcome).get("requires", []) as Array).size()) == 1)
	_check("移除最后一个条件会删掉结局", model.remove_requirement(req_outcome, cam_burn))
	_check("条件删空后结局不再存在", not model.has_node(req_outcome))

	# 结局名字 / 色调可编辑
	_check("结局改名", model.set_outcome_label("caught", "被当场抓住"))
	_check("结局名已更新", String(model.find_node("caught")["label"]) == "被当场抓住")
	_check("空结局名被拒", not model.set_outcome_label("caught", "   "))
	_check("结局色调可改", model.set_outcome_tone("caught", "neutral"))
	_check("非法色调被拒", not model.set_outcome_tone("caught", "unknown"))

	# 静默移动（画布拖拽用）不广播 changed，普通移动才广播
	var move_model = load(MODEL_PATH).new()
	move_model.load_from(DATA_PATH)
	var change_count := [0]
	move_model.changed.connect(func(): change_count[0] += 1)
	move_model.move_node("round_playing", Vector2(11, 22), false)
	_check("静默移动不广播 changed", change_count[0] == 0, str(change_count[0]))
	move_model.move_node("round_playing", Vector2(11, 22), true)
	_check("普通移动广播 changed", change_count[0] == 1, str(change_count[0]))

	# 删：删节点要带走相关连线与结局条件
	var before_edges: int = model.edges.size()
	model.remove_node(enemy_watch)
	_check("删除节点后查不到", not model.has_node(enemy_watch))
	_check("删除节点不波及其它节点的连线计数", model.edges.size() <= before_edges)
	var dangling := 0
	for edge in model.edges:
		if not (model.has_node(String(edge["from"])) and model.has_node(String(edge["to"]))):
			dangling += 1
	_check("删除后没有悬空连线", dangling == 0, str(dangling))

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

	# 存取：条件也要完整落盘
	var persist_id: String = model.add_outcome([enemy_patrol, cam_burn], "持久化结局", "fail")
	_check("持久化结局可创建", not persist_id.is_empty())
	_check("保存到文件", model.save_to(TMP_SAVE), str(model.last_errors))
	var reloaded = load(MODEL_PATH).new()
	_check("从文件载入", reloaded.load_from(TMP_SAVE), str(reloaded.last_errors))
	_check("存取后节点数一致", reloaded.nodes.size() == model.nodes.size(),
		"%d vs %d" % [reloaded.nodes.size(), model.nodes.size()])
	_check("存取后结局数量一致", reloaded.outcomes.size() == model.outcomes.size())
	_check("存取后结局条件保留",
		int((reloaded.find_node(persist_id).get("requires", []) as Array).size()) == 2,
		str(reloaded.find_node(persist_id)))
	_check("载入不存在的文件返回 false", not reloaded.load_from("res://no_such_graph.json"))
	_check("载入失败有 last_errors", not reloaded.last_errors.is_empty())
	_check("坏数据不炸且被拒", not reloaded.from_dict({"nodes": "not an array"}))

	# 外部数据里的重复连线 / 结局端点连线在载入时过滤掉
	var dirty: Dictionary = model.to_dict()
	dirty["edges"].append({"id": "dup", "from": "enemy_patrol", "to": "enemy_blind", "label": "重复"})
	dirty["edges"].append({"id": "bad", "from": "caught", "to": "enemy_patrol", "label": "结局当端点"})
	var filtered = load(MODEL_PATH).new()
	_check("带脏连线的数据能载入", filtered.from_dict(dirty), str(filtered.last_errors))
	_check("重复/结局端点连线被过滤", filtered.edges.size() == model.edges.size(),
		"%d vs %d" % [filtered.edges.size(), model.edges.size()])
	var only_empty := {
		"nodes": [{
			"id": "empty_outcome", "kind": "outcome", "entity": "", "state": "",
			"label": "空结局", "tone": "neutral", "requires": [], "pos": [0, 0],
		}],
		"edges": [],
	}
	var empty_model = load(MODEL_PATH).new()
	_check("只有空结局的数据被拒", not empty_model.from_dict(only_empty))


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

	# 拖放：模板 → 画布新建节点
	var template_data := {
		"state_graph_node": true, "kind": "template",
		"entity": "敌人", "state": "潜行",
	}
	_check("画布接受状态节点拖放", editor.canvas._can_drop_data(Vector2.ZERO, template_data))
	var before_nodes: int = editor.model.nodes.size()
	editor.canvas._drop_data(Vector2(320, 180), template_data)
	_check("拖放画布后节点 +1", editor.model.nodes.size() == before_nodes + 1,
		"%d vs %d" % [editor.model.nodes.size(), before_nodes + 1])
	_check("拖放后画布节点同步", editor.get_graph_node_count() == editor.model.nodes.size())

	# 拖放：已有节点 → 右侧结局面板
	var enemy_patrol := _find_node_id(editor.model, "敌人", "巡逻")
	var cam_burn := _find_node_id(editor.model, "摄像头", "过载烧毁")
	var condition_data := {
		"state_graph_node": true, "kind": "existing", "id": enemy_patrol,
		"entity": "敌人", "state": "巡逻",
	}
	_check("结局面板接受状态节点拖放", editor.outcome_panel._can_drop_data(Vector2.ZERO, condition_data))
	editor.outcome_panel.clear_conditions()
	editor.outcome_panel._drop_data(Vector2.ZERO, condition_data)
	_check("拖入状态成为结局条件", editor.outcome_panel.get_condition_ids().has(enemy_patrol))
	editor.outcome_panel._drop_data(Vector2.ZERO, {
		"state_graph_node": true, "kind": "existing", "id": cam_burn,
		"entity": "摄像头", "state": "过载烧毁",
	})
	_check("第二个条件也加进来了", editor.outcome_panel.get_condition_ids().size() == 2)

	var before_outcomes: int = editor.model.outcomes.size()
	var custom_outcome: String = editor.outcome_panel.create_outcome("测试逃脱", "win")
	_check("生成结局成功", not custom_outcome.is_empty(), str(editor.model.last_errors))
	_check("结局数量 +1", editor.model.outcomes.size() == before_outcomes + 1)
	_check("结局条件写入模型",
		int((editor.model.find_node(custom_outcome).get("requires", []) as Array).size()) == 2,
		str(editor.model.find_node(custom_outcome)))
	_check("画布出现结局节点", editor.get_graph_node_count() == editor.model.nodes.size())
	_check("生成后清空待用条件", editor.outcome_panel.get_condition_ids().is_empty())

	# 整理布局 + 带条件的存取
	editor.arrange_layout()
	_check("整理布局后画布节点仍一致", editor.get_graph_node_count() == editor.model.nodes.size())
	_check("保存带条件的图", editor.save_to(TMP_REQ), str(editor.model.last_errors))
	_check("重新载入带条件的图", editor.load_from(TMP_REQ), str(editor.model.last_errors))
	_check("载入后结局条件保留",
		int((editor.model.find_node(custom_outcome).get("requires", []) as Array).size()) == 2)

	editor.queue_free()


# --- 断言工具 -----------------------------------------------------------------

func _find_node_id(model, entity: String, state: String) -> String:
	for node in model.nodes:
		if String(node.get("entity", "")) == entity and String(node.get("state", "")) == state:
			return String(node["id"])
	return ""


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
