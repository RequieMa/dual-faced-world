# 二面世界 / Dual-Faced World

Godot 4.x 个项目。大体积资源位于 external-assets/，通过百度网盘同步，不进 Git。

## 开发流程

分支模型、TDD、独立评审、release/hotfix 与版本 tag 见
[docs/GIT_WORKFLOW.md](docs/GIT_WORKFLOW.md)；agent 的强制契约见
[AGENTS.md](AGENTS.md)。

- `main`：稳定发布线，合并后打 `vX.Y.Z` tag
- `release`：端到端测试版本
- `develop`：集成分支
- `feature-*` / `hotfix-*`：短生命周期分支

## Demo 场景

```sh
godot --path . scenes/<name>.tscn
```

- `scenes/main.tscn`：游戏入口，实例化 `scenes/game_root.tscn`；启动即进入 **3 轮可玩 demo**
  （`E` 拾取磁带拿线索 → `H` 开门 → `F` 把朋友引导到门口；第 2/3 轮有巡逻敌人，
  先过载机位用闪光挡住它再按 `F`；`1–4` 切换真实机位画面、`R` 失败重试 / 通关重玩，完整键位见
  [docs/MECHANICS_GAMEPLAY.md](docs/MECHANICS_GAMEPLAY.md)）
- `scenes/game_root.tscn`：W12 集成场景（摄像头 / 引导 / 对话 / 双画风 / 循环），
  玩法与接线见 [docs/MECHANICS_GAMEPLAY.md](docs/MECHANICS_GAMEPLAY.md)；设计决定见
  [docs/DESIGN_DECISIONS.md](docs/DESIGN_DECISIONS.md)
- `scenes/monitor_grid_demo.tscn`：监控墙 4 路放大 transition
- `scenes/theater_monitor.tscn` / `scenes/theater_map.tscn`：剧院地图与监控
- `scenes/integrated_sim.tscn`：集成 simulation（档案回放 + 实时推进 + 线索板）
- `scenes/puzzle_lab.tscn`：解谜实验室（8 种常规解谜，见 [docs/PUZZLE_LAB.md](docs/PUZZLE_LAB.md)）
- `scenes/state_graph_editor.tscn`：2D 状态图编辑器（状态切换 / 结局条件可拖拽编辑，见
  [docs/STATE_GRAPH_EDITOR.md](docs/STATE_GRAPH_EDITOR.md)）
- `scenes/demo_*.tscn`：TimeManager / TapeArchive / ClueManager 的模块 demo

## 测试

```sh
godot --headless --path . --script tests/run_all.gd
godot --headless --path . --script tests/smoke_test.gd
godot --headless --path . --script tests/test_game_root_smoke.gd
godot --headless --path . --script tests/test_integrated_sim.gd
godot --headless --path . --script tests/test_integrated_sim_live.gd
godot --headless --path . --script tests/test_puzzle_lab.gd
```

`tests/run_all.gd` 会自动发现 `tests/smoke_test.gd` 与 `tests/test_*.gd`，新增套件不用改它。
