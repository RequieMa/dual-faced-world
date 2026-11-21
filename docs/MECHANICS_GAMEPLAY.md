# 集成装配（W12）：GameRoot 与端到端 smoke

本篇记录 [Issue #19](https://github.com/RequieMa/dual-faced-world/issues/19) 的装配结果：
把 W1–W8 的系统接进一个可运行场景，并用 headless smoke 固定「进场 → 摄像头 → 引导 →
过载 → 循环重开」这条主链。

## 0. 设计决定（2026-11-21，#20）

owner 已拍板：玩法是**回放**（线索在录像带里），不是时间回溯；二段跳不保留；烧毁摄像头不恢复；
数值用可配置 JSON。完整记录与影响见 [DESIGN_DECISIONS.md](DESIGN_DECISIONS.md)。
本场景的实现按这套决定对齐：`LoopManager` 只做轮次/重开，`PlayerController.action_enabled` 默认关闭。

## 1. 入口与运行

`scenes/main.tscn` 现在实例化 `scenes/game_root.tscn`，所以 `scenes/main.tscn` 仍是唯一入口：

```sh
godot --path .
# 或指定场景
godot --path . scenes/main.tscn
```

`scenes/game_root.tscn` 只放「内容」（World 子树：地面、灯、相机、NPC、指示灯、门、扬声器），
系统由根脚本 `scripts/game_root.gd` 在 `_ready()` 里 `new()` 出来并接线，不新增 autoload。

### 1.1 操作（键盘，运行时注册，不写 `project.godot`）

| 键 | 作用 |
|---|---|
| `1`–`4` | 切换关卡机位（`theater.json` 的 cameras 顺序：C1–C4） |
| `0` | 离开当前机位（进入冷却） |
| `F` / `G` / `O` | 对当前提示对象发「跟我来 / 等待 / 开门」 |
| `Tab` | 切换提示对象（npc_imaginary ↔ npc_real） |
| `I` | 开/关指示灯 `light_a` |
| `H` | 打开门 `door_a` |
| `Space` | 推进对话（没有进行中的对话时无效） |
| `T` | 开/关录像带检查面板 |
| `←` / `→` | 面板内切带 |
| `↑` / `↓` | 面板内快进 / 快退 10 秒 |
| `Esc` | 关面板；没有面板时离开机位 |
| `R` | 失败后重试本轮；通关后重玩 demo |

### 1.2 可玩 demo（序章，3 轮）

`scenes/main.tscn` 启动即进入 demo（`auto_tick == true` 时 `_ready` 自动 `start_demo()`）：

- **目标**：每轮 60 秒内按 `F` 让 npc_imaginary 跟随并走到门口（route 终点）；到达即本轮成功；
- **3 轮**；每轮得分 = `100 + 剩余秒数`；烧毁摄像头每台 `−30`（烧毁永久，M16）；
- **失败**：超时 → 本轮失败，按 `R` 重试同一轮；**通关**：3 轮完成，按 `R` 重玩；
- 每轮开始自动解锁一盘磁带给录像带面板（demo 的简化线索获取，正式版应改为场景拾取）；
- 验收：`tests/test_prologue_demo.gd`（31 条断言：通关、超时重试、烧毁扣分、HUD、磁带解锁）。

这是验证「目标 / 计时 / 失败 / 重开」骨架的可玩 demo；敌人、危险、剧情化目标还没接。
`auto_tick == false`（headless 测试）时不会自动开局，测试用 `start_demo()` 显式驱动。

录像带面板只显示已发现的带（默认库 `known_to_player=false`）：demo 每轮自动解锁一盘；
手动验证时也可用 `TapeArchive.discover(tape_id)` 先发现 2–3 盘，再按 `T` / `←→` / `↑↓` 验证。
面板打开时只响应录像带相关按键（`T` / `←→` / `↑↓` / `Esc`），避免后台误切机位。
`Space` 与 W8 的 `player_jump` 同为空格，但 W8 未接进本场景（跳跃默认关闭），未来同场时需定优先级。

```text
Main (scenes/main.tscn)
└── GameRoot (scenes/game_root.tscn, scripts/game_root.gd)
    ├── CameraSession      W1 摄像头停留 / 过载 / 冷却 / 烧毁
    ├── GuideBus           W2 提示 / 指示灯 / 开门（目标注册表）
    ├── LoopManager        W6 一轮起止 / 回退 / 世界复位
    ├── DialogueController W3 两类对话框（UI 代码内构建）
    ├── StyleController    W4 钢笔 / 铅笔两层画风
    └── World              场景内容，GameRoot 按 get_target_id() 注册到 GuideBus
        ├── NpcReal / NpcImaginary  W2 可响应 NPC
        ├── Indicator                W2 指示灯
        ├── Door                     W2 可开门
        └── Speaker                  W2 扬声器（订阅 hint_sent）
```

## 2. 接线与公开 API

`GameRoot` 是宿主门面，内部仍遵守各模块在 `docs/MECHANICS_CONTRACTS.md` 里的契约：

| API | 说明 |
|---|---|
| `switch_camera(id) -> bool` / `leave_camera()` | 转发 `CameraSession.enter/leave` |
| `tick(delta)` | 推进摄像头计时与场景里可 `tick` 的 NPC；真实游玩时由 `_process` 调用 |
| `send_hint(id, text)` / `set_indicator(id, on)` / `open_door(id)` | 转发 `GuideBus` |
| `start_dialogue(id, group_override = "")` | 转发 `DialogueController.start` |
| `apply_style(group, enabled)` | 转发 `StyleController.apply_style` |
| `start_round()` / `end_round(summary) -> bool` / `restart_round(time = 0.0)` | 转发 `LoopManager`，并维护「当前是否有一轮进行中」 |
| `reset_for_loop(time)` | `LoopManager` 参与者协议：复位摄像头焦点/冷却、NPC、指示灯 |
| `get_state()` | 聚合 camera / guide / loop / dialogue / style / round_active |

信号：`camera_overloaded`、`hint_sent`、`round_started`、`round_ended`、`definition_error`。
装配/数据错误同时写 `last_errors` 并发 `definition_error`，不抛错。

### 计时与可复现性

所有计时都由 `tick(delta)` 推进。`auto_tick` 默认开启（`_process` 里 tick，单帧 delta 限步到 0.1s，
避免切窗/卡顿一帧烧毁机位）；headless 测试把它关掉、用固定步长调用 `tick()`，不依赖真实帧率。
`auto_tick` 只在 `_ready()` 读取，测试/宿主需要在 `add_child()` 之前设置。

### 轮次与重开语义（回放）

`restart_round()` = 结束当前轮（若有）→ `rewind_to(time, [GameRoot])` → `start_round()`：

- 这里的「rewind」是**回到录像带内的某一刻重开一轮**（设计决定 #20：玩法是回放，不是时间回溯）；
- 摄像头：清空当前机位与冷却；**烧毁机位保持烧毁**（M16 已拍板：永久不恢复）；
- NPC：用进入场景时的 `to_dict()` 快照复位（状态 / 位置 / 路线）；
- 指示灯：复位到进入场景时的开关状态；
- 门：`GuideableDoor` 没有 `close()`，开门状态不参与循环复位。

## 3. 数据来源

- 摄像头计时：`resources/data/surveillance.json`（经 `CameraConfig` + `ConfigLoader`）；
- 关卡：`resources/data/levels/theater.json`（房间 / 机位，经 `level.schema.json` 校验；
  加载失败时回落到默认机位并记录 `last_errors`）；装配期会拿 `level.cameras` 与
  `surveillance.json` 做双向差集，不一致时 `push_warning` 并记入 `get_level_state().camera_mismatches`
  （计时以 `surveillance.json` 为准）；
- 对话：`resources/data/dialogues.json`；
- 录像带：`TapeArchive` autoload 的默认磁带库（`resources/tapes/*.tres`），面板只读展示事件与线索；
- 场景内容与 NPC 路线：直接写在 `scenes/game_root.tscn`。

## 4. 端到端 smoke

```sh
godot --headless --path . --script tests/test_game_root_smoke.gd
godot --headless --path . --script tests/test_game_root_input.gd   # 输入 + 关卡数据
godot --headless --path . --script tests/run_all.gd                # 全套回归
```

`tests/test_game_root_smoke.gd` 覆盖：场景/脚本存在、主入口装配 GameRoot、五个系统已实例化、
World 目标已注册、摄像头切换与过载烧毁、hint/灯/门、一轮起止与循环重开、
重开后世界复位（烧毁机位保留）、对话两行播放、画风开关、聚合状态。

`tests/test_game_root_input.gd` 覆盖：关卡数据 schema 校验、`get_level_state`、输入动作注册/清理、
`handle_action` 的切机位/提示/灯/门/对话/录像带面板（开关、切带、快进快退）。

## 5. 已知限制

- 玩法闭环还差「目标与胜负」：输入已接（切机位 / 提示 / 灯 / 门 / 对话 / 录像带检查），
  但还没有「查录像 → 引导朋友 → 过载拖住敌人 → 重开」的完整关卡流程与失败条件。
- 录像带面板只读展示 `TapeArchive` 的事件与 `ClueManager` 的线索，不改变线索状态；
  磁带库目前全部是默认库（`resources/tapes/*.tres`），还没有「在场景里拾取磁带」的交互。
- 摄像头**画面**仍由现有监控墙负责；GameRoot 只装配会话状态，不复制监控 UI。
- 双画风目前只覆盖 World 里按 `real` / `imaginary` 打组的 NPC 网格（由 GameRoot 绑定 World 时补齐）；
  地面/门框等占位几何未打组，开关画风不会改变它们。
- `World` 节点缺失时只记录 `last_errors` / 发 `definition_error`，不中止启动（引导目标为空）。
- W5 危险效果 / 盲区、W7 潜行、W8 亲身段落未接进本场景：它们的触发位置/输入需要先有
  关卡数据（`resources/data/levels/*.json`）和玩法层输入接线，超出本 issue 的验收范围。
- 终章动作段（M15，二段跳）**不保留**（设计决定 #20）：`PlayerController.action_enabled` 默认 `false`，
  `JumpSection` 仅作为可选项保留，不接任何关卡。
- 场景内的占位几何用于验证装配，不是最终美术。
