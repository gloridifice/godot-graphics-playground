# Motion Matching

当前是小型、可重建的地面 Motion Matching 实现，不是按 WASD 切换动画名。走路／跑步各自检索前后轴与横移轴的帧，先按实际移动方向混合，再按实际水平速度连续混合两种步态。跳跃／下落仍由外层原生状态机负责，地面站立和蹲伏分别检索相应姿态标签。

## 运行

打开 `addons/motion/demo.tscn`，F6 运行、F 捕获鼠标：

- W 向前；A／D 左右横移；S 后退。站立移动面向相机前方，不随侧移／后退转身。
- Shift 加速：W／A／D／S 分别使用独立的 Run／RunLeft／RunRight／RunBack，左右／后退不再加速播放步行动作。Ctrl 蹲行；现有蹲行动画只有向前，所以蹲行仍向移动方向转身。
- 右侧改为实时 **Motion Matching 图示**：数据库点云、P／p 跟踪点、四通道贡献条及检索／混合／decay／IK 数据流；主雾实验场也复用此图示。
- 左侧集中调参和脚部诊断，保留 **Motion pose decay** 开关（F5）、半衰期滑条、Tab／R 地形检查点、F3／F4 足部调试及双脚开关。

`MotionCharacter.motion_matching` 提供运行时诊断；`get_debug_state()` 返回主导片段、时间、倍率、成本、混合状态、`walk`／`run` 两步态状态、`run_blend` 及三个预测轨迹偏移。另有 `pose_available`、`pose_target`／`pose_current`（Vector2，横／纵轴分别为左右脚的骨架空间 z），由 IK 前真实骨骼求值提供给图示。每种步态另含 `longitudinal`／`lateral` 的独立匹配状态及 `direction_blend`（横移权重）；斜向或中间速度的最终姿态并不等于单个主导片段。显式复位可调用 `reset()`；角色会自动检测超过 1 m 的单 tick 传送。配置资源只读共享，播放状态和可变 AnimationTree 节点每角色独立。

## 运行时图示

`ui/motion_matching_view.gd` 是只读原生 Control，主场景与 demo 共用：

- 散点取全部数据库帧的左右脚模型空间 z（特征列 2／5）；青色点云突出当前主导片段，坐标单位为米。这只是 **22 维特征的二维切片**，图上距离不等于归一化检索成本，也不代表二维 BlendSpace。
- 青色空心圈 **P** 为本 tick 原生混合后的动画目标，黄色实心点 **p** 为实际追踪后的 IK 前姿态；连线与短轨迹直观显示 decay 延迟。P 是混合姿态，不保证恰好落在某个数据库帧上。
- Walk Z／Walk X／Run Z／Run X 条形图显示方向与步态权重乘积，即四通道的最终贡献；蹲伏显示独立通道。
- Jump／Fall 显示 **NATIVE**，隐藏地面跟踪点并注明检索／decay 旁路；不把空中动作误画为 Motion Matching 检索结果。

图示只消费诊断数据，不驱动播放，不截获鼠标，也不替换内部 AnimationTree。

点云在只读数据库切换时一次投影并构建缓存 ArrayMesh：全部帧为一个背景批次，每个片段预建一个高亮批次；常态只提交背景与当前片段两个网格，不逐帧逐点调用抗锯齿圆绘制或重新三角化。圆点通过顶点透明羽化保留软边，面板样式也逐实例缓存。P／p、短迹、片段与混合贡献仍逐帧更新，保持 2/3 UI 缩放，不通过隐藏图示或降低刷新率提速。图形匹配回归对完整图示相对隐藏状态设置宽松的 **80 次额外 draw call** 预算，不用硬件相关的 FPS 阈值判定。

## 数据与检索

`guard.res` 当前有 424 个候选帧，来自 Idle、Walk、Run、StrafeLeft、StrafeRight、WalkBack、RunLeft、RunRight、RunBack、CrouchIdle、CrouchWalk。按约 30 Hz 离线采样，每段最多 180 帧，待机最多 120 帧，避免长待机片段挤占搜索。采样的是最终统一到守卫骨架、去掉水平根运动、校准时长后的动画。

每个候选含 22 维特征：双脚模型空间位置 6、速度 6、根水平速度 2、0.2／0.4／0.6 秒后的根水平偏移 6、左右接触值 2。模型 +Z 是前方，+X 是角色左侧。当前片段均为直线循环步态，库内根速度取原始根行程的平均值，未来偏移按直线速度生成；没有虚构转弯轨迹数据。

站立时 Walk／Run 各有前后、横移两个独立检索通道，按库内根速度方向限制候选，不按动画名硬编码。Walk 只允许待机／步行，Run 通过标准步速成本偏好四向真实跑步；运行时仍按数据速度与方向筛选，而不是按 WASD 或片段名硬切。达到步速后不会掺入待机。运行时用碰撞解算后的相对平台速度、输入目标、加减速预测未来轨迹，墙面会先把目标投影到可移动切线。位姿来自排在 IK 之前的 `MotionPoseSample`，不会把锁脚后的姿态反馈进检索。默认每 0.1 秒穷举兼容姿态标签的所有帧，使用逐维标准差归一化的加权距离；延续当前帧与其他候选共同竞争，跳转需要超过连续性余量，并等待上一次交叉混合完成。步态偏好是成本项，不是方向到片段的硬编码映射。

播放使用原生节点：

```text
Grounded:
  Walk     [A/B] ┐
                 WalkDirection (Blend2) ┐
  WalkSide [A/B] ┘                      │
                                        Speed (Blend2) → output
  Run      [A/B] ┐                      │
                 RunDirection (Blend2) ┘
  RunSide  [A/B] ┘

每通道（以及 Crouch）：
  AClip → ASeek → ARate ┐
                        Mix → output
  BClip → BSeek → BRate ┘
```

`WalkDirection`／`RunDirection` 使用碰撞解算后、扣除平台运输的实际速度，并转换到角色模型空间。横移权重为 `|vx| / (|vx| + |vz|)`，另一轴取其余权重；45° 左前方因此持续混合前进与左横移各 50%，不是选择其中之一。前后／左右符号同样取实际速度，停步后回到待机；输入目标只参与轨迹预测，不覆盖实际方向权重。所有通道同步混合原生接触曲线。

`Speed` 使用同一真实水平速度：低于步速时纯 Walk，步速至跑速之间线性混合，达到跑速时纯 Run。默认 1.5／3／4.5 m/s 分别对应跑步权重 0／0.5／1；按 Shift 只改变物理目标速度，不直接切动画权重，加速和减速均依照实际速度。阈值使用角色 Inspector 中的 walk_speed／run_speed。两个通道和其内部槽位均启用原生 sync，零权重通道也继续播放，避免进入混合时恢复过期帧。

前后／横移与 Walk／Run 四通道的循环时钟共用接触相位：从库内左脚接触上升沿估计各片段相位原点，将各片段标准周期的行程**向量**按方向、步态权重合成，再用实际速度除以合成行程长度计算共同步频。斜向两段垂直半步的净行程短于单段完整步幅，不能只混合行程标量。按主导通道对齐其余通道的支撑相位，必要时通过原有 A/B 交叉混合校正，不能直接跳转可见的活动槽位。否则两种步态频率漂移，会把接触曲线平均成长期半接触，令 Foot Lock 无法完成落地减速。这里只调整播放速率／相位，不修改骨骼步幅或驱动根位移。

匹配可从片段的任意候选时间开始，不总从第零帧播放。两个槽位默认用 0.12 秒交叉混合；接触曲线随骨骼一起混合。Native TimeScale 同步 Inspector 里的步速，动画不驱动 CharacterBody3D 位移。

## 姿态 decay 追踪

角色子节点 `MotionMatching` 的 Inspector → **Pose Tracking**：

- `pose_smoothing_enabled`：默认开启；关闭即恢复原生动画输出，不保留旧的追踪姿态。
- `pose_half_life`：默认 **0.06 s**，范围 0～0.3 s；0 旁路平滑。半衰期越大，跟随越柔、延迟也越明显。

原生动画每 tick 求出的目标姿态为 P，显示姿态 p 持续追踪它，权重为 `1 - 2^(-delta / half_life)`。骨骼局部位置／缩放做线性插值，旋转走最短路径球面插值；不是只在换片段时执行一次，也不平滑 CharacterBody 的位置、速度或碰撞。对固定 P，每经过一个半衰期，剩余姿态误差减半，与物理 tick 频率无关。它是持续的一阶低通，不是保留速度的全身惯性化；较大半衰期会削弱快速摆动幅度。

追踪状态逐角色独立，只应用于 Grounded／Crouch；首次求值、`reset()`／传送和重新开启时从当前动画姿态初始化，进入 Jump／Fall 时清除历史并保留原生空中动画。检索仍采样平滑前的原动画与原生接触曲线，防止显示延迟影响检索；Foot Placement 在平滑后运行，落地与支撑约束优先于视觉缓动。半衰期较大时应重新检查落脚和锁定时长。

完整物理顺序：碰撞移动 → 检索／更新槽位 → `AnimationTree.advance()` → `Skeleton3D.advance()`（原动画采样 → 可选姿态 decay → Foot Placement → 两腿 IK → 脚掌旋转）。平滑历史只保存 IK 前姿态，不能反馈上一帧锁脚结果；足部锁定不会被每次匹配强制重置。

## 重建与边界

`tools/build_mixamo.gd` 一次重建模型、动画库、原生播放图和检索库：

```powershell
godot --headless --path . --editor --import
godot --headless --path . --script res://addons/motion/tools/build_mixamo.gd
```

四向跑步分别使用本机已下载的 Mixamo `Run Forward.fbx`、`Jog Strafe Left.fbx`、`Jog Strafe Right.fbx`、`Jog Backward.fbx`；横移步行来自原守卫资源仓库，后退步行来自另一套 Mixamo 骨架。重建时按骨名和全局静止姿态旋转映射到守卫骨架，保留目标骨长、按髋高比例转换根轨迹，再统一生成接触曲线和特征；不是直接复制异骨架局部旋转。

四个跑步片段均为原地动画，重建沿各自模型空间动作轴（前 +Z、左 +X、右 −X、后 −Z）投影支撑区鞋底反向速度来估计步幅。库内统一按 6 m/s 标定，Run／RunLeft／RunRight／RunBack 周期约 0.468／0.296／0.245／0.258 s，运行默认 4.5 m/s 时纯轴向以 0.75 倍率播放。方向元数据仅用于离线标定，运行时检索仍使用正确的方向速度／轨迹，不把原地横跑／后退跑误认为待机。来源、文件映射与 SHA-256 见 [SOURCE](../SOURCE.md)。

当前四个正交方向都具有独立步行与跑步动作。没有专门的起停、急转、斜向、旋转轨迹或蹲伏侧移动作；斜跑由对应的前／后跑与左右横跑持续混合，不能等同于完整八向动作库。没有 Stride Warping、根运动驱动、保留速度的全身惯性化或大规模数据库索引；有限数据、交叉混合与姿态追踪仍可能在急转／斜向出现滑步。原有 Foot Lock 负责支撑期约束。

已知脚部限制：全速前跑和斜后方全速跑的双脚静止支撑仍不足，`foot_placement_test`／`contact_transition_test` 的对应支撑断言尚未通过；动作匹配与骨骼混合验证不能替代锁脚验证。

验证命令：

```powershell
godot --headless --path . --script res://addons/motion/tests/speed_blend_test.gd
godot --path . --script res://addons/motion/tests/motion_matching_test.gd --max-fps 60
godot --path . --script res://addons/motion/tests/foot_placement_test.gd --max-fps 60
```

无窗口的 speed_blend_test 另从原生修改器完成回调读取真正的显示骨骼，验证 30／60／120 Hz 下的姿态半衰期、关闭／零半衰期／复位／空中旁路；原有精确混合对照关闭姿态追踪，以区分动画目标 P 与显示姿态 p。测试按角色当前步速／跑速配置验证端点及 25%／50%／75% 中间混合权重、目标速度与实际速度不一致时的混合，并用独立 AnimationPlayer 对照端点和中间原生骨骼，防止只更新权重文字却没有真正混合。同一测试还覆盖四象限 20°／45°／70° 及步行／跑步的真实方向混合，以独立 AnimationPlayer 骨骼和原生 RESET 相对旋转混合规则对照，并检查目标方向与实际方向不一致的情形。contact_transition_test 另验证斜向及方向／速度同时混合时，最终 IK 鞋底仍有双脚静止支撑。匹配测试通过真实输入覆盖前／左／右／后及 Shift，并用独立 AnimationPlayer 对照最终骨骼，验证匹配结果确实播放到相应时间，而非只更新诊断字符串；还验证墙前停步和双实例并发槽位隔离。后者增加左右／后退的真实支撑、摆动、释放和世界空间锁脚验证。匹配测试的 draw-call 检查需要真实渲染窗口，但窗口不可聚焦、输入通过角色脚本入口发送，不捕获鼠标；可追加 `-- --screenshots` 保存截图到临时目录。
