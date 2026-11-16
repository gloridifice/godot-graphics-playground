# Mixamo 资源来源

## 固定来源

- 原始角色与动画服务：[Adobe Mixamo](https://www.mixamo.com/)。本包使用守卫角色，不是生成模型。
- 配套 FBX 与贴图取自 [aaronsnoswell/3DCharacter](https://github.com/aaronsnoswell/3DCharacter)，固定提交 [`1902fb9674350f2b68b5a26b8eccd64570ac8dd4`](https://github.com/aaronsnoswell/3DCharacter/tree/1902fb9674350f2b68b5a26b8eccd64570ac8dd4)。下载归档内的提交标记与该 SHA 一致。
- 向前跑步由用户提供的本机 `Downloads/Run Forward.fbx` 替换，本地保留文件名 `run.fbx`；这是带 `mixamorig1_` 命名空间的原地跑步动画，不再使用上游 `Running.fbx`。素材原始授权由提供者核实。
- 后退动作取自 [ArielOliveira/3rdPersonController](https://github.com/ArielOliveira/3rdPersonController)，固定提交 [`c4858b658abe4165a6e32892e2becad3250665b3`](https://github.com/ArielOliveira/3rdPersonController/tree/c4858b658abe4165a6e32892e2becad3250665b3)，路径为 `Assets/Characters/Charlotte/Animations/Locomotion/Action/Unarmed/Walking Backwards.fbx`。这是另一套 Mixamo 骨架，不是守卫原骨架。
- 仅使用以上仓库的 Mixamo 原始 FBX 与 `Guard Texture.png`，没有引入上游控制器脚本、Unity 工程、`Player.blend`、`Player.dae` 或截图。

| 本地 `assets/mixamo/` 文件 | 上游文件 |
| --- | --- |
| `character.fbx` | `Mixamo/Standard Walk.fbx`（含角色网格、骨架与行走） |
| `idle.fbx` | `Mixamo/Idle.fbx` |
| `run.fbx` | 用户提供：`Run Forward.fbx` |
| `jump.fbx` | `Mixamo/Jump.fbx` |
| `fall.fbx` | `Mixamo/Falling Idle.fbx` |
| `crouch_idle.fbx` | `Mixamo/Sword And Shield Crouch Idle.fbx` |
| `crouch_walk.fbx` | `Mixamo/Sneaking Forward.fbx` |
| `strafe_left.fbx` | `3DCharacter`：`Mixamo/Left Strafe Walking.fbx` |
| `strafe_right.fbx` | `3DCharacter`：`Mixamo/Right Strafe Walking.fbx` |
| `walk_back.fbx` | `3rdPersonController`：上述 `Walking Backwards.fbx` |
| `Guard Texture.png` | `Guard Texture.png` |

FBX 只重命名、不修改字节。`character_0.png`、`character_1.png`、`character_2.png` 是 Godot 从角色 FBX 提取的内嵌贴图。所有原始资源都保留在本目录，不依赖下载目录或绝对文件路径。

新增原文件 SHA-256：

- `run.fbx`：`09dfdc5a68b52abb949db17275463077c48e4413a0b33f0093f7959ba9706057`
- `strafe_left.fbx`：`d3546640b63ef62b6a65587811ad92c8ac5a6bd8bc9c58b01d644cce93e3cad9`
- `strafe_right.fbx`：`c8f0bb229e33988017e12204e503e3a8b9a00c8e6d7ef59c15a049571b85eb4f`
- `walk_back.fbx`：`1bfbda587b58c7c0243f312b04af75d0c80b9f92d6225cbdc09baff4be26722a`

## 本地处理

`tools/build_mixamo.gd` 使用 Godot 自带 FBX 导入器读取动画；用户提供的跑步及新增横移／后退按骨名及全局静止姿态映射旋转，保留守卫骨长、按髋高比例转换根轨迹，删除非骨骼轨道、清除髋部水平根运动、去除空中动作的额外竖直轨迹、按原根行程校准行走类播放时长；原地 Run 无净根行程，从支撑区鞋底向后的速度估计完整周期步幅（约 2.807 m），按库内标准 6 m/s 校准为约 0.468 s（运行默认跑速 3 m/s，TimeScale 为 0.5），配置循环并添加完整 `RESET`。另从原动画鞋底轨迹离线估计左右接触意图，生成可被 AnimationTree 混合的连续接触曲线；没有改写原始 FBX。模型移除多余动画播放器，保留骨架、蒙皮、材质和贴图。再从同一动画库离线采样脚部姿态／速度、平均根速度、直线未来轨迹及接触，生成 Motion Matching 检索资源。输出 Godot 原生 `.scn`／`.res`／`.tres`；运行时不联网、不转换模型、不使用 Blender。

## 使用限制

这些美术资源不是本项目原创内容，也不因本项目或其余 addon 的许可而成为 MIT／CC0 素材。`3DCharacter` 未附独立开源许可；其他仓库的代码许可也不能视为对 Mixamo 动画、模型和贴图的额外授权。

Adobe 的 [Mixamo FAQ](https://helpx.adobe.com/creative-cloud/faq/mixamo-faq.html) 说明角色与动画可免版税用于个人、商业及非商业项目；具体权利仍受 Adobe 条款约束。这里将它们用于本项目角色演示，不提供独立素材包授权。不要把原始或派生 Mixamo 模型／动画作为独立素材库出售或再分发；公开发布本仓库、可复用 addon 或其他素材包前，应核实 Adobe 当前条款与贴图权利，必要时让使用者自行从 Mixamo 下载有权使用的资源。
