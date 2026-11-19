extends "res://scripts/monitor_grid.gd"
## 监控器网格 → 单击频道 → 全屏锁定 → ESC/右键返回 的 transition 演示。
##
## 状态机与 transition 逻辑在基类 monitor_grid.gd；这里只提供 4 路机位数据，
## 演示行为（4 个立方体、点击放大、扫描线、ESC 返回）保持不变。

## 四个频道在共享 3D 世界中的观察目标（各自立方体中心）。
const CELL_CAMERA_TARGETS: Array[Vector3] = [
	Vector3(-5.0, 0.6, 0.0),
	Vector3(5.0, 0.6, 0.0),
	Vector3(0.0, 0.6, -5.0),
	Vector3(0.0, 0.6, 5.0),
]

## 各频道机位相对目标的偏移，使四个画面构图各不相同。
const CELL_CAMERA_OFFSETS: Array[Vector3] = [
	Vector3(2.0, 1.6, 2.2),
	Vector3(-2.1, 1.4, 2.0),
	Vector3(1.8, 1.9, -2.1),
	Vector3(-1.9, 1.3, -2.3),
]


func _ready() -> void:
	cell_targets = CELL_CAMERA_TARGETS
	cell_offsets = CELL_CAMERA_OFFSETS
	super._ready()
