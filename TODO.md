# TODO

## 触发通道

- [ ] **Windows 部署 Super Agent 微信 Source（强制绑定 Windows）**
  - 依赖：Windows 桌面会话 + 已登录微信客户端 + `wxauto-bridge` sidecar（**不在 npm 包内**，需按插件的 sidecar 契约部署）
  - 建议与 macOS 这套完全隔离：独立 DSH 安装 / profile / `stateDir`，不复用同一个 bot 或同一个状态库
  - 配置：`baseUrl=http://127.0.0.1:8787`、`tokenFile`（0600）、`selfWxid`、`rooms`；`atOnly=true`
  - Policy：微信允许名单只放本人 wxid；先 `observe`，确认 decision 正常后再 `auto`
  - 风险：微信 UI 自动化非腾讯官方授权，存在封号风险；bridge 必须常驻在已登录的桌面会话
  - 备注：跨机时 Mac 侧可用 `ssh -N -L 8787:127.0.0.1:8787 user@win` 隧道；面板里的 `bridgeTask/bridgeLauncher` 只适用于本机 Windows

- [ ] **macOS 飞书 Source（进行中）**
  - [x] 安装 `lark-cli` 1.0.100 + skills
  - [ ] 创建飞书企业自建应用，开启机器人能力
  - [ ] 开通权限：`im:message.group_at_msg:readonly`、`im:message.p2p_msg:readonly`、`im:message:readonly`、`im:message:send_as_bot`、`im:chat:read`、`im:chat.members:read`
  - [ ] 事件订阅：使用长连接接收 `im.message.receive_v1`，并发布应用版本
  - [ ] 配置 `~/.lark-cli-dsh-superagent`（strict mode = bot），生成 `~/.local/bin/lark-bot`
  - [ ] 面板 Feishu Source 填 `lark-bot` 绝对路径，保存时校验应用/机器人
  - [ ] Policy 飞书允许名单填本人 `open_id`（`ou_…`）
  - [ ] 群里 `@机器人` 验证 observe；确认后切 `auto`

- [ ] （可选）微信前端 relay：`dsh-wechat` 扫码登录 → 微信消息转成 GitHub Issue（作者 RequieMa）→ 现有 GitHub Source 接单
  - 需要 Issue-only fine-grained token，避免把 owner 权限交给前端 agent

## 工程

- [ ] `integrated_sim` Phase 1（已提 Issue，等待 Super Agent 接单/执行）
- [ ] Phase 1 完成后评估 → `release`；通过端到端测试后 `release → main` 并打 `v0.1.0`
- [ ] 评估是否把 `godot-bridge` 的 `godot_*` 工具稳定用于 Worker preset（首个真实工单验证）
