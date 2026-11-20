# 机制接口契约（W0）

本文件是 [#10](https://github.com/RequieMa/dual-faced-world/issues/10) 的产物：把 10 个并行开发流
（[#21](https://github.com/RequieMa/dual-faced-world/issues/21) 总表）之间的接口先冻结，各流按本文件编码，
互不依赖对方的实现。

**改契约的流程**：单独 PR 改本文件 → 在总表 issue 里 @ 受影响的流 → 各流对齐后再改实现。不要偷偷改签名。

## 0. 通用约定

| 约定 | 说明 |
|---|---|
| 依赖注入 | 系统都是普通 `Node` / `RefCounted`，由宿主（W12 的 `GameRoot`）`new()` 出来并接线；**不要新增 autoload** |
| 时间 | 所有时长单位为秒（`float`）；`tick(delta)` 由宿主每帧调用，模块内部不用 `_process` |
| 坐标 | 沿用 Godot 约定（+X 东、+Z 南、+Y 上），地图 1 单位 = 1 米 |
| 失败语义 | 查询类返回 `bool`/空集合；状态变化用信号广播；配置错误写 `last_errors` 并 `push_warning`，不崩溃 |
| 序列化 | 需要进存档/循环重置的模块提供 `to_dict() -> Dictionary` 与 `from_dict(data) -> void` |
| 测试 | 新测试只 `new()` 本模块，不依赖 autoload，不依赖真实帧率（用 `tick(0.1)` 序列复现） |
| 命名 | 文件 `snake_case.gd`；信号用过去式（`overload_started`）；私有成员 `_` 前缀 |

## 1. CameraSession（W1 实现）

- 文件：`scripts/camera/camera_session.gd`（`extends Node`）
- 职责：摄像头停留计时、过载、冷却、烧毁；**不做画面**（画面仍由现有 MonitorGrid/相机负责）。

```gdscript
# 配置来自 resources/data/surveillance.json（见 §9）
func configure(config: Dictionary) -> void   # { "cameras": { "C1": {"dwell": 6.0, "cooldown": 4.0} } }
func enter(camera_id: String) -> bool        # 冷却中/已烧毁/未知机位 -> false
func leave(camera_id: String) -> void        # 记录冷却；未进入时调用无副作用
func tick(delta: float) -> void              # 推进停留/冷却计时
func get_state() -> Dictionary               # {"current", "remain", "cooldowns": {id: remain}, "burned": [ids]}
func is_burned(camera_id: String) -> bool
func to_dict() -> Dictionary
func from_dict(data: Dictionary) -> void

signal overload_started(camera_id: String)   # 停留超时
signal overload_finished(camera_id: String)  # 过载结束（烧毁/恢复策略见设计题 M16）
signal burned(camera_id: String)             # 该机位永久失效（默认策略）
signal cooldown_changed(camera_id: String, remain: float)
```

错误语义：`enter` 在冷却中返回 `false` 并 `push_warning`（不换当前机位）；已烧毁返回 `false`；
`configure` 缺省某机位时用默认值（`push_warning`），不阻止启动。

## 2. GuideBus / GuideableNpc（W2 实现）

- 文件：`scripts/guide/guide_bus.gd`、`scripts/guide/guideable_npc.gd`、`speaker_beacon.gd`、`indicator_light.gd`、`guideable_door.gd`
- 职责：玩家 → 世界 的三种引导动作；NPC 侧响应。

```gdscript
# GuideBus（Node）
func send_hint(target_id: String, text: String) -> bool
func set_indicator(id: String, on: bool) -> bool
func open_door(id: String) -> bool
func get_state() -> Dictionary

signal hint_sent(target_id: String, text: String)
signal indicator_changed(id: String, on: bool)
signal door_opened(id: String)

# GuideableNpc（Node，挂到 agent 上）
enum State { IDLE, WAIT, FOLLOW, OPEN_DOOR }
func setup(npc_id: String, group: String) -> void   # group: real / imaginary
func on_hint(text: String) -> bool                 # 未知提示返回 false
func tick(delta: float) -> void
func get_state() -> Dictionary
func to_dict() -> Dictionary
func from_dict(data: Dictionary) -> void

signal arrived(npc_id: String)
signal needs_hint(npc_id: String, hint: String)
```

错误语义：目标 id 不存在返回 `false` + `push_warning`；重复开灯/开门幂等（状态不变、不重复发信号）。

## 3. LoopManager（W6 实现）

- 文件：`scripts/loop/loop_manager.gd`、`scripts/loop/loop_state.gd`
- 职责：一轮的起止、回退到某时刻、世界重置、玩家知识保留；**不预置剧情理由**（见设计题 M12/M13）。

```gdscript
func start_round() -> void
func end_round(summary: Dictionary) -> void
func rewind_to(time: float) -> bool
func reset_world(participants: Array) -> void   # 逐个调用 participant.reset_for_loop(snapshot)
func get_round_index() -> int
func get_history() -> Array                     # 每轮 summary
func to_dict() -> Dictionary
func from_dict(data: Dictionary) -> void

signal round_started(round_index: int)
signal round_ended(round_index: int, summary: Dictionary)
signal world_reset()
```

参与者协议（鸭子类型，不新增基类）：`func reset_for_loop(state: Dictionary) -> void`。

语义：
- `start_round` 使轮次 +1 并广播（首轮从 1 开始）；
- `rewind_to(t)` 重置世界后把时间基准设为 t（由宿主把 t 交给 TimeManager），返回是否成功；
- **知识保留**：`ClueManager` 里的 timeline 线索不清空（只读消费）。
- M16 拍板前：烧毁的机位在 `rewind_to` 后**默认保持烧毁**（由参与者自己决定，LoopManager 不强制）。

## 4. PersonGroup（W2 实现，W3/W6 消费）

- 文件：`scripts/person/person_group.gd`（`extends Node`，挂到 agent / 对话对象上）
- 职责：区分「真实的人」与「幻想中的朋友」，供对话样式、画风、重置规则消费。

```gdscript
const REAL := "real"
const IMAGINARY := "imaginary"

func setup(group: String) -> void   # 非法值 -> push_warning 并回落到 REAL
func get_group() -> String
func is_real() -> bool
func to_dict() -> Dictionary
func from_dict(data: Dictionary) -> void
```

## 5. DialogueController（W3 实现）

- 文件：`scripts/dialogue/dialogue_controller.gd`、`scripts/dialogue/dialogue_theme.gd`
- 数据：`resources/data/dialogues.json`（schema 见 §9）

```gdscript
func load_defs(path: String) -> bool
func start(dialogue_id: String, group: String) -> bool   # group 决定主题；未知 id -> false
func advance() -> void
func is_active() -> bool
func get_state() -> Dictionary

signal line_shown(line: Dictionary)   # {"speaker", "text", "group"}
signal finished(dialogue_id: String)
```

错误语义：`load_defs` 失败返回 `false`（不抛错）；`start` 未知 id 返回 `false` 且不发 `line_shown`。

## 6. ConfigLoader（W0 已实现）

- 文件：`scripts/config/config_loader.gd`（`extends RefCounted`）

```gdscript
signal definition_error(message: String)
var last_errors: Array[String]

func load_json(path: String, schema_path: String = "") -> Dictionary
func validate(data: Variant, schema: Dictionary) -> Array
```

规则：失败返回 `{}` 且 `last_errors` 非空；成功清空 `last_errors`；schema 子集见 §9。

## 7. SaveService（W6 实现）

- 文件：`scripts/save/save_service.gd`

```gdscript
const VERSION := 1
func snapshot(managers: Dictionary) -> Dictionary     # {version, created_at, data:{...}}
func restore(path: String) -> Dictionary              # 失败返回 {} 并 push_warning
func save(path: String, snapshot: Dictionary) -> bool
func load(path: String) -> Dictionary
```

错误语义：版本不符/坏 JSON → 返回 `{}` + `push_warning`，不崩溃、不覆盖旧档。

## 8. VisionCone（W5 实现，W7 消费）/ StyleController（W4 实现，W12 消费）

```gdscript
# VisionCone（Node）
func setup(origin_getter: Callable, direction_getter: Callable, half_angle_deg: float, range_m: float) -> void
func sees(point: Vector3) -> bool
func get_debug_state() -> Dictionary

# StyleController（Node）
func apply_style(group: String, enabled: bool) -> bool   # group: real / imaginary
func set_param(name: String, value: float) -> bool
func get_state() -> Dictionary
```

`sees` 必须是纯函数（给定原点/朝向/点即可判定，不依赖帧），便于 W7 用假数据单测。

## 9. 数据文件与 schema

| 文件 | 归属 | schema | 说明 |
|---|---|---|---|
| `resources/data/surveillance.json` | W1 | `schema/surveillance.schema.json` | 机位 → `dwell` / `cooldown`（秒） |
| `resources/data/dialogues.json` | W3 | `schema/dialogues.schema.json` | `dialogues[]` → `{id, group, lines[]}` |
| `resources/data/levels/*.json` | W9/W12 | `schema/level.schema.json` | 关卡最小结构（房间 + 机位） |

schema 子集（`ConfigLoader` 支持）：`type`（object/array/string/number/integer/boolean/any）、
`required`、`properties`、`additional_properties`、`items`、`enum`、`min`、`max`。未知关键字忽略。

## 10. 并行开发约束（重申）

- 每个流只在自己的 glob 内新增文件（见各 issue）；**共享文件只归 W12**（`scenes/main.tscn`、`project.godot`、`README.md`、docs 索引）。
- **只读**：`scripts/sim/*`、`monitor_grid*.gd`、`integrated_sim.gd`、`puzzle_lab.gd`/`scripts/puzzles/*`、`time_manager.gd`、`clue_manager.gd`、`tape_*`、`theater_*.gd`、现有测试与场景。
- 新增输入动作一律用运行时 `InputMap.add_action`，不改 `project.godot`。
- 测试入口统一 `tests/run_all.gd`（新增套件要加进去）。
