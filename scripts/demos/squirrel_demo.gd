extends Node3D
## 独立飞鼠 demo：只保留一只飞鼠 + 近景相机，方便和参考 3d(1).html 对照。
## 运行 scenes/demo_squirrel.tscn（F6）。

const SQUIRREL_SCRIPT := preload("res://scripts/demos/reference_squirrel.gd")

var squirrel: Node3D
var _camera: Camera3D
var _time := 0.0


func _ready() -> void:
	_build_environment()
	_build_floor()
	_build_light()
	_build_camera()
	squirrel = SQUIRREL_SCRIPT.new()
	squirrel.name = "DemoSquirrel"
	add_child(squirrel)
	squirrel.global_position = Vector3(0, 0.02, 0)


func _build_environment() -> void:
	var world := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.035, 0.05, 0.08)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.5, 0.62, 0.78)
	environment.ambient_light_energy = 0.55
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	world.environment = environment
	add_child(world)


func _build_floor() -> void:
	var floor := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(5, 5)
	floor.mesh = plane
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.13, 0.12, 0.12)
	material.roughness = 1.0
	floor.material_override = material
	add_child(floor)
	var grid := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(2.5, 0.01, 2.5)
	grid.mesh = box
	var grid_mat := StandardMaterial3D.new()
	grid_mat.albedo_color = Color(0.22, 0.2, 0.24)
	grid.material_override = grid_mat
	grid.position.y = 0.005
	add_child(grid)


func _build_light() -> void:
	var light := DirectionalLight3D.new()
	light.light_color = Color(0.75, 0.85, 1.0)
	light.light_energy = 1.2
	light.rotation_degrees = Vector3(-55, -35, 0)
	add_child(light)
	var fill := OmniLight3D.new()
	fill.light_color = Color(1.0, 0.72, 0.46)
	fill.light_energy = 1.6
	fill.omni_range = 4.0
	fill.position = Vector3(-0.8, 1.0, 0.6)
	add_child(fill)


func _build_camera() -> void:
	_camera = Camera3D.new()
	_camera.fov = 42.0
	_camera.position = Vector3(0.55, 0.42, 0.78)
	add_child(_camera)
	_camera.look_at(Vector3(0, 0.22, 0))


func _process(delta: float) -> void:
	_time += delta
	if squirrel != null:
		squirrel.tick(delta)
	if _camera != null and squirrel != null:
		# 跟随飞鼠，方便近距离观察翼膜和尾巴。
		var focus: Vector3 = squirrel.global_position + Vector3(0, 0.12, 0)
		var angle := sin(_time * 0.22) * 0.24 + 0.82
		_camera.position = focus + Vector3(sin(angle) * 0.72, 0.30, cos(angle) * 0.72)
		_camera.look_at(focus)
