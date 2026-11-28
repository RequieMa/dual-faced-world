extends Node3D
## 轻量 3D 燃烧场 + 黑体辐射体积渲染 + 程序化火焰音频。
##
## 参考 procedural-fire 的结构：低分辨率 3D 标量场（温度/燃料/烟尘）、
## 浮力驱动的半拉格朗日平流、混合燃烧、黑体色温度 LUT 和 raymarch。
## 这里刻意把网格压缩到 20×24×20，并且只在 ~10Hz 更新，先把效果跑通，
## 后续可以换成 GPU compute / 更低分辨率来优化。

signal camera_threat_changed(camera_id: String, threatened: bool)

const FLAME_SHADER := preload("res://shaders/fire_flames.gdshader")
const GRID := Vector3i(24, 28, 24)
const BOX_MIN := Vector3(-15.0, 0.0, -27.0)
# 火场扩大后，机位抬高到 4m 左右；体积顶面仍低于机位，保证能看到火焰顶面。
const BOX_MAX := Vector3(-2.0, 2.6, -13.0)
const SOURCE := Vector3(-8.5, 0.18, -20.0)
const SIM_HZ := 8.0
const FIRE_START_RADIUS := 1.0
const FIRE_MAX_RADIUS := 8.0
const FIRE_GROWTH_PER_SEC := 0.10
const CAMERA_BURN_TIME := 20.0

const CAMERA_BURN_RADIUS := 0.45

var age := 0.0
var radius := FIRE_START_RADIUS
var intensity := 0.0

var _temp: PackedFloat32Array
var _fuel: PackedFloat32Array
var _soot: PackedFloat32Array
var _temp_next: PackedFloat32Array
var _fuel_next: PackedFloat32Array
var _soot_next: PackedFloat32Array
var _accum := 0.0
var _time := 0.0
var _texture: ImageTexture3D = null
var _blackbody_lut: ImageTexture = null
var _volume: MeshInstance3D = null
var _flames: Array[MeshInstance3D] = []
var _light: OmniLight3D = null
var _embers: GPUParticles3D = null
var _audio: AudioStreamPlayer3D = null
var _audio_stream: AudioStreamWAV = null
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.seed = 991
	_init_fields()
	_build_blackbody_lut()
	_build_texture()
	_build_volume()
	_build_audio()
	_update_texture()


func tick(delta: float) -> void:
	if delta <= 0.0:
		return
	age += delta
	radius = minf(FIRE_MAX_RADIUS, FIRE_START_RADIUS + age * FIRE_GROWTH_PER_SEC)
	intensity = clampf(age / 8.0, 0.15, 1.0)
	_accum += delta
	var steps := 0
	while _accum >= 1.0 / SIM_HZ and steps < 3:
		var dt := 1.0 / SIM_HZ
		_step(dt)
		_accum -= dt
		steps += 1
	if steps > 0:
		_update_texture()
		_update_volume_uniforms()
		_update_audio()


## 火焰是否已经烧到某个机位（用于 20 秒曝光烧毁判定）。
func threatens_camera(camera_position: Vector3) -> bool:
	if age < 1.0:
		return false
	var flat := Vector2(camera_position.x - SOURCE.x, camera_position.z - SOURCE.z)
	if flat.length() > radius + CAMERA_BURN_RADIUS:
		return false
	return camera_position.y <= BOX_MAX.y + 0.8


func threatens_point(point: Vector3) -> bool:
	if age < 1.0:
		return false
	var flat := Vector2(point.x - SOURCE.x, point.z - SOURCE.z)
	return flat.length() <= radius and point.y <= BOX_MAX.y + 0.8


## 给飞鼠的火焰敏感点：火心 + 扩张半径上的四个采样点。
func get_fire_points() -> Array[Vector3]:
	var points: Array[Vector3] = [SOURCE + Vector3(0, 0.35, 0)]
	if radius > 1.2:
		for direction in [Vector3(1, 0, 0), Vector3(-1, 0, 0), Vector3(0, 0, 1), Vector3(0, 0, -1)]:
			points.append(SOURCE + direction * radius * 0.72 + Vector3(0, 0.35, 0))
	return points


func debug_stats() -> Dictionary:
	var max_temperature := 0.0
	var max_soot := 0.0
	var max_fuel := 0.0
	for index in _temp.size():
		max_temperature = maxf(max_temperature, _temp[index])
		max_soot = maxf(max_soot, _soot[index])
		max_fuel = maxf(max_fuel, _fuel[index])
	return {"temp": max_temperature, "soot": max_soot, "fuel": max_fuel}


func get_state() -> Dictionary:
	return {
		"age": age,
		"radius": radius,
		"intensity": intensity,
		"source": SOURCE,
		"grid": GRID,
		"sim_hz": SIM_HZ,
	}


# --- 3D 场 ---------------------------------------------------------------------

func _init_fields() -> void:
	var count := GRID.x * GRID.y * GRID.z
	_temp = _make_field(count)
	_fuel = _make_field(count)
	_soot = _make_field(count)
	_temp_next = _make_field(count)
	_fuel_next = _make_field(count)
	_soot_next = _make_field(count)


func _make_field(count: int) -> PackedFloat32Array:
	var field := PackedFloat32Array()
	field.resize(count)
	return field


func _index(x: int, y: int, z: int) -> int:
	return (z * GRID.y + y) * GRID.x + x


func _cell_position(x: int, y: int, z: int) -> Vector3:
	var cell := (BOX_MAX - BOX_MIN) / Vector3(GRID)
	return BOX_MIN + Vector3(x + 0.5, y + 0.5, z + 0.5) * cell


func _step(dt: float) -> void:
	_time += dt
	var cell := (BOX_MAX - BOX_MIN) / Vector3(GRID)
	# 火焰扩张同时扩大热解区；否则相机虽然被“半径”判定烧到，画面里却仍是一小撮。
	var source_radius := 0.45 + radius * 0.28
	var source_heat := 1050.0

	# Semi-Lagrangian advection with a cheap buoyant + curl-noise velocity.
	for z in GRID.z:
		for y in GRID.y:
			for x in GRID.x:
				var i := _index(x, y, z)
				var temperature := _temp[i]
				var wx := sin(float(y) * 0.7 + float(z) * 0.9 + age * 1.7) * 0.7
				var wz := cos(float(x) * 0.65 + float(z) * 0.4 - age * 1.1) * 0.7
				var wy := 0.65 + clampf((temperature - 293.0) / 900.0, 0.0, 2.4)
				var px := clampi(int(round(x - wx * dt / cell.x)), 0, GRID.x - 1)
				var py := clampi(int(round(y - wy * dt / cell.y)), 0, GRID.y - 1)
				var pz := clampi(int(round(z - wz * dt / cell.z)), 0, GRID.z - 1)
				var s := _index(px, py, pz)
				_temp_next[i] = _temp[s]
				_fuel_next[i] = _fuel[s]
				_soot_next[i] = _soot[s]

	# Source injection around the stage fire point.
	for z in GRID.z:
		for y in GRID.y:
			for x in GRID.x:
				var p := _cell_position(x, y, z)
				var flat := Vector2(p.x - SOURCE.x, p.z - SOURCE.z).length()
				if flat > source_radius or p.y > SOURCE.y + 0.9:
					continue
				var i := _index(x, y, z)
				var falloff := 1.0 - clampf(flat / maxf(source_radius, 0.001), 0.0, 1.0)
				var flicker := 0.72 + 0.28 * sin(_time * 17.0 + p.x * 9.0 + p.z * 7.0)
				_fuel_next[i] = maxf(_fuel_next[i], (0.45 + falloff * 0.35) * flicker)
				_temp_next[i] = maxf(_temp_next[i], source_heat + falloff * 220.0)
				_soot_next[i] = maxf(_soot_next[i], falloff * 0.14 * flicker)

	# Mixing-limited burn, cooling and soot transport.
	for z in GRID.z:
		for y in GRID.y:
			for x in GRID.x:
				var i := _index(x, y, z)
				var fuel := _fuel_next[i]
				var burn := minf(fuel, 0.65) * (1.0 - exp(-dt * 2.4))
				_fuel_next[i] = maxf(fuel - burn, 0.0)
				var temperature := _temp_next[i]
				temperature += burn * 2100.0
				temperature -= (temperature - 293.0) * dt * 0.22
				temperature = maxf(temperature, 293.0)
				_temp_next[i] = temperature
				_soot_next[i] = maxf(_soot_next[i] + burn * 0.42, 0.0) * exp(-dt * 0.18)
				# No fire inside the solid floor.
				if y == 0 and _temp_next[i] < 500.0:
					_fuel_next[i] = 0.0
					_soot_next[i] = 0.0

	_temp = _temp_next
	_fuel = _fuel_next
	_soot = _soot_next
	_temp_next = _make_field(GRID.x * GRID.y * GRID.z)
	_fuel_next = _make_field(GRID.x * GRID.y * GRID.z)
	_soot_next = _make_field(GRID.x * GRID.y * GRID.z)


# --- 黑体 LUT / 体积纹理 --------------------------------------------------------

func _build_blackbody_lut() -> void:
	var image := Image.create(256, 2, false, Image.FORMAT_RGBA8)
	for i in 256:
		var temperature := lerpf(700.0, 3000.0, float(i) / 255.0)
		var color := _blackbody_color(temperature)
		image.set_pixel(i, 0, Color(color.r, color.g, color.b, 1.0))
		# 烟尘近似：温度低时比黑体略灰、略蓝，亮度略低。
		var soot := Color(color.r * 0.82 + 0.04, color.g * 0.88 + 0.03,
			color.b * 0.96 + 0.04, 1.0)
		image.set_pixel(i, 1, soot)
	_blackbody_lut = ImageTexture.create_from_image(image)


## sRGB 黑体近似（Tanner Helland / Neil Bartlett），避免把 CIE 全表塞进 shader。
func _blackbody_color(temperature: float) -> Color:
	var t := clampf(temperature, 700.0, 3000.0) / 100.0
	var r: float
	var g: float
	var b: float
	if t <= 66.0:
		r = 255.0
		g = 99.4708025861 * log(t) - 161.1195681661
		b = 0.0
	else:
		r = 329.698727446 * pow(t - 60.0, -0.1332047592)
		g = 288.1221695283 * pow(t - 60.0, -0.0755148492)
		b = 255.0
	if t >= 66.0:
		b = 255.0
	elif t <= 19.0:
		b = 0.0
	else:
		b = 138.5177312231 * log(t - 10.0) - 305.0447927307
	return Color(clampf(r, 0.0, 255.0) / 255.0, clampf(g, 0.0, 255.0) / 255.0,
		clampf(b, 0.0, 255.0) / 255.0, 1.0)


func _build_texture() -> void:
	var slices: Array[Image] = []
	for z in GRID.z:
		var image := Image.create(GRID.x, GRID.y, false, Image.FORMAT_RGBA8)
		slices.append(image)
	_texture = ImageTexture3D.new()
	_texture.create(Image.FORMAT_RGBA8, GRID.x, GRID.y, GRID.z, false, slices)


func _update_texture() -> void:
	if _texture == null:
		return
	# 可见火舌走交叉面片；体积层隐藏时不重建 20 张 3D 切片，避免无谓上传。
	if _volume != null and not _volume.visible:
		return
	var slices: Array[Image] = []
	for z in GRID.z:
		var image := Image.create(GRID.x, GRID.y, false, Image.FORMAT_RGBA8)
		for y in GRID.y:
			for x in GRID.x:
				var i := _index(x, y, z)
				var heat := clampf((_temp[i] - 293.0) / 2200.0, 0.0, 1.0)
				var soot := clampf(_soot[i], 0.0, 1.0)
				var fuel := clampf(_fuel[i], 0.0, 1.0)
				image.set_pixel(x, y, Color(heat, soot, fuel, 1.0))
		slices.append(image)
	_texture.update(slices)


# --- 视觉 / 音频 ---------------------------------------------------------------

func _build_volume() -> void:
	var material := ShaderMaterial.new()
	material.shader = preload("res://shaders/procedural_fire.gdshader")
	material.set_shader_parameter("fire_tex", _texture)
	material.set_shader_parameter("blackbody_lut", _blackbody_lut)
	material.set_shader_parameter("box_min", BOX_MIN)
	material.set_shader_parameter("box_max", BOX_MAX)
	material.set_shader_parameter("source_pos", SOURCE)
	material.set_shader_parameter("fire_radius", FIRE_START_RADIUS)
	material.set_shader_parameter("fire_height", 2.0)
	material.set_shader_parameter("intensity", intensity)
	_volume = MeshInstance3D.new()
	_volume.name = "FireVolume"
	var box := BoxMesh.new()
	box.size = BOX_MAX - BOX_MIN
	_volume.mesh = box
	_volume.position = (BOX_MIN + BOX_MAX) * 0.5
	_volume.material_override = material
	_volume.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# 体积层保留为火光/热雾；可见火舌用交叉面片，避免高位机位只看到一个发光团。
	_volume.visible = false
	add_child(_volume)
	_build_flames()


func _build_flames() -> void:
	# 多层 billboard：主火舌 + 两侧偏移的小火舌，避免看到一根均匀的光柱。
	for index in 4:
		var flame := MeshInstance3D.new()
		flame.name = "Flame_%d" % index
		var quad := QuadMesh.new()
		quad.size = Vector2(1.5, 2.5)
		flame.mesh = quad
		var offsets := [Vector3(0, 0, 0), Vector3(-0.42, 0, 0.18),
			Vector3(0.42, 0, -0.18), Vector3(0.08, 0, 0.36)]
		flame.position = SOURCE + offsets[index] + Vector3(0, 1.25, 0)
		flame.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		flame.visible = true
		var material := ShaderMaterial.new()
		material.shader = FLAME_SHADER
		material.set_shader_parameter("blackbody_lut", _blackbody_lut)
		material.set_shader_parameter("intensity", 0.0)
		material.set_shader_parameter("seed", float(index) * 3.1)
		flame.material_override = material
		add_child(flame)
		_flames.append(flame)
	# 火光：让舞台/幕布/地面被火焰照亮，而不是只看到一张贴片。
	_light = OmniLight3D.new()
	_light.name = "FireLight"
	_light.position = SOURCE + Vector3(0, 1.15, 0)
	_light.light_color = Color(1.0, 0.35, 0.08)
	_light.light_energy = 2.0
	_light.omni_range = 7.0
	add_child(_light)
	_build_embers()


func _build_embers() -> void:
	_embers = GPUParticles3D.new()
	_embers.name = "FireEmbers"
	_embers.amount = 44
	_embers.lifetime = 1.4
	_embers.preprocess = 1.2
	_embers.position = SOURCE + Vector3(0, 0.5, 0)
	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	process.emission_box_extents = Vector3(0.45, 0.12, 0.45)
	process.direction = Vector3(0, 1, 0)
	process.spread = 18.0
	process.initial_velocity_min = 0.2
	process.initial_velocity_max = 0.9
	process.gravity = Vector3(0, 1.5, 0)
	process.scale_min = 0.5
	process.scale_max = 1.4
	process.color = Color(1.0, 0.35, 0.05)
	_embers.process_material = process
	var ember_mesh := SphereMesh.new()
	ember_mesh.radius = 0.022
	ember_mesh.height = 0.044
	var ember_material := StandardMaterial3D.new()
	ember_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ember_material.albedo_color = Color(1.0, 0.35, 0.05)
	ember_material.emission_enabled = true
	ember_material.emission = Color(1.0, 0.25, 0.02)
	ember_material.emission_energy_multiplier = 4.0
	ember_mesh.material = ember_material
	_embers.draw_pass_1 = ember_mesh
	add_child(_embers)


func _update_volume_uniforms() -> void:
	if _volume == null or _volume.material_override == null:
		return
	var material := _volume.material_override as ShaderMaterial
	material.set_shader_parameter("intensity", intensity)
	material.set_shader_parameter("source_pos", SOURCE)
	material.set_shader_parameter("fire_radius", maxf(radius, 0.35))
	material.set_shader_parameter("fire_height", minf(2.5, 1.8 + radius * 0.22))
	var flame_width := 1.2 + radius * 0.70
	var flame_height := 2.0 + radius * 0.70
	for index in _flames.size():
		var flame := _flames[index]
		if flame == null:
			continue
		var width_scale := 1.0 if index == 0 else (0.42 if index < 3 else 0.30)
		var height_scale := 1.0 if index == 0 else (0.66 if index < 3 else 0.48)
		flame.scale = Vector3(flame_width * width_scale,
			flame_height * height_scale / 2.5, 1.0)
		var offset := Vector3(0, 0, 0)
		if index > 0:
			offset = [Vector3(-0.42, 0, 0.18), Vector3(0.42, 0, -0.18),
				Vector3(0.08, 0, 0.36)][index - 1]
		flame.position = SOURCE + offset + Vector3(0, flame_height * height_scale * 0.5, 0)
		var flame_material := flame.material_override as ShaderMaterial
		var layer_intensity := 0.55 if index == 0 else 0.75
		flame_material.set_shader_parameter("intensity",
			intensity * layer_intensity * (0.82 + 0.18 * sin(age * 2.0 + index)))
	if _light != null:
		_light.light_energy = 1.5 + intensity * 3.0 + 0.5 * sin(age * 8.0)
		_light.omni_range = 5.0 + radius * 1.4
	if _embers != null:
		_embers.amount_ratio = clampf(0.25 + intensity * 0.75, 0.0, 1.0)


func _build_audio() -> void:
	var samples := 22050
	var bytes := PackedByteArray()
	bytes.resize(samples * 2)
	var low := 0.0
	var crackle := 0.0
	for i in samples:
		var noise := _rng.randf_range(-1.0, 1.0)
		low = lerpf(low, noise, 0.035)
		if _rng.randf() < 0.0012:
			crackle = _rng.randf_range(0.25, 0.9)
		crackle *= 0.92
		var value := low * 0.55 + noise * 0.08 + crackle * (noise * 0.8 + low)
		value = clampf(value, -1.0, 1.0)
		var sample := int(value * 32767.0)
		bytes[i * 2] = sample & 0xFF
		bytes[i * 2 + 1] = (sample >> 8) & 0xFF
	_audio_stream = AudioStreamWAV.new()
	_audio_stream.format = AudioStreamWAV.FORMAT_16_BITS
	_audio_stream.mix_rate = samples
	_audio_stream.stereo = false
	_audio_stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
	_audio_stream.loop_begin = 0
	_audio_stream.loop_end = samples
	_audio_stream.data = bytes
	_audio = AudioStreamPlayer3D.new()
	_audio.name = "FireAudio"
	_audio.stream = _audio_stream
	_audio.position = SOURCE + Vector3(0, 0.4, 0)
	_audio.unit_size = 4.0
	_audio.max_distance = 30.0
	_audio.volume_db = -22.0
	add_child(_audio)
	_audio.play()


func _update_audio() -> void:
	if _audio == null:
		return
	_audio.volume_db = lerpf(-22.0, -7.0, intensity)
	_audio.pitch_scale = 0.94 + intensity * 0.1
