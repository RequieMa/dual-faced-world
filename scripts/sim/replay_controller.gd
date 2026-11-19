extends Node
## ReplayController：档案回放的时间轴（第二阶段也复用它，签名不再变）。
##
## playback_time / speed / paused 全部由时钟 delta 驱动，不用 VideoStreamPlayer：
## 回放位置是「档案时间轴上的秒数」，画面则来自 TapeSampler 采样。
## 暂停时不推进；到达带尾自动暂停并广播 tape_finished。

signal ticked(previous: float, current: float)
signal seeked(previous: float, current: float, forward: bool)
signal state_changed()
signal tape_finished(tape)

var tape = null
var active := false
var paused := true
var speed := 1.0
var playback_time := 0.0


func _process(delta: float) -> void:
	advance(delta)


## 打开一盘带：停在带首、默认暂停，等玩家按播放。
func open_tape(new_tape) -> void:
	tape = new_tape
	active = true
	paused = true
	playback_time = float(tape.time_start) if tape != null else 0.0
	state_changed.emit()


func close() -> void:
	active = false
	paused = true
	tape = null
	playback_time = 0.0
	state_changed.emit()


func set_paused(value: bool) -> void:
	if paused == value:
		return
	paused = value
	state_changed.emit()


func toggle_paused() -> void:
	set_paused(not paused)


func set_speed(value: float) -> void:
	speed = clampf(value, 0.1, 8.0)
	state_changed.emit()


## 时钟驱动播放；返回是否推进了时间。
func advance(delta: float) -> bool:
	if not active or paused or delta <= 0.0:
		return false
	var previous := playback_time
	var target := clampf(playback_time + delta * speed, _window_start(), _window_end())
	if is_equal_approx(target, previous):
		return false
	playback_time = target
	ticked.emit(previous, playback_time)
	if playback_time >= _window_end() - 0.0001:
		paused = true
		state_changed.emit()
		tape_finished.emit(tape)
	return true


## 定位：向前 seek 只重建状态不补播事件（事件窗口起点直接推到目标），
## 向后 seek 让窗口起点一起回退，重播时事件会重新落入窗口（去重由 ClueManager 负责）。
## 「窗口起点」只由 ReplayEventDispatcher 持有，controller 不重复维护一份。
func seek(value: float) -> Dictionary:
	var previous := playback_time
	var target := clampf(value, _window_start(), _window_end())
	playback_time = target
	var forward := target >= previous
	seeked.emit(previous, target, forward)
	state_changed.emit()
	return {"previous": previous, "current": target, "forward": forward}


func get_state() -> Dictionary:
	return {
		"active": active,
		"paused": paused,
		"speed": speed,
		"playback_time": playback_time,
		"tape_id": String(tape.tape_id) if tape != null else "",
		"time_start": _window_start(),
		"time_end": _window_end(),
	}


func _window_start() -> float:
	return float(tape.time_start) if tape != null else 0.0


func _window_end() -> float:
	return float(tape.time_end) if tape != null else 0.0
