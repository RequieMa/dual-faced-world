## 工单 / 背景

<!-- 关联 Issue / 工单链接，说明为什么要做 -->

## 改动

<!-- 一句话说明改了什么；列出关键文件 -->

## TDD 证据

- 红（先失败的测试）：
  ```text
  <命令与失败输出摘要>
  ```
- 绿（实现后通过）：
  ```text
  <命令与通过输出摘要>
  ```

> 无行为变更（纯文档/配置）时说明原因：____

## 自检

- [ ] 从 `develop` 切出的 `feature-*` 分支
- [ ] 全量测试通过（或注明“未验证”及原因）
- [ ] `git diff develop...HEAD` 自查过，无无关改动
- [ ] 无调试残留、密钥、`external-assets/` 内容、`.godot/`
- [ ] Conventional Commits

## 独立评审

- Reviewer（agent / 人）：
- 结论：阻塞项 / 建议项 / 测试可信度 / 是否可合并

## 风险与回滚

<!-- 可能的回归点；如何回滚 -->

## 合并要求

- [ ] 目标分支正确：`feature-*`/`hotfix-*` → `develop`/`release`；`develop` → `release`；`release` → `main`
- [ ] CI 全绿、reviewer 结论为「可合并」，结论原文已贴到 PR 评论
- [ ] `feature-*` / `hotfix-*`：作者 squash 合并并删除分支
- [ ] `develop→release` / `release→main`：release 负责人 rebase 合并，不删 `release`
