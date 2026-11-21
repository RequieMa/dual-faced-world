# AGENTS.md — dual-faced-world

本文件是仓库级 agent 契约。所有在 `dual-faced-world` 里工作的 agent（Super Agent executor、reviewer subagent、以及被委托的其它 agent）都必须遵守。

## 1. 分支模型（强制）

```text
main       ← 只接受 release 的合并；合并后打版本 tag
release    ← 端到端测试版本；只接受 develop 的合并（以及 release 上的 hotfix）
develop    ← 集成分支；只接受 feature-* 的 PR
feature-*  ← 从 develop 切出，完成后 PR 回 develop
hotfix-*   ← 从 release 切出，修完 PR 回 release，再回合 develop
```

- 禁止直接 push 到 `main` / `develop` / `release`。
- 禁止 force push 到任何共享分支。
- **PR 由作者自己合并**：CI 全绿 + 独立评审无阻塞项即可 squash 合并，不再等人批准（规则集已把 required review 设为 0）。
- 共享分支启用了 required linear history：PR 用 Squash / Rebase 合并，禁止 merge commit。

## 2. 接单流程（每一步都必须做）

0. 同步基线：

   ```sh
   git fetch origin
   git switch develop
   git pull --ff-only
   ```

1. 从 `develop` 切分支：

   ```sh
   git switch -c feature-<slug>
   ```

   `slug` 用工单短名（`DSH_SUPERAGENT_NAME`），kebab-case、小写、≤ 40 字符。
   例：`DSH_SUPERAGENT_NAME=demo-tape-ui` → `feature-demo-tape-ui`。

2. **先写测试（红）**：新增/修改失败测试，运行并确认失败原因正确。
3. **实现（绿）**：最小改动让测试通过。
4. **重构**：测试保持绿的前提下清理。
5. **自检**：跑完整测试、检查 `git diff develop...HEAD`、确认没有调试残留/密钥/大文件。
6. **独立评审**：用 `subagent` 工具新开一个 reviewer（不复用你的上下文），交给它：
   - `git diff develop...HEAD`
   - 测试命令与红/绿两次输出
   - 工单目标与验收标准
   要求它逐条列出阻塞问题；修完后让它复审一次。
7. **提交**：Conventional Commits（`feat:` / `fix:` / `test:` / `docs:` / `refactor:` / `chore:`）。
8. **推送**：`git push -u origin feature-<slug>`
9. **开 PR**：`gh pr create --base develop --head feature-<slug>`。
   描述必须包含：工单链接、TDD 证据（红/绿命令与结果）、自检、reviewer 结论、风险。
10. **合并**：等 CI 全绿、reviewer 明确「可合并」后由作者自己合并：

    ```sh
    gh pr merge <n> --squash --delete-branch
    ```

    合并后关掉对应 issue（PR 未写 `closes #N` 时手动 `gh issue close`）。CI 红或有阻塞项时不得合并。

## 3. TDD 与测试

- 行为变更必须有测试；纯文档/配置变更可免，但要在 PR 里说明原因。
- 顺序必须“先红后绿”；PR 里贴失败与通过两次输出。
- 测试命令（`project.godot` 就绪后）：

  ```sh
  godot --headless --path . --script tests/smoke_test.gd
  ```

- `project.godot` 与 `tests/smoke_test.gd` 已就位；新增系统/场景时先补对应测试，再实现。
- 不得为了通过而删除/跳过测试；不得改 `.gitignore` 排除测试。
- 不在 shell 里直接跑 Godot 做长时交互（文件沙箱会拦 `user://`）；优先用 `godot_run_headless` / `godot_run_project`。

## 4. 评审 agent 的职责

- 只读，不改代码。
- 输出四段：**阻塞项 / 建议项 / 测试是否可信 / 是否可合并**。
- 「是否可合并」是合并门槛：有阻塞项时作者不得合并；修完需复审一次。
- 重点检查：需求覆盖、边界条件、测试是否真的会失败、是否有隐藏行为变更、Godot 4.x 兼容性、是否夹带大文件。

## 5. Release 与 Hotfix

`develop → release` 必须同时满足：

- 计划内的 feature 全部合并；
- 全量测试通过；
- 无 P0/P1 未解决；
- 有发布说明 / 变更清单；
- 由 release 负责人（人或被指派的 release agent）发起 PR。

`release` 出问题：

```sh
git switch -c hotfix-<slug> release
# 修复 + 测试
git push -u origin hotfix-<slug>
gh pr create --base release --head hotfix-<slug>
```

hotfix 合并进 `release` 后，必须把 `release` 回合 `develop`（PR 或 fast-forward，取决于保护规则）。

`release` 验证通过：

1. 发 `release → main` 的 PR；
2. 合并后在 `main` 打 tag：`git tag -a vX.Y.Z -m "..." && git push origin vX.Y.Z`；
3. tag 只打在 `main` 上；hotfix 发布用 patch 版本。

## 6. 禁止事项

- 直接 push `main` / `develop` / `release`
- 在 feature 分支上顺手改无关模块
- 提交 `external-assets/` 内容、`.godot/`、`autoload/`、密钥
- 用 `--no-verify` 跳过 hooks
- 把 stateDir、日志、截图提交进仓库
- 在 CI 未绿或 reviewer 仍有阻塞项时合并 PR
