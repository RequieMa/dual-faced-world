extends SceneTree
## W6 存档服务测试（SaveService）。
## 运行：godot --headless --path . --script tests/test_save_service.gd
## 退出码 0 = 全绿，1 = 有用例失败。
##
## 覆盖 docs/MECHANICS_CONTRACTS.md §7 与 Issue #16 的存档验收：
## - snapshot() 收集 manager.to_dict()，带 version / created_at；
## - save 写盘、load 读回、restore = load + manager.from_dict；
## - 存 → 改 → 读回一致；坏文件 / 版本不符 / 缺 managers 返回 {} + 错误，不崩溃、不改旧状态；
## - restore 同时接受路径与快照字典（Issue #16 的 restore(data)）。
##
## 注意：Godot 的 JSON 把数字统一读成 float，所以测试数据用 float / string，
## 并单独断言「整数读回为浮点」这一 JSON 语义，避免误报「不一致」。

const SAVE_SERVICE := "res://scripts/save/save_service.gd"
const TEMP_DIR := "user://save_service_test"

## 契约方法清单：实现被改名或删掉时在开头就失败，而不是少跑断言还 PASS。
const REQUIRED_METHODS: Array[String] = ["snapshot", "save", "load", "restore"]
## 全绿时应执行的断言数：运行时错误会中止当前用例，靠数量守恒抓住「假绿」。
const EXPECTED_CHECKS := 60

var _failures: Array[String] = []
var _checks: int = 0


## 假 manager：只实现契约要求的 to_dict()/from_dict()。
class FakeManager extends RefCounted:
	var data: Dictionary = {}
	var restore_calls: int = 0

	func _init(initial: Dictionary = {}) -> void:
		data = initial.duplicate(true)

	func to_dict() -> Dictionary:
		return data.duplicate(true)

	func from_dict(value: Dictionary) -> void:
		restore_calls += 1
		data = value.duplicate(true)


## 只有 from_dict：不能进存档。
class NoDictManager extends RefCounted:
	func from_dict(_value: Dictionary) -> void:
		pass


## 只有 to_dict：能存不能恢复。
class NoRestoreManager extends RefCounted:
	var data: Dictionary = {"value": "keep"}

	func to_dict() -> Dictionary:
		return data.duplicate(true)


## to_dict 返回非字典：快照不成立。
class BrokenManager extends RefCounted:
	func to_dict():
		return "not a dictionary"


## Node 版 fake manager：用于验证 manager 被释放后的快照行为。
class NodeManager extends Node:
	var data: Dictionary = {"value": "node"}

	func to_dict() -> Dictionary:
		return data.duplicate(true)

	func from_dict(value: Dictionary) -> void:
		data = value.duplicate(true)


func _initialize() -> void:
	_check("存在 scripts/save/save_service.gd", ResourceLoader.exists(SAVE_SERVICE))
	if not ResourceLoader.exists(SAVE_SERVICE):
		_report()
		return

	var probe = _service()
	_check("SaveService 可实例化", probe != null)
	if probe == null:
		_report()
		return
	var missing := _missing_api(probe)
	_check("SaveService 提供契约方法", missing.is_empty(), str(missing))
	if not missing.is_empty():
		_report()
		return

	_ensure_temp_dir()
	_test_snapshot()
	_test_freed_manager()
	_test_save_load_roundtrip()
	_test_save_failure_paths()
	_test_restore()
	_test_restore_from_dictionary()
	_test_error_semantics()
	_test_invalid_snapshot_not_saved()
	_cleanup()
	_report()


# --- 断言 ---------------------------------------------------------------------

func _check(label: String, condition: bool, detail: String = "") -> void:
	_checks += 1
	if condition:
		print("PASS  ", label)
	else:
		var message := label
		if not detail.is_empty():
			message += "  [" + detail + "]"
		_failures.append(message)
		printerr("FAIL  ", message)


func _report() -> void:
	if _checks != EXPECTED_CHECKS:
		var count_message := "断言数不符：实际 %d，期望 %d（有测试用例被运行时错误中止？）" % [_checks, EXPECTED_CHECKS]
		_failures.append(count_message)
		printerr("FAIL  ", count_message)
	print("----")
	if _failures.is_empty():
		print("SAVE_SERVICE_TEST_PASS (%d checks)" % _checks)
		quit(0)
	else:
		printerr("SAVE_SERVICE_TEST_FAIL (失败 %d 项 / 执行 %d checks)" % [_failures.size(), _checks])
		for failure in _failures:
			printerr("  - ", failure)
		quit(1)


# --- 工具 ---------------------------------------------------------------------

func _service(initial: Dictionary = {}):
	var script_resource = load(SAVE_SERVICE)
	if script_resource == null or not script_resource.can_instantiate():
		return null
	return script_resource.new(initial)


func _missing_api(instance) -> Array[String]:
	var missing: Array[String] = []
	for method_name in REQUIRED_METHODS:
		if not instance.has_method(method_name):
			missing.append(method_name)
	return missing


func _path(name: String) -> String:
	return TEMP_DIR + "/" + name


func _ensure_temp_dir() -> void:
	var absolute := ProjectSettings.globalize_path(TEMP_DIR)
	if not DirAccess.dir_exists_absolute(absolute):
		DirAccess.make_dir_recursive_absolute(absolute)


func _write(name: String, content: String) -> String:
	var path := _path(name)
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(content)
	file.close()
	return path


func _has_error_containing(service, needle: String) -> bool:
	for message in service.last_errors:
		if String(message).find(needle) >= 0:
			return true
	return false


func _cleanup() -> void:
	var absolute := ProjectSettings.globalize_path(TEMP_DIR)
	if not DirAccess.dir_exists_absolute(absolute):
		return
	for file_name in DirAccess.get_files_at(absolute):
		DirAccess.remove_absolute(absolute + "/" + String(file_name))
	for dir_name in DirAccess.get_directories_at(absolute):
		DirAccess.remove_absolute(absolute + "/" + String(dir_name))
	DirAccess.remove_absolute(absolute)


# --- snapshot -----------------------------------------------------------------

func _test_snapshot() -> void:
	var camera := FakeManager.new({"camera": "C1", "dwell": 6.0})
	var service = _service({"camera": camera})

	var snap: Dictionary = service.snapshot()
	_check("snapshot 带 version=1", int(snap.get("version", 0)) == 1, str(snap))
	_check("snapshot 的 created_at 是 unix 秒整数",
		typeof(snap.get("created_at")) == TYPE_INT and int(snap["created_at"]) > 0, str(snap))
	var managers_snapshot: Dictionary = snap.get("managers", {})
	_check("snapshot 收集 manager.to_dict()",
		managers_snapshot.has("camera")
		and (managers_snapshot["camera"] as Dictionary).get("camera") == "C1", str(snap))

	(managers_snapshot["camera"] as Dictionary)["camera"] = "C9"
	_check("snapshot 与 manager 状态隔离（深拷贝）", camera.data["camera"] == "C1",
		str(camera.data))

	var dialogue := FakeManager.new({"line": "hello"})
	var explicit: Dictionary = service.snapshot({"dialogue": dialogue})
	var explicit_managers: Dictionary = explicit.get("managers", {})
	_check("snapshot(managers) 收集传入的 manager",
		explicit_managers.has("dialogue") and explicit_managers.has("camera"), str(explicit))
	var replacement := FakeManager.new({"camera": "C2"})
	var overridden: Dictionary = service.snapshot({"camera": replacement})
	_check("snapshot(managers) 中同名 manager 覆盖已注册的",
		(overridden["managers"]["camera"] as Dictionary).get("camera") == "C2", str(overridden))

	var broken = _service({"broken": NoDictManager.new()})
	_check("manager 缺 to_dict 时 snapshot 返回空字典", broken.snapshot().is_empty(),
		str(broken.snapshot()))
	_check("缺少 to_dict 时记录错误", not broken.last_errors.is_empty(), str(broken.last_errors))

	var broken_dict = _service({"broken": BrokenManager.new()})
	_check("to_dict 返回非字典时 snapshot 返回空字典", broken_dict.snapshot().is_empty(),
		str(broken_dict.snapshot()))
	_check("to_dict 返回非字典时记录错误", not broken_dict.last_errors.is_empty(),
		str(broken_dict.last_errors))


func _test_freed_manager() -> void:
	var node_manager := NodeManager.new()
	var service = _service({"node": node_manager})
	node_manager.free()
	_check("manager 被释放后 snapshot 返回空字典", service.snapshot().is_empty())
	_check("manager 被释放时记录错误", not service.last_errors.is_empty(), str(service.last_errors))


# --- save / load ----------------------------------------------------------------

func _test_save_load_roundtrip() -> void:
	var service = _service()
	var loop_manager := FakeManager.new({"outcome": "caught", "elapsed": 42.5, "clues": 2.0})
	var snap: Dictionary = service.snapshot({"loop": loop_manager})
	var path := _path("slot_roundtrip.json")

	_check("save 写入成功", service.save(path, snap))
	_check("save 后文件存在", FileAccess.file_exists(path))
	_check("save 后没有残留 .tmp 临时文件", not FileAccess.file_exists(path + ".tmp"))

	var loaded: Dictionary = service.load(path)
	_check("load 读回 version", int(loaded.get("version", 0)) == 1, str(loaded))
	_check("load 读回 created_at 一致", int(loaded.get("created_at", 0)) == int(snap["created_at"]),
		str(loaded))
	var loaded_managers: Dictionary = loaded.get("managers", {})
	_check("load 读回 managers 数据",
		(loaded_managers.get("loop", {}) as Dictionary) == {"outcome": "caught", "elapsed": 42.5, "clues": 2.0},
		str(loaded_managers))

	service.save(path, service.snapshot({"loop": FakeManager.new({"outcome": "escaped", "elapsed": 88.0, "clues": 5.0})}))
	loaded = service.load(path)
	_check("再次 save 覆盖旧档，load 读回最新数据",
		(loaded["managers"]["loop"] as Dictionary).get("outcome") == "escaped", str(loaded))

	var int_path := _path("slot_int.json")
	service.save(int_path, service.snapshot({"ints": FakeManager.new({"count": 3})}))
	var int_loaded: Dictionary = service.load(int_path)
	_check("JSON 存档把整数读回为浮点（Godot JSON 语义）",
		typeof((int_loaded["managers"]["ints"] as Dictionary).get("count")) == TYPE_FLOAT,
		str(int_loaded))
	_check("整数读回后数值不变", int((int_loaded["managers"]["ints"] as Dictionary).get("count")) == 3,
		str(int_loaded))

	_check("load 不存在的文件返回空字典", service.load(_path("no_such_slot.json")).is_empty())
	_check("load 不存在文件时记录错误", not service.last_errors.is_empty(), str(service.last_errors))


func _test_save_failure_paths() -> void:
	var service = _service()
	var snap: Dictionary = service.snapshot({"loop": FakeManager.new({"value": "good"})})
	var dir_path := _path("slot_is_directory.json")
	var absolute_dir := ProjectSettings.globalize_path(dir_path)
	if not DirAccess.dir_exists_absolute(absolute_dir):
		DirAccess.make_dir_recursive_absolute(absolute_dir)

	_check("save 到已存在目录失败并记录错误",
		not service.save(dir_path, snap) and not service.last_errors.is_empty(),
		str(service.last_errors))
	_check("save 到已存在目录后没有 .tmp 残留", not FileAccess.file_exists(dir_path + ".tmp"))
	DirAccess.remove_absolute(absolute_dir)


# --- restore --------------------------------------------------------------------

func _test_restore() -> void:
	var camera := FakeManager.new({"camera": "C1", "cooldown": 0.0})
	var service = _service({"camera": camera})
	var path := _path("slot_restore.json")
	_check("准备：写入存档", service.save(path, service.snapshot()))
	_check("准备：改动 manager 状态", camera.data["camera"] == "C1")
	camera.data = {"camera": "changed"}
	camera.restore_calls = 0

	var restored: Dictionary = service.restore(path)
	_check("restore 返回读到的存档", not restored.is_empty() and int(restored.get("version", 0)) == 1,
		str(restored))
	_check("restore 逐个调用 manager.from_dict()",
		camera.restore_calls == 1 and camera.data["camera"] == "C1", str(camera.data))

	var other := FakeManager.new({"value": "before"})
	var svc = _service({"camera": camera, "other": other})
	var partial: Dictionary = {"version": 1, "created_at": 1, "managers": {"other": {"value": "after"}}}
	var result: Dictionary = svc.restore(partial)
	_check("restore 恢复快照里有的 manager", other.data["value"] == "after" and result.size() > 0,
		str(other.data))
	_check("restore 不改快照里没有的 manager", camera.data["camera"] == "C1", str(camera.data))

	var no_restore := NoRestoreManager.new()
	var svc_skip = _service({"skip": no_restore})
	var skipped: Dictionary = svc_skip.restore(
		{"version": 1, "created_at": 1, "managers": {"skip": {"value": "new"}, "ghost": {"x": 1.0}}})
	_check("缺少 from_dict / 未注册的 manager 被跳过，restore 仍返回存档",
		not skipped.is_empty() and no_restore.data["value"] == "keep", str(no_restore.data))

	var bad_data := FakeManager.new({"kept": "yes"})
	var svc_bad = _service({"bad": bad_data})
	var bad_result: Dictionary = svc_bad.restore(
		{"version": 1, "created_at": 1, "managers": {"bad": "not-a-dictionary"}})
	_check("manager 的存档数据不是字典时跳过且不改状态",
		not bad_result.is_empty() and bad_data.data == {"kept": "yes"}, str(bad_data.data))


func _test_restore_from_dictionary() -> void:
	var camera := FakeManager.new({"camera": "C1"})
	var service = _service({"camera": camera})
	var saved: Dictionary = {
		"version": 1,
		"created_at": 123,
		"managers": {"camera": {"camera": "saved", "dwell": 6.5}},
	}
	var restored: Dictionary = service.restore(saved)
	_check("restore(快照字典) 直接应用数据（Issue #16 restore(data)）",
		not restored.is_empty() and camera.data.get("camera") == "saved", str(camera.data))


# --- 错误语义 -------------------------------------------------------------------

func _test_error_semantics() -> void:
	var camera := FakeManager.new({"camera": "keep"})
	var service = _service({"camera": camera})

	var bad_json_path := _write("bad.json", "{not json")
	_check("坏 JSON 的 load 返回空字典", service.load(bad_json_path).is_empty())
	_check("坏 JSON 记录错误", not service.last_errors.is_empty(), str(service.last_errors))
	_check("读坏档不改 manager 状态", camera.data["camera"] == "keep", str(camera.data))

	var array_path := _write("array.json", "[1, 2, 3]")
	_check("根节点不是对象的 load 返回空字典", service.load(array_path).is_empty())
	_check("根节点错误被记录", not service.last_errors.is_empty(), str(service.last_errors))

	var missing_version := _write("missing_version.json", "{\"managers\": {}}")
	var loaded_missing: Dictionary = service.load(missing_version)
	_check("缺少 version 的 load 返回空字典", loaded_missing.is_empty())
	_check("缺少 version 的错误提到版本", _has_error_containing(service, "version"),
		str(service.last_errors))

	var bad_version := _write("bad_version.json", "{\"version\": 99, \"managers\": {}}")
	_check("版本不符的 load 返回空字典", service.load(bad_version).is_empty())
	_check("版本不符的错误提到版本", _has_error_containing(service, "version"),
		str(service.last_errors))

	var bad_managers := _write("bad_managers.json", "{\"version\": 1, \"managers\": []}")
	_check("managers 不是对象的 load 返回空字典", service.load(bad_managers).is_empty())
	_check("managers 类型错误被记录", not service.last_errors.is_empty(), str(service.last_errors))

	var restore_result: Dictionary = service.restore(bad_version)
	_check("版本不符的 restore 返回空字典", restore_result.is_empty())
	_check("版本不符的 restore 不覆盖旧档", camera.data["camera"] == "keep", str(camera.data))
	_check("版本不符的 restore 记录错误", not service.last_errors.is_empty(), str(service.last_errors))

	var missing_restore: Dictionary = service.restore(_path("no_such_slot.json"))
	_check("文件不存在的 restore 返回空字典", missing_restore.is_empty())
	_check("文件不存在的 restore 不改状态", camera.data["camera"] == "keep", str(camera.data))


func _test_invalid_snapshot_not_saved() -> void:
	var service = _service()
	var path := _path("slot_protected.json")
	var good: Dictionary = service.snapshot({"loop": FakeManager.new({"value": "good"})})
	_check("准备：写入合法存档", service.save(path, good))

	_check("save 拒绝空快照", not service.save(path, {}))
	_check("拒绝保存时记录错误", not service.last_errors.is_empty(), str(service.last_errors))
	_check("空路径 save 失败并记录错误",
		not service.save("", {}) and not service.last_errors.is_empty(), str(service.last_errors))
	var reloaded: Dictionary = service.load(path)
	_check("拒绝保存后旧档仍在且可读",
		(reloaded.get("managers", {}) as Dictionary).has("loop"), str(reloaded))

	var bad_version: Dictionary = {"version": 99, "managers": {}}
	_check("save 拒绝版本不符的快照", not service.save(path, bad_version))
	_check("拒绝保存后旧档未被覆盖",
		(service.load(path).get("managers", {}) as Dictionary).has("loop"), str(service.load(path)))
