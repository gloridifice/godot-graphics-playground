# Godot 4.6：Foot Placement + Foot Lock 设计案

-   **状态**：设计案
-   **建议实现语言**：GDScript
-   **适用对象**：具有标准双足骨骼、行走/奔跑动画的第三人称角色
-   **文档范围**：运行时脚部地面适配、支撑期脚部锁定，以及与 Godot 原生
    IK 修改器的集成

------------------------------------------------------------------------

## 1. 背景与目标

角色动画通常在动画资源中预先定义脚部轨迹。当地面高度、坡度或台阶与动画制作时的假设不一致时，容易出现：

-   脚掌悬空或穿入地面；
-   脚掌与坡面角度不一致；
-   支撑期脚掌随角色根节点移动，产生滑步；
-   左右脚处于不同高度时，腿部伸展异常；
-   IK 在脚尚处于摆动阶段时过早介入，破坏原始迈步轨迹。

本系统在动画求值之后执行脚部适配。它读取动画产生的脚部姿态，通过地面查询生成目标，再使用
IK 修改腿部骨骼。

### 1.1 设计目标

1.  在摆动末期检测脚下地面，让脚掌平滑接近地面。
2.  在支撑期锁定脚掌的世界空间位置，避免脚掌滑动。
3.  根据地面法线修正脚掌朝向。
4.  左右脚独立运行状态机和 IK 权重。
5.  允许动画继续播放，IK 只在需要时修正腿部姿态。
6.  将地面查询、接触状态、目标生成和 IK 求解分层，方便扩展。

### 1.2 非目标

首个版本不负责：

-   自动生成或重定向行走动画；
-   全身动力学、质心控制或物理步态规划；
-   自动选择下一步落脚点；
-   完整的 Motion Matching、Stride Warping 或 Motion Warping；
-   手部、身体、头部等其它部位的通用 IK；
-   多足动物的足端规划。

------------------------------------------------------------------------

## 2. 核心设计原则

系统按脚部所处的步态阶段使用不同的目标更新策略。

  阶段               目标位置来源                 水平位置是否跟随动画 IK 作用
  ------------------ -------------------------- ---------------------- ----------
  Swing（摆动）      原始动画                                       是 通常关闭
  Approach（接近）   动画脚位置投影到地面                           是 渐进增强
  Stance（支撑）     捕获的锁定位置                                 否 保持有效
  Release（释放）    从锁定目标过渡回动画目标                 逐渐恢复 渐进减弱

最重要的边界：

-   **Approach**：脚仍在完成向前迈步。目标的水平位置跟随动画脚，系统主要修正垂直距离和脚掌朝向。
-   **Stance**：脚掌已经落地。系统捕获一次世界空间落点，后续保持该落点，不再跟随动画脚的水平移动。
-   **Release**：脚准备离地。系统解除锁定，将控制权平滑交还给原始动画。

不能仅凭 Raycast 命中就进入 Stance。摆动期间，射线可能提前命中地面。

------------------------------------------------------------------------

## 3. Godot 原生能力与项目职责边界

### 3.1 引擎原生能力

Godot 4.6 的骨骼修改器体系可用于构建该功能：

-   `Skeleton3D`：持有骨骼及最终姿态。
-   `SkeletonModifier3D`：在动画姿态求值之后执行骨骼修改。
-   `IKModifier3D`：IK 修改器基础类型。
-   `TwoBoneIK3D`：求解由根骨、中间骨和末端骨构成的两段骨骼链。
-   `Node3D`：可作为脚部 IK Target、膝盖 Pole/Hint 的空间目标节点。
-   `PhysicsDirectSpaceState3D` / `RayCast3D`：提供地面查询能力。

### 3.2 项目自定义能力

Godot 不直接提供完整的自动 Foot Placement / Foot Lock
工作流。以下逻辑由项目实现：

-   左右脚的地面射线发射策略；
-   脚底距离和脚踝偏移换算；
-   地面目标位置与朝向计算；
-   Approach、Stance、Release 状态机；
-   支撑期锁定位置的捕获、维护和释放；
-   根据距离、动画曲线和状态计算混合权重；
-   骨盆高度补偿；
-   调试绘制、参数配置和异常恢复。

### 3.3 混合职责

优先让 `TwoBoneIK3D` 的修改器影响权重承担 IK
姿态与动画姿态的整体混合。若项目需要左右腿不同权重、脚掌旋转独立权重或更复杂的局部混合，应在确认引擎修改器的实际混合行为后，选择以下一种实现：

1.  左右腿分别使用独立 IK Modifier；
2.  使用自定义 `SkeletonModifier3D`，在单个修改器中处理双腿；
3.  在自定义修改器中读取动画姿态、求解
    IK，并按每条腿的权重混合骨骼姿态。

不要同时对同一条骨骼链叠加多个互相竞争的 IK 修改器。

------------------------------------------------------------------------

## 4. 节点与模块结构

建议把控制逻辑与骨骼求解节点分开。下面是逻辑结构示意，实际场景树可根据角色预制体调整：

``` text
CharacterBody3D
├── VisualRoot
│   └── Skeleton3D
│       ├── LeftFootTarget        (Node3D)
│       ├── LeftKneePole          (Node3D)
│       ├── LeftLegIK              (TwoBoneIK3D)
│       ├── RightFootTarget       (Node3D)
│       ├── RightKneePole         (Node3D)
│       └── RightLegIK             (TwoBoneIK3D)
└── FootPlacementController
```

`FootPlacementController`
是逻辑模块，不要求必须作为物理射线节点的父节点。若使用
`PhysicsDirectSpaceState3D`，也可以不创建常驻 `RayCast3D` 节点。

### 4.1 模块职责

  模块                      职责
  ------------------------- --------------------------------------------
  FootPlacementController   驱动左右脚更新、管理全局配置
  FootGroundQuery           根据动画脚姿态执行地面查询
  FootTargetSolver          计算地面目标位置、脚底偏移和朝向
  FootStateMachine          管理单只脚的步态状态
  FootLock                  捕获、维护、释放世界空间锁定变换
  FootIKDriver              更新 IK Target、Pole/Hint 和 Modifier 权重
  PelvisSolver（后续）      根据双脚可达性调整骨盆

每只脚持有独立的
`FootRuntimeState`。左右脚共享配置，但不共享运行时状态。

------------------------------------------------------------------------

## 5. 数据结构

以下为概念结构，字段类型可按 GDScript 或 C# 实际实现调整。

``` text
FootPlacementConfig
    ray_start_height
    ray_length
    sole_offset
    contact_distance
    full_ik_distance
    approach_blend_speed
    release_blend_speed
    max_foot_pitch
    max_foot_roll
    ground_collision_mask
    max_lock_error
    lock_break_distance

FootRuntimeState
    phase
    ik_weight
    distance_weight
    animation_contact_weight

    animated_foot_transform
    ground_hit_position
    ground_hit_normal
    has_ground_hit

    placement_target
    lock_transform
    is_locked

    previous_animated_foot_transform
    vertical_velocity
    debug_flags
```

状态枚举：

``` text
FootPhase
    SWING
    APPROACH
    STANCE
    RELEASE
```

建议将配置资源化，例如通过 `Resource`
保存角色通用参数；每只脚的锁定坐标、当前权重和状态必须保存在运行时实例中，不能放在共享配置资源里。

------------------------------------------------------------------------

## 6. 地面查询与目标计算

### 6.1 查询起点

每帧从**动画求值后的脚部姿态**获取脚掌参考点。根据角色重力方向向下发射射线。

对于常规直立角色：

``` text
ray_origin = animated_foot_position + up * ray_start_height
ray_end    = ray_origin - up * ray_length
```

其中 `up` 应取角色使用的重力上方向。若项目只支持世界 Y
轴向上，可以直接使用 `Vector3.UP`。

射线应排除角色自身碰撞体，并使用专用碰撞层过滤可行走地面。

### 6.2 脚底距离

不要直接把脚踝到碰撞点的距离当作脚底间隙。脚踝与鞋底之间存在模型相关偏移。

最小实现可以定义：

``` text
sole_point = animated_foot_transform * local_sole_offset
distance   = dot(sole_point - hit_position, ground_normal)
```

如果使用垂直射线，垂直距离也可以作为初版近似；对于坡面，更推荐沿地面法线计算有符号距离。

需要注意：`local_sole_offset` 必须根据模型的骨骼朝向和脚掌局部坐标校准。

### 6.3 Approach 目标

Approach
阶段需要保留迈步的水平轨迹。目标位置由当前动画脚的位置投影到地面得到：

``` text
projected_sole = project animated sole point onto detected ground
target_ankle  = projected_sole - ground_normal * sole_offset
```

工程实现中应明确 `sole_offset`
的方向和单位，避免把脚踝目标错误地放到地面以下。

目标的水平位置随动画脚每帧更新。不要在 Approach
阶段提前锁定脚的世界坐标。

### 6.4 脚掌朝向

初版使用地面法线修正脚掌的俯仰和横滚，同时尽量保留动画提供的朝前方向：

1.  从动画脚姿态获取脚掌 forward 方向；
2.  将 forward 投影到地面切平面；
3.  用地面法线作为脚掌 up 方向；
4.  由正交化后的 forward/up 构造目标旋转；
5.  限制最大 pitch/roll，过滤墙面、悬崖侧面等异常法线。

不要直接将脚掌完整旋转到法线方向并丢弃动画的朝前方向，否则脚可能在坡面上突然扭转。

------------------------------------------------------------------------

## 7. 混合权重设计

权重至少区分三种来源：

-   `distance_weight`：脚底与地面的距离决定的权重；
-   `animation_contact_weight`：动画曲线或步态事件提供的接触意图；
-   `phase_weight`：状态机阶段允许的 IK 权重。

基础距离权重：

``` text
distance_weight =
    1 - smoothstep(full_ik_distance,
                   contact_distance,
                   foot_ground_distance)
```

其中 `full_ik_distance` 小于 `contact_distance`。距离越近，权重越高。

建议的组合：

``` text
approach_weight =
    distance_weight * animation_contact_weight

final_weight =
    phase_weight * approach_weight
```

Stance 阶段应将 `phase_weight` 保持为 1，并由状态机维持锁定目标。Release
阶段对权重进行平滑衰减。

### 7.1 没有动画曲线时

可以先根据脚部垂直速度、脚底距离和步态时间估计接触：

-   脚正在下降；
-   脚底距离低于阈值；
-   动画处于摆动末期。

但脚部速度和距离只能作为近似。长期方案优先使用动画曲线或明确的步态事件。

### 7.2 权重平滑

权重变化应使用基于 `delta`
的插值或弹簧模型，避免帧率变化导致不同的过渡速度。

``` text
weight = move_toward(
    weight,
    target_weight,
    blend_speed * delta
)
```

Approach 和 Release
可以使用不同速度。不要在每帧无条件把权重直接设置为距离公式结果，否则射线抖动可能导致权重抖动。

------------------------------------------------------------------------

## 8. Foot Lock 状态机

### 8.1 Swing

行为：

-   原始动画主导脚部运动；
-   不捕获锁定位置；
-   通常 IK 权重为 0；
-   可以继续执行射线查询，为 Approach 预热地面信息。

进入条件：脚从 Release 完成离地，或动画步态事件标记脚进入摆动期。

### 8.2 Approach

行为：

-   每帧读取动画脚位置；
-   每帧更新地面查询；
-   以动画脚水平位置为基础投影到地面；
-   根据距离和接触曲线增加 IK 权重；
-   脚仍然可以向前移动。

进入条件：脚进入摆动末期，且检测到有效可行走地面。

进入 Stance 的条件建议同时考虑：

-   存在有效地面命中；
-   脚底距离小于接触阈值；
-   脚部垂直速度接近零或仍在下降；
-   动画接触曲线超过阈值，或收到明确的落地事件。

不能只以 Raycast 命中作为落地条件。

### 8.3 Stance

进入时只执行一次捕获：

``` text
lock_transform = current_foot_world_transform
is_locked = true
```

之后每帧：

``` text
ik_target = lock_transform
ik_weight = stance_weight
```

关键要求：

-   锁定坐标使用世界空间，避免角色根节点移动时锁定点跟着角色移动；
-   不能每帧重新捕获锁定位置；
-   锁定目标应包含位置和旋转；
-   若地面是移动平台，需要记录平台局部空间锁定变换，并每帧转换回世界空间；
-   角色瞬移、传送或发生大幅根节点重定位时，应主动清除锁定状态。

### 8.4 Release

进入条件：动画曲线、脚跟抬起事件或步态状态表明脚即将离地。

行为：

1.  将锁定目标与当前动画目标之间进行平滑过渡；
2.  逐渐降低 IK 权重；
3.  解除 `is_locked`；
4.  完成后进入 Swing。

Release
不应在脚仍明显承重时突然解除锁定。若动画没有明确事件，可以用脚部上升速度和动画接触曲线共同判断。

------------------------------------------------------------------------

## 9. Stance 中的目标空间与移动平台

### 9.1 静态地面

捕获世界空间脚掌变换：

``` text
lock_world = foot_world_transform
```

角色继续移动时，IK 仍然将脚保持在 `lock_world`。

### 9.2 移动平台

如果角色站在移动平台上，直接锁定世界空间位置会导致平台移动后脚留在原地。

推荐捕获：

``` text
lock_platform_local =
    platform_global_transform.affine_inverse()
    * foot_world_transform
```

每帧更新：

``` text
lock_world =
    platform_global_transform
    * lock_platform_local
```

如果平台失效、离开场景或无法继续识别，应按项目策略解除锁定或退回静态世界空间目标。

------------------------------------------------------------------------

## 10. IK 求解与骨盆补偿

### 10.1 Two-Bone IK

每条腿使用独立的两骨 IK 链：

``` text
Hip -> Knee -> Ankle
```

输入包括：

-   脚踝目标位置；
-   膝盖 Pole/Hint 位置；
-   大腿和小腿骨骼链；
-   IK 权重。

Pole/Hint
应根据角色朝向和动画膝盖弯曲方向初始化。不要只用一个固定世界坐标方向，否则角色转身时膝盖可能翻转。

### 10.2 骨盆补偿（后续阶段）

左右脚目标高度不一致时，单独移动脚踝目标可能导致一条腿过度伸展。

后续增加 `PelvisSolver`：

1.  计算左右髋关节到脚目标的距离；
2.  与大腿、小腿长度及可达范围比较；
3.  估算需要的骨盆高度偏移；
4.  限制最大偏移；
5.  对偏移进行阻尼和平滑；
6.  在应用最终腿部 IK 前更新骨盆姿态。

第一版可以暂不实现 Pelvis
Adjustment，但应预留接口。不要在缺少可达性验证时直接取左右脚高度差作为骨盆偏移。

### 10.3 脚掌旋转与腿部 IK 的顺序

建议先计算脚掌目标变换，再更新 IK Target。确认 `TwoBoneIK3D`
的末端旋转能力和当前版本属性后，再决定由 IK
修改器承担脚踝旋转，或由独立骨骼修改逻辑补充脚掌旋转。

------------------------------------------------------------------------

## 11. 每帧执行顺序

逻辑顺序如下：

``` text
AnimationMixer evaluates animation
        |
        v
Read animated foot transforms
        |
        v
Ground query for left/right feet
        |
        v
Calculate sole distance and ground normal
        |
        v
Update each foot state machine
        |
        +--> Swing: follow animation
        |
        +--> Approach: update projected ground target
        |
        +--> Stance: maintain captured lock transform
        |
        +--> Release: blend back to animation
        |
        v
Calculate IK targets and per-foot weights
        |
        v
Update IK Target / Pole nodes
        |
        v
Apply SkeletonModifier / TwoBoneIK3D
        |
        v
Final skeleton pose
```

必须保证控制器读取的是动画求值后的脚部姿态，并且 IK
修改器在目标更新之后执行。若控制器与修改器的回调顺序不确定，应显式安排处理优先级或将目标更新逻辑放入适当的骨骼修改阶段。

物理查询应使用一致的物理帧数据。若动画更新频率与物理帧不同，需要明确查询时机，避免同一帧读取不一致的角色变换。

------------------------------------------------------------------------

## 12. 边界情况与降级策略

  情况                 处理策略
  -------------------- ---------------------------------------------------------
  射线未命中           不创建新地面目标；按状态平滑降低 IK，避免沿用过期命中点
  命中墙面或过陡坡面   根据法线与角色 Up 的夹角过滤
  脚掌位于地面以下     限制最大修正量，避免 IK 突然弹出
  射线命中自身         排除角色 RID 或碰撞层
  两脚目标不可达       限制 IK 目标距离，后续由 PelvisSolver 补偿
  角色瞬移/传送        清除两脚锁定并重置状态
  动画中断或切换       根据新动画的接触曲线重建状态，必要时清锁
  角色转向             世界空间锁定保持原位；Pole/Hint 随角色局部方向更新
  移动平台             使用平台局部空间锁定
  地面法线突变         对法线和脚掌旋转进行角度限制与平滑
  帧率波动             所有平滑过程使用 `delta` 或固定物理时间步

当射线丢失时，不应继续无限期保持一个过期的 Stance
锁定点。需要结合当前接触状态和地面有效性决定短暂容错或解除锁定。

------------------------------------------------------------------------

## 13. 调试与可视化

建议提供可开关的 Foot IK Debug：

-   绘制左右脚射线；
-   绘制 Raycast 命中点和地面法线；
-   绘制动画脚位置；
-   绘制 Approach 投影目标；
-   绘制 Foot Lock 目标；
-   用不同颜色区分 Swing / Approach / Stance / Release；
-   在屏幕上显示左右脚的
    `distance_weight`、`animation_contact_weight`、`ik_weight`；
-   绘制髋、膝、踝三点和 IK 目标连线；
-   显示脚目标是否超出腿部可达范围。

调试模式应能单独关闭左脚或右脚 IK，以便比较原始动画与修正结果。

------------------------------------------------------------------------

## 14. 参数初值建议

以下仅作为初始调参范围，最终值应根据角色模型尺寸、动画速度和地面尺度确定。

  参数                         建议初值 说明
  ------------------------ ------------ -----------------------------
  `ray_start_height`             0.25 m 从脚部参考点上方开始查询
  `ray_length`                   0.60 m 最大查询距离
  `contact_distance`             0.15 m Approach 开始明显介入的距离
  `full_ik_distance`             0.02 m 接近地面时达到完整权重
  `sole_offset`              按模型标定 脚踝/参考点到鞋底的偏移
  `approach_blend_speed`            8.0 Approach 权重渐变速度
  `release_blend_speed`            10.0 Release 权重渐变速度
  `max_foot_pitch`                  35° 限制脚掌俯仰
  `max_foot_roll`                   25° 限制脚掌横滚

所有距离参数都应按项目世界单位理解。若项目使用厘米或其它尺度，应统一换算，不能直接照搬上述米制数值。

------------------------------------------------------------------------

## 15. 实施阶段

### Phase 1：基础 Foot Placement

-   [ ] 为左右脚读取动画求值后的脚部姿态；
-   [ ] 实现左右脚独立 Raycast；
-   [ ] 计算脚底距离、地面目标位置和法线；
-   [ ] 接入 `TwoBoneIK3D`；
-   [ ] 实现 IK 权重渐变；
-   [ ] 确保脚在 Approach 阶段继续沿动画轨迹向前移动。

**验收：**

-   平地行走时脚掌不会明显悬空或穿地；
-   IK 介入过程连续，没有明显弹跳；
-   摆动阶段的原始迈步轨迹基本保留；
-   左右脚可以独立开关和调节权重。

### Phase 2：Foot Lock

-   [ ] 实现 Swing / Approach / Stance / Release 状态机；
-   [ ] 使用动画曲线或步态事件识别接触阶段；
-   [ ] 在进入 Stance 时捕获一次世界空间脚掌变换；
-   [ ] Stance 期间持续使用锁定目标；
-   [ ] Release 阶段平滑解除锁定；
-   [ ] 处理射线丢失、动画中断和角色瞬移。

**验收：**

-   支撑期脚掌在世界空间基本保持静止；
-   角色根节点前进时脚不会明显向前滑动；
-   脚掌离地时不会被锁定点拖住；
-   连续行走时左右脚状态切换稳定。

### Phase 3：地形适配

-   [ ] 使用地面法线修正脚掌朝向；
-   [ ] 对坡度和法线突变进行限制；
-   [ ] 支持移动平台局部空间锁定；
-   [ ] 加入膝盖 Pole/Hint 稳定策略；
-   [ ] 加入调试绘制和运行时参数面板。

**验收：**

-   上下坡时脚掌能合理贴合地面；
-   角色转向时膝盖不会频繁翻转；
-   移动平台上脚掌能跟随平台；
-   异常地面不会导致骨骼姿态突然跳变。

### Phase 4：骨盆补偿（可选）

-   [ ] 计算双腿 IK 可达性；
-   [ ] 根据可达性计算骨盆偏移；
-   [ ] 对偏移进行限幅和阻尼；
-   [ ] 验证高低差地形上的身体姿态。

**验收：**

-   双脚处于不同高度时腿部不会明显过度伸展；
-   骨盆运动连续；
-   不会明显破坏上半身动画。

------------------------------------------------------------------------

## 16. Definition of Done（整体完成标准）

系统达到以下条件即可认为第一版完成：

1.  左右脚具有独立的运行时状态和 IK 权重。
2.  Approach 阶段使用动画脚的当前水平轨迹生成地面目标。
3.  Stance 阶段只在进入时捕获一次锁定变换。
4.  Stance 锁定使用世界空间坐标，角色移动不会带动静态地面上的锁定点。
5.  Release 阶段可以平滑解除锁定。
6.  无有效地面命中时不会继续使用长期过期的目标。
7.  IK 修改器执行顺序稳定，读取到的动画姿态与目标更新时机一致。
8.  平地连续行走、停止、转向、上下坡等测试场景没有明显脚部弹跳、穿地或滑步。
9.  调试模式能够显示射线、命中点、目标点、锁定点、状态和权重。

------------------------------------------------------------------------

## 17. 参考文档

-   Godot：`SkeletonModifier3D`
    https://docs.godotengine.org/en/4.6/classes/class_skeletonmodifier3d.html
-   Godot：`IKModifier3D`
    https://docs.godotengine.org/en/4.6/classes/class_ikmodifier3d.html
-   Godot：`TwoBoneIK3D`
    https://docs.godotengine.org/en/4.6/classes/class_twoboneik3d.html
-   Godot：`Skeleton3D`
    https://docs.godotengine.org/en/4.6/classes/class_skeleton3d.html
-   Godot：`PhysicsDirectSpaceState3D`
    https://docs.godotengine.org/en/4.6/classes/class_physicsdirectspacestate3d.html

> 说明：本文中的节点组织、状态机、数据结构和处理流程属于项目设计。Godot
> 原生 IK 节点负责骨骼链求解；完整的 Foot Placement、Foot
> Lock、地面检测和步态状态管理由项目实现。正式编码前，应以目标 Godot 4.6
> 小版本的类参考核对 `TwoBoneIK3D` 的具体属性名称和修改器求值顺序。
