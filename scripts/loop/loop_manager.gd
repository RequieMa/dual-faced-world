extends Node
## W6 循环 / 回溯框架：一轮的起止、回退到某时刻（含世界重置）、玩家知识保留。
##
## 契约见 docs/MECHANICS_CONTRACTS.md §3。本类只做原语，不预设剧情理由
## （M12 / M13 见 Issue #20）：
## - 回放式重开：`start_round()` + `reset_world(participants, 起点时间)`；
## - 回退到时刻：`rewind_to(time, participants)`。
##
## 世界重置与知识保留分离：
## - 世界状态只通过调用方传入的 participants 处理；参与者是鸭子类型，
##   实现 `reset_for_loop(time: float) -> void` 把自己重置到 time 这一刻；
## - 本类不持有 ClueManager，也不提供清空知识的路径，所以玩家的 timeline 线索
##   在回退 / 重开时不会被清空（ClueManager 只读消费，见契约 §3）。
## - M16 拍板前不恢复烧毁的机位：是否恢复由参与者（W1 适配器）自己决定。

signal round_started(round_index: int)
signal round_ended(round_index: int, summary: Dictionary)
signal world_reset()

const LoopState := preload("res://scripts/loop/loop_state.gd")

var _state


func _init() -> void:
	_state = LoopState.new()


## 开始新一轮：轮次 +1 并广播 round_started（首轮从 1 开始）。
func start_round() -> void:
	_state.begin_round(_state.get_round() + 1)
	round_started.emit(_state.get_round())


## 结束当前轮：记录 summary（补齐 round/time/outcome/clues/solved，字段可扩展）
## 并广播 round_ended。不修改调用方传入的字典。
func end_round(summary: Dictionary) -> void:
	var recorded: Dictionary = _state.record(summary, _state.get_round())
	round_ended.emit(int(recorded["round"]), recorded.duplicate(true))


## 回退到 time：先把所有参与者重置到该时刻，再广播 world_reset，返回 true。
## 单个参与者不可用时 push_warning 并继续，不整体失败（契约 §3）。
func rewind_to(time: float, participants: Array) -> bool:
	reset_world(participants, time)
	world_reset.emit()
	return true


## 只做世界重置，不广播 world_reset（由 rewind_to 统一广播）。
## 回放式重开可以直接用 `reset_world(participants, 起点)`。
func reset_world(participants: Array, time: float) -> void:
	for participant in participants:
		_reset_participant(participant, time)


func get_round_index() -> int:
	return _state.get_round()


func get_history() -> Array:
	return _state.get_history()


func to_dict() -> Dictionary:
	return _state.to_dict()


func from_dict(data: Dictionary) -> void:
	_state.from_dict(data)


# --- 内部 ---------------------------------------------------------------------

func _reset_participant(participant, time: float) -> void:
	# is_instance_valid 同时挡住 null、非 Object 值和已 free 的 Node/RefCounted；
	# 直接对已释放实例做 `is Object` 会抛引擎级 SCRIPT ERROR。
	if not is_instance_valid(participant):
		push_warning("LoopManager: 跳过已释放或非 Object 的参与者")
		return
	if not participant.has_method("reset_for_loop"):
		push_warning("LoopManager: 参与者 %s 没有 reset_for_loop(time)，已跳过" % participant)
		return
	participant.reset_for_loop(time)
