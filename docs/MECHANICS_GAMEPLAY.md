# 集成装配（W12）：GameRoot 与端到端 smoke

本篇记录 [Issue #19](https://github.com/RequieMa/dual-faced-world/issues/19) 的装配结果：
把 W1–W8 的系统接进一个可运行场景，并用 headless smoke 固定「进场 → 摄像头 → 引导 →
过载 → 循环重开」这条主链。

## 1. 入口与运行

`scenes/main.tscn` 现在实例化 `scenes/game_root.tscn`，所以 `scenes/main.tscn` 仍是唯一入口：

```sh
godot --path .
# 或指定场景
godot --path . scenes/main.tscn
```

`scenes/game_root.tscn` 只放「内容」（World 子树：地面、灯、相机、NPC、指示灯、门、扬声器），
系统由根脚本 `scripts/game_root.gd` 在 `_ready()` 里 `new()` 出来并接线，不新增 autoload。

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

所有计时都由 `tick(delta)` 推进。`auto_tick` 默认开启（`_process` 里 tick），
headless 测试把它关掉、用固定步长调用 `tick()`，不依赖真实帧率。

### 循环重开语义

`restart_round()` = 结束当前轮（若有）→ `rewind_to(time, [GameRoot])` → `start_round()`：

- 摄像头：清空当前机位与冷却；**烧毁机位保持烧毁**（M16 未拍板前的契约默认）；
- NPC：用进入场景时的 `to_dict()` 快照复位（状态 / 位置 / 路线）；
- 指示灯：复位到进入场景时的开关状态；
- 门：`GuideableDoor` 没有 `close()`，开门状态不参与循环复位。

## 3. 数据来源

- 摄像头计时：`resources/data/surveillance.json`（经 `CameraConfig` + `ConfigLoader`）；
- 对话：`resources/data/dialogues.json`；
- 场景内容与 NPC 路线：直接写在 `scenes/game_root.tscn`（本 issue 不新增 data 文件）。

## 4. 端到端 smoke

```sh
godot --headless --path . --script tests/test_game_root_smoke.gd
godot --headless --path . --script tests/run_all.gd   # 全套回归
```

`tests/test_game_root_smoke.gd` 覆盖：场景/脚本存在、主入口装配 GameRoot、五个系统已实例化、
World 目标已注册、摄像头切换与过载烧毁、hint/灯/门、一轮起止与循环重开、
重开后世界复位（烧毁机位保留）、对话两行播放、画风开关、聚合状态。

## 5. 已知限制

- 本 issue 的验收由 headless smoke 驱动：场景已装配并可运行，但还没接玩家输入
  （切机位 / 发 hint / 开关门等由后续玩法层接线），当前用于观察装配结果与跑自动化。
- 摄像头**画面**仍由现有监控墙负责；GameRoot 只装配会话状态，不复制监控 UI。
- W5 危险效果 / 盲区、W7 潜行、W8 亲身段落未接进本场景：它们的触发位置/输入需要先有
  关卡数据（`resources/data/levels/*.json`）和设计拍板（M16 等），超出本 issue 的验收范围。
- 场景内的占位几何用于验证装配，不是最终美术。
