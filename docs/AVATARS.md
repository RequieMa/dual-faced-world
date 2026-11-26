# Avatar 资产管线（Blender → Godot）

demo 里的三个角色模型来自 `external-assets/` 的 zip。`external-assets/` 不进入 git
（只有 `.gdignore` 例外），所以导出的 GLB 放在 `external-assets/generated/`，运行时不经过
Godot 编辑器导入，而是用 `GLTFDocument` 从磁盘直接加载；文件不存在时自动回退到 primitive。

## 当前状态

| 角色 | 用途 | 源文件 | 运行时文件 |
|---|---|---|---|
| Soyo | 莽撞 NPC | `SOYO1.blend` | `external-assets/generated/soyo.glb` |
| Tactical Lumine | 玩家 | `Tactical Lumine.blend`（zstd 压缩，先解压） | `external-assets/generated/lumine.glb` |
| 枫丹 | 谨慎 NPC | **zip 内只有材质预设，没有 mesh** | `external-assets/generated/fontaine.glb`（待补） |

### 关于“枫丹”zip

`枫丹_by_小二今天吃啥啊_*.zip` 里是 10 个角色名的 `.blend` + `模型预设导入.py`。
逐个打开检查后，每个 `.blend` 都只有 `2` 个对象（一个灯光 + 一个空物体），`0` 个 mesh、
`0` 个 armature；`模型预设导入.py` 是一个把材质预设套到**已有模型**上的 Blender 插件。
因此这个包本身不能直接作为谨慎 NPC 的可见模型。

目前谨慎 NPC 使用 primitive 占位；只要把真正的枫丹 mesh 导出成
`external-assets/generated/fontaine.glb`（或提供带 mesh 的 `.blend`），`room_demo.gd`
会自动加载并替换占位，不需要改场景。

## 导出

使用 Blender 4.2 LTS（可携带版即可）：

```powershell
$blender = "E:\dev\tool\blender-4.2.17\blender-4.2.17-windows-x64\blender.exe"
& $blender -b external-assets\_work\soyo\SOYO1.blend `
  --python tools\blender\export_character.py -- soyo external-assets\generated\soyo.glb
& $blender -b external-assets\_work\lumine\TacticalLumine_decoded.blend `
  --python tools\blender\export_character.py -- lumine external-assets\generated\lumine.glb

# 有真正枫丹 mesh 的 .blend 时（generic 模式）：
& $blender -b <fontaine-mesh>.blend `
  --python tools\blender\export_character.py -- fontaine external-assets\generated\fontaine.glb
```

`Tactical Lumine.blend` 是 zstd 压缩流；先解压：

```powershell
zstd -d -f "external-assets\_work\lumine\Tactical Lumine.blend" `
  -o "external-assets\_work\lumine\TacticalLumine_decoded.blend"
```

导出脚本做这些事：

- 只保留角色 mesh / armature；去掉 MMD rigid body helper、WGT、cage、文字等；
- 去掉 `*Outline*`、`edge_*` 材质的面（描边在 Godot 里用 inverted-hull 重做，避免双重描边）；
- 把复杂 Blender 节点材质简化成 Principled + 选中的 base color 贴图：
  - 优先 `Diffuse` / `Texture` / `albedo`；
  - 排除 `shadow`、`lightmap`、`normal`、`ramp`、`mask`、`highlight`；
  - 这样 Soyo 用 `soyo_body_pants` / `soyo_hair` / `soyo_clothes`，
    Lumine 用 `*_Diffuse` / `Lumine Clothes Texture`；
- 导出 GLB（embedded textures、skins、无动画；源 `.blend` 没有可用动作）。

## Godot 侧

- `scripts/room_demo/avatar_loader.gd`
  - `GLTFDocument.append_from_file()` → 运行时场景；
  - 按目标身高归一化：Soyo 1.72m，Lumine 玩家 1.60m（第一人称相机在 1.66m，避免埋进头）；
  - 上臂骨放下来（源 rest pose 是 T-pose）；
  - 每个 surface 替换成 `shaders/anime_toon.gdshader`，并把
    `shaders/anime_outline.gdshader` 设为 `next_pass`；
  - 贴图/alpha/描边宽度都在运行时反推，不依赖导入的 `.import` 文件。
- `scripts/room_demo/room_demo.gd`
  - 玩家加载 Lumine；莽撞 NPC 加载 Soyo；谨慎 NPC 尝试 Fontaine，失败则保留占位；
  - 模型缺失只 warning，不阻塞场景和测试。
- `scripts/room_demo/room_player.gd` / `npc_actor.gd`
  - `attach_avatar()` 隐藏 primitive 身体，保留 NPC 的名字标签和视锥。

## 二次元渲染

`anime_toon.gdshader` 是参考 `E:\dev\vibe\reference` 的 my-npr 思路重写的 Godot 版本：

- base color 贴图 × 色；
- 半兰伯特式阈值阴影，阴影不是纯黑而是 `shadow_tint`（偏蓝紫）；
- 简单的 Fresnel 边缘光；
- 窄描边用 `next_pass` + `cull_front` + 沿法线外扩；
- 不依赖 WebGPU/TSL，也不要求 VRM 插件。

它不会 1:1 复刻 Endfield 的 SDF 面部阴影/多 ramp 高光，但保留了“贴图色块 + 硬阴影 +
描边 + 边缘光”的二次元读感，且在 Forward+ 下开销很小。

## 为什么不在 `.gdignore` 外

仓库约定 `external-assets/` 的内容不进 git；GLB 是本地生成/分发资产，不提交。
如果换机器或清理了 `external-assets/`，重新跑上面的 Blender 命令即可；没有 GLB 时 demo
仍能运行，只是回到 primitive avatar。
