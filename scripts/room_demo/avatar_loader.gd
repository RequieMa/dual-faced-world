extends RefCounted
## 运行时加载 external-assets 里的 GLB avatar（这些资源不进 git，也不经过 Godot 编辑器导入）。
##
## - 用 GLTFDocument 从磁盘直接读 .glb，生成场景；
## - 按目标身高归一化（Soyo 原始约 5.96m，Lumine 约 1.57m）；
## - 把导入后的 StandardMaterial3D 替换成 `anime_toon.gdshader`，并加 `anime_outline.gdshader`
##   作为 next_pass，接近 Blender 预设的二次元描边/色块阴影效果；
## - 文件不存在时返回 null，调用方回退到 primitive。

const TOON_SHADER := preload("res://shaders/anime_toon.gdshader")
const OUTLINE_SHADER := preload("res://shaders/anime_outline.gdshader")

static var _white_texture: ImageTexture


static func load_avatar(path: String, target_height: float = 1.72,
		yaw_degrees: float = 0.0) -> Node3D:
	if not FileAccess.file_exists(path):
		return null
	var document := GLTFDocument.new()
	var state := GLTFState.new()
	var error := document.append_from_file(ProjectSettings.globalize_path(path), state)
	if error != OK:
		push_warning("AvatarLoader: 加载 GLB 失败 %s (err=%s)" % [path, error])
		return null
	var scene := document.generate_scene(state)
	if scene == null:
		return null

	var bounds := _relative_bounds(scene)
	if bounds.size.y <= 0.0001:
		push_warning("AvatarLoader: %s 的包围盒高度为 0" % path)
		return null
	var scale := target_height / bounds.size.y
	var center := bounds.get_center()
	scene.scale = Vector3.ONE * scale
	scene.position = Vector3(-center.x, -bounds.position.y, -center.z) * scale
	scene.rotation_degrees.y = yaw_degrees

	var wrapper := Node3D.new()
	wrapper.name = "Avatar"
	wrapper.add_child(scene)
	_apply_relaxed_pose(scene)
	_apply_toon(scene, scale)
	return wrapper


## 模型原始 rest pose 是 T-pose；把上臂放下来，避免 NPC 站着张开双臂。
## 只改上臂骨，不碰腿/裙骨，保持模型原有造型。
static func _apply_relaxed_pose(root: Node3D) -> void:
	var bone_pairs := [
		["腕.L", "腕.R"],
		["Bip001 L UpperArm", "Bip001 R UpperArm"],
	]
	for node in root.find_children("*", "Skeleton3D", true, false):
		var skeleton := node as Skeleton3D
		for pair in bone_pairs:
			var left_index := skeleton.find_bone(String(pair[0]))
			var right_index := skeleton.find_bone(String(pair[1]))
			if left_index < 0 or right_index < 0:
				continue
			var rotation := Quaternion(Vector3(1, 0, 0), deg_to_rad(75.0))
			skeleton.set_bone_pose_rotation(left_index, rotation)
			skeleton.set_bone_pose_rotation(right_index, rotation)


## 递归计算场景相对根的 AABB（GLTF 场景可能有多级节点）。
static func _relative_bounds(node: Node3D, parent_transform: Transform3D = Transform3D.IDENTITY) -> AABB:
	var transform := parent_transform * node.transform
	var result := AABB()
	var has_result := false
	if node is MeshInstance3D:
		var mesh_instance := node as MeshInstance3D
		var aabb := mesh_instance.get_aabb()
		for corner_index in 8:
			var corner := aabb.get_endpoint(corner_index)
			var point := transform * corner
			if not has_result:
				result = AABB(point, Vector3.ZERO)
				has_result = true
			else:
				result = result.expand(point)
	for child in node.get_children():
		if child is Node3D:
			var child_bounds := _relative_bounds(child, transform)
			if child_bounds.size.length_squared() <= 0.0:
				continue
			if not has_result:
				result = child_bounds
				has_result = true
			else:
				result = result.merge(child_bounds)
	return result


static func _apply_toon(root: Node3D, scale: float) -> void:
	var outline_width := 0.010 / maxf(scale, 0.0001)
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := node as MeshInstance3D
		if mesh_instance.mesh == null:
			continue
		for surface_index in mesh_instance.mesh.get_surface_count():
			var source := mesh_instance.get_active_material(surface_index)
			var texture: Texture2D = null
			var base_color := Color.WHITE
			var source_name := ""
			if source is StandardMaterial3D:
				var standard := source as StandardMaterial3D
				texture = standard.albedo_texture
				base_color = standard.albedo_color
				source_name = standard.resource_name
			elif source is BaseMaterial3D:
				base_color = (source as BaseMaterial3D).albedo_color
			var toon := ShaderMaterial.new()
			toon.shader = TOON_SHADER
			var lower_name := source_name.to_lower()
			# Genshin 的脸部贴图是“脸部阴影/表情层”，大部分像素 alpha=0；开 alpha 裁剪会把整张脸剔掉。
			var use_alpha := not ("face" in lower_name or "skin" in lower_name)
			toon.set_shader_parameter("albedo_tex", texture if texture != null else _white())
			toon.set_shader_parameter("has_texture", texture != null)
			toon.set_shader_parameter("albedo_color", base_color)
			toon.set_shader_parameter("use_alpha", use_alpha)
			var tint := _shadow_tint_for(source_name)
			toon.set_shader_parameter("shadow_tint", tint)
			toon.set_shader_parameter("rim_strength", 0.22)

			var outline := ShaderMaterial.new()
			outline.shader = OUTLINE_SHADER
			outline.set_shader_parameter("outline_width", outline_width)
			outline.set_shader_parameter("outline_color", Color(0.018, 0.022, 0.03, 1.0))
			toon.next_pass = outline
			mesh_instance.set_surface_override_material(surface_index, toon)


static func _shadow_tint_for(material_name: String) -> Color:
	var lower := material_name.to_lower()
	if "hair" in lower:
		return Color(0.52, 0.57, 0.72)
	if "face" in lower or "skin" in lower:
		return Color(0.76, 0.68, 0.72)
	if "eye" in lower:
		return Color(0.6, 0.66, 0.82)
	return Color(0.62, 0.68, 0.82)


static func _white() -> ImageTexture:
	if _white_texture == null:
		var image := Image.create(1, 1, false, Image.FORMAT_RGBA8)
		image.fill(Color.WHITE)
		_white_texture = ImageTexture.create_from_image(image)
	return _white_texture
