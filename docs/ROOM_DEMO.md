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
| `WASD` | 第一人称移动（有起步加速/松键减速，走路时轻微头部起伏） |
| 鼠标 | 看（非坐下时捕获鼠标） |
| 靠近椅子 `F` | 坐下 / 站起；坐下后仍是第一人称看墙上的屏幕 |
| 坐下后点墙上画面 | 放大该摄像头（鼠标射线转发到屏幕 SubViewport） |
| 放大画面右键 | 朝画面里的位置发一束激光，引导 NPC |
| `S`（坐下、放大画面时） | 截图当前画面，照片进底部仓库 |
| 把底部照片拖到墙上滚动屏 | 组合线索 / 引导 NPC（拖放区对齐 3D 屏幕的投影） |
| `E`（靠近门） | 门解锁后离开；未解锁只提示 |
| `R`（完成界面） | 重开 |

## 3. 内容与数值（Scope 缩小版）

- **房间**：1 个 16×12m、净高 3.4m 的控制室 + 原型地图上的舞台/后台/侧门观察区。
  舞台约 8×8m，后台约 10×8m，中间是 1.5m 宽的连接通道；后台前墙经短通道连接侧门小房间。
  观察区有舞台地台/幕布/大熊、后台道具堆盲区、地毯、沙发、书架、柜子、花箱和墙板。
  控制室（玩家所在房间）不在这张原型图上，位置保持独立。
- **椅子 / 屏幕**：椅子放在监控屏正前方约 1.7m，椅背朝门，坐下后正对屏幕；坐姿视高 1.36m。
  监控屏和滚动屏都是墙上的 3D 物理屏（SubViewport 贴 QuadMesh），拖放区按 3D 投影对齐。
- **镜头**：第一人称画面经过 `lens_distortion.gdshader` 轻微桶形畸变；HUD 在更高 CanvasLayer，
  不受畸变影响。放大画面有“← 返回 4 路画面”按钮，`Esc`/退格也可退出放大（站起仍用 `F`）。
  玩家自己的 avatar 放在 layer 2，第一人称相机剔除该层，避免看到模型内壁。
- **烧毁画面**：机位过载后画面切换成动态雪花噪声，不保留最后一帧。
- **摄像头**：按地图放 C1 舞台全景、C2 舞台/后台门口、C3 后台主视角、C4 侧门；
  机位贴墙装在接近天花板的位置，俯视房间，画面带广角桶形/鱼眼畸变，
  并叠加老电视的扫描暗纹、颗粒和边缘压暗。
- **停留/过载**：每台停留 **45 秒**（原设定“几分钟”缩成 demo 秒数），超时过载烧毁；
  切走后 **8 秒**冷却。烧毁是本次运行内永久，重开 `R` 才恢复。
- **NPC**：`reckless`（莽撞）跑得比谨慎快、视锥较窄，收到激光会冲过去，找不到线索就跑开；
  连续跑空 3 次后会暂时忽略信号。`cautious`（谨慎）走得慢、视锥较宽，会顺着激光过去
  并仔细翻找，不会因为跑空而忽略信号。两人都会在无指令时自己巡逻/四处张望。
  移动速度已下调（莽撞约 1.65m/s、谨慎约 0.6m/s、玩家约 2.2m/s）；NPC 改用
  `CharacterBody3D + move_and_slide`，会被墙体和家具挡住，不再穿墙。
- **线索**：2 个，放在房间角落/家具后面；NPC 只有走到很近且看得到时才会顺手捡，
  大多数情况需要玩家用激光或截图把他们引过去。
- **飞鼠**：舞台/后台各有 1 只（共 2 只），尺寸与钥匙/线索 primitive 的 0.34m 一致。
  会在地面巡游、展开翼膜滑翔、贴墙攀爬；碰到线索会叼起，飞一段后在房间内换位置放下。
  已经预留火焰敏感接口：火源进入警戒半径时飞鼠立即转向并加速逃离（`set_fire_sources`）。
- **火焰**：舞台中央有程序化 3D 燃烧场，火焰会随时间扩张并烧向舞台机位；
  扩张到半径 3m 时舞台幕布/地台/道具会焦黑（区域损毁），
  机位被火焰持续覆盖 **20 秒** 会走 `CameraSession.force_burn()` 过载爆炸。
  燃烧场是 20×24×20 的低分辨率 CPU 网格（温度/燃料/烟尘 + 浮力半拉格朗日平流），
  渲染端用 3D 纹理 raymarch、黑体温度 LUT 和加法混合；音频是运行时合成的风声/噼啪声。
- **拍照**：NPC 捡到线索自动拍照；照片带拍摄时间、机位和缩略图（headless 下用占位纹理）。
- **组合/冷却**：滚动屏上最后两张线索照片的**拍摄时间差 ≤ 20 秒**，且是门禁码的两半，
  才会合成 `A-317`；间隔太久、不是一对或截图展示结束后，滚动屏进入冷却并自动清屏，
  不会停在不可用状态。等待第二张照片超过 12 秒也会自动冷却重置。
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
| 监控画面鱼眼 + 老电视扫描线 shader | `shaders/fisheye_feed.gdshader` |
| Blender → GLB 导出脚本 | `tools/blender/export_character.py` |
| 照片仓库/组合 | `scripts/room_demo/photo_store.gd` |
| HUD / 照片仓库 / 拖放区 | `scripts/room_demo/room_ui.gd` |
| 3D 监控屏内容 | `scripts/room_demo/monitor_ui.gd` |
| 3D 滚动屏内容 | `scripts/room_demo/scroll_screen_ui.gd` |
| 飞鼠 | `scripts/room_demo/flying_squirrel.gd` |
| 程序化火焰 | `scripts/room_demo/fire_system.gd` + `shaders/procedural_fire.gdshader` |
| 测试 | `tests/test_room_demo.gd` |

Avatar 资产说明见 [docs/AVATARS.md](AVATARS.md)。当前：鸡哥 = 莽撞 NPC，
Soyo = 谨慎 NPC，Tactical Lumine = 玩家。枫丹 zip 只有材质预设、没有 mesh，暂不参与 demo。

旧 demo 的回归仍走 `scenes/game_root.tscn`；`tests/test_game_root_*.gd` 已改成直接加载
`game_root.tscn`，不再假设 `main.tscn` 是旧入口。

## 5. 验证

```sh
godot --headless --path . --script tests/test_room_demo.gd   # 104 checks
godot --headless --path . --script tests/run_all.gd          # 29 suites
```

交互自检：

1. 开局走到椅子旁按 `F`，确认 4 路画面出现；
2. 点 C1 放大，右键画面一点，观察 NPC 是否转向/跑去目标；
3. 等 NPC 捡到线索，底部出现照片；按 `S` 再截一张；
4. 把两张门禁码照片拖到滚动屏，确认出现 `A-317` 且门变绿；
5. 站起走回门按 `E`，确认完成界面。

## 6. 已知简化

- 鸡哥（莽撞）、Soyo（谨慎）、Tactical Lumine（玩家）已换成模型；枫丹 zip 只有材质
  预设、没有 mesh，暂不参与 demo（见 `docs/AVATARS.md`）；
- 模型没有可用的跑步动画：Soyo/Lumine 只做了上臂放下的 A-pose，鸡哥是无骨骼静态模型；
- NPC 用 waypoint 直线移动，没有导航网格/碰撞避让；
- 照片缩略图在 headless 下是占位色块；真实运行会截 SubViewport 画面；
- 程序化火焰目前是 CPU 低分辨率版本：每 0.1s 跑一次 20×24×20 网格，并重建 20 张 3D 纹理切片；
  体积 raymarch 每像素 28 步。先保证效果和 20 秒烧毁逻辑；后续可改 GPU compute、降低更新频率、
  复用纹理切片或按画面远近降 raymarch 步数来优化；
- 没有动画/音效/字幕；数值为 demo 尺度，不是最终设计；
- 摄像头过载只做光效 + 机位烧毁，没有做物理爆炸伤害。
