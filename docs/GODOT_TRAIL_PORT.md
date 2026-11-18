# 从 godot-trail 移植的工程基础

来源：`RequieMa/godot-trail`，提交 `1ebe076`（本机参考副本：`~/references/godot-trail`）。
Godot 4.7 / 纯 GDScript / Forward+。

## 移植内容

| 类别 | 文件 | 价值 |
|---|---|---|
| 工程配置 | `project.godot` | Godot 4.7 基线、main scene、三个 autoload |
| 双时钟系统 | `scripts/time_manager.gd` | 实时/档案双时钟、救援事件时间轴、静默补播 |
| 录像带系统 | `scripts/tape_archive.gd`、`scripts/tapes/tape_resource.gd`、`resources/tapes/*.tres` | 数据模型 + 发现/归档/播放定位 |
| 线索系统 | `scripts/clue_manager.gd`、`resources/data/clues.json` | JSON 定义驱动、运行时登记、解锁 |
| 监控墙/地图 | `scripts/theater_map.gd`、`scripts/theater_monitor.gd`、`scripts/monitor_grid_demo.gd` | 9 路 SubViewport、全屏锁定过渡、数据驱动机位 |
| 演示场景 | `scenes/*.tscn`、`scripts/demos/*.gd`、`scripts/demo_ui.gd` | 可运行的系统 demo |
| 着色器 | `shaders/grid_ground.gdshader`、`shaders/scanline_vignette.gdshader` | 网格地面、扫描线/暗角 |
| 测试 | `tests/smoke_test.gd` | 校验 main scene 可加载、可实例化 |
| 经验 | `MEMORY.md` | Godot/DSH/Game Studio 的真实踩坑与约定 |

同时补了 `.gitignore` 的 `.dsh/` 与 `autoload/`（本机工具状态、godot-bridge 注入文件不入库）。

## 没有移植

- `docs/screenshots/`（参考仓库的展示图，本仓库暂不需要）
- `README.md`、`manifests/`、`external-assets/`（结构已存在或属于仓库自身说明）
- 与 godot-trail 叙事强绑定的命名；`project.godot` 的 `config/name` 已改为「二面世界 / Dual-Faced World」

## 验证

```sh
/Applications/Godot_mono.app/Contents/MacOS/Godot \
  --headless --path . --script tests/smoke_test.gd
```

期望输出 `SMOKE_TEST_PASS`，退出码 0。

## 后续

这些是工程底座，不是《二面世界》的最终玩法内容：

1. 保留可复用的系统（时间/线索/录像带/监控墙）与测试；
2. 用二面世界的设定替换 `theater_*` / `tape_*` 的演示内容；
3. 在 `project.godot` 里逐步确定正式 main scene；
4. 任何行为变更按 `AGENTS.md` 先写测试。
