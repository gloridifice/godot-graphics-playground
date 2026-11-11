# 当前架构

## 入口与边界

- `project.godot` 主场景为 `scenes/fog_playground.tscn`，F5 启动 CSG 跳跃扰雾实验场；程序化森林保留为 `addons/heightfield_fog/demo.tscn`，可独立 F6 运行。使用 Godot 4.7.2 / Forward+；Windows 配置为 D3D12。
- 当前唯一雾效实现为 `addons/heightfield_fog/`，GDScript 管理节点、烘焙与初始化，Godot fog shader 与原生 FogVolume 负责显示。
- 旧 SWE GPU 求解器、玩家雾交互、全局高度场烘焙插件、旧实验场及其专属工具／测试／资源已移除。当前 addon 新增独立 GPU SWE：每盒推进厚度与水平动量，起跳注入动量。没有恢复旧全局求解器，也没有三维空气、持续风力输送或四面体渲染。
- 保留通用 `scenes/player.tscn`、`scripts/player/`、`scripts/camera/`、`scripts/ui/`、网格地面 shader 和 Phantom Camera 插件，森林示例复用玩家与第三人称相机。第三方来源见 `THIRD_PARTY.md`。
- `addons/JehenoThirdPersonController/` 独立保存 Jeh3no 的第三人称状态机控制器、相机、HUD、角色及配套美术／音效和测试地图；这是场景型资产，不是编辑器插件。仅适配资源路径及导入元数据，尚未接入森林或替换项目玩家。`scenes/fog_playground.tscn` 基于该测试地图，保留对 addon 资产的引用，并添加四个局部高度雾盒（地面、斜坡、出生高台及远处跳台）。上游测试地图保留启动捕获鼠标、Ctrl 切换；本地 `fog_playground` 通过项目子类改为默认自由鼠标、F 切换控制、Esc／失焦释放，不修改第三方脚本；来源、许可及入口见 [导入说明](../addons/JehenoThirdPersonController/SOURCE.md)。

## 雾盒与烘焙

- `heightfield_fog_box.gd` 定义一个盒体对应一个局部高度场的 `HeightfieldFogBox` 节点。原点为底心，支持世界 Y 旋转、单位缩放。原生移动／旋转工具与 `box_gizmo.gd` 的宽高深手柄共同控制盒体，尺寸编辑支持撤销。
- `baker.gd` 收集 Source Root 下可见的静态 MeshInstance3D，排除蒙皮及 `heightfield_fog_ignore` 分组。使用 Godot 顺时针正面的向上三角形，在局部 X/Z 网格中心求交，仅接受底／顶高度区间内的结果，每格保留最高面。跨界斜面按采样位置裁剪，不夹平到盒顶。
- 无承载格无效，整盒无承载面则拒绝替换原纹理。地形纹理与烘焙签名仅驻留节点内存，场景不保存 Image／ImageTexture 数据或高度图资源引用。编辑器和运行时每次进入场景树都会清空缓存，延后两个处理帧自动烘焙，等待父场景生成几何；烘焙不标记场景为未保存。盒体变换、尺寸、分辨率或 Source Root 变化后旧结果不显示，需显式重烘焙或重新进入场景；场景内源几何编辑不自动扫描。
- 多个盒体可用不同高度区间分离上下楼层；每盒内部仍只保存一层。盒体不改变模型、玩家或相机碰撞。

## 初始化与显示

- `initialization.gd` 定义可保存为 `.tres` 的 `HeightfieldFogInitialization`。每盒默认独立资源，也可共享资产；共享编辑影响所有引用者，单独调整需 Make Unique。
- 参数包含基础高度、偏移、水平雾顶、初始厚度上限、浓度和确定性 fBm 的振幅／频率／层数／种子／采样偏移。初始化资产缓存一张盒体无关的 512² FastNoiseLite 无缝纹理，CPU 初态与 GPU 密度共享信号；种子／层数变化更新缓存，频率／偏移通过采样坐标生效。自然模式按世界坐标与风向拉伸采样，普通模式按局部坐标采样。
- 静态预览和 SWE 都消费同一 `create_thickness()` 结果，shader 不再重建另一套程序化雾顶。先计算基准高度加噪波，Horizontal Top 开启时减承载高度，再裁零并应用 Max Thickness；高于雾顶的岩石不被雾毯覆盖。修改形状参数会重建每盒初态并重置 SWE，不重烘焙地形，不向共享资产写入盒体数据。旧 `layer_height` 兼容为基础高度，旧 Top Variation／Scale 迁移为噪波振幅／频率。
- `heightfield_fog.gdshader` 保留旧 2.5D 密度剖面和默认关闭的 Natural Mist。自然模式使用顶部 smoothstep 渐淡、竖向解析积分平均及基于同一噪波纹理的软覆盖率，形成贴地雾带和透明间隙。浓度、覆盖率、顶部软化、密度细节与风速只更新显示，不重置物理状态。风速只在共享引擎时间下平移世界空间密度，不移动静态厚度或推动 SWE。两种模式都按局部侧边距离渐出厚度，不改变承载面。见 [薄雾生成合约](specs/heightfield-mist.md)。
- 原生 FogVolume 累积多个盒体，重叠增浓。盒顶限制烘焙承载高度，不是雾层硬顶盖；体积 Y 向留过滤余量。需要启用体积雾的 WorldEnvironment。
- `demo.gd` 在编辑器／运行时以固定种子生成 48×48 米起伏森林、土路、针叶树、倒木和大小岩石，不引入外部美术资源。`demo.tscn` 的 ClearingMist／DeepForestMist 覆盖空地与后方森林，共享 `presets/forest_mist.tres` 自然薄雾预设；两个盒底 Y=−2 m，基准雾顶为世界 Y=0.55 m，噪波振幅 0.35 m、频率 0.4，初始贴地厚度限制为 0.38 m，覆盖率控制为 0.5。运行时开启 SWE，从与编辑器一致的噪波薄层初始化；模拟可继续输送和堆积，不强制维持初始上限。旧预设留给分层测试；Source Root 限定为地形与岩石，排除树冠和倒木。游戏和测试场景启动时鼠标自由可见，F 锁定并隐藏后使用 WASD／鼠标／空格控制第三人称角色；Esc 释放，单击不捕获；所有雾盒进入场景时自动烘焙，森林无需单独调度。原双层解析几何测试独立保留在 `fixtures/stacked_floors.tscn`，不再依赖展示场景。

## CSG 雾实验场

- `scenes/fog_playground.tscn` 开启原生体积雾，背景密度为零；`FogFields` 下的 GroundMist、RampMist、SpawnPlatformMist、SteppingStonesMist 分别覆盖地面、斜坡、高台与远处跳台。地面使用水平雾顶，其余使用贴承载面的薄层；均开启自然密度漂移。四个盒体均开启 SWE，接收脚下起跳汇聚／落地扩散事件。
- `scripts/fog_playground.gd` 是场景专用 `@tool` 脚本：等待 CSG 更新后，通过 `get_meshes()` 将最终合并表面暴露为 `_FogCSGSurface`。派生节点不保存、不渲染、不投影、不创建碰撞，仅供现有 MeshInstance3D 烘焙器读取；不修改 addon 的通用烘焙合约。
- Source Root 限定 `Structures`，排除角色；编辑器和运行时进入场景时先构建 CSG 派生网格，再由雾盒自动烘焙四个内存高度图，不再保存独立 `.res`。修改 CSG 后，选根节点点击 **Bake all playground fog**，刷新派生网格并重烘焙全部雾盒；烘焙结果不需保存，布局及参数编辑照常保存。

## 主场景角色与鼠标控制

- `scripts/player/fog_playground_player.gd` 继承第三方 `PlayerCharacter`，保留原状态机与碰撞，在真实 `move_and_slide()` 前后检测接地起跳／落地，以胶囊底端计算脚底世界坐标。初次出生接地不施加落地冲量；空中二段跳不触发地面汇聚，落地需向下速度超过 1 m/s，避免微小贴坡抖动重复触发。
- `scripts/fog_playground.gd` 将起跳事件以 `-takeoff_pull`（默认 −0.8）、落地事件以 `landing_push`（默认 +1）传给各盒的 `disturb_mist()`。只注入水平动量，厚度汇聚、堆积与扩散由 SWE 通量产生；保留每盒高度隔离，不叠加视觉清空／扩散环。
- `scripts/camera/fog_playground_camera.gd` 继承第三方 `CameraHolder`，场景内覆盖其脚本。启动光标可见，物理 F 切换捕获／释放，Esc、窗口失焦或退出释放；单击、Ctrl 和重新获得焦点不捕获。释放时暂停状态机输入并停止水平移动，但仍执行重力、碰撞和真实落地事件，相机缩放同样仅在捕获时处理。

## 森林角色与物理

- `demo.tscn` 实例化项目 `scenes/player.tscn`；`demo.gd` 在土路入口按实际地形高度安置胶囊。玩家控制器沿相机水平基移动、使用正常重力与跳跃，释放鼠标或窗口失焦后停止输入。没有重新接入旧玩家扰雾求解器；demo 将 `jumped(feet_position)` 转发到各盒体的 `disturb_mist()`，只在起跳时向实际 SWE 状态注入径向动量。
- `scripts/camera/third_person_rig.gd` 与 Phantom Camera 提供第三人称跟随、限俯仰环绕及碰撞避让，跟随距离 4 m。统一控制器默认不捕获鼠标，只接受 Input Map 的 `capture_mouse`（物理 F）进入锁定隐藏状态；Esc、失焦或退出控制器释放，不因单击／重新获得焦点而捕获。相机碰撞层为环境 1，玩家为 2，避免被自身胶囊挡住。
- 程序化地面生成三角网格静态碰撞，岩石／树干／倒木主干生成凸碰撞；不生成树冠／细枝碰撞。地形四边增加防跌落边界；这些物理体与雾的承载高度图独立。
- 雾盒核心不依赖角色／相机；森林展示场景依赖项目玩家与 Phantom Camera，不是仅复制 addon 即具备的控制器。

## GPU SWE 与起跳

- `swe_solver.gd` 在全局 RenderingDevice 的渲染线程维护每盒独立双缓冲状态；`shaders/swe.glsl` 实现一阶有限体积 Rusanov、静水重建、GPU CFL 归约与供给格排出量限制。盒外和无效格反射，动量阻尼不衰减质量。
- 初始场为高度图和初始化厚度；正常帧不回读 CPU。稳定的 R32F 输出经 Texture2DRD 直接绑定 FogVolume。自然模式保留软剖面和密度细节，但使用 SWE 厚度而非程序化雾顶。
- 60 Hz 固定 tick 内分子步，GPU 保证实际 CFL；过载有追赶上限与丢时诊断，极端 CFL 限制可能使物理时间落后。暂停保留状态，重置／基础参数变化／重烘焙重建状态，退出释放 GPU 资源。
- 起跳坐标转换到各盒局部，默认 2.5 m 范围注入 1.8 m/s 径向速度对应的动量，事件强度限定为 [−1, 1]，负值汇聚、正值扩散；省略强度时保留森林原有向外冲量。每次最多四事件，各施加一次。高差 1.5 m 外不施加，不直接删除厚度，也不按计时器恢复。旧视觉扩散环已移除。多个盒体独立响应，但不交换通量。
- `swe_metrics()` 返回异步 GPU timestamp 与独立 CPU 提交计时，`swe_snapshot()` 仅显式诊断回读。精确边界见 [局部高度雾 SWE 合约](specs/heightfield-swe.md)。

## 验证与限制

- addon 的 `bake_test.gd` 覆盖真实场景保存／加载不保留高度图、加载与重复进入场景自动采样新几何，以及上下层分离、旋转盒、跨顶斜面及失效／失败烘焙；`initialization_test.gd` 覆盖初态高度／厚度上限、无效格／高岩石、噪波缓存失效、平移／旋转盒世界场一致性、资产保存加载及旧字段迁移。
- `natural_mist_test.gd` 用真实 Forward+ 画面检查低处有雾／高岩石露出、顶部软化、零风速稳定、旋转盒体的世界空间连续性和非零风速漂移，以及资源噪波频率确实影响静态与暂停的 SWE 初态、SWE 厚度纹理实际显示、旋转盒起跳坐标、外观编辑保留暂停状态和 GPU 资源重建；不把 headless 编译当作 shader 验证。
- `swe_test.gd` 验证真实 GPU 的静水平衡、干湿推进、无效格、非负和质量，以及向内汇聚／向外冲量、跨高度隔离、强冲量与模拟时钟。
- `tests/fog_playground_jump_test.gd` 从配置的主场景启动，验证真实第三方控制器跳跃／落地一次性事件、GPU 向内／向外动量和中心增厚／质量守恒，以及默认自由鼠标、F 双向切换、Esc／失焦释放、单击不捕获、释放期间仍可落地扰雾。
- `tests/forest_walk_test.gd` 在有焦点的图形窗口检查真实场景落地、W 行走与贴坡、跳跃落地及 GPU 动量注入、默认自由鼠标、物理 F／Esc 切换、单击不捕获及地图边界阻挡。`tools/profile_forest_swe.gd` 可重复测量固定视角的模拟暂停／运行／起跳负载。
- 真正 GPU 路径使用 Forward+ / D3D12 冒烟运行；headless 测试不替代 GPU 验证。没有性能预算保证，也未承诺所有视角无走样；盒边渐出不等同于内部孔洞的距离场过滤。
- `doco/changes/` 与 `doco/tmp/` 的旧材料不代表当前实现，不作为启动或验证入口。

操作与命令见 [实验场指南](guides/playground.md) 和 [addon 说明](../addons/heightfield_fog/README.md)。
