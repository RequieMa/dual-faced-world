extends Node3D
## SpeakerBeacon：引导三件套之一——扬声器（W2）。
##
## 玩家通过它「说出提示词」：bus.hint_sent -> 这里的 on_bus_hint() -> play_hint()。
## 只负责呈现/记录提示，不决定剧情，也不直接驱动 NPC（NPC 由 GuideBus 解析）。
## 视觉为程序化占位（方块 + 文字），不引入素材文件。

signal hint_played(speaker_id: String, text: String)

@export var speaker_id: String = "speaker_a"
@export var show_visual: bool = true

var _last_text := ""
var _play_count := 0
var _body: MeshInstance3D = null
var _label: Label3D = null


func _ready() -> void:
	_build_visual()
	_refresh_visual()


func setup(id: String) -> void:
	speaker_id = id
	_refresh_visual()


func get_speaker_id() -> String:
	return speaker_id


## 播放一条提示。空文本拒绝；每次成功播放发一次 hint_played。
func play_hint(text: String) -> bool:
	var hint := text.strip_edges()
	if hint.is_empty():
		push_warning("SpeakerBeacon: 空提示不能播放")
		return false
	_last_text = hint
	_play_count += 1
	_refresh_visual()
	hint_played.emit(speaker_id, hint)
	return true


## 直接接 GuideBus.hint_sent(target_id, text) 的适配方法。
func on_bus_hint(_target_id: String, text: String) -> void:
	play_hint(text)


func get_state() -> Dictionary:
	return {
		"id": speaker_id,
		"last_text": _last_text,
		"play_count": _play_count,
	}


func to_dict() -> Dictionary:
	return {
		"id": speaker_id,
		"last_text": _last_text,
		"play_count": _play_count,
	}


func from_dict(data: Dictionary) -> void:
	if not data is Dictionary:
		push_warning("SpeakerBeacon: from_dict 需要 Dictionary，已忽略")
		return
	if data.has("id") and data["id"] is String:
		speaker_id = data["id"]
	if data.has("last_text") and data["last_text"] is String:
		_last_text = data["last_text"]
	if data.has("play_count") and (data["play_count"] is int or data["play_count"] is float):
		_play_count = int(data["play_count"])
	_refresh_visual()


# --- 占位视觉 -----------------------------------------------------------------

func _build_visual() -> void:
	if not show_visual or _body != null:
		return
	_body = MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.7, 0.7, 0.7)
	_body.mesh = mesh
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.95, 0.78, 0.24)
	_body.material_override = material
	add_child(_body)

	_label = Label3D.new()
	_label.font_size = 28
	_label.pixel_size = 0.004
	_label.position = Vector3(0.0, 0.8, 0.0)
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.modulate = Color(1.0, 0.92, 0.65)
	add_child(_label)


func _refresh_visual() -> void:
	if _label != null:
		_label.text = speaker_id if _last_text.is_empty() else "%s: %s" % [speaker_id, _last_text]
