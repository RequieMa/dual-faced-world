extends Node3D
## Demo 用的磁带拾取点：靠近后按 E 拾取，拾取后隐藏。
## 只负责“场景交互 + 视觉”，线索登记与磁带解锁由 GameRoot 调 autoload 完成。

signal picked_up(tape_id: String)

@export var tape_id: String = "T-01"
@export var clue_id: String = "door_code_A"
@export var show_visual: bool = true

var _collected := false
var _body: MeshInstance3D = null
var _label: Label3D = null


func _ready() -> void:
	_build_visual()
	_refresh_visual()


## 每轮开始时换带并复位；空字符串表示沿用当前值。
func reset(next_tape_id: String = "", next_clue_id: String = "") -> void:
	if not next_tape_id.is_empty():
		tape_id = next_tape_id
	if not next_clue_id.is_empty():
		clue_id = next_clue_id
	_collected = false
	_refresh_visual()


## 拾取。已拾取时返回 false（幂等，不重复发信号）。
func collect() -> bool:
	if _collected:
		return false
	_collected = true
	_refresh_visual()
	picked_up.emit(tape_id)
	return true


func is_collected() -> bool:
	return _collected


func get_state() -> Dictionary:
	return {
		"tape_id": tape_id,
		"clue_id": clue_id,
		"collected": _collected,
		"position": position,
	}


# --- 占位视觉 -----------------------------------------------------------------

func _build_visual() -> void:
	if not show_visual or _body != null:
		return
	_body = MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.38, 0.18, 0.62)
	_body.mesh = mesh
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.95, 0.78, 0.30)
	material.emission_enabled = true
	material.emission = Color(0.55, 0.38, 0.05)
	_body.material_override = material
	add_child(_body)

	_label = Label3D.new()
	_label.text = "磁带"
	_label.font_size = 28
	_label.pixel_size = 0.005
	_label.position = Vector3(0.0, 0.45, 0.0)
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.modulate = Color(1.0, 0.9, 0.55)
	add_child(_label)


func _refresh_visual() -> void:
	visible = not _collected
	if _label != null:
		_label.text = "%s 磁带" % tape_id
