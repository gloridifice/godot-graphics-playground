# Motion Matching

当前是小型、可重建的地面 Motion Matching 实现，不是按 WASD 切换动画名。走路／跑步各自检索帧，再按实际水平速度连续混合两种步态。跳跃／下落仍由外层原生状态机负责，地面站立和蹲伏分别检索相应姿态标签。

## 运行

打开 `addons/motion/demo.tscn`，F6 运行、F 捕获鼠标：

- W 向前；A／D 左右横移；S 后退。站立移动面向相机前方，不随侧移／后退转身。
- Shift 加速；Ctrl 蹲行。现有蹲行动画只有向前，所以蹲行仍向移动方向转身。
- 面板显示主导动画、采样时间、播放倍率、检索成本及 Walk／Run 百分比。原有 Tab／R 地形检查点、F3／F4 足部调试与双脚开关保持不变。

`MotionCharacter.motion_matching` 提供运行时诊断；`get_debug_state()` 返回主导片段、时间、倍率、成本、混合状态、`walk`／`run` 两通道状态、`run_blend` 及三个预测轨迹偏移；中间速度的最终姿态并不等于单个主导片段。显式复位可调用 `reset()`；角色会自动检测超过 1 m 的单 tick 传送。配置资源只读共享，播放状态和可变 AnimationTree 节点每角色独立。

## 数据与检索

`guard.res` 当前有 399 个候选帧，来自 Idle、Walk、Run、StrafeLeft、StrafeRight、WalkBack、CrouchIdle、CrouchWalk。按约 30 Hz 离线采样，每段最多 180 帧，待机最多 120 帧，避免长待机片段挤占搜索。采样的是最终统一到守卫骨架、去掉水平根运动、校准时长后的动画。

每个候选含 22 维特征：双脚模型空间位置 6、速度 6、根水平速度 2、0.2／0.4／0.6 秒后的根水平偏移 6、左右接触值 2。模型 +Z 是前方，+X 是角色左侧。当前片段均为直线循环步态，库内根速度取原始根行程的平均值，未来偏移按直线速度生成；没有虚构转弯轨迹数据。

站立时 Walk／Run 两通道独立检索。Walk 通道只允许待机／步行，Run 通道优先跑步但允许缺少跑步素材的侧向／后向以加速步行回退；达到步速后不会在速度混合层内掺入待机。运行时用碰撞解算后的相对平台速度、输入目标、加减速预测未来轨迹，墙面会先把目标投影到可移动切线。位姿来自排在 IK 之前的 `MotionPoseSample`，不会把锁脚后的姿态反馈进检索。默认每 0.1 秒穷举兼容姿态标签的所有帧，使用逐维标准差归一化的加权距离；延续当前帧与其他候选共同竞争，跳转需要超过连续性余量，并等待上一次交叉混合完成。步态偏好是成本项，不是方向到片段的硬编码映射。

播放使用原生节点：

```text
Grounded:
  Walk [A/B 匹配槽位] ┐
                      Speed (Blend2) → output
  Run  [A/B 匹配槽位] ┘

每通道（以及 Crouch）：
  AClip → ASeek → ARate ┐
                        Mix → output
  BClip → BSeek → BRate ┘
```

`Speed` 使用碰撞解算后、扣除平台运输的真实水平速度：低于步速时纯 Walk，步速至跑速之间线性混合，达到跑速时纯 Run。默认 1.5／2.25／3 m/s 分别对应跑步权重 0／0.5／1；按 Shift 只改变物理目标速度，不直接切动画权重，加速和减速均依照实际速度。阈值使用角色 Inspector 中的 walk_speed／run_speed。两个通道和其内部槽位均启用原生 sync，零权重通道也继续播放，避免进入混合时恢复过期帧。

Walk／Run 的循环时钟还需与接触相位一致：从库内左脚接触上升沿估计各片段相位原点，根据两片段标准周期行程与混合权重计算共同步频，保持加权平均速度对应实际移动；按主导通道对齐另一通道的支撑相位，必要时通过原有 A/B 交叉混合校正，不能直接跳转可见的活动槽位。否则两种步态频率漂移，会把接触曲线平均成长期半接触，令 Foot Lock 无法完成落地减速。这里只调整播放速率／相位，不修改骨骼步幅或驱动根位移。

匹配可从片段的任意候选时间开始，不总从第零帧播放。两个槽位默认用 0.12 秒交叉混合；接触曲线随骨骼一起混合。Native TimeScale 同步 Inspector 里的步速，动画不驱动 CharacterBody3D 位移。

完整物理顺序：碰撞移动 → 检索／更新槽位 → `AnimationTree.advance()` → `Skeleton3D.advance()`（原动画采样 → Foot Placement → 两腿 IK → 脚掌旋转）。足部锁定不是另一个动画播放器，也不会被每次匹配强制重置。

## 重建与边界

`tools/build_mixamo.gd` 一次重建模型、动画库、原生播放图和检索库：

```powershell
godot --headless --path . --editor --import
godot --headless --path . --script res://addons/motion/tools/build_mixamo.gd
```

向前 Run 使用用户提供的 `Run Forward.fbx`；左右横移来自原守卫资源仓库，后退来自另一套 Mixamo 骨架。重建时按骨名和全局静止姿态旋转映射到守卫骨架，保留目标骨长、按髋高比例转换根轨迹，再统一生成接触曲线和特征。不是直接复制异骨架局部旋转。用户 Run 为原地动画，重建从支撑区鞋底后移速度估计步幅，库内按标准 6 m/s 标定周期约 0.468 s，运行默认 3 m/s 时以 0.5 倍率播放；检索仍使用对应的前向速度／轨迹，而非把零根行程误认为待机。来源及固定提交见 [SOURCE](../SOURCE.md)。

当前新增的是**左右横移步行、后退步行**。没有独立的横向／后退跑步资源，Shift 时这些步行会加快播速，而前向使用真实 Run。没有专门的起停、急转、斜向、旋转轨迹或蹲伏侧移动作；斜向从现有候选检索最近步态，不能等同于完整八向动作库。没有 Stride Warping、根运动驱动、全身惯性化或大规模数据库索引；有限数据与交叉混合仍可能在急转／斜向出现滑步，原有 Foot Lock 负责支撑期约束。

验证命令：

```powershell
godot --headless --path . --script res://addons/motion/tests/speed_blend_test.gd
godot --path . --script res://addons/motion/tests/motion_matching_test.gd --max-fps 60
godot --path . --script res://addons/motion/tests/foot_placement_test.gd --max-fps 60
```

无窗口的 speed_blend_test 按角色当前步速／跑速配置验证端点及 25%／50%／75% 中间混合权重、目标速度与实际速度不一致时的混合，并用独立 AnimationPlayer 对照端点和中间原生骨骼，防止只更新权重文字却没有真正混合。匹配测试通过真实输入覆盖前／左／右／后及 Shift，并用独立 AnimationPlayer 对照最终骨骼，验证匹配结果确实播放到相应时间，而非只更新诊断字符串；还验证墙前停步和双实例并发槽位隔离。后者增加左右／后退的真实支撑、摆动、释放和世界空间锁脚验证。需要有焦点的图形窗口；可追加 `-- --screenshots` 保存截图到临时目录。
