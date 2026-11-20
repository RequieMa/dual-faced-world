extends SceneTree
## 一键跑全部 headless 测试：逐个用 OS.execute 起一个新的 Godot 进程，
## 汇总每套的结果并给出总退出码（CI 与本地都用同一条命令）。
##
## 用法：godot --headless --path . --script tests/run_all.gd
## 退出码：0 = 全部通过，1 = 有套件失败（会打印失败套件的输出）。

const SUITES: Array[String] = [
	"tests/smoke_test.gd",
	"tests/test_config.gd",
	"tests/test_integrated_sim.gd",
	"tests/test_integrated_sim_live.gd",
	"tests/test_puzzle_lab.gd",
]


func _initialize() -> void:
	var exe := OS.get_executable_path()
	var project_path := ProjectSettings.globalize_path("res://")
	if project_path.ends_with("/") or project_path.ends_with("\\"):
		project_path = project_path.substr(0, project_path.length() - 1)

	var failed: Array[String] = []
	for suite in SUITES:
		var output: Array = []
		var exit_code := OS.execute(exe,
			["--headless", "--path", project_path, "--script", "res://" + String(suite)],
			output, true)
		if exit_code == 0:
			print("[PASS] ", suite)
		else:
			failed.append(String(suite))
			printerr("[FAIL] ", suite, " exit=", exit_code)
			for line in output:
				printerr("  ", line)

	print("----")
	if failed.is_empty():
		print("RUN_ALL_PASS (%d suites)" % SUITES.size())
		quit(0)
	else:
		printerr("RUN_ALL_FAIL (%d/%d): %s" % [failed.size(), SUITES.size(), ", ".join(failed)])
		quit(1)
