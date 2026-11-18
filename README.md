# 二面世界 / Dual-Faced World

Godot 4 项目。大体积资源位于 external-assets/，通过百度网盘同步，不进 Git。

## 开发流程

分支模型、TDD、独立评审、release/hotfix 与版本 tag 见
[docs/GIT_WORKFLOW.md](docs/GIT_WORKFLOW.md)；agent 的强制契约见
[AGENTS.md](AGENTS.md)。

- `main`：稳定发布线，合并后打 `vX.Y.Z` tag
- `release`：端到端测试版本
- `develop`：集成分支
- `feature-*` / `hotfix-*`：短生命周期分支
