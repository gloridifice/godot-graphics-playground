# 当前架构

## 入口与边界

- `project.godot` 主场景为 `addons/heightfield_fog/demo.tscn`，F5 启动程序化森林局部高度雾示例。使用 Godot 4.7.2 / Forward+；Windows 配置为 D3D12。
- 当前唯一雾效实现为 `addons/heightfield_fog/`，GDScript 管理节点、烘焙与初始化，Godot fog shader 与原生 FogVolume 负责显示。
- 旧 SWE GPU 求解器、玩家雾交互、全局高度场烘焙插件、旧实验场及其专属工具／测试／资源已移除。当前 addon 新增独立 GPU SWE：每盒推进厚度与水平动量，起跳注入动量。没有恢复旧全局求解器，也没有三维空气、持续风力输送或四面体渲染。
- 保留通用 `scenes/player.tscn`、`scripts/player/`、`scripts/camera/`、`scripts/ui/`、网格地面 shader 和 Phantom Camera 插件，森林示例复用玩家与第三人称相机。第三方来源见 `THIRD_PARTY.md`。

## 雾盒与烘焙

- `heightfield_fog_box.gd` 定义一个盒体对应一个局部高度场的 `HeightfieldFogBox` 节点。原点为底心，支持世界 Y 旋转、单位缩放。原生移动／旋转工具与 `box_gizmo.gd` 的宽高深手柄共同控制盒体，尺寸编辑支持撤销。
- `baker.gd` 收集 Source Root 下可见的静态 MeshInstance3D，排除蒙皮及 `heightfield_fog_ignore` 分组。使用 Godot 顺时针正面的向上三角形，在局部 X/Z 网格中心求交，仅接受底／顶高度区间内的结果，每格保留最高面。跨界斜面按采样位置裁剪，不夹平到盒顶。
- 无承载格无效，整盒无承载面则拒绝替换原纹理。地形纹理随场景保存；盒体变换、尺寸、分辨率或 Source Root 变化后旧结果不显示，需显式重新烘焙。源模型几何变化需用户手动重烘焙。
- 多个盒体可用不同高度区间分离上下楼层；每盒内部仍只保存一层。盒体不改变模型、玩家或相机碰撞。

## 初始化与显示

- `initialization.gd` 定义可保存为 `.tres` 的 `HeightfieldFogInitialization`。每盒默认独立资源，也可共享资产；共享编辑影响所有引用者，单独调整需 Make Unique。
- 参数包含基础高度、偏移、水平雾顶、浓度和确定性 fBm 的振幅／频率／层数／种子／采样偏移。资源变化时按每盒地形重建临时厚度纹理，不重烘焙地形，不将盒体数据写回共享资产。旧节点 `layer_height` 读取兼容为基础高度。
- `heightfield_fog.gdshader` 保留旧静态 2.5D 层；新增默认关闭的 Natural Mist 模式。自然模式以基准雾顶和世界空间低频起伏重建厚度，Horizontal Top 开启时先减承载高度再裁零，避免高处岩石获得等厚雾毯。下部密度连续、顶部 smoothstep 渐淡，仍对竖向密度做解析积分平均。两种模式都按局部 X/Z 侧边距离渐出厚度，不改变承载面。
- 自然模式的风向拉伸、轻微坐标扭曲和密度细节在 GPU 查询时计算，使用共享引擎运行时间与世界 X/Z 坐标，不随盒体旋转、不逐帧重建初态纹理。新参数调整仅更新 uniform；旧 Initial Noise 的振幅／频率／层数被绕过，种子和偏移复用。零风速静止，非零风速仅平移程序化场，不模拟质量或绕流；原生体积范围额外容纳雾顶起伏。
- 原生 FogVolume 累积多个盒体，重叠增浓。盒顶限制烘焙承载高度，不是雾层硬顶盖；体积 Y 向留过滤余量。需要启用体积雾的 WorldEnvironment。
- `demo.gd` 在编辑器／运行时以固定种子生成 48×48 米起伏森林、土路、针叶树、倒木和大小岩石，不引入外部美术资源。`demo.tscn` 的 ClearingMist／DeepForestMist 覆盖空地与后方森林，共享 `presets/forest_mist.tres` 自然薄雾预设；两个盒底 Y=−2 m，基准雾顶为世界 Y=0.55 m，运行时开启 SWE，以此水平雾顶初始化；程序化雾顶不再覆盖模拟厚度。编辑器静态预览仍可使用 ±0.25 m 起伏。旧预设留给分层测试；Source Root 限定为地形与岩石，排除树冠和倒木。运行时使用 WASD／鼠标／空格的第三人称角色，Esc 释放鼠标、单击恢复；示例启动自动烘焙，普通节点不自动烘焙。原双层解析几何测试独立保留在 `fixtures/stacked_floors.tscn`，不再依赖展示场景。

## 森林角色与物理

- `demo.tscn` 实例化项目 `scenes/player.tscn`；`demo.gd` 在土路入口按实际地形高度安置胶囊。玩家控制器沿相机水平基移动、使用正常重力与跳跃，释放鼠标或窗口失焦后停止输入。没有重新接入旧玩家扰雾求解器；demo 将 `jumped(feet_position)` 转发到各盒体的 `disturb_mist()`，只在起跳时向实际 SWE 状态注入径向动量。
- `scripts/camera/third_person_rig.gd` 与 Phantom Camera 提供第三人称跟随、限俯仰环绕及碰撞避让，跟随距离 4 m。相机碰撞层为环境 1，玩家为 2，避免被自身胶囊挡住。
- 程序化地面生成三角网格静态碰撞，岩石／树干／倒木主干生成凸碰撞；不生成树冠／细枝碰撞。地形四边增加防跌落边界；这些物理体与雾的承载高度图独立。
- 雾盒核心不依赖角色／相机；森林展示场景依赖项目玩家与 Phantom Camera，不是仅复制 addon 即具备的控制器。

## GPU SWE 与起跳

- `swe_solver.gd` 在全局 RenderingDevice 的渲染线程维护每盒独立双缓冲状态；`shaders/swe.glsl` 实现一阶有限体积 Rusanov、静水重建、GPU CFL 归约与供给格排出量限制。盒外和无效格反射，动量阻尼不衰减质量。
- 初始场为高度图和初始化厚度；正常帧不回读 CPU。稳定的 R32F 输出经 Texture2DRD 直接绑定 FogVolume。自然模式保留软剖面和密度细节，但使用 SWE 厚度而非程序化雾顶。
- 60 Hz 固定 tick 内分子步，GPU 保证实际 CFL；过载有追赶上限与丢时诊断，极端 CFL 限制可能使物理时间落后。暂停保留状态，重置／基础参数变化／重烘焙重建状态，退出释放 GPU 资源。
- 起跳坐标转换到各盒局部，默认 2.5 m 范围注入 1.8 m/s 径向速度对应的动量；每次最多四事件，各施加一次。高差 1.5 m 外不施加，不直接删除厚度，也不按计时器恢复。旧视觉扩散环已移除。多个盒体独立响应，但不交换通量。
- `swe_metrics()` 返回异步 GPU timestamp 与独立 CPU 提交计时，`swe_snapshot()` 仅显式诊断回读。精确边界见 [局部高度雾 SWE 合约](specs/heightfield-swe.md)。

## 验证与限制

- addon 的 `bake_test.gd` 覆盖上下层分离、旋转盒、跨顶斜面及失效／失败烘焙；`initialization_test.gd` 覆盖初态高度、无效格、水平雾顶、非负厚度、种子、资产保存加载及旧字段兼容。
- `natural_mist_test.gd` 用真实 Forward+ 画面检查低处有雾／高岩石露出、顶部软化、零风速稳定、旋转盒体的世界空间连续性和非零风速漂移，以及 SWE 厚度纹理实际显示、旋转盒起跳坐标、暂停和 GPU 资源重建；不把 headless 编译当作 shader 验证。
- `swe_test.gd` 验证真实 GPU 的静水平衡、干湿推进、无效格、非负和质量，以及起跳动量、跨高度隔离、强冲量与模拟时钟。
- `tests/forest_walk_test.gd` 在有焦点的图形窗口检查真实场景落地、W 行走与贴坡、跳跃落地及 GPU 动量注入、释放／恢复控制及地图边界阻挡。`tools/profile_forest_swe.gd` 可重复测量固定视角的模拟暂停／运行／起跳负载。
- 真正 GPU 路径使用 Forward+ / D3D12 冒烟运行；headless 测试不替代 GPU 验证。没有性能预算保证，也未承诺所有视角无走样；盒边渐出不等同于内部孔洞的距离场过滤。
- `doco/changes/` 与 `doco/tmp/` 的旧材料不代表当前实现，不作为启动或验证入口。

操作与命令见 [实验场指南](guides/playground.md) 和 [addon 说明](../addons/heightfield_fog/README.md)。
