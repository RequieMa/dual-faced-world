extends Node
## GuideBus：玩家 → 世界 的引导动作总线（W2）。
##
## 契约见 docs/MECHANICS_CONTRACTS.md §2：
##   register_target / unregister_target / get_targets
##   send_hint(target_id, text) / set_indicator(id, on) / open_door(id) / get_state()
##   signal hint_sent(target_id, text) / indicator_changed(id, on) / door_opened(id)
##
## 这里是目标注册表：场景把 NPC / 灯 / 门注册进来，bus 按 id 解析到节点并做
## 鸭子类型调用（NPC.on_hint / 灯.set_on+is_on / 门.open+is_open）。
## 未注册 / 能力不符的目标一律返回 false + push_warning，不崩、不发成功信号；
## 重复开灯/开门幂等：状态不变时不重复发信号。
##
## demo_* 是演示场景专用的自动播放（契约外的便利功能），默认关闭，不影响单测。

signal hint_sent(target_id: String, text: String)
signal indicator_changed(id: String, on: bool)
signal door_opened(id: String)

## demo 场景用：自动把子节点里带 get_target_id() 的 NPC/灯/门注册进来，
## 并把 hint_sent 接到扬声器的 on_bus_hint()。默认关闭，单测显式注册。
@export var auto_register_targets: bool = false
@export var demo_autoplay: bool = false
## [{ "at": 0.5, "action": "hint", "id": "npc_a", "text": "follow" }, ...]
@export var demo_steps: Array = []

var _targets: Dictionary = {}  # target_id -> Node
var _demo_time := 0.0
var _demo_index := 0


func _ready() -> void:
	if auto_register_targets:
		_auto_register(self)
		_wire_speakers(self)
	set_process(demo_autoplay and not demo_steps.is_empty())


func _process(delta: float) -> void:
	if not demo_autoplay:
		return
	_demo_time += delta
	while _demo_index < demo_steps.size():
		var entry = demo_steps[_demo_index]
		if not (entry is Dictionary):
			push_warning("GuideBus: demo 步骤必须是 Dictionary，已跳过: %s" % str(entry))
			_demo_index += 1
			continue
		var step: Dictionary = entry
		if _demo_time < float(step.get("at", 0.0)):
			break
		_apply_demo_step(step)
		_demo_index += 1
	# 仅 demo_autoplay 时由 bus 代宿主 tick 已注册的 NPC；生产环境由 GameRoot 调 tick，
	# 避免两边同时 tick 导致移动速度翻倍。
	for target_id in _targets.keys():
		var node = _targets[target_id]
		if is_instance_valid(node) and node.has_method("tick"):
			node.tick(delta)


# --- 公开接口（W0 契约） -------------------------------------------------------

## 注册一个目标节点。空 id / null / 重复 id 返回 false。
func register_target(target_id: String, node: Node) -> bool:
	if target_id.is_empty():
		push_warning("GuideBus: 目标 id 不能为空")
		return false
	if node == null:
		push_warning("GuideBus: 目标 %s 的节点为 null" % target_id)
		return false
	if _targets.has(target_id):
		push_warning("GuideBus: 目标 id 重复注册: %s" % target_id)
		return false
	_targets[target_id] = node
	return true


func unregister_target(target_id: String) -> void:
	_targets.erase(target_id)


## 已注册 id，排序后返回，保证 get_state / 测试输出稳定。
func get_targets() -> Array:
	# 目标可能在注册后被释放；这里顺手清掉失效条目，避免 get_state 继续列出幽灵 id。
	for target_id in _targets.keys():
		if not is_instance_valid(_targets[target_id]):
			_targets.erase(target_id)
	var ids: Array = _targets.keys()
	ids.sort()
	return ids


## 让目标 NPC 接受一条提示；NPC 拒绝（未知提示 / 无路径）时返回 false 且不发信号。
func send_hint(target_id: String, text: String) -> bool:
	var node := _resolve_target(target_id)
	if node == null:
		return false
	var hint := text.strip_edges()
	if hint.is_empty():
		push_warning("GuideBus: 空提示不能发送")
		return false
	if not node.has_method("on_hint"):
		push_warning("GuideBus: 目标 %s 不能接收 hint" % target_id)
		return false
	var accepted = node.on_hint(hint)
	if accepted != true:
		return false
	hint_sent.emit(target_id, hint)
	return true


## 设置灯的状态。目标能力不符 / 未注册返回 false；状态不变时幂等且不重复发信号。
func set_indicator(id: String, on: bool) -> bool:
	var node := _resolve_target(id)
	if node == null:
		return false
	if not node.has_method("set_on") or not node.has_method("is_on"):
		push_warning("GuideBus: 目标 %s 不是可设置的指示灯" % id)
		return false
	var before := bool(node.is_on())
	var applied = node.set_on(on)
	if applied != true:
		return false
	var after := bool(node.is_on())
	if before != after:
		indicator_changed.emit(id, after)
	return true


## 打开门。目标能力不符 / 未注册返回 false；已经打开时幂等且不重复发信号。
func open_door(id: String) -> bool:
	var node := _resolve_target(id)
	if node == null:
		return false
	if not node.has_method("open") or not node.has_method("is_open"):
		push_warning("GuideBus: 目标 %s 不是可打开的门" % id)
		return false
	var was_open := bool(node.is_open())
	var applied = node.open()
	if applied != true:
		return false
	var now_open := bool(node.is_open())
	if now_open and not was_open:
		door_opened.emit(id)
	return true


## 调试 / 测试 / 存档用快照：目标列表 + 各类目标自己的状态。
func get_state() -> Dictionary:
	var npcs := {}
	var indicators := {}
	var doors := {}
	for target_id in _targets.keys():
		var node = _targets[target_id]
		if not is_instance_valid(node):
			continue
		var key := String(target_id)
		if node.has_method("on_hint") and node.has_method("get_state"):
			npcs[key] = node.get_state()
		elif node.has_method("is_on"):
			indicators[key] = bool(node.is_on())
		elif node.has_method("is_open"):
			doors[key] = bool(node.is_open())
	return {
		"targets": get_targets(),
		"npcs": npcs,
		"indicators": indicators,
		"doors": doors,
	}


# --- 内部 ---------------------------------------------------------------------

func _resolve_target(target_id: String) -> Node:
	if target_id.is_empty():
		push_warning("GuideBus: 目标 id 为空")
		return null
	if not _targets.has(target_id):
		push_warning("GuideBus: 未注册的目标: %s" % target_id)
		return null
	var node = _targets[target_id]
	if not is_instance_valid(node):
		_targets.erase(target_id)
		push_warning("GuideBus: 目标已失效，已移除: %s" % target_id)
		return null
	return node


func _auto_register(node: Node) -> void:
	for child in node.get_children():
		if child.has_method("get_target_id"):
			var target_id := String(child.get_target_id())
			if not target_id.is_empty():
				register_target(target_id, child)
		_auto_register(child)


func _wire_speakers(node: Node) -> void:
	for child in node.get_children():
		if child.has_method("play_hint") and child.has_method("on_bus_hint"):
			var callback := Callable(child, "on_bus_hint")
			if not hint_sent.is_connected(callback):
				hint_sent.connect(callback)
		_wire_speakers(child)


func _apply_demo_step(step: Dictionary) -> void:
	match String(step.get("action", "")):
		"hint":
			send_hint(String(step.get("id", "")), String(step.get("text", "")))
		"indicator":
			set_indicator(String(step.get("id", "")), bool(step.get("on", false)))
		"door":
			open_door(String(step.get("id", "")))
		_:
			push_warning("GuideBus: 未知 demo 步骤: %s" % str(step))
