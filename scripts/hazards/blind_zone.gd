extends Node
## W5 盲区失明（Issue #15）：过载后「那一片区域从此看不见」。
##
## 契约：set_blind(area_id, on)、is_visible(camera_id)。
## 供 W1/W12 查询：摄像头会话/监控墙在显示与切换前先问 is_visible()。
##
## 语义：
## - 登记 camera_id -> area_id 后，`set_blind(area_id, true)` 让该区域所有机位不可见；
## - 未登记的机位把自身 id 当作区域，因此 set_blind("C1", true) 也直接生效；
## - 默认只认显式 set_blind（M16 未拍板，不自动恢复），也不做几何判定：
##   区域划分由 W12/关卡数据决定，避免把 theater_map 的房间矩形写死在这里。
## - 不修改 theater_map.gd；不新增 autoload。

## area_id -> true（只保留被盲化的区域，顺序稳定便于存档 diff）。
var _blind_areas: Dictionary = {}
## camera_id -> area_id
var _camera_areas: Dictionary = {}


## 登记/改挂机位所属区域。重复登记同一区域幂等。
func register_camera(camera_id: String, area_id: String) -> bool:
	if camera_id.is_empty() or area_id.is_empty():
		push_warning("BlindZone.register_camera: camera_id / area_id 不能为空")
		return false
	_camera_areas[camera_id] = area_id
	return true


## 设置区域盲化状态。区域 id 是动态的（过载产生的新盲区无需预先登记）。
func set_blind(area_id: String, on: bool) -> void:
	if area_id.is_empty():
		push_warning("BlindZone.set_blind: area_id 不能为空")
		return
	if on:
		_blind_areas[area_id] = true
	else:
		_blind_areas.erase(area_id)


## 机位当前是否可见（其所属区域没有失明）。
func is_visible(camera_id: String) -> bool:
	var area_id := String(_camera_areas.get(camera_id, camera_id))
	return not _blind_areas.has(area_id)


func is_area_blind(area_id: String) -> bool:
	return _blind_areas.has(area_id)


## 运行状态快照（W12 存档/循环重置可按需读取）。
func get_state() -> Dictionary:
	return {
		"blind_areas": _blind_areas.keys(),
		"camera_areas": _camera_areas.duplicate(),
	}


## 清空所有盲区（显式调用才恢复；用于循环重置/调试，不自动触发）。
func reset() -> void:
	_blind_areas.clear()
