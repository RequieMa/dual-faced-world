# Git 协作规范（dual-faced-world）

本规范面向人，也作为 `AGENTS.md` 的展开说明。目标是：`main` 永远可发布，`release` 永远可端到端测试，`develop` 永远可集成，所有改动可追溯。

## 1. 分支

| 分支 | 作用 | 允许的来源 | 合并去向 |
|---|---|---|---|
| `main` | 稳定发布线 | `release` | —（合并后打 tag） |
| `release` | 端到端测试版本 | `develop`、`hotfix-*` | `main` |
| `develop` | 集成分支 | `feature-*`、`release` 回合 | `release` |
| `feature-<slug>` | 单个功能/工单 | `develop` | `develop`（PR + 独立评审后自合并） |
| `hotfix-<slug>` | release 上的紧急修复 | `release` | `release`，再回合 `develop` |

```text
main       ●──────────────●────────────● (v0.1.0, v0.2.0)
            \            /            /
release      ●──●───────●────●───────●
              \        /      \     /
develop        ●──●──●─●──●────●───●
                \    /    \     /
feature-*        ●──●      ●───●
hotfix-*                         ● (从 release 切)
```

命名：小写 kebab-case，`feature-` / `hotfix-` 前缀，slug ≤ 40 字符，例如
`feature-tape-archive-ui`、`hotfix-save-corruption`。

## 2. 一个 feature 的标准流程

```sh
git fetch origin
git switch develop
git pull --ff-only
git switch -c feature-<slug>

# TDD：先写失败测试 → 实现 → 重构（细节见 AGENTS.md）

git add -A
git commit -m "feat: ..."
git push -u origin feature-<slug>
gh pr create --base develop --head feature-<slug>
```

要求：

1. **从 `develop` 切出**，不从 `main` 或别的 feature 切。
2. **先红后绿**：PR 里要有失败测试与通过测试的输出。
3. **独立 review**：由另一个 agent（新上下文）或人 review；reviewer 的「是否可合并」是合并门槛。
4. PR 描述使用 `.github/pull_request_template.md` 的清单。
5. **自合并**：CI 全绿 + reviewer 无阻塞项后，作者自己 squash 合并并删除分支；不再等人批准。

## 3. 评审

- Reviewer 只读，输出：阻塞项 / 建议项 / 测试可信度 / 是否可合并。
- 不再要求人工批准：reviewer 无阻塞项 + CI 全绿即可由作者合并（ruleset 的 approval 数为 0）。
- 作者与 reviewer 不能是同一个 agent 会话；有阻塞项时不得合并，修完复审一次。

## 4. Release 评估清单

`develop` 准备进 `release` 前逐项确认：

- [ ] 本轮计划的 feature 全部合并
- [ ] 全量测试通过（含 headless 冒烟）
- [ ] 无 P0/P1 未解决
- [ ] 资源清单 `manifests/asset_manifest.json` 与实际一致
- [ ] 发布说明 / 变更清单已写
- [ ] 版本号按 SemVer 确定（`vMAJOR.MINOR.PATCH`）

```sh
# 本地预检（不要直接 push 到 release）
git fetch origin
git log --oneline origin/release..origin/develop   # 本轮要进 release 的提交
```

然后由 release 负责人开 `develop → release` 的 PR，合并方式选 **Rebase and merge**（不删 `release`）。

> 仓库 ruleset `release-for-testing` 对 `main` / `develop` / `release` 启用了
> **required linear history**，因此禁止 merge commit；`git merge --no-ff` 会被拒绝。

## 5. Release 验证与发布

1. 在 `release` 上做端到端测试（编辑器/导出包/关键路径）。
2. 发现问题：从 `release` 切 `hotfix-<slug>`，修完 PR 回 `release`，再回合 `develop`。
3. 验证通过后由 release 负责人开 `release → main` 的 PR（**Rebase and merge**，不删 `release`）；合并后：

   ```sh
   git fetch origin
   git switch main
   git pull --ff-only
   git tag -a vX.Y.Z -m "vX.Y.Z"
   git push origin vX.Y.Z
   ```

4. 版本规则：新功能 → MINOR；修复 → PATCH；不兼容变更 → MAJOR（Godot 项目通常从 `v0.x.y` 起步）。

## 6. Commit 规范

Conventional Commits：

```text
feat: 新功能
fix: 修复
test: 测试
docs: 文档
refactor: 重构（不改行为）
chore: 构建/工具/依赖
```

subject 用祈使句、≤ 72 字符；body 说明“为什么”，不要只写“改了什么”。

## 7. 已启用的 Ruleset

仓库已启用 `release-for-testing`（active），覆盖 `refs/heads/main`、`develop`、`release`：

| 规则 | 值 |
|---|---|
| Pull request | 必须；**required approvals = 0**；不要求 Code Owner review |
| 线性历史 | 必须（禁止 merge commit） |
| 禁止删除分支 | 是 |
| 禁止 non-fast-forward | 是 |
| 允许的合并方式 | merge / squash / rebase（线性历史实际排除 merge commit） |
| 未归属提交 | 需额外 approval（`require_extra_approval_for_unattributed_changes`） |

配套：

- `.github/CODEOWNERS` 仅作路由；ruleset 的 `require_code_owner_review=false`，它不阻塞合并。
- Worker 提交使用已归属 GitHub 的 `RequieMa-Agent` 身份（`gh-agent` credential helper）。实测 PR #24–#33 由该身份提交并直接合并，未触发额外 approval；换成未归属身份时 ruleset 会要求额外 approval。
- **CI 不是 GitHub 强制项**：ruleset 未配置 required status checks，`headless` 绿只是流程要求。建议 admin 把 `headless` 加进 ruleset 的 required checks（Agent 账号 `admin=false`，改不了）。
- 仍建议 admin 把默认分支从 `main` 改为 `develop`（Agent 账号 `admin=false`，改不了）。

## 8. Super Agent 的硬约束

`AGENTS.md` 会被 Worker 会话读取，其中已写明：

- 必须从 `develop` 切 `feature-<slug>`；
- TDD 先红后绿；
- 自检后用独立 subagent 复审；
- 只提 PR 到 `develop`；CI 绿 + 独立评审无阻塞项后**自己 squash 合并**并删分支；
- release/hotfix 流程与 tag 规则；`develop→release` / `release→main` 由 release 负责人 rebase 合并，不删 `release`。

Super Agent 的 `prepare` 命令已改为 clone 仓库后 `checkout develop`，保证 Worker 起点正确。
