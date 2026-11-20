# 解谜实验室（puzzle_lab）

一个可交互的 demo-scene，把 8 种常规解谜类型放在同一个房间里：

```sh
godot --path . scenes/puzzle_lab.tscn          # 直接跑这个场景（demo 没有挂成 main scene）
godot --headless --path . --script tests/test_puzzle_lab.gd   # 101 条断言
```

- 左侧列表或直接点 3D 台子都能打开谜题；`ESC` 关闭；解开后顶面变绿、列表打勾，8/8 亮完成横幅。
- 每个谜题都是独立的 `Control` 脚本，可以单独复用、单独测试；实验室只负责房间、进度和开关页面。

| # | 谜题 | 文件 | 核心机制 | 正解 |
|---|---|---|---|---|
| 1 | 数字密码锁 | `scripts/puzzles/keypad_puzzle.gd` | 数字输入 + 线索解析 + 错误反馈 | 4012 |
| 2 | 钥匙与门 | `scripts/puzzles/key_door_puzzle.gd` | 拾取 / 背包 / 道具对目标使用 / 干扰项 | 黄铜钥匙 + 铁门 |
| 3 | 开关顺序 | `scripts/puzzles/sequence_puzzle.gd` | 序列记忆 / 顺序推理，按错复位 | B → D → A → C → E |
| 4 | 物品组合 | `scripts/puzzles/combine_puzzle.gd` | 背包内合成新道具，再用于环境 | 镜片 + 镜筒 → 望远镜 → 窗台 |
| 5 | 线路连接 | `scripts/puzzles/wire_puzzle.gd` | 匹配连线 / 错误弹开 | 红→1、蓝→2、绿→3、黄→4 |
| 6 | 转盘拨轮 | `scripts/puzzles/dial_puzzle.gd` | 旋钮到目标刻度（保险箱式） | 3-7-1 |
| 7 | 隐藏物 | `scripts/puzzles/hidden_object_puzzle.gd` | 场景翻找 / 计件 / 空找反馈 | 5 件目标物 |
| 8 | 证词推理 | `scripts/puzzles/testimony_puzzle.gd` | 读多条证词找矛盾（叙事推理） | 选「丙」 |

共用外壳在 `scripts/puzzles/puzzle_base.gd`：标题 / 线索 / 状态行 / 重置 / 返回，以及
`solved` / `close_requested` / `state_changed` 三个信号。新增谜题只要继承它并实现 `build_body()`。

## 美术与素材策略

**本 demo 没有任何外部素材**：房间、台子、标签、UI 全部程序化生成（`BoxMesh` / `Label3D` /
代码搭的 Control），所以仓库里不会多出二进制文件，也符合 `AGENTS.md`「不夹带大文件、
`external-assets/` 不入库」的约定。

要把它升级成"有质感"的版本时，按下面的来源收集（**都优先 CC0**，避免商用授权风险）：

| 用途 | 推荐来源 | 许可证 | 备注 |
|---|---|---|---|
| UI 框架 / 按钮 / 面板 | [Kenney UI Pack](https://kenney.nl/assets/ui-pack) | CC0 | 九宫格切图，直接替换 `PanelContainer` 的 StyleBox |
| 输入提示图标 | [Kenney Input Prompts](https://kenney.nl/assets/input-prompts) | CC0 | 键鼠/手柄提示 |
| 道具图标（钥匙/镜片/纸条…） | [Kenney Game Icons](https://kenney.nl/assets/game-icons) | CC0 | 背包列表图标 |
| 拼图 / 滑块素材 | [Kenney Puzzle Pack](https://kenney.nl/assets/puzzle-pack) | CC0 | 若以后加"拼图/滑块"第 9 类 |
| 交互/错误音效 | [Kenney Interface Sounds](https://kenney.nl/assets/interface-sounds) | CC0 | 密码错误、接线、开锁各一条 |
| 环境音 / 脚步 | [Kenney RPG Audio](https://kenney.nl/assets/rpg-audio) | CC0 | 房间底噪 |
| 家具 / 房间道具 3D | [Kenney Furniture Kit](https://kenney.nl/assets/furniture-kit) | CC0 | 替换 BoxMesh 台子 |
| HDRI / 模型 / PBR 贴图 | [Poly Haven](https://polyhaven.com/) / [ambientCG](https://ambientcg.com/) | CC0 | 房间光照与地面材质 |
| 中文 UI 字体 | [Noto Sans SC](https://fonts.google.com/noto/specimen/Noto+Sans+SC)（OFL） | OFL | 现在用引擎默认字体，正式版建议换 |
| 参考实现 | [Godot demo projects](https://github.com/godotengine/godot-demo-projects) | MIT | 学节点组织，不要直接抄素材 |
| 杂项 2D/音频 | [OpenGameArt](https://opengameart.org/) / [freesound](https://freesound.org/) | 逐项确认（筛 CC0） | 每个文件都要留许可证 |

授权做法：

1. 下载包放进 `external-assets/puzzle_lab/<pack>/`（该目录被 gitignore，按仓库约定走网盘同步）；
2. 只把**确实要入库**的小图/音效裁剪后放进 `resources/assets/puzzle_lab/`，并保留 `LICENSE.txt`；
3. 在 `manifests/asset_manifest.json` 里登记文件、来源、许可证与作者（CC-BY 必须署名）；
4. 不要入库 NC / ND 素材；商用前逐条复核许可证原文。

替换点（按优先级）：

- `scenes/puzzle_lab.tscn` 的 `Camera3D` / 灯光 → 换成 HDRI 环境；
- `puzzle_lab.gd::_add_station()` 里的 `BoxMesh` → 换家具模型（保持 `Station_XX` 命名即可）；
- `puzzle_base.gd::_build_shell()` 的 `PanelContainer` → 套 Kenney 的 StyleBox；
- 各谜题里 `make_button()` 生成的按钮 → 套主题（`Theme` 资源）或换带图标的按钮；
- 音效：在 `succeed()` / `fail()` 里各播一条（`AudioStreamPlayer` 做池）。

## 已知取舍

- 交互半径/判定都是写死的常量（如密文、顺序、拨轮目标），换关卡时改常量或改成资源；
- 隐藏物是 9 个固定"位置按钮"，没有真正的 3D 隐藏物；要升级就把位置换成场景里的 `Area3D`；
- 证词推理只有 4 条固定文本，没有和 `ClueManager` 打通；接入时可把证词做成数据文件。
