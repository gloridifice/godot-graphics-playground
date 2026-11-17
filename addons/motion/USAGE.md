# Motion：Godot 原生第三人称角色

Mixamo 守卫模型与动画，使用 `CharacterBody3D`、`AnimationPlayer`、`AnimationTree`、`Skeleton3D` 和 `SpringArm3D`。不依赖第三方控制器、Phantom Camera、Blender 或编辑器插件。当前使用 Godot 4.7.2。已接入 Motion Matching、左右横移／后退动作、原生双腿 IK、地面适配和支撑期锁脚，以及空中自动吸附的程序化悬挂攀爬。

## 运行与接入

- **F5**：项目主雾实验场已使用 `motion_character.tscn`，保留行走、起跳和落地扰雾。
- 独立体验：打开 `addons/motion/demo.tscn`，按 **F6**。含平地、10／18／28 cm 方块、六级楼梯、球体、纵／横坡和移动平台；左侧橙色低顶净高 1.65 m，仍可蹲行通过。
- 其他场景：实例化 `addons/motion/motion_character.tscn`；角色原点就是脚底，保持 Y 朝上、单位缩放。环境使用碰撞层 1，角色使用层 2。自带相机默认启用。

| 输入 | 行为 |
| --- | --- |
| F / Esc | 切换控制 / 释放鼠标；吸附时 Esc 同时脱离，落地前禁止重抓 |
| WASD / 鼠标 | 相机相对移动 / 环绕；站立时 A／D 横移、S 后退，不转身；攀爬时沿表面交替换手 |
| 按住 Shift | 跑步 |
| 空格 | 接地跳跃，无二段跳；空中遇到有效抓点自动吸附，不另按抓握键 |
| 按住 Ctrl | 蹲下、蹲行；蹲伏时不能跳跃 |
| 滚轮 | 调整跟随距离 |
| Tab / R（仅 demo） | 下一个地形检查点 / 重置当前检查点 |
| F3 / F4（仅 demo） | IK 调试线 / 总开关 |
| F5（仅 demo） | Motion Matching 姿态 decay 开关 |
| 1 / 2（仅 demo） | 左／右脚独立开关 |

默认鼠标自由，单击不捕获；失焦释放。释放时停止水平输入，保留重力、碰撞和落地。松开 Ctrl 后若头顶被挡住，保持蹲伏，离开低顶后自动站起，释放鼠标也不会强行站起。

Input Map 使用 `move_left`、`move_right`、`move_forward`、`move_back`、`jump`、`sprint`、`crouch`、`capture_mouse`、`release_mouse`。缺失动作在进入场景时补齐到运行时 InputMap，不修改项目文件，也不覆盖已有绑定；自定义绑定请在项目设置中配置。

## 不锁鼠标的自动化控制

自动化、回放或脚本角色可直接给单个 `MotionCharacter` 发送相机相对指令，不需要捕获鼠标，也不依赖窗口焦点：

```gdscript
player.set_external_input(Vector2(0, -1))                    # 向前走
player.set_external_input(Vector2(1, 0), true)               # 向右跑
player.set_external_input(Vector2.ZERO, false, false, true)  # 跳跃按下
player.set_external_input(Vector2.ZERO)                     # 松开跳跃并停下
player.clear_external_input()                              # 归还普通玩家输入
```

完整参数为 `set_external_input(axis, sprint=false, crouch=false, jump=false)`。指令保持到下一次更新；移动轴限长为 1，跳跃按上升沿触发，腾空期间的跳跃不会排队到落地后执行。每个角色独立保存指令；外部控制期间相机不处理捕获键／鼠标事件，不修改全局 `Input` 或鼠标模式。碰撞、加减速、接地、攀爬、动画和 IK 仍走正常物理流程；悬挂取消可直接调用 `release_climb()`。

常规测试使用 `tests/control_driver.gd` 将进程内的合成动作送到该入口，窗口设为不可聚焦；不是把系统鼠标隐藏后模拟手动游玩。

## 原生状态机

选中角色的 `AnimationTree`，打开 `animations/locomotion.tres`：

```text
Start → Grounded [Motion Matching：Idle / Walk / Run / 左右横移 / 后退]
          ↕   ↘     ↗
        Crouch ←→ Jump → Fall
 [Motion Matching：CrouchIdle / CrouchWalk]
                    ↕
                  Climb [程序化悬挂 / 交替换手]
```

物理接地、竖直速度和实际蹲伏状态决定目标状态；直接使用原生 `AnimationNodeStateMachinePlayback.travel()`，状态间 0.12 秒混合，不等待动画结束才落地。地面动作按当前原始脚部姿态／速度、接触状态及预测未来轨迹检索候选帧，走路／跑步分别检索前后与横移片段，交给原生双槽位 TimeSeek／TimeScale／Blend2 从匹配时间播放；先按真实方向持续混合两轴，再按真实速度连续混合两种步态；不是方向到动画名的固定映射。使用碰撞解算后的实际水平速度及墙面投影后的目标，顶墙时回到待机。模型水平根位移已移除，起跳／下落的竖直轨迹也由物理独占，避免动画再次移动角色。`RESET` 保存完整骨骼静止姿态。

控制器 Inspector 可调行走／跑步／蹲行速度（默认 1.5 / 4.5 / 0.7 m/s）、加减速、转向、跳跃初速度和蹲高。站立胶囊 2.1 m、蹲伏默认 1.6 m；缩放碰撞体始终保持脚底不动，站起前用真实物理形状查询检查空间。每个角色独立保存碰撞形状与动画播放状态。足部 IK 仅调整骨架，不代替碰撞控制器跨越台阶；程序化攀爬由独立组件负责，不包含台阶自动跨越、翻上平台或翻滚。

通用信号：

- `jumped(feet_position)`：真实接地起跳一次。
- `landed(feet_position)`：离地后以大于 1 m/s 向下速度接地一次；出生接地不触发。
- `ground_moved(from_feet, to_feet, duration)`：持续接地且真实水平位移超过 0.05 m/s 时触发；静止、顶墙、空中不触发。

本包不引用雾或水体。主场景的 `scripts/fog_playground.gd` 接收这些信号并转发给雾盒；森林仍保留原独立胶囊角色。

## Motion Matching

`motion_matching/` 包含离线特征烘焙、424 帧原生检索资源、运行时检索和 IK 前姿态采样。站立时面向相机前方，A／D／S 使用新接入的 Mixamo 左横移、右横移和后退步行；四象限斜向按实际速度的前后／横移分量持续混合两种方向，45° 时各占 50%；Walk／Run 再按真实速度混合，默认 1.5／3／4.5 m/s 对应跑步权重 0／0.5／1，Shift 只改变物理目标速度；四向跑步均有独立 Mixamo 动作：Shift＋W／A／D／S 对应 Run／RunLeft／RunRight／RunBack，不再以加速步行代替横跑／后退跑。蹲行仍使用现有向前动作并向移动方向转身。主场景和 demo 右侧改为实时 Motion Matching 图示：全部数据库帧的双脚前向位置点云、真实目标 P／追踪 p 及尾迹、四通道最终混合贡献、decay 状态和数据流。图中明确标注二维姿态切片，不把二维距离当成 22 维检索成本；空中动作显示 NATIVE。demo 左侧集中调参与脚部诊断。

新增默认开启的姿态 decay：IK 前的显示姿态持续平滑跟随原生动画目标，不改变角色物理移动。选中角色子节点 `MotionMatching` → **Pose Tracking** 可开关 `pose_smoothing_enabled`、调节 `pose_half_life`（默认 0.06 s；越大越柔，0 旁路）。demo 面板也提供开关／半衰期滑条，F5 快速对比。跳跃／下落不延迟，复位／传送清除追踪历史。

采样维度、播放图、追踪公式、重建和有限动作库的边界见 [Motion Matching 说明](motion_matching/USAGE.md)。

## 脚部地面适配与锁定

`foot_placement/` 使用前置 SkeletonModifier3D 读取当前动画、左右独立 TwoBoneIK3D 定位脚踝、后置修改器修正鞋底朝向。角色显式按物理 tick 推进 AnimationTree 后再推进 Skeleton3D，避免回调顺序和上一帧 IK 污染；Motion Matching 的原始动画采样位于 FootPlacement 修改器之前。原生动画库带有左右接触曲线；Swing／Approach／Contact／Stance／Release 分别保留摆动、仅做渐进高度／朝向修正、以支撑局部速度连续减速、停稳后捕获锁点和释放锁定。前后／横移及 Walk／Run 四通道按混合周期行程向量共用步频，并按接触上升沿对齐相位，避免混合后长期半接触。平台使用局部落点，跳跃与传送会清锁；高低差时按腿部可达性平滑降低骨盆。

原动画步幅已按控制器速度校准，Inspector 改步速会同步调整原生 TimeScale。主场景自动启用，无需改扰雾连接。详细配置、限制及 demo 验证路线见 [Foot Placement 说明](foot_placement/USAGE.md)。

## 程序化攀爬

空中检测到可达且身体空间有效的攀爬区域后自动进入 `Climb`。双手先锁区域局部掌心点，由悬垂姿态和双臂可达性反推胶囊目标，再抬肩、施加程序化摇摆并执行双臂 IK。无输入时悬挂，WASD 交替换手；ESC 脱离并释放鼠标，落地前禁止在任何区域重抓，真实轻落地也会重置。支撑失效等非主动掉落仍允许重抓。

Demo 的 Tab 最后两个检查点为青色顶面／墙面；主场景也有同一验证区。区域放置、守卫标定、顺序、生命周期及限制见 [攀爬说明](climbing/USAGE.md)。

## 资源与重建

- `assets/mixamo/`：配套 FBX、贴图和 Godot 原生导入设置。
- `assets/guard.scn`：原生模型场景，移除了源 FBX 自带的动画播放器。
- `animations/mixamo.res`：原生骨骼动画及接触曲线；`animations/locomotion.tres`：外层状态机、Walk／Run 双通道及各自双槽位匹配播放图。
- `motion_matching/guard.res`：离线姿态／速度／轨迹／接触特征，只读共享。
- `foot_placement/guard.tres`：守卫鞋底与 IK 配置，运行时锁定数据不写入资源。
- `climbing/guard.tres`：守卫抬肩、掌心和悬垂约束标定；`demo/climbing_course.tscn`：区域与实体一致的墙／顶板。
- `demo/validation_course.tscn`：可在编辑器检查的碰撞地形；demo 面板可独立开关双脚、切换原始动画及调节骨盆限幅。
- `ui/motion_matching_view.gd`：主场景与 demo 共用的只读运行时图示，不控制动画或鼠标。
- [SOURCE.md](SOURCE.md)：固定来源版本、文件映射和 Mixamo 使用限制。

调整／替换源 FBX 后，先让 Godot 完成导入，再执行：

```powershell
godot --headless --path . --script res://addons/motion/tools/build_mixamo.gd
```

重建工具会重新校准步幅节奏、按 `foot_placement/guard.tres` 的鞋底标定生成接触曲线，并覆盖生成的模型、动画库、状态机和 Motion Matching 数据库；手动编辑这些生成资源前请注意。原始动作多数共享守卫骨架；Run Forward、Jog Strafe Left／Right、Jog Backward 及异骨架后退步行会按骨名／全局静止姿态重定向到守卫，横移步行也做静止姿态对齐。四个原地跑步片段沿各自动作轴投影鞋底支撑速度以估计步幅，再校准时长；不将横向／后向的零根行程当作待机。任意其他 Mixamo 角色仍不保证骨名、体型与静止姿态兼容，更换模型需要重新标定并检查重定向与接触。

## 验证

在项目根运行。常规测试默认不捕获鼠标、不主动取得焦点；控制器、脚部、攀爬及衔接测试均可 headless，匹配测试的 draw-call 检查仍需真实渲染窗口（不可聚焦）：

```powershell
godot --headless --path . --script res://addons/motion/tests/contact_transition_test.gd
godot --headless --path . --script res://addons/motion/tests/speed_blend_test.gd
godot --headless --path . --script res://addons/motion/tests/motion_character_test.gd
godot --headless --path . --script res://addons/motion/tests/foot_placement_test.gd
godot --path . --script res://addons/motion/tests/motion_matching_test.gd --max-fps 60
godot --headless --path . --script res://addons/motion/tests/climbing_test.gd
```

只有显式追加 `-- --interactive-input` 的控制器测试才会取得焦点并验证真实 F／Esc 鼠标捕获；它会影响桌面鼠标，必须由用户明确选择，不能作为常规自动化命令。主场景 `tests/fog_playground_jump_test.gd` 默认也使用无捕获输入，该标记仅用于其交互输入检查。森林旧控制器的 `tests/forest_walk_test.gd` 尚无脚本输入入口，未指定该标记时拒绝运行并返回 2，不会悄悄锁鼠标或假报通过。

控制器测试覆盖实际行走／跑步、斜向速度、骨骼动画、跳跃与低顶蹲行；足部测试从最终骨骼姿态覆盖四向落脚、世界锁定、释放、可调步速、不同踏面、曲面法线、移动平台、传送、查询失效及单腿／多实例隔离；匹配测试对照独立 AnimationPlayer 验证八种方向／步速输入的实际播放姿态、时间、朝向、停步及并发槽位隔离。追加 `-- --screenshots` 可将动作画面保存到系统临时目录。主场景 SWE / Stable Fluids 联动由 `tests/fog_playground_jump_test.gd` 验证，命令见项目[实验场指南](../../doco/guides/playground.md)。
