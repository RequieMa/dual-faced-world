# integrated_sim（Phase 1：只读回放）

`integrated_sim` 是二面世界的集成 simulation：一条 0–90s 的确定性时间线，被切成 3 盘录像带
（[0,15)、[15,30)、[30,45)），玩家在监控墙上回看档案，实时视图冻结在 `t1=45`。

## 模块

| 文件 | 职责 |
|---|---|
| `scripts/sim/sim_timeline.gd` | EventTimeline：waypoint 插值 + 10Hz 全量快照 + 事件表 + 录像带切分（确定性、可重复生成） |
| `scripts/sim/tape_sampler.gd` | `sample(timeline, tape, playback_time)`：把绝对播放位置钳到带窗口后取状态，位置在相邻快照间插值 |
| `scripts/sim/replay_controller.gd` | `playback_time / speed / paused` 用时钟 delta 驱动（不用 `VideoStreamPlayer`） |
| `scripts/sim/replay_event_dispatcher.gd` | 只把落在 `(last_sample_time, playback_time]` 的事件派发出去；seek 不补播 |
| `scripts/sim/sim_world.gd` | 20×20 地图 + 边界墙 + 3 agent + 4 道具；`apply_state()` 是唯一的状态写入口 |
| `scripts/monitor_grid.gd` | 监控墙 transition 基类（机位数据驱动），`monitor_grid_demo.gd` 只是它的一个子类 |
| `scripts/clue_board.gd` | 线索板：按时间排序，cause 用装订线上的折线箭头指向被引用线索 |
| `scripts/integrated_sim.gd` + `scenes/integrated_sim.tscn` | 集成场景：监控墙 / 回放 UI / 线索板 |

## EventTimeline

- 每个 agent 一组 `{t, p}` 关键帧，段内线性插值；关键帧落在交互事件时刻上。
- 每 0.1s 一份快照，含**所有** agent 位置与**所有**道具位置/状态；`state_at()` 在快照间插值位置、
  状态量按阶跃取左端。
- 事件用 `cause` 引用线索 id（`type_target_t`）形成因果链：

| t | 事件 | cause |
|---|---|---|
| 12.0 | pickup Key_01 by Agent_A | — |
| 20.0 | switch Switch_01=ON by Agent_B | — |
| 28.0 | unlock Door_01 by Agent_A | `pickup_Key_01_12.0` |
| 35.0 | pass Door_01 by Agent_C | `unlock_Door_01_28.0` |
| 52.0 / 60.0 / 75.0 | planned（`planned=true`，第一阶段不消费、不派发） | — |

`Door_02`（内室门）在档案时间线里始终 `locked`：它的解锁是 planned 事件，交给第二阶段由实时交互判定。

## Phase 2：实时推进 / 拖拽 / live 因果链

- **时钟**：实时视图 `present_time` 从 45 起按 1x 推进；进入回放后冻结（`TimeManager.speed = 0`），
  切回实时恢复。时间线走完（90s）停在末帧。
- **每帧**：`LiveRuntime.step(present_time)` → `compose(present_time)`（EventTimeline 状态 + live 覆盖）
  → `SimWorld.apply_state()`。live 覆盖只记「拖拽位置 / 已被实时改写的道具状态」，位置与状态仍只有一个写入口。
- **交互判定**（`scripts/sim/live_runtime.gd`，XZ 平面距离）：

| 道具 | 条件 | 事件 | cause |
|---|---|---|---|
| `Key_01` | 无人持有且 agent 在 1.5 内 | `pickup`（source=live），之后跟随该 agent | — |
| `Switch_01` | 处于 off 且 agent 在 1.6 内 | `switch`（source=live） | 最近一条 switch 线索 |
| `Door_01/02` | 锁着且**持钥匙的 agent** 在 2.0 内 | `unlock`（source=live） | 该钥匙的 pickup 线索（archive 或 live） |

  还没看过档案时，「pickup 线索」直接取时间线上的 archive 事件 id，等玩家回放到该事件后线索板才会画出箭头。
- **拖拽**：只有实时模式 + 放大视图内可拖 `Key_01` / `Switch_01`（射线拾取 → 与地面 y=0 求交，夹在地图内）。
  回放中拖拽会被拒绝并提示，道具位置不变。拖拽会清掉持有者，之后可以被 agent 重新拾取。
  回放里看到的是档案采样状态，切回实时后立刻被 live 状态覆盖。

## 契约（第二阶段不要改）

- `SimWorld.apply_state(state)`：回放、实时、拖拽后的画面都只能走它。
- `ClueManager.register_clue(t, type, actor, target, cause, source) -> String`：去重键
  `(t, type, actor, target)`，`t` 归一到 0.1s（同一 0.1s 内同 type/actor/target 只登记一次），
  命中时返回空串；`source` 取 `archive`（回放派发）或 `live`（实时交互）。
- `ReplayController` 的 `playback_time / speed / paused` 由时钟驱动；`seek()` 区分前/后向。
  事件窗口起点只由 `ReplayEventDispatcher.last_sample_time` 持有。
- 旧的「全局标志」线索接口改名为 `register_flag(id, value)`，与新签名区分。

## 运行与验证

```sh
# 逻辑/契约测试
godot --headless --path . --script tests/test_integrated_sim.gd        # 93 条
godot --headless --path . --script tests/test_integrated_sim_live.gd   # 30 条

# 交互验证（godot-bridge）
godot_run_project(scene="scenes/integrated_sim.tscn")  # 然后 click 监控格 / 拖进度条 / 拖道具 / eval
```

`eval` 可读：`scene.get_sim_snapshot()`（模式、时钟、播放位置、agent/道具状态、线索、live 覆盖）、
`scene.get_tape_list()`、`scene.get_clue_board_snapshot()`、`scene.get_focus_snapshot()`。
