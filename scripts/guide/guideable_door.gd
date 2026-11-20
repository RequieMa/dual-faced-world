extends Node3D
## GuideableDoor：引导三件套之一——可开的门（W2）。
##
## 被 GuideBus.open_door(id) 解析到后调用 open()；重复开门幂等
## （状态不变、不重复发 opened），由 bus 决定是否广播。
## 视觉为程序化占位：铰链 pivot + 门板，开门时绕铰链转 90°。

signal opened(id: String)

@export var door_id: String = "door_a"
@export var show_visual: bool = true

var _open := false
var _pivot: Node3D = null


func _ready() -> void:
	_build_visual()
	_apply_visual()


func setup(id: String) -> void:
	door_id = id


func get_target_id() -> String:
	return door_id


## 开门。返回 true 表示调用成功（即使已经开着），首次打开时发一次 opened。
func open() -> bool:
	if _open:
		return true
	_open = true
	_apply_visual()
	opened.emit(door_id)
	return true


func is_open() -> bool:
	return _open


func get_state() -> Dictionary:
	return {
		"id": door_id,
		"open": _open,
	}


func to_dict() -> Dictionary:
	return {
		"id": door_id,
		"open": _open,
	}


func from_dict(data: Dictionary) -> void:
	if data.has("id"):
		if data["id"] is String:
			door_id = data["id"]
		else:
			push_warning("GuideableDoor: from_dict 的 id 类型不符，已忽略")
	if data.has("open"):
		if data["open"] is bool:
			_open = data["open"]
		else:
			push_warning("GuideableDoor: from_dict 的 open 类型不符，已忽略")
	_apply_visual()


# --- 占位视觉 -----------------------------------------------------------------

func _build_visual() -> void:
	if not show_visual or _pivot != null:
		return
	# 铰链在门框左缘：pivot 平移 -0.6，门板再相对 pivot 偏移 +0.6。
	_pivot = Node3D.new()
	_pivot.position = Vector3(-0.6, 0.0, 0.0)
	add_child(_pivot)

	var panel := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(1.2, 2.0, 0.12)
	panel.mesh = mesh
	panel.position = Vector3(0.6, 1.0, 0.0)
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.82, 0.55, 0.34)
	panel.material_override = material
	_pivot.add_child(panel)


func _apply_visual() -> void:
	if _pivot != null:
		_pivot.rotation.y = -PI / 2.0 if _open else 0.0
