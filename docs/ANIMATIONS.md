# Mixamo 动作库（Lumine demo）

从 Mixamo 下载的动作放在本地（`external-assets/` 被 gitignore，不提交）：

```text
external-assets/animations/mixamo_raw2/      # 原始 FBX（Without Skin, 30fps）
external-assets/animations/lumine_mixamo_animations.glb  # 已重定向到 Lumine 的 GLB
external-assets/_work/mixamo-chrome2/        # 复用登录态的临时 Chrome profile
external-assets/_work/mixamo_fetch3.mjs      # 可重复下载脚本
```

## 动作清单

| UI 名称 | FBX 文件 | 类型 |
| --- | --- | --- |
| idle_standing | `idle_standing.fbx` | 站姿 |
| idle_breathing | `idle_breathing.fbx` | 站姿 |
| walk_forward | `walk_forward.fbx` | 移动 |
| walk_backward | `walk_backward.fbx` | 移动 |
| run_forward | `run_forward.fbx` | 移动 |
| strafe_left | `strafe_left.fbx` | 移动 |
| look_around | `look_around.fbx` | 张望 |
| look_nervous | `look_nervous.fbx` | 张望 |
| hide_crouch_idle | `hide_crouch_idle.fbx` | 躲藏 |
| hide_crouch_walk | `hide_crouch_walk.fbx` | 躲藏 |
| hide_hiding | `hide_hiding.fbx` | 躲藏 |
| hide_cover_idle | `hide_cover_idle.fbx` | 躲藏 |

## Demo

```bash
godot --path . --scene scenes/demo_animation.tscn
```

左侧按钮是动作名；点击后循环播放，标题显示当前动作。

## 说明

- Mixamo 下载设置为 `FBX 7.4`、`Without Skin`、`30fps`、`none`。
- Lumine 原模型 Body/Hair/Skirt 等网格没有顶点组和 Armature modifier，脚本先做 automatic weights，再把 Mixamo 骨骼重定向到 Bip001，并烘焙动作。
- 当前是自动蒙皮/自动重定向的第一版，权重和原始 Lumine 的服装/头发可能还有变形；动作名称和资产已经可用于后续挑选、分配。
