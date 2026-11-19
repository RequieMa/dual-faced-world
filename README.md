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

- `scenes/main.tscn`：基线入口（占位）
- `scenes/monitor_grid_demo.tscn`：监控墙 4 路放大 transition
- `scenes/theater_monitor.tscn` / `scenes/theater_map.tscn`：剧院地图与监控
- `scenes/integrated_sim.tscn`：集成 simulation（档案回放 + 实时推进 + 线索板）
- `scenes/puzzle_lab.tscn`：解谜实验室（8 种常规解谜，见 [docs/PUZZLE_LAB.md](docs/PUZZLE_LAB.md)）
- `scenes/demo_*.tscn`：TimeManager / TapeArchive / ClueManager 的模块 demo
