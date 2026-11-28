extends Node3D
## Lumine + Mixamo 动作循环 demo。
## 运行 scenes/demo_animation.tscn，左侧按钮切换动作，当前动作会循环播放。
## 动作 FBX 原始文件在 external-assets/animations/mixamo_raw2，已重定向到 Lumine。

const GLB := "res://external-assets/animations/lumine_mixamo_animations.glb"

const ACTION_LABELS := {
	"idle_standing": "idle_standing / 站姿 · 自然",
	"idle_breathing": "idle_breathing / 站姿 · 呼吸",
	"walk_forward": "walk_forward / 移动 · 前进",
	"walk_backward": "walk_backward / 移动 · 后退",
	"run_forward": "run_forward / 移动 · 奔跑",
	"strafe_left": "strafe_left / 移动 · 左侧移",
	"look_around": "look_around / 张望 · 环顾",
	"look_nervous": "look_nervous / 张望 · 紧张",
	"hide_crouch_idle": "hide_crouch_idle / 躲藏 · 蹲伏",
	"hide_crouch_walk": "hide_crouch_walk / 躲藏 · 蹲行",
	"hide_hiding": "hide_hiding / 躲藏 · 藏身",
	"hide_cover_idle": "hide_cover_idle / 躲藏 · 掩体",
}

var model: Node3D
var _player: AnimationPlayer
var _current := ""
var _buttons: VBoxContainer
var _label: Label


func _ready() -> void:
	_build_environment()
	_load_model()
	_build_camera()
	_build_ui()
	_choose_animation("idle_standing")


func _load_model() -> void:
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err := doc.append_from_file(ProjectSettings.globalize_path(GLB), state)
	if err != OK:
		push_error("GLB load failed: %s" % err)
		return
	model = doc.generate_scene(state)
	# Mixamo/Lumine 的朝向约定不同，demo 里统一转回面向镜头。
	model.rotation_degrees.y = 180.0
	add_child(model)
	_player = _find_animation_player(model)
	if _player == null:
		push_error("AnimationPlayer not found")
		return
	for action_name in _player.get_animation_list():
		if ACTION_LABELS.has(action_name):
			_player.get_animation(action_name).loop_mode = Animation.LOOP_LINEAR


func _build_environment() -> void:
	var world := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.035, 0.045, 0.065)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.62, 0.72, 0.9)
	env.ambient_light_energy = 0.85
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	world.environment = env
	add_child(world)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, -28, 0)
	sun.light_energy = 1.4
	add_child(sun)
	var rim := OmniLight3D.new()
	rim.position = Vector3(-2, 1.6, -2)
	rim.light_color = Color(0.55, 0.7, 1.0)
	rim.light_energy = 2.0
	rim.omni_range = 6.0
	add_child(rim)
	var floor := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(8, 8)
	floor.mesh = plane
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.14, 0.16, 0.2)
	mat.roughness = 1.0
	floor.material_override = mat
	add_child(floor)


func _build_camera() -> void:
	var camera := Camera3D.new()
	camera.position = Vector3(0, 1.2, 3.3)
	camera.fov = 38.0
	add_child(camera)
	camera.look_at(Vector3(0, 0.9, 0))


func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var panel := PanelContainer.new()
	panel.position = Vector2(18, 18)
	panel.custom_minimum_size = Vector2(390, 480)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.02, 0.035, 0.055, 0.92)
	style.border_color = Color(0.25, 0.55, 0.75)
	style.set_border_width_all(1)
	style.set_corner_radius_all(4)
	style.set_content_margin_all(14)
	panel.add_theme_stylebox_override("panel", style)
	layer.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 7)
	panel.add_child(box)
	var title := Label.new()
	title.text = "Lumine · Mixamo 动作库"
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", Color(0.55, 0.9, 1.0))
	box.add_child(title)
	_label = Label.new()
	_label.text = "选择动作"
	_label.add_theme_font_size_override("font_size", 15)
	_label.add_theme_color_override("font_color", Color(0.85, 0.75, 0.55))
	box.add_child(_label)
	_buttons = VBoxContainer.new()
	_buttons.add_theme_constant_override("separation", 3)
	box.add_child(_buttons)
	for action_name in ACTION_LABELS.keys():
		var button := Button.new()
		button.text = ACTION_LABELS[action_name]
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.custom_minimum_size = Vector2(0, 27)
		button.add_theme_font_size_override("font_size", 13)
		button.pressed.connect(_choose_animation.bind(String(action_name)))
		_buttons.add_child(button)


func _choose_animation(action_name: String) -> void:
	if _player == null or not _player.has_animation(action_name):
		return
	_current = action_name
	_player.play(action_name)
	_player.speed_scale = 1.0
	if _label != null:
		_label.text = "当前：%s" % ACTION_LABELS.get(action_name, action_name)


func _find_animation_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node
	for child in node.get_children():
		var found := _find_animation_player(child)
		if found != null:
			return found
	return null
