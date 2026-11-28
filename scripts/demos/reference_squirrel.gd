extends Node3D
## 参考 3d(1).html 的糖袋鼯造型 demo。
## 不是 primitive 拼接：身体+尾巴是一条连续管状 mesh，头部是变形球，
## 耳朵是生成的双层叶面，翼膜是四肢/身体之间的 Coons 风格面片。

const SIZE := 0.34
const FUR := Color("#eccea6")
const SHADE := Color("#d4a97c")
const PINK := Color("#e9a091")
const LINE := Color("#3b2a21")
const EYE := Color("#1d1411")

var _visual: Node3D
var _tail_tip: Node3D
var _time := 0.0


func _ready() -> void:
	_build_model()


func _build_model() -> void:
	_visual = Node3D.new()
	_visual.name = "GliderVisual"
	# 先按参考模型 0.44m 左右的自然尺寸搭，再整体缩到钥匙大小 0.34m。
	_visual.scale = Vector3.ONE * (SIZE / 0.44)
	add_child(_visual)

	_build_body_tail()
	_build_head()
	_build_limbs()
	_build_membranes()


func _build_body_tail() -> void:
	var points: Array[Vector3] = [
		Vector3(0, 0.085, -0.15),
		Vector3(0, 0.075, -0.08),
		Vector3(0, 0.065, 0.00),
		Vector3(0, 0.058, 0.08),
		Vector3(0, 0.060, 0.14),
		Vector3(0, 0.080, 0.19),
		Vector3(0, 0.120, 0.23),
		Vector3(0, 0.170, 0.255),
		Vector3(0, 0.220, 0.265),
		Vector3(0, 0.265, 0.250),
	]
	var radii: Array[float] = [0.070, 0.075, 0.072, 0.060, 0.045,
		0.040, 0.042, 0.040, 0.032, 0.014]
	var colors: Array[Color] = []
	for i in points.size():
		var t := float(i) / float(points.size() - 1)
		var color := FUR.lerp(SHADE, clampf(t * 0.45, 0.0, 0.45))
		if t > 0.62:
			color = color.lerp(PINK, clampf((t - 0.62) * 1.2, 0.0, 0.55))
		colors.append(color)
	_add_mesh("BodyTail", _tube_mesh(points, radii, colors, 16))

	_tail_tip = Node3D.new()
	_tail_tip.position = points[points.size() - 1]
	_visual.add_child(_tail_tip)


func _build_head() -> void:
	var head := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.075
	sphere.height = 0.15
	sphere.radial_segments = 24
	sphere.rings = 16
	head.mesh = sphere
	head.scale = Vector3(1.0, 0.90, 1.08)
	head.position = Vector3(0, 0.095, -0.165)
	head.material_override = _material(FUR)
	_visual.add_child(head)

	var muzzle := MeshInstance3D.new()
	var muzzle_mesh := SphereMesh.new()
	muzzle_mesh.radius = 0.040
	muzzle_mesh.height = 0.075
	muzzle.mesh = muzzle_mesh
	muzzle.scale = Vector3(1.0, 0.72, 1.35)
	muzzle.position = Vector3(0, 0.070, -0.225)
	muzzle.material_override = _material(FUR.lerp(SHADE, 0.25))
	_visual.add_child(muzzle)

	var nose := MeshInstance3D.new()
	var nose_mesh := SphereMesh.new()
	nose_mesh.radius = 0.018
	nose_mesh.height = 0.033
	nose.mesh = nose_mesh
	nose.position = Vector3(0, 0.075, -0.255)
	nose.material_override = _material(PINK)
	_visual.add_child(nose)

	for side in [-1, 1]:
		var eye := MeshInstance3D.new()
		var eye_mesh := SphereMesh.new()
		eye_mesh.radius = 0.017
		eye_mesh.height = 0.034
		eye.mesh = eye_mesh
		eye.position = Vector3(side * 0.043, 0.102, -0.221)
		eye.material_override = _material(EYE)
		_visual.add_child(eye)
		var shine := MeshInstance3D.new()
		var shine_mesh := SphereMesh.new()
		shine_mesh.radius = 0.005
		shine_mesh.height = 0.010
		shine.mesh = shine_mesh
		shine.position = Vector3(side * 0.047, 0.108, -0.235)
		shine.material_override = _material(Color.WHITE)
		_visual.add_child(shine)
		# 叶面耳：外耳 + 内耳，两片网格而不是球。
		var ear := MeshInstance3D.new()
		ear.mesh = _ear_mesh(0.12, 0.130, 0.034, FUR, LINE)
		ear.position = Vector3(side * 0.052, 0.138, -0.148)
		ear.rotation_degrees = Vector3(0, side * 34, side * -45)
		ear.material_override = _vertex_material()
		_visual.add_child(ear)
		var inner := MeshInstance3D.new()
		inner.mesh = _ear_mesh(0.096, 0.090, 0.020, PINK, PINK)
		inner.position = Vector3(side * 0.055, 0.142, -0.152)
		inner.rotation_degrees = Vector3(0, side * 34, side * -45)
		inner.material_override = _vertex_material()
		_visual.add_child(inner)


func _build_limbs() -> void:
	# 四条腿也用连续管状 mesh，而不是 Capsule。
	for side in [-1, 1]:
		var front_points: Array[Vector3] = [
			Vector3(side * 0.055, 0.095, -0.075),
			Vector3(side * 0.105, 0.065, -0.050),
			Vector3(side * 0.165, 0.035, -0.025),
		]
		var hind_points: Array[Vector3] = [
			Vector3(side * 0.050, 0.080, 0.080),
			Vector3(side * 0.115, 0.060, 0.095),
			Vector3(side * 0.190, 0.032, 0.120),
		]
		_add_mesh("Foreleg", _tube_mesh(front_points, [0.022, 0.017, 0.012],
			[FUR, FUR.lerp(SHADE, 0.35), SHADE], 8))
		_add_mesh("Hindleg", _tube_mesh(hind_points, [0.026, 0.020, 0.013],
			[FUR, FUR.lerp(SHADE, 0.35), SHADE], 8))
		# 小脚掌
		var paw := MeshInstance3D.new()
		var paw_mesh := SphereMesh.new()
		paw_mesh.radius = 0.018
		paw_mesh.height = 0.022
		paw.mesh = paw_mesh
		paw.scale = Vector3(1.4, 0.55, 1.0)
		paw.position = Vector3(side * 0.172, 0.033, -0.025)
		paw.material_override = _material(PINK)
		_visual.add_child(paw)
		var hind_paw := paw.duplicate() as MeshInstance3D
		hind_paw.position = Vector3(side * 0.197, 0.030, 0.123)
		_visual.add_child(hind_paw)


func _build_membranes() -> void:
	for side in [-1, 1]:
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		var mu := 9
		var mv := 5
		var edge_points: Array[Vector3] = []
		for i in mu:
			var u := float(i) / float(mu - 1)
			var inner := Vector3(side * (0.055 + 0.015 * u), 0.082 - 0.025 * u, -0.075 + 0.155 * u)
			var outer := Vector3(side * (0.225 + 0.025 * u), 0.055 + 0.025 * u, -0.045 + 0.165 * u)
			for j in mv:
				var v := float(j) / float(mv - 1)
				var p := inner.lerp(outer, v)
				# 翼膜中间略下垂，边缘更薄。
				p.y -= sin(PI * u) * sin(PI * v) * 0.028
				st.set_color(SHADE.lerp(FUR, 0.25 + 0.25 * (1.0 - v)))
				st.add_vertex(p)
				if j == mv - 1:
					edge_points.append(p)
		for i in mu - 1:
			for j in mv - 1:
				var a := i * mv + j
				var b := a + 1
				var c := a + mv
				var d := c + 1
				st.add_index(a); st.add_index(c); st.add_index(b)
				st.add_index(b); st.add_index(c); st.add_index(d)
		var mesh := st.commit()
		var membrane := MeshInstance3D.new()
		membrane.name = "Patagium"
		membrane.mesh = mesh
		membrane.material_override = _vertex_material(true)
		_visual.add_child(membrane)
		# 翼膜自由缘的深色边线，让轮廓从身体上分离出来。
		var rim_colors: Array[Color] = []
		for point in edge_points:
			rim_colors.append(LINE)
		var rim_radii: Array[float] = []
		for point in edge_points:
			rim_radii.append(0.0045)
		_add_mesh("PatagiumRim", _tube_mesh(edge_points, rim_radii, rim_colors, 5))


func _tube_mesh(points: Array[Vector3], radii: Array[float], colors: Array[Color],
		sides: int) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in points.size():
		var tangent: Vector3
		if i == 0:
			tangent = (points[1] - points[0]).normalized()
		elif i == points.size() - 1:
			tangent = (points[i] - points[i - 1]).normalized()
		else:
			tangent = (points[i + 1] - points[i - 1]).normalized()
		var normal := tangent.cross(Vector3.UP)
		if normal.length_squared() < 0.0001:
			normal = Vector3.RIGHT
		normal = normal.normalized()
		var binormal := normal.cross(tangent).normalized()
		for j in sides:
			var angle := TAU * float(j) / float(sides)
			var offset := normal * cos(angle) * radii[i] + binormal * sin(angle) * radii[i] * 0.82
			var color := colors[i]
			if sin(angle) < -0.25:
				color = color.lerp(Color(0.98, 0.92, 0.82), 0.65)
			st.set_color(color)
			st.add_vertex(points[i] + offset)
	for i in points.size() - 1:
		for j in sides:
			var next := (j + 1) % sides
			var a := i * sides + j
			var b := i * sides + next
			var c := (i + 1) * sides + j
			var d := (i + 1) * sides + next
			st.add_index(a); st.add_index(b); st.add_index(c)
			st.add_index(b); st.add_index(d); st.add_index(c)
	st.generate_normals()
	return st.commit()


func _ear_mesh(length: float, width: float, cup: float, color_a: Color,
		color_b: Color) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var ns := 10
	var nt := 6
	for i in ns + 1:
		var s := float(i) / float(ns)
		var half := width * 0.5 * pow(maxf(0.0, sin(PI * (0.12 + 0.88 * s))), 0.7)
		for j in nt + 1:
			var t := float(j) / float(nt) * 2.0 - 1.0
			var p := Vector3(t * half, s * length, cup * (1.0 - t * t))
			var color := color_a.lerp(color_b, 1.0 if absf(t) > 0.75 or s > 0.92 else 0.0)
			st.set_color(color)
			st.add_vertex(p)
	for i in ns:
		for j in nt:
			var a := i * (nt + 1) + j
			var b := a + 1
			var c := a + nt + 1
			var d := c + 1
			st.add_index(a); st.add_index(b); st.add_index(c)
			st.add_index(b); st.add_index(d); st.add_index(c)
	st.generate_normals()
	return st.commit()


func _add_mesh(node_name: String, mesh: ArrayMesh) -> void:
	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = mesh
	instance.material_override = _vertex_material()
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_visual.add_child(instance)


func _material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.84
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return material


func _vertex_material(double_sided: bool = false) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	material.roughness = 0.85
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	if double_sided:
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return material


func tick(delta: float) -> void:
	_time += delta
	if _visual != null:
		_visual.position.y = sin(_time * 2.1) * 0.006
	if _tail_tip != null:
		_tail_tip.rotation.z = sin(_time * 1.5) * 0.05
