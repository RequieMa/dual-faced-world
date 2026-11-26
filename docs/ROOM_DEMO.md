# 主场景 Demo：控制室 + 两个观察房间

`scenes/main.tscn` 现在是新的 **3D 控制室 demo**；旧的 3 轮可玩 demo 仍在
`scenes/game_root.tscn`，原场景没有改动。本文只记录新 demo 的玩法和 Scope 缩小决定。

## 1. 一句话玩法

玩家被关在控制室里，面对墙上的监控大屏和滚动屏；坐进椅子后**仍然保持第一人称视角**，
只是键鼠可以操作墙面屏幕。用 4 路摄像头观察两个房间里的两个 NPC，用激光/截图引导他们
找线索。NPC 找到线索会自动拍照；玩家把两张门禁码照片拖到滚动屏组合出 `A-317`，
门解锁后回到门口按 `E` 离开。

> 监控台和滚动屏都是墙上的 3D 物理屏幕：内容由 `SubViewport` 渲染再贴到 QuadMesh 上，
> 不是坐下后弹一个全屏 2D 面板。鼠标点击通过射线换算成屏幕纹理坐标后转发进 SubViewport。

## 2. 操作

| 输入 | 作用 |
|---|---|
| `WASD` | 第一人称移动 |
| 鼠标 | 看（非坐下时捕获鼠标） |
| 靠近椅子 `F` | 坐下 / 站起；坐下后仍是第一人称看墙上的屏幕 |
| 坐下后点墙上画面 | 放大该摄像头（鼠标射线转发到屏幕 SubViewport） |
| 放大画面右键 | 朝画面里的位置发一束激光，引导 NPC |
| `S`（坐下、放大画面时） | 截图当前画面，照片进底部仓库 |
| 把底部照片拖到墙上滚动屏 | 组合线索 / 引导 NPC（拖放区对齐 3D 屏幕的投影） |
| `E`（靠近门） | 门解锁后离开；未解锁只提示 |
| `R`（完成界面） | 重开 |

## 3. 内容与数值（Scope 缩小版）

- **房间**：1 个控制室 + 2 个小观察房间（A/B，中间有门洞）；旧剧院地图不参与。
- **摄像头**：每房间 2 台，面对面摆放；机位贴墙装在接近天花板的角落（y≈2.7），
  俯视房间，画面带广角桶形/鱼眼畸变，所以画面里能看到对面的摄像头模型和弯曲的墙线。
- **停留/过载**：每台停留 **45 秒**（原设定“几分钟”缩成 demo 秒数），超时过载烧毁；
  切走后 **8 秒**冷却。烧毁是本次运行内永久，重开 `R` 才恢复。
- **NPC**：`reckless`（莽撞）跑得比谨慎快、视锥较窄，收到激光会冲过去，找不到线索就跑开；
  连续跑空 3 次后会暂时忽略信号。`cautious`（谨慎）走得慢、视锥较宽，会顺着激光过去
  并仔细翻找，不会因为跑空而忽略信号。两人都会在无指令时自己巡逻/四处张望。
  移动速度已下调（莽撞约 1.65m/s、谨慎约 0.6m/s、玩家约 2.2m/s）；NPC 改用
  `CharacterBody3D + move_and_slide`，会被墙体和家具挡住，不再穿墙。
- **线索**：2 个，放在房间角落/家具后面；NPC 只有走到很近且看得到时才会顺手捡，
  大多数情况需要玩家用激光或截图把他们引过去。
- **拍照**：NPC 捡到线索自动拍照；照片带拍摄时间、机位和缩略图（headless 下用占位纹理）。
- **组合**：滚动屏上最后两张线索照片的**拍摄时间差 ≤ 20 秒**，且是门禁码的两半，才会
  合成 `A-317`；间隔太久或不是一对会提示失败。
- **截图**：`S` 截当前放大画面，落到滚动屏后会让 NPC 去截图中心位置查看（谨慎慢走、
  莽撞冲过去）。
- **结束**：门禁码组合成功后门解锁；走回门口按 `E` 出现完成界面。

## 4. 文件

| 用途 | 文件 |
|---|---|
| 主场景 | `scenes/main.tscn` |
| 装配/流程 | `scripts/room_demo/room_demo.gd` |
| 第一人称玩家 | `scripts/room_demo/room_player.gd` |
| NPC 行为/视锥 | `scripts/room_demo/npc_actor.gd` |
| Avatar 运行时加载 / 归一化 / toon 材质 | `scripts/room_demo/avatar_loader.gd` |
| 二次元 toon / 描边 shader | `shaders/anime_toon.gdshader`、`shaders/anime_outline.gdshader` |
| 监控画面鱼眼 shader | `shaders/fisheye_feed.gdshader` |
| Blender → GLB 导出脚本 | `tools/blender/export_character.py` |
| 照片仓库/组合 | `scripts/room_demo/photo_store.gd` |
| HUD / 照片仓库 / 拖放区 | `scripts/room_demo/room_ui.gd` |
| 3D 监控屏内容 | `scripts/room_demo/monitor_ui.gd` |
| 3D 滚动屏内容 | `scripts/room_demo/scroll_screen_ui.gd` |
| 测试 | `tests/test_room_demo.gd` |

Avatar 资产说明（包括枫丹 zip 只有材质预设、没有 mesh 的原因）见
[docs/AVATARS.md](AVATARS.md)。Soyo / Lumine 已接入；枫丹模型缺失时谨慎 NPC 回退到
primitive 占位，放入 `external-assets/generated/fontaine.glb` 后会自动替换。

旧 demo 的回归仍走 `scenes/game_root.tscn`；`tests/test_game_root_*.gd` 已改成直接加载
`game_root.tscn`，不再假设 `main.tscn` 是旧入口。

## 5. 验证

```sh
godot --headless --path . --script tests/test_room_demo.gd   # 70 checks
godot --headless --path . --script tests/run_all.gd          # 26 suites
```

交互自检：

1. 开局走到椅子旁按 `F`，确认 4 路画面出现；
2. 点 C1 放大，右键画面一点，观察 NPC 是否转向/跑去目标；
3. 等 NPC 捡到线索，底部出现照片；按 `S` 再截一张；
4. 把两张门禁码照片拖到滚动屏，确认出现 `A-317` 且门变绿；
5. 站起走回门按 `E`，确认完成界面。

## 6. 已知简化

- Soyo（莽撞）和 Tactical Lumine（玩家）已换成 Blender 模型；谨慎 NPC 的枫丹 zip
  只有材质预设、没有 mesh，目前仍是 primitive 占位（见 `docs/AVATARS.md`）；
- 模型是静态 rest pose（源 .blend 没有可用动作），只做了上臂放下的 A-pose，没有跑步动画；
- NPC 用 waypoint 直线移动，没有导航网格/碰撞避让；
- 照片缩略图在 headless 下是占位色块；真实运行会截 SubViewport 画面；
- 没有动画/音效/字幕；数值为 demo 尺度，不是最终设计；
- 摄像头过载只做光效 + 机位烧毁，没有做物理爆炸伤害。
