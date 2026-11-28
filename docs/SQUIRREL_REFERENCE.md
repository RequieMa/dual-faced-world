# 飞鼠参考模型对照

参考文件：

`E:\Users\86139\xwechat_files\wxid_sclfrdlrth3l11_a7be\msg\file\2026-11\3d(1).html`

参考实现的关键点：

- 身体 + 尾巴是**一条连续的 CatmullRom 管状 mesh**，尾根自然过渡，不是分段球；
- 头是变形球体，前部压成 snout，并按顶点着色出腹部/口鼻；
- 耳朵是**生成的双层叶面网格**（外耳 + 内耳），不是球；
- 四肢是动态管，脚是 IK 后的脚掌；
- 翼膜是前后肢/身体之间的 **Coons 风格动态面片**，边缘有 free edge 管；
- 有完整的地面行走/滑翔高度曲线、脊柱跟随、尾巴惯性、耳朵抖动、眨眼和尾巴 curl。

当前独立 demo：

```bash
godot --path . --scene scenes/demo_squirrel.tscn
```

已经改成 `scripts/demos/reference_squirrel.gd`：

- 身体 + 尾巴连续管 mesh；
- 变形头 + 吻部 + 眼睛高光；
- 叶面外耳/内耳；
- 四肢管 mesh + 脚掌；
- 前后肢之间的翼膜面片和深色 free edge。

但**还没有完全复刻参考**：

- 参考是 72 段身体 + 18 边环、动态 IK、地面踏步、滑翔姿态和尾巴物理；
- 当前 demo 是静态 3/4 展示姿态，没有完整 IK/踏步/滑翔骨骼；
- 当前主场景 `scripts/room_demo/flying_squirrel.gd` 仍是旧版轻量模型，尚未切换到这个参考式模型。

要真正达到参考效果，下一步应把参考的：

1. 连续曲线管（CatmullRom + 变半径）；
2. 3D 两骨 IK；
3. Coons 翼膜；
4. 脊柱/尾巴/耳朵动画；
5. 顶点色/描边材质

完整移植到 `Glider` 类，再替换主场景飞鼠。
