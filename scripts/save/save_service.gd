extends RefCounted
## W6 存档服务（M18）。契约见 docs/MECHANICS_CONTRACTS.md §7。
##
## - `snapshot()` 只收集 manager.to_dict()，不调用 from_dict，带 version / created_at；
## - `save(path, snapshot)` 只写文件；`load(path)` 只读文件 + 版本校验；
## - `restore(source)` = load 后逐个 manager.from_dict()；source 既可以是存档路径，
##   也可以是已读出的快照字典（兼容 Issue #16 的 restore(data)）；
## - 失败返回 {} 并写 last_errors + push_warning：不崩溃、不覆盖旧档。
##
## 注意：Godot 的 JSON 会把所有数字读成 float（3 读回是 3.0），
## 所以 load() 会保留 managers 里的数值类型语义，但调用方不要依赖 int/float 严格区分。
## manager.to_dict() 必须返回 JSON-safe 的原始数据（Dictionary/Array/String/数字/bool/null）；
## JSON.stringify 会把 Vector3 / Node 等序列化成字符串且不报错，适配器需先自行转换。

const VERSION := 1

var last_errors: Array[String] = []

var _managers: Dictionary = {}


## 可选的构造参数：`SaveService.new({"camera": adapter, ...})` 让 snapshot() 无参可用。
func _init(initial_managers: Dictionary = {}) -> void:
	for manager_name in initial_managers.keys():
		register_manager(String(manager_name), initial_managers[manager_name])


## 注册一个可存档 manager（需要 to_dict()；恢复时还需要 from_dict()）。
func register_manager(manager_name: String, manager) -> bool:
	if manager_name.is_empty():
		_fail("manager 名称不能为空")
		return false
	# is_instance_valid 同时挡住 null、非 Object 值和已 free 的实例。
	if not is_instance_valid(manager):
		_fail("manager '%s' 不是有效对象（null 或已释放）" % manager_name)
		return false
	_managers[manager_name] = manager
	return true


## 收集快照：默认用已注册的 managers；传入的 managers 会覆盖同名项。
func snapshot(managers: Dictionary = {}) -> Dictionary:
	last_errors.clear()
	var source: Dictionary = _managers.duplicate()
	for manager_name in managers.keys():
		source[String(manager_name)] = managers[manager_name]

	var data: Dictionary = {}
	for manager_name in source.keys():
		var key := String(manager_name)
		var manager = source[manager_name]
		if not is_instance_valid(manager) or not manager.has_method("to_dict"):
			_fail("manager '%s' 不可用（已释放）或缺少 to_dict()，无法生成快照" % key)
			return {}
		var manager_data: Variant = manager.to_dict()
		if not manager_data is Dictionary:
			_fail("manager '%s'.to_dict() 未返回 Dictionary" % key)
			return {}
		data[key] = (manager_data as Dictionary).duplicate(true)

	return {
		"version": VERSION,
		"created_at": int(Time.get_unix_time_from_system()),
		"managers": data,
	}


## 写档：只写文件。非法快照 / 写失败返回 false（不产生半成品存档）。
## 先写临时文件再 rename：写入中断不会截断旧档（契约「不覆盖旧档」）。
func save(path: String, snapshot_data: Dictionary) -> bool:
	last_errors.clear()
	if path.is_empty():
		_fail("存档路径不能为空")
		return false
	var validated: Dictionary = _validate_snapshot(snapshot_data, path)
	if validated.is_empty():
		return false
	_ensure_parent_dir(path)

	var temp_path := path + ".tmp"
	var file := FileAccess.open(temp_path, FileAccess.WRITE)
	if file == null:
		_fail("打开临时存档失败（%s）: %s" % [temp_path, error_string(FileAccess.get_open_error())])
		return false
	file.store_string(JSON.stringify(validated, "\t"))
	var write_error := file.get_error()
	file.close()
	if write_error != OK:
		_remove_if_exists(temp_path)
		_fail("写入临时存档失败（%s）: %s" % [temp_path, error_string(write_error)])
		return false

	var rename_error := DirAccess.rename_absolute(ProjectSettings.globalize_path(temp_path),
		ProjectSettings.globalize_path(path))
	if rename_error != OK:
		_remove_if_exists(temp_path)
		_fail("替换存档失败（%s）: %s" % [path, error_string(rename_error)])
		return false
	return true


## 读档 + 版本校验：失败返回 {}（原因见 last_errors）。
func load(path: String) -> Dictionary:
	last_errors.clear()
	if path.is_empty() or not FileAccess.file_exists(path):
		_fail("存档不存在: %s" % path)
		return {}
	var text := FileAccess.get_file_as_string(path)
	if text.strip_edges().is_empty():
		_fail("存档文件为空: %s" % path)
		return {}
	# 用 JSON 实例而不是 JSON.parse_string：解析失败不往 stderr 打引擎级 ERROR。
	var json := JSON.new()
	if json.parse(text) != OK:
		_fail("存档 JSON 解析失败（%s）: %s" % [path, json.get_error_message()])
		return {}
	if not json.data is Dictionary:
		_fail("存档根节点必须是对象: %s" % path)
		return {}
	return _validate_snapshot(json.data, path)


## 恢复：load（路径）或直接校验快照字典，再逐个 manager.from_dict()。
## 返回恢复成功的快照；失败返回 {}。缺失 / 不可恢复的 manager 跳过并 push_warning。
func restore(source) -> Dictionary:
	last_errors.clear()
	var snapshot_data: Dictionary = {}
	if source is String or source is StringName:
		# 显式 self.load()：类里的 load() 会遮蔽全局 load()，这里要的是读档方法。
		snapshot_data = self.load(String(source))
	elif source is Dictionary:
		snapshot_data = _validate_snapshot(source, "restore")
	else:
		_fail("restore 需要存档路径或快照字典，实际是 %s" % str(typeof(source)))
		return {}
	if snapshot_data.is_empty():
		return {}

	var saved_managers: Dictionary = snapshot_data.get("managers", {})
	for manager_name in saved_managers.keys():
		var key := String(manager_name)
		var manager = _managers.get(key)
		if not is_instance_valid(manager):
			push_warning("SaveService: 存档里的 manager '%s' 未注册或已释放，已跳过" % key)
			continue
		if not manager.has_method("from_dict"):
			push_warning("SaveService: manager '%s' 缺少 from_dict()，已跳过" % key)
			continue
		var manager_data: Variant = saved_managers[manager_name]
		if not manager_data is Dictionary:
			push_warning("SaveService: manager '%s' 的存档数据不是 Dictionary，已跳过" % key)
			continue
		manager.from_dict((manager_data as Dictionary).duplicate(true))
	return snapshot_data


# --- 内部 ---------------------------------------------------------------------

func _validate_snapshot(data: Dictionary, origin: String) -> Dictionary:
	var version: Variant = data.get("version")
	var version_type := typeof(version)
	if version_type != TYPE_INT and version_type != TYPE_FLOAT:
		_fail("%s: 缺少 version 字段或类型不符" % origin)
		return {}
	if int(version) != VERSION:
		_fail("%s: 存档 version 不兼容（需要 %d，实际 %d）" % [origin, VERSION, int(version)])
		return {}
	var raw_managers: Variant = data.get("managers", {})
	if not raw_managers is Dictionary:
		_fail("%s: managers 字段必须是对象" % origin)
		return {}

	var validated: Dictionary = data.duplicate(true)
	validated["version"] = VERSION
	var created_at: Variant = validated.get("created_at")
	var created_type := typeof(created_at)
	if created_type == TYPE_INT or created_type == TYPE_FLOAT:
		validated["created_at"] = int(created_at)
	else:
		validated.erase("created_at")
	validated["managers"] = (raw_managers as Dictionary).duplicate(true)
	return validated


func _ensure_parent_dir(path: String) -> void:
	var dir_path := path.get_base_dir()
	if dir_path.is_empty():
		return
	var absolute := ProjectSettings.globalize_path(dir_path)
	if not DirAccess.dir_exists_absolute(absolute):
		DirAccess.make_dir_recursive_absolute(absolute)


func _remove_if_exists(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _fail(message: String) -> void:
	last_errors.append(message)
	push_warning("SaveService: " + message)
