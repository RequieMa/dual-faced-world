extends Node
## ReplayEventDispatcher：回放中「什么时候该播放视觉事件」的唯一判定点。
##
## 语义（来自 Issue #3）：
## - 只有事件时间落入 (last_sample_time, playback_time] 才派发；
## - 向前 seek 只重建状态、不补播事件（窗口起点跟到目标）；
## - 向后 seek 之后窗口起点一起回退，重播时会重新落入窗口。
## 是否重复登记由 ClueManager 的去重键 (t, type, actor, target) 兜底。

signal event_dispatched(entry: Dictionary)

const SimTimeline = preload("res://scripts/sim/sim_timeline.gd")

var _timeline: Dictionary = {}
var last_sample_time := 0.0
var dispatched_count := 0


func reset(timeline: Dictionary, start_time: float) -> void:
	_timeline = timeline
	last_sample_time = start_time
	dispatched_count = 0


## 播放推进一帧：派发窗口内的事件，然后移动窗口起点。
func advance(current: float) -> void:
	if _timeline.is_empty():
		return
	var window_from := last_sample_time
	var window_to := maxf(current, window_from)
	for entry in SimTimeline.events_between(_timeline, window_from, window_to):
		dispatched_count += 1
		event_dispatched.emit(entry)
	last_sample_time = window_to


## seek：不论方向都不派发事件，窗口起点直接落到目标时刻。
func seek(target: float, _forward: bool) -> void:
	last_sample_time = target


func get_state() -> Dictionary:
	return {"last_sample_time": last_sample_time, "dispatched_count": dispatched_count}
