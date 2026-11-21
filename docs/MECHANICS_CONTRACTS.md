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
| 失败语义 | 配置错误写 `last_errors` 并发 `definition_error` 信号（是否 `push_warning`/记日志由调用方决定，测试里不污染 stderr）；运行时非法调用返回 `false` 并 `push_warning` |
| 序列化 | 需要进存档/循环重置的模块提供 `to_dict() -> Dictionary` 与 `from_dict(data) -> void`；`from_dict` 缺失字段保持默认值、类型不符忽略该字段并 `push_warning`，不抛错 |
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
signal overload_finished(camera_id: String)  # 过载结束（M16 已拍板：烧毁永久，不恢复）
signal burned(camera_id: String)             # 该机位永久失效（设计决定 #20）
signal cooldown_changed(camera_id: String, remain: float)
```

错误语义：

- 同机位重复 `enter`：返回 `true`，不重置停留计时（`remain` 保持不变），不发信号。
- 从机位 A 直接 `enter` 机位 B：先按 `leave(A)` 的规则让 A 进入冷却（`cooldown > 0` 时发一次
  `cooldown_changed(A, cooldown)`），再进入 B。
- 冷却中 / 已烧毁 / 未知机位：返回 `false`；不换当前机位、不改变任何状态，**不发信号**
  （避免宿主在 `cooldown_changed` 等回调里重试 `enter` 造成递归）。
- `configure` 缺省某机位时用**代码默认值**（`dwell = 6.0`、`cooldown = 4.0`，W1 定义为常量并在这里登记），
  并 `push_warning`，不阻止启动。`surveillance.json` 的键是机位 id 的**权威计时来源**；
  `level.cameras[]` 只描述场景摆放，W12 交叉校验，不一致时以 `surveillance.json` 为准并警告。

## 2. GuideBus / GuideableNpc（W2 实现）

- 文件（都在 `scripts/guide/`）：`guide_bus.gd`、`guideable_npc.gd`、`speaker_beacon.gd`、`indicator_light.gd`、`guideable_door.gd`
- 职责：玩家 → 世界 的三种引导动作；NPC 侧响应。GuideBus 是目标注册表：场景把 NPC/灯/门的节点
  注册进来（`register_target`），`send_hint` 等按 id 解析到具体节点。

```gdscript
# GuideBus（Node）
func register_target(target_id: String, node: Node) -> bool   # 重复 id 返回 false
func unregister_target(target_id: String) -> void
func get_targets() -> Array                                   # 已注册 id
func send_hint(target_id: String, text: String) -> bool
func set_indicator(id: String, on: bool) -> bool
func open_door(id: String) -> bool
func get_state() -> Dictionary

signal hint_sent(target_id: String, text: String)
signal indicator_changed(id: String, on: bool)
signal door_opened(id: String)

# GuideableNpc（Node，挂到 agent 上）
enum State { IDLE, WAIT, FOLLOW, OPEN_DOOR }
func setup(npc_id: String, group: String) -> void   # group 先经 PersonGroup.normalize()
func on_hint(text: String) -> bool                 # 未知提示返回 false
func tick(delta: float) -> void
func get_state() -> Dictionary
func to_dict() -> Dictionary
func from_dict(data: Dictionary) -> void

signal arrived(npc_id: String)
signal needs_hint(npc_id: String, hint: String)
```

错误语义：未注册/不存在的目标 id 返回 `false` + `push_warning`；重复开灯/开门幂等（状态不变、不重复发信号）。

## 3. LoopManager（W6 实现）

- 文件：`scripts/loop/loop_manager.gd`（可选 `loop_state.gd` 只放轮次 summary 结构）
- 职责：一轮的起止、回到录像带某一时刻重开一轮（含世界重置）、玩家知识保留。
- **设计决定（2026-11-21，#20）**：玩法采用**回放**（录像带），不是时间回溯；本模块只负责轮次/重开，
  不承担「改写过去」。`rewind_to` 的语义是「回到录像带内的某一刻重开」，不是时间旅行。
  详见 `docs/DESIGN_DECISIONS.md`。

```gdscript
func start_round() -> void
func end_round(summary: Dictionary) -> void
func rewind_to(time: float, participants: Array) -> bool
func reset_world(participants: Array, time: float) -> void
func get_round_index() -> int
func get_history() -> Array
func to_dict() -> Dictionary
func from_dict(data: Dictionary) -> void

signal round_started(round_index: int)
signal round_ended(round_index: int, summary: Dictionary)
signal world_reset()
```

**参与者协议**（鸭子类型，不新增基类、不改对方文件）：

```gdscript
func reset_for_loop(time: float) -> void   # 参与者把自己重置到 time 这一刻
```

谁会实现它（由 W12 装配时接线，参与者都是**新增适配器**，不碰只读模块）：

| 参与者 | 实现位置 | 做法 |
|---|---|---|
| 时间轴 | `scripts/loop/time_participant.gd`（W6/W12） | 调 `TimeManager.rewind_present_time(time)`（见下） |
| 世界 | `scripts/loop/world_participant.gd`（W12） | 调现有 `SimWorld.apply_state(SimTimeline.state_at(t))`（`apply_state` 是唯一写入口） |
| 摄像头 | W1 的 `CameraSession` 适配器 | `from_dict`/清空冷却；烧毁**保持**（M16 已拍板：永久） |
| 引导 | W2 的 `GuideBus` 适配器 | 复位灯/门/NPC 状态 |

语义：
- `start_round` 使轮次 +1 并广播（首轮从 1 开始）；
- `end_round` 记录 summary（`{round, time, outcome, clues: int, solved: int}`，字段可扩展）；
- `rewind_to(t, participants)` = 先 `reset_world(participants, t)` 再广播 `world_reset`，然后返回 true；
  单个参与者 `reset_for_loop` 抛错/不存在时 `push_warning` 并继续（不整体失败）；
- **知识保留**：`ClueManager` 里的 timeline 线索不清空（只读消费，不改 `clue_manager.gd`）；
- M16 已拍板（#20）：烧毁的机位**永久不恢复**；`rewind_to` 后由 W1 的参与者保持烧毁。

### TimeManager 的唯一例外改动（W12 负责）

`scripts/time_manager.gd` 对除 W12 外的所有流只读。W12 新增一个方法（不改现有行为）：

```gdscript
## 把「现在」回到某个时刻：设置 present_time、广播 present_time_changed、
## 重排救援事件游标（_next_index 指向第一个 t > 新 present_time 的事件），
## 清空 fired_events / deferred_events；speed 保持不变。
func rewind_present_time(time: float) -> void
```

W6 通过 `time_participant.gd` 调它，不直接写 `present_time` 字段。

## 4. PersonGroup（W2 实现，W3/W6 消费）

- 文件：`scripts/person/person_group.gd`（`extends Node`，挂到 agent / 对话对象上）
- 职责：区分「真实的人」与「幻想中的朋友」，供对话样式、画风、重置规则消费。

```gdscript
const REAL := "real"
const IMAGINARY := "imaginary"
## 唯一归一化入口：friend -> imaginary，stranger -> real，其它未知值 -> REAL + push_warning
static func normalize(group: String) -> String

func setup(group: String) -> void   # 内部调用 normalize
func get_group() -> String
func is_real() -> bool
func to_dict() -> Dictionary
func from_dict(data: Dictionary) -> void
```

**group 的单一事实来源**：数据文件与运行时一律写规范值 `real` / `imaginary`；
`friend` / `stranger` 只是给文案用的别名，必须经 `normalize()` 才能进入状态。W3 的
`dialogues.schema.json` 枚举也只接受规范值。

## 5. DialogueController（W3 实现）

- 文件：`scripts/dialogue/dialogue_controller.gd`、`scripts/dialogue/dialogue_theme.gd`
- 数据：`resources/data/dialogues.json`（schema 见 §9）

```gdscript
func load_defs(path: String) -> bool
func start(dialogue_id: String, group_override: String = "") -> bool
func advance() -> void
func is_active() -> bool
func get_state() -> Dictionary

signal line_shown(line: Dictionary)   # {"speaker", "text", "group"}，group 已归一化
signal finished(dialogue_id: String)
```

group 解析顺序：`group_override` 非空则用它，否则用 dialogue 定义自带的 `group`；两者都经
`PersonGroup.normalize()`，决定主题（`line_shown` 里的 group 是解析后的规范值）。

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
func snapshot(managers: Dictionary) -> Dictionary
func restore(path: String) -> Dictionary
func save(path: String, snapshot: Dictionary) -> bool
func load(path: String) -> Dictionary
```

- `managers` 形状：`{ "camera": manager, ... }`，每个 manager 必须实现 `to_dict()` / 由保存方
  在恢复时用 `from_dict()`；`snapshot` 只收集、不调用 `from_dict`。
- `snapshot` 返回 `{ "version": VERSION, "created_at": <unix 秒 int>, "managers": {name: {...}} }`。
- `save(path, snapshot)` 只写文件；`load(path)` 只读文件 + 版本校验，返回 `{}` 表示失败。
- `restore(path)` = `load` + 逐个 `manager.from_dict(data)`（缺失的 manager 跳过并 `push_warning`）。
- 错误语义：版本不符/坏 JSON/文件不存在 → 返回 `{}` + `push_warning`，不崩溃、不覆盖旧档。

`ClueManager` / `TimeManager` 只读，不提供 `to_dict/from_dict`：需要存档的流自己写适配器
（放在 `scripts/save/adapters/`，通过公开 API 读写，不改这两个文件）。

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
| `resources/data/surveillance.json` | W1 | `schema/surveillance.schema.json` | 机位 → `dwell` / `cooldown`（秒）；键是机位 id |
| `resources/data/dialogues.json` | W3 | `schema/dialogues.schema.json` | `dialogues[]` → `{id, group, lines[]}`，`group` 只允许 `real` / `imaginary` |
| `resources/data/levels/*.json` | W9/W12 | `schema/level.schema.json` | 关卡最小结构（房间 + 机位） |

**所有 JSON 读入统一走 `ConfigLoader`**（带 schema，失败返回 `{}`），不要在模块里手写
`FileAccess`+`JSON.parse_string`。

schema 子集（`ConfigLoader` 支持）：
- `type`：`object` / `array` / `string` / `number` / `integer` / `boolean` / `any`；
  **`integer` 接受“整数值的 float”**（Godot 的 JSON 解析把数字统一成 float，3 也是 3.0）；
- `required`、`properties`、`items`、`enum`、`min`、`max`；
- `additional_properties`：`true`（允许未知字段）/ `false`（拒绝）/ 对象（对未知字段套用该 schema）；
- 写了未知 `type`（例如拼错的 `integerr`）会被判成 **schema 错误**，不会静默放宽；
- 未知关键字（`$comment` 等）忽略，保持向前兼容。

`load_json` 只接受**对象根**（数组根请包一层，例如 `{"items": [...]}`），失败不返回半成品。

## 10. 并行开发约束（重申）

- 每个流只在自己的 glob 内新增文件（见各 issue）；**共享文件只归 W12**（`scenes/main.tscn`、`project.godot`、`README.md`、docs 索引）。
  **唯一例外**：`time_manager.gd` 的 `rewind_present_time()` 由 W12 添加（见 §3）。
- **只读**：`scripts/sim/*`、`monitor_grid*.gd`、`integrated_sim.gd`、`puzzle_lab.gd`/`scripts/puzzles/*`、`clue_manager.gd`、`tape_*`、`theater_*.gd`、现有测试与场景；`time_manager.gd` 除上述例外也只读。
- 新增输入动作一律用运行时 `InputMap.add_action`，不改 `project.godot`。
- 测试入口统一 `tests/run_all.gd`：它会自动发现 `tests/smoke_test.gd` + `tests/test_*.gd`（按文件名排序），
  **新增套件不需要改 `run_all.gd`**；文件命名为 `tests/test_<domain>*.gd` 即可被收录。
