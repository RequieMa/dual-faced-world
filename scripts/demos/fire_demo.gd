extends Node3D
## 独立火焰 demo：便于和 procedural-fire 对照 / 调 shader。
## 运行 scenes/demo_fire.tscn（F6）。

const FIRE_SCRIPT := preload("res://scripts/room_demo/fire_system.gd")

var fire: Node3D
var _camera: Camera3D
var _time := 0.0
var _label: Label


func _ready() -> void:
	_build_environment()
	_build_stage()
	_build_camera()
	_build_ui()
	fire = FIRE_SCRIPT.new()
	fire.name = "DemoFire"
	add_child(fire)


func _build_environment() -> void:
	var world := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.012, 0.016, 0.025)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.22, 0.28, 0.38)
	environment.ambient_light_energy = 0.28
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	environment.glow_enabled = true
	environment.glow_intensity = 1.1
	environment.glow_strength = 1.15
	environment.glow_bloom = 0.25
	environment.glow_hdr_threshold = 0.55
	world.environment = environment
	add_child(world)


func _build_stage() -> void:
	var floor := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(20, 20)
	floor.mesh = plane
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.12, 0.105, 0.1)
	material.roughness = 1.0
	floor.material_override = material
	add_child(floor)
	var platform := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(10, 0.18, 7)
	platform.mesh = box
	var platform_mat := StandardMaterial3D.new()
	platform_mat.albedo_color = Color(0.22, 0.13, 0.13)
	platform.material_override = platform_mat
	platform.position = Vector3(-8.5, -0.09, -20.0)
	add_child(platform)
	# 远一点的后墙，给火焰一个暗背景。
	var wall := MeshInstance3D.new()
	var wall_box := BoxMesh.new()
	wall_box.size = Vector3(14, 6, 0.2)
	wall.mesh = wall_box
	var wall_mat := StandardMaterial3D.new()
	wall_mat.albedo_color = Color(0.1, 0.08, 0.08)
	wall.material_override = wall_mat
	wall.position = Vector3(-8.5, 2.5, -27)
	add_child(wall)
	_build_campfire()


func _build_campfire() -> void:
	var wood_mat := StandardMaterial3D.new()
	wood_mat.albedo_color = Color(0.09, 0.055, 0.035)
	wood_mat.roughness = 1.0
	for index in 4:
		var log := MeshInstance3D.new()
		var mesh := CylinderMesh.new()
		mesh.top_radius = 0.16
		mesh.bottom_radius = 0.20
		mesh.height = 2.5
		log.mesh = mesh
		log.material_override = wood_mat
		log.position = Vector3(-8.5, 0.18, -20.0)
		log.rotation_degrees = Vector3(90, index * 45.0, 12.0)
		add_child(log)
	# 一圈石头，给火焰一个参考场景。
	for index in 12:
		var angle := TAU * float(index) / 12.0
		var stone := MeshInstance3D.new()
		var sphere := SphereMesh.new()
		sphere.radius = 0.20 + 0.05 * sin(index * 2.3)
		sphere.height = sphere.radius * 1.4
		stone.mesh = sphere
		var stone_mat := StandardMaterial3D.new()
		stone_mat.albedo_color = Color(0.22, 0.21, 0.20)
		stone_mat.roughness = 1.0
		stone.material_override = stone_mat
		stone.position = Vector3(-8.5 + cos(angle) * 1.35, 0.18,
			-20.0 + sin(angle) * 1.35)
		add_child(stone)


func _build_camera() -> void:
	_camera = Camera3D.new()
	_camera.fov = 38.0
	_camera.position = Vector3(-8.5, 1.35, -12.4)
	add_child(_camera)
	_camera.look_at(Vector3(-8.5, 0.9, -20.0))


func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_label = Label.new()
	_label.position = Vector2(22, 18)
	_label.add_theme_font_size_override("font_size", 18)
	_label.add_theme_color_override("font_color", Color(0.9, 0.75, 0.55))
	layer.add_child(_label)


func _process(delta: float) -> void:
	_time += delta
	if _camera != null:
		var angle := sin(_time * 0.18) * 0.10
		_camera.position = Vector3(-8.5 - sin(angle) * 0.7, 1.35, -12.4)
		_camera.look_at(Vector3(-8.5, 0.9, -20.0))
	if fire != null:
		fire.tick(delta)
		if _label != null:
			var state: Dictionary = fire.get_state()
			_label.text = "fire   age %.1fs   radius %.2fm   sim %s" % [
				float(state.get("age", 0.0)), float(state.get("radius", 0.0)),
				str(state.get("grid", ""))]
