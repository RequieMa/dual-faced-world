extends SceneTree
## 一键跑全部 headless 测试：自动发现 tests/smoke_test.gd + tests/test_*.gd，
## 逐个用 OS.execute 起一个新的 Godot 进程，汇总每套结果并给出总退出码。
##
## 用法：godot --headless --path . --script tests/run_all.gd
## 退出码：0 = 全部通过，1 = 有套件失败（会打印失败套件的输出），2 = 没发现任何套件。
##
## 新增测试只需命名 tests/test_<domain>*.gd，不需要改本文件（避免共享文件冲突）。


func _initialize() -> void:
	var suites := _collect_suites()
	if suites.is_empty():
		printerr("RUN_ALL_FAIL: 没有发现任何测试套件（tests/smoke_test.gd 或 tests/test_*.gd）")
		quit(2)
		return

	var exe := OS.get_executable_path()
	var project_path := ProjectSettings.globalize_path("res://")
	if project_path.ends_with("/") or project_path.ends_with("\\"):
		project_path = project_path.substr(0, project_path.length() - 1)

	var failed: Array[String] = []
	for suite in suites:
		var output: Array = []
		var exit_code := OS.execute(exe,
			["--headless", "--path", project_path, "--script", "res://" + suite],
			output, true)
		if exit_code == 0:
			print("[PASS] ", suite)
		else:
			failed.append(suite)
			printerr("[FAIL] ", suite, " exit=", exit_code)
			for line in output:
				printerr("  ", line)

	print("----")
	if failed.is_empty():
		print("RUN_ALL_PASS (%d suites)" % suites.size())
		quit(0)
	else:
		printerr("RUN_ALL_FAIL (%d/%d): %s" % [failed.size(), suites.size(), ", ".join(failed)])
		quit(1)


func _collect_suites() -> Array:
	var suites: Array = []
	if FileAccess.file_exists("res://tests/smoke_test.gd"):
		suites.append("tests/smoke_test.gd")
	var names := DirAccess.get_files_at("res://tests")
	names.sort()
	for file_name in names:
		if file_name.begins_with("test_") and file_name.ends_with(".gd"):
			suites.append("tests/" + String(file_name))
	return suites
