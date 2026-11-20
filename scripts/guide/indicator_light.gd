extends Node3D
## IndicatorLight：引导三件套之一——指示灯（W2）。
##
## 被 GuideBus.set_indicator(id, on) 解析到后调用 set_on()；重复设置同一状态
## 是幂等的（状态不变、不重复发 state_changed），由 bus 决定是否广播。
## 视觉为程序化占位球 + OmniLight3D，不引入素材文件。

signal state_changed(id: String, on: bool)

@export var light_id: String = "light_a"
@export var show_visual: bool = true
@export var on_color: Color = Color(1.0, 0.86, 0.35)

var _on := false
var _sphere: MeshInstance3D = null
var _material: StandardMaterial3D = null
var _omni: OmniLight3D = null


func _ready() -> void:
	_build_visual()
	_apply_visual()


func setup(id: String) -> void:
	light_id = id


func get_target_id() -> String:
	return light_id


## 设置开关。返回 true 表示调用成功（即使状态没变），状态变化时才发信号。
func set_on(on: bool) -> bool:
	if _on == on:
		_apply_visual()
		return true
	_on = on
	_apply_visual()
	state_changed.emit(light_id, _on)
	return true


func is_on() -> bool:
	return _on


func get_state() -> Dictionary:
	return {
		"id": light_id,
		"on": _on,
	}


func to_dict() -> Dictionary:
	return {
		"id": light_id,
		"on": _on,
	}


func from_dict(data: Dictionary) -> void:
	if data.has("id"):
		if data["id"] is String:
			light_id = data["id"]
		else:
			push_warning("IndicatorLight: from_dict 的 id 类型不符，已忽略")
	if data.has("on"):
		if data["on"] is bool:
			_on = data["on"]
		else:
			push_warning("IndicatorLight: from_dict 的 on 类型不符，已忽略")
	_apply_visual()


# --- 占位视觉 -----------------------------------------------------------------

func _build_visual() -> void:
	if not show_visual or _sphere != null:
		return
	_sphere = MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = 0.3
	mesh.height = 0.6
	_sphere.mesh = mesh
	_material = StandardMaterial3D.new()
	_material.albedo_color = Color(0.20, 0.20, 0.22)
	_sphere.material_override = _material
	add_child(_sphere)

	_omni = OmniLight3D.new()
	_omni.omni_range = 4.0
	_omni.light_energy = 0.0
	add_child(_omni)


func _apply_visual() -> void:
	if _material != null:
		_material.albedo_color = on_color if _on else Color(0.20, 0.20, 0.22)
		_material.emission_enabled = _on
		_material.emission = on_color
		_material.emission_energy_multiplier = 1.6
	if _omni != null:
		_omni.light_energy = 1.2 if _on else 0.0
