extends RefCounted
## 录像带采样器：把「某盘带 + 播放位置」变成一份完整状态。
##
## playback_time 是绝对档案时间（与 EventTimeline 同一条时间轴），
## 采样时钳制到该带窗口 [time_start, time_end]：越界的播放位置不会读到别的带的内容。

const SimTimeline = preload("res://scripts/sim/sim_timeline.gd")


static func sample(timeline: Dictionary, tape, playback_time: float) -> Dictionary:
	var target := playback_time
	if tape != null:
		target = clampf(playback_time, float(tape.time_start), float(tape.time_end))
	else:
		target = clampf(playback_time, 0.0, float(timeline.get("duration", SimTimeline.DURATION)))
	var state: Dictionary = SimTimeline.state_at(timeline, target)
	var result: Dictionary = state.duplicate(true)
	result["sampled_time"] = target
	return result
