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

- [x] `integrated_sim` Phase 1（Issue #3：只读回放，`scenes/integrated_sim.tscn`）
- [x] `integrated_sim` Phase 2（Issue #6：实时推进、道具拖拽、live 因果链）
- [x] 解谜实验室 demo（`scenes/puzzle_lab.tscn`：8 种常规解谜类型，程序化占位美术）
- [x] W0–W12 机制落地（契约 / 摄像头过载 / 引导 NPC / 两类对话 / 双画风 / 敌人危险 / 循环存档 / 潜行 / 亲身段落 / 集成装配）
  - 契约：`docs/MECHANICS_CONTRACTS.md`；装配：`docs/MECHANICS_GAMEPLAY.md`；场景：`scenes/game_root.tscn`
- [x] 设计拍板对齐（Issue #20）：玩法改为「回放」、二段跳默认关、烧毁不恢复 —— 见 `docs/DESIGN_DECISIONS.md`
  - 数值：摄像头 `dwell` / `cooldown` 已走 `resources/data/surveillance.json`；交互半径、拖拽拾取半径仍是代码常量（后续可抽，见下）
- [x] 玩法层输入 + 关卡数据：`GameRoot` 支持键盘操作（1–4 机位 / `F` `G` `O` 提示 / `I` 灯 / `H` 门 /
  `Space` 对话 / `T` 录像带面板），关卡走 `resources/data/levels/theater.json`
- [ ] 玩法闭环（目标/胜负）：把「回放查线索 → 监控引导 → 过载代价 → 重开一轮」接成完整流程
  - 磁带拾取（场景里发现磁带 → TapeArchive.discover）
  - 关卡目标与失败条件（例如：在第 N 轮内保住某个 NPC / 阻止舞台起火）
  - 多轮目标推进与结局判定
- [ ] 按 `docs/PUZZLE_LAB.md` 的清单把占位美术换成 CC0 素材（UI / 图标 / 音效 / 家具 / 字体）
- [ ] 把交互半径 / 拖拽拾取半径等常量抽到数据文件（等真机试玩后再调）
- [ ] 评估 `develop → release`；通过端到端测试后 `release → main` 并打 `v0.1.0`
- [ ] 评估是否把 `godot-bridge` 的 `godot_*` 工具稳定用于 Worker preset（首个真实工单验证）
