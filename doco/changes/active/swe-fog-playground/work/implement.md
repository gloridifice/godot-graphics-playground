# Implementation design

## 1. Baseline and goals

### 已有事实

- 当前 `project.godot` 标识 Godot 4.7、Forward+、Windows D3D12 和 Jolt Physics，没有配置主场景键（run/main_scene）。
- 当前仅有配置、默认图标和 doco 基础设施；没有玩家脚本、场景、相机插件、高度场、计算着色器或运行验证。
- [当前架构](../../../../architecture.md)尚是未记录架构的初始说明，没有可继承的当前规格或有效 ADR。创建阶段不将目标覆盖到当前架构。
- 本变更只创建文档。本文列出的文件、类型、方法和默认值均为拟议实现，不是现有 API。

### 目标与参考入口

需求分别见[实验场](specs/playground.md)、[高度场](specs/terrain-bake.md)、[雾场](specs/fog-field.md)。先交付可观察的平面第三人称场景，再接入雾场；数值夹具不改变主场景的平面定位。

外部只读参考位置（不是本变更的本地文档链接）：

```text
G:\MyProjects\Rust\water-simulation
```

| 参考文件 | 借鉴内容与排除项 |
| --- | --- |
| src/bin/terrain_bake.rs | 离线工具边界；不复用硬编码资源路径或 `.sweh` 兼容约定 |
| src/ocean/scene/terrain.rs | XZ 三角形投影、浮点高度、覆盖/版本/来源检查；不直接继承海底 fallback |
| src/ocean/simulation/nearshore/shaders/shore_compute.wgsl | 静水重构、Rusanov、受限 MUSCL、SSP-RK2；去除 FFT、泡沫、Manning 摩擦及水体阈值 |
| src/ocean/simulation/nearshore/mod.rs | 子步和多缓冲调度思路；不引入 wgpu 运行时或原有 12 m/s CFL 上限 |

参考仓库未提供项目级许可证；算法可独立实现，若需要逐段复制源码，先明确授权和署名条件。不复制其美术资源。

## 2. Overall approach

### 拟议目录与职责

```text
scenes/fog_playground.tscn          主场景、地面、照明、边界、诊断 UI
scenes/player.tscn                  胶囊角色与相机目标点
scripts/player/player_controller.gd 物理移动，不依赖雾或相机插件类型
scripts/camera/third_person_rig.gd  相机输入/跟随接口，隔离插件或原生回退
shaders/grid_ground.gdshader        米制抗锯齿网格材质
addons/phantom_camera/              执行时固定版本的第三方插件（保留许可）
addons/fog_terrain_baker/           编辑器入口与静态几何烘焙
scripts/fog/fog_terrain_data.gd     高度场 Resource 与验证
scripts/fog/fog_settings.gd         有单位的参数、范围及默认值
scripts/fog/fog_field_3d.gd         主线程生命周期、配置/暂停/重置/诊断接口
scripts/fog/fog_simulation_rd.gd    渲染线程资源、计算调度和状态发布
shaders/fog/                        初始化、SWE、源项、步长、发布和 fog shader
assets/fog/playground_terrain.res   显式烘焙的版本化二进制资源
```

脚本调度用 GDScript，GPU 数值工作用 GLSL compute，不新增 C#/Rust/GDExtension 依赖。最终文件拆分可小幅调整，但不把求解器、烘焙器和角色控制混入单一场景脚本。

### 依赖与数据流

```text
选定静态几何 → 编辑器烘焙器 → FogTerrainData（持久资产）
                                      ↓
FogSettings → FogField3D → 渲染线程 FogSimulationRD
                                      ↓
                         高度场 + h/qx/qz/m 状态
                                      ↓
                          稳定发布纹理 / Texture2DRD
                                      ↓
                           FogVolume 自定义 fog shader
                                      ↓
                            Godot 原生体积渲染

玩家输入 → PlayerController → CharacterBody3D + 相机目标点
鼠标输入 → ThirdPersonRig → PhantomCamera3D → Camera3D
```

玩家与相机不依赖求解器。玩家不进入烘焙分组，也不回写雾状态。调试 UI 只调用 FogField3D 的公共接口。

## 3. APIs and data model

### 拟议接口与所有权

- `FogTerrainBaker.bake(root, settings) -> FogBakeResult`：离线同步操作，返回资源或明确的错误码/说明；在全部验证通过后保存。烘焙进度、失败和重烘焙提示由编辑器工具负责。
- `FogTerrainData.validate() -> Error`：验证格式、长度、有限值及几何范围；来源摘要另与加载场景的一次性摘要比较。
- `FogField3D.initialize(data, settings) -> void`：主线程验证并异步请求渲染线程建立资源；完成后发出 `initialized`，失败发出 `failed(message)`，不能用立即返回值伪装 GPU 初始化成功。
- `set_paused(paused)`、`reset_field()`、`set_wind(velocity_xz, response_seconds)`、`set_debug_view(view)`：运行控制。风/消散/显示参数直接配置可实时生效；UI 所有数字改值后立即调用 reset_field，按用户新增交互要求实时重放初态，开关不重置。区域/分辨率变化必须给出匹配资产并重建。
- `request_diagnostics()`：仅调试时请求异步快照，通过信号返回累计模拟时间、质量收支、有效子步及可用 GPU 耗时；不成为正常推进所必需的每帧同步步骤。
- `ThirdPersonRig.get_movement_basis() -> Basis`：提供水平移动方向；插件细节不泄漏给玩家控制器。相机适配器持有唯一激活实现。

FogField3D 拥有运行实例、配置快照、发布纹理包装和状态机：uninitialized → initializing → running 或 paused，失败进入 `failed`，退出进入 `disposed`。初始化/重置使用递增 generation，过期回调不能发布已经释放的资源。

### 数据格式

- 高度资源 v1：世界 XZ 原点、范围、`Vector2i` 分辨率、独立 X/Z 格距、`PackedFloat32Array` 高度、有效字节数组、X/Z 面通行数组，以及来源清单/摘要。X 面数组为 `(Nx+1)*Nz`，Z 面数组为 `Nx*(Nz+1)`，共享面只保存一次。
- 单元中心坐标：`origin + (index + 0.5) * spacing`；世界到纹理映射使用同一公式。当前版本要求轴对齐世界网格，FogField 节点不得额外旋转/缩放网格。
- 模拟状态 `RGBA32F = (h, qx, qz, m)`，保留当前/候选两份完整状态、源项半步中间状态和 RK 预测状态，共四份；首版不降到 FP16。拒绝候选时当前状态不变，接受后由 GPU 控制标记切换当前/候选角色，无需 CPU 回读选择结果。
- 静态高度上传为线性浮点纹理，有效/通行信息独立保存；求解器使用精确格点读取，不让双线性采样混合障碍。
- 稳定发布纹理保存 `(h, m, ux, uz)`，由每次完成推进后的发布 pass 写入。材质另采样高度与有效信息，不直接绑定随子步交换的状态角色。
- 小型 GPU 控制缓冲保存剩余模拟时间、当前子步 dt、累计实际推进、CFL 最大速率及预算告警；面通量和正性限制使用独立临时缓冲。

### 生命周期与兼容

所有 RD 资源的创建、计算、屏障与释放在主 RenderingDevice 的渲染线程完成，通过 `RenderingServer.call_on_render_thread` 排队，不使用与场景材质隔离的 local device。Godot 的渲染线程调度点和 FogVolume 的消费顺序必须先由接线原型确认；允许固定一帧发布延迟，不允许读写竞争。

资源仅初始化/重建时分配；参数通过小型 uniform/control 更新。暂停保留发布结果，重置清空时间债务与动态历史；退出先解除材质引用和更新请求，再在安全时点释放 RID。重建失败保留清晰失败状态，不让旧尺寸纹理与新区域混用。不修改 D3D12 配置来掩盖兼容失败。

## 4. Algorithms and rules

### 4.1 平面场景、玩家和相机

- 用 PlaneMesh 和单个静态地面碰撞建立 64 米方形场景，四周使用边界碰撞。网格 shader 使用黄绿色草地底色，在世界 XZ 上绘制 1/5 米线，用屏幕导数抗锯齿；不使用外部纹理或图像生成资源。
- 玩家胶囊高 1.8 米、半径 0.35 米，初始中心 Y 略高于 0.9 米；以物理帧 `move_and_slide` 移动。重力取项目正常重力，水平输入按相机基向量投影至 XZ 并归一化。
- 玩家层与静态地面层分开；相机碰撞只查询静态几何，排除玩家自身。角色形状朝向对称，不引入角色动画系统。
- 使用 PhantomCamera3D Third Person Follow，Camera3D 配置 PhantomCameraHost，follow target 为玩家上身独立 Node3D。插件该模式自带 SpringArm3D 行为，不再串联第二套弹簧臂。
- 相机适配器只提交目标和环绕角度，不同时直接覆盖 Camera3D transform。初始距离约 4 米，语义俯仰范围仰视 10°到俯视 65°；具体 Godot 欧拉角符号由适配器统一处理。
- 执行时先下载官方稳定发行包并验证 4.7，记录确切 tag/commit 和许可证，不追踪浮动 main。若兼容验证失败，使用原生 SpringArm3D + Camera3D 实现同一接口并记录证据。

### 4.2 离线高度场与初始化

1. 收集显式分组中的静态 MeshInstance3D，读取支持的三角形表面并应用世界变换；无效/不支持输入报错。
2. 地面三角形投影到 XZ，在覆盖的格中心计算最高 Y；保存有效位，诊断多层重叠。障碍投影保守地标记相交网格面，退化的垂直墙投影线段同样处理。
3. 来源摘要覆盖选中节点路径、相关变换、用于烘焙的几何数据和烘焙配置，不包含玩家/相机。运行时仅初始化时比较，不逐帧扫描。
4. 保存完整 v1 资源并安全替换旧资源。初始平面也走这一链路；缺失/过期时要求用户显式重烘焙。
5. GPU 初始化支持统一雾顶或贴地厚度；`m=c0*h*mask`，`q=0`。无效/阻挡格为零，不对动态历史自动重网格化。

### 4.3 雾动力与浓度

定义：`b` 为地面高度（m），`h` 为承载层厚（m），`u` 为水平速度（m/s），`q=h*u`；`m` 为可见雾的面含量，采用可调视觉单位，$c=m/h$。它不是未经标定的真实液态水含量。

```text
∂t h + div(q) = 0
∂t q + div(q⊗u + 0.5*g_eff*h²*I) = -g_eff*h*grad(b) + h*(w-u)/tau
∂t m + div(m*u) = div(D*h*grad(m/h)) - lambda*m
lambda = ln(2) / half_life
```

- 沿 X/Z 使用静水重构 + Rusanov；对雾顶、速度及浓度使用受限 MUSCL 重构，薄层/障碍/域边界局部降阶。保留一阶诊断路径，正式默认二阶 SSP-RK2。
- 面通量采用统一正向约定，相邻单元消费同一个面值。雾量通量由层质量通量和上风浓度构造；正性限流在共享面实施，不能分别 clamp 两边而破坏守恒。
- 同一个 `g_eff` 用于压力、床面修正及 `sqrt(g_eff*h)` 波速；不保留水体常数 `9.81` 和 `4.905`、Manning 摩擦、FFT 松弛带、泡沫发射或额外压缩增浓项。
- 用源项半步 → 守恒 SSP-RK2 → 源项半步分裂。每个源项区间对风使用 $u=w+(u-w)\exp(-dt/tau)$，对雾量使用 `m*=exp(-lambda*dt)`；源项不因 RK 两阶段而重复积分整步。
- 混合默认 `D=0`。开启时使用相邻有效层的非负面厚度构造浓度差通量，干格/阻挡面系数为 0，并把显式扩散稳定条件纳入 dt；不直接模糊厚度或动量纹理。
- 数值干阈值初值 `h_epsilon=1e-4 m`，只处理除零与极薄层；被清除的量进入诊断。正常守恒验证不依赖清理。速度上限只作为异常保护和报错依据，不用于“调慢雾”。
- 开放边界以出流复制内部状态、入流采用显式背景层厚与风的匹配动量；默认入流雾浓度为 0。封闭边界反射法向动量，层/雾量通量为 0；障碍与无效面不通行。

### 4.4 时间推进与 GPU 调度

- CPU 以固定 30 Hz 累积模拟请求；正常小帧不改变模拟 tick 数。暂停不累积新时间，恢复不补暂停期间墙钟时间。
- 不依赖同步 CPU 读取最大速度：在 GPU 上按当前状态归约二维速率 $(|ux|+c_{wave})/dx+(|uz|+c_{wave})/dz$，同时用风目标的逐轴速度给源项加速留界；之后单独步长 pass 计算 $dt=\min(remaining,CFL/max\_rate,diffusion\_limit)$，CFL 初值 0.2。
- 每轮执行归约/步长、源项半步、RK 预测、预测检查、RK 校正/末次源项、候选检查和提交；仅接受候选时切换完整状态角色并扣减剩余时间。候选失败保留当前状态，缩小 dt 后重算所有阶段。不同全局依赖用独立 dispatch 与正确屏障，不在单 dispatch 中假定 workgroup 间同步。
- 每次渲染调度最多编码 8 个子步槽，剩余时间为 0 时槽内早退出；尚未推进的时间保留到下次。积压超过 0.1 秒时限幅并记录被丢弃时间，避免恢复后无界追帧。
- 当前状态与预测阶段都需要保持正性/CFL 安全；预测阶段若违反候选步长的稳定约束，应拒绝该候选并缩小 dt 后重试，不发布非法状态或以 clamp 代替稳定性。失败重试也占有限预算，持续失败禁用雾并提示。
- 累计实际模拟时间驱动噪声与源项；对长帧/预算受限情况显示实际推进不足，不能把墙钟时间假称为模拟时间。

### 4.5 体积密度映射

对世界位置 `(x,y,z)`，查得 `b,h,m`，令 $s=(y-b)/h$。仅在有效层内赋值：

```text
rho = (m / max(h, epsilon)) * f(s)
f(s) = 6*s*(1-s), 0 < s < 1；否则 0
```

该曲线在 [0,1] 上积分为 1、两端为 0，保持平均浓度语义。实际渲染不再单点判断薄层：对 froxel 的世界 Y 足迹区间 [y-a,y+a] 用 F(s)=3s²−2s³（s 裁到 [0,1]）作解析平均，DENSITY = extinction_scale × m × (F(s_hi)−F(s_lo))/(2a)。足迹由透视相机姿态、投影和体积雾分辨率/深度分布估计，半宽上限 0.25 米；绘制前更新插值后相机参数，避免使用上一帧相机。该平均只改变边缘过滤，不回写厚度或雾量。由独立 extinction_scale 将视觉密度映射到 fog shader 的 DENSITY；不把未标定量宣称为真实消光系数。渲染插值只对有效贡献者归一化，先拒绝无效/阻挡单元，避免跨障碍混出密度。

一个局部 box FogVolume 包围有效区域，初始垂直范围从最低地面到最高地面加 4 米，并在上下各加入 0.25 米过滤保护带。材质显式使用 SDF 控制包围盒，避免引擎默认的额外 10 cm box-edge 淡出侵蚀接地薄层。GPU 维护最大雾顶与越界标记，低频异步诊断（默认每 0.5 秒，非逐帧）按需扩展包围盒并报告越界；不截断模拟层厚。默认平面场应始终在初始范围内；极端堆积到扩展生效前的短暂裁切属于需记录的限制，不宣称任意地形均无裁切。全局体积雾密度为 0，先验证无噪声；之后可用均值约为 1 的弱低频噪声乘密度，沿统一风缓慢移动，时间取实际模拟时间。该纹理运动只是细节，不能替代 SWE 输送。

当前采用 size/depth=192/192、长度 24 米、detail spread=2；关闭原生时间重投影和 Halton 抖动，依靠空间区间过滤降低接地闪烁。EMISSION 使用独立亮度，不再次乘密度后触发引擎打包饱和。主场景默认消光 4、亮度 0.8。控制缓冲扩为 64 字节，发布 pass 在 GPU 归约有效格层厚最小/最大值及速度最大值，每 0.5 秒异步读回，用于常驻状态说明；不逐帧回读。优先缩短不必要的体积雾距离、调整 froxel 尺寸/深度，再考虑增加噪声复杂度。不得通过不可见区域仍有密度或巨大包围盒“补足”薄雾。

### 4.6 初始参数与调参边界

| 参数 | 初始值/范围 | 重置语义 |
| --- | --- | --- |
| 区域/网格 | 64 × 64 m，128²；验证后比较 256² | 重烘焙并重建 |
| 层厚/浓度 | 0.25 m、c0=1 视觉单位，浓白外观 | UI 数字改值即时重置 |
| 初始化噪波 | 有符号 fBm，振幅 0.25 m、频率 0.32/m、3 层、种子 7、offset=-0.2 m | 数字变化实时重置，不等松手；高度裁切到 0 |
| 噪波偏移 | 独立的 X/Z 采样偏移；高度 offset 允许 -2..2 m | 同上 |
| 约化重力开关 | 默认开；关闭使压力、床面源项及波速中的有效重力全为 0 | 实时，不重置，保留风/输送 |
| 有效重力 | 0.02 m/s²；首轮调试 0.005～0.05 | 实时，影响后续步长 |
| 风 | (0.05, 0) m/s，tau=20 s | 实时 |
| 消散 | 半衰期 300 s；调试 120～600 s | 实时 |
| 混合 | 默认 0 m²/s | 实时，影响稳定步长 |
| 模拟/渲染 | 30 Hz、CFL=0.2；渲染每帧 | 时间频率修改保留实际时间语义 |

数值 UI 统一使用 SpinBox 派生的左右拖拽控件，保留 Range 范围/步长、箭头与精确输入解析；左键拖动数值持续发出 value_changed，Shift 精调，双击恢复文本输入。初始化草稿已取消，所有数字变化写入运行配置后请求重置；开关保持不重置。暂停状态在重置后不变。此规则是用户在验收阶段明确要求的交互变更，不修改求解器算法或资产格式。

所有参数拒绝 NaN/Infinity；tau 与半衰期必须为正，关闭消散用独立开关；厚度/浓度非负。首版没有持续雾源，也不自动补充因开放边界流出的可见雾。

## 5. Fixed decisions and discretion

### 固定决策

- 主场景先用网格平面与胶囊玩家；第三人称移动是完整交付的一部分，不是雾完成后的附加项。
- 单层 XZ SWE、独立浓度、弱有效重力、速度趋近式风、原生 FogVolume、主 RD 共享纹理；不改成二维贴片或独立三维烟雾求解器。
- 高度场显式离线生成；角色不参与雾碰撞；GPU 状态默认 F32；不逐帧回读。
- 当前仅创建完整变更包；所有实现任务保持未完成。

### 允许局部调整

- 在不改变契约的前提下调整场景层级、文件粒度、UI 布局、配色和相机平滑参数。
- 选择经过验证的 Phantom Camera 稳定版；仅在兼容失败时走已定义的原生相机回退。
- 在行为验证通过且实际测量支持的情况下优化 pass 合并、workgroup 大小和缓冲复用；不跳过共享通量、正性或稳定性约束。

### 执行门槛而非未决设计

- 开始编码前没有需要用户补充的核心设计选择。插件具体版本、Godot 主 RD 到 fog shader 的真实调度与格式支持属于必须实测的兼容门槛，不是已验证事实。
- GPU 接线失败时暂停后续求解器/体积渲染实现，报告原因；未经同意不切换渲染后端或扩展到自研 Ray March。相机插件失败有明确的原生回退，不阻塞基础场景。

## 6. Verification and documentation impact

验证按阶段执行，映射到各目标规范的 P/T/F 场景。数值检查使用实际生产 shader 与可解析/守恒的行为预期，不以复制实现的测试证明自己；视觉检查使用真实 GUI，固定相机、参数、随机种子和累计模拟时间。编译成功、headless 成功不能替代 fog shader 的 GPU 运行与画面验证。

GPU 接线和计时必须在实际 4.7/D3D12 上验证；若环境不可用，记录未验证并保留任务未完成。GPU timestamp 不支持时明确标识，不能用 CPU 排队时间代替。比较 128²/256² 时分别记录分辨率、硬件、实际子步数、模拟耗时与体积渲染耗时。

交付后更新[当前架构](../../../../architecture.md)，将已通过验收的实验场、高度场和雾场契约整理到 doco 下的当前 specs 目录（交付时新建），补充实际运行/烘焙指南与插件版本/许可。只同步已实现事实；创建阶段仅保留计划文档，不写“已经支持”。

### 调研来源与证据边界

- [Godot 体积雾](https://docs.godotengine.org/en/stable/tutorials/3d/volumetric_fog.html)、[fog shader](https://docs.godotengine.org/en/latest/tutorials/shaders/shader_reference/fog_shader.html)、[Texture2DRD](https://docs.godotengine.org/en/stable/classes/class_texture2drd.html)。latest 文档不等于本机 4.7 已验证兼容。
- [Phantom Camera 安装](https://phantom-camera.dev/overview/installation)、[Third Person Follow](https://phantom-camera.dev/follow-modes/third-person)、[兼容 FAQ](https://phantom-camera.dev/support/faq)、[官方仓库/许可](https://github.com/ramokz/phantom-camera)。官方说明第三人称模式使用 SpringArm3D；具体版本和本机行为留待执行阶段验证。
- [浅层重气体模型](https://agupubs.onlinelibrary.wiley.com/doi/10.1029/2007GC001762)及[静水重构](https://doi.org/10.1137/S1064827503431090)提供模型与数值依据，不构成真实雾物理标定。
- [ARM 体积雾](https://developer.arm.com/community/arm-community-blogs/b/mobile-graphics-and-gaming-blog/posts/clustered-volumetric-fog)与[INSIDE 深度感知上采样](https://pixelmager.github.io/depth_aware_upsampling/upsampling.html)仅作为未来替代渲染的参考，不纳入本次交付。
- 已完成网络检索和参考代码阅读；部分网页正文抓取受代理限制，尚未安装插件或运行 GPU/GUI 验证。
