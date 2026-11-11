# Heightfield Fog

独立 GDScript addon，一个 `HeightfieldFogBox` 节点对应一个局部高度场。使用 Godot 原生 FogVolume 合成 **2.5D 高度层**，不使用四面体。需要 Forward+ 和开启体积雾的 WorldEnvironment。

## 使用

1. 启用 Heightfield Fog 插件（本项目已启用）。新建 `HeightfieldFogBox` 节点。
2. 节点原点是**底面中心**。原生 Move/Rotate gizmo 控制位置和 Y 旋转；三个自定义手柄调整宽、高、深，支持撤销。不要旋转 X/Z 或缩放节点／父级，用 Size 改尺寸。
3. Source Root 指向包含静态模型的节点，留空使用当前场景。自动选取可见 MeshInstance3D 的向上表面；蒙皮不参与。为不需要烘焙的 mesh 添加 `heightfield_fog_ignore` 分组（例如玩家、透明叶片）。
4. 点击 Inspector 的 **Bake local heightfield**，再保存场景。高度图随场景保存，不需要独立资源路径。改变盒体位置／尺寸／旋转或分辨率后旧结果停止显示，需要重烘焙。修改源模型后也要手动重烘焙。
5. 在 **Initialization** 新建 `HeightfieldFogInitialization`，或拖入 `.tres` 初始化资产。展开资源调初态；外观仍由节点的 Extinction、Tint、Brightness 控制。**Edge Fade** 为向内渐出的宽度（米，默认 1，0 关闭），实时生效，无需重烘焙。

直接打开 `demo.tscn` 按 F6，或 F5 启动主场景，可查看程序化森林：缓坡、土路、针叶树、倒木、大小岩石和两片局部薄雾。示例复用项目 `scenes/player.tscn` 与 Phantom Camera 第三人称控制器：WASD 行走、鼠标环绕、空格跳跃、Esc 释放鼠标、单击恢复；地面、岩石、树干及倒木有碰撞，边缘防跌落。森林已开启 GPU SWE；起跳向脚边注入径向动量，雾随后输送和堆积，不按计时器恢复。行走和落地不触发。核心雾盒仍独立于这些示例依赖。固定种子生成几何，不使用外部美术素材。示例启动时自动烘焙地面与岩石，不烘焙树冠／倒木；常规使用不会隐式重烘焙。原桥下／桥面分层场景保留在 `fixtures/stacked_floors.tscn` 供测试使用。

## 初始化资产

`initialization.gd` 定义 `HeightfieldFogInitialization` Resource，可独立保存为 `.tres`。每个新盒体默认拥有独立资源；也可让多个盒体引用同一资产，编辑共享资产会更新所有引用它的盒体。需要单独修改时使用 Inspector 的 **Make Unique（设为唯一）**。

| 参数 | 含义 |
| --- | --- |
| Base Height | 默认 0.4 m；普通模式为地面上方厚度，Horizontal Top 模式为相对盒底的雾顶高度 |
| Height Offset | 有符号高度偏移，单位 m，最终厚度不小于 0 |
| Horizontal Top | 从设定雾顶减去每格承载高度；无噪声时雾顶水平 |
| Concentration | 初始浓度，无量纲，默认 1；不改变厚度，0 为无雾 |
| Noise Amplitude | 有符号 fBm 的高度振幅，单位 m，默认 0（关闭） |
| Noise Frequency | 盒体局部 X/Z 空间频率，单位 1/m |
| Noise Octaves / Seed | fBm 层数／随机种子，相同配置确定性重现 |
| Noise Offset | 局部 X/Z 噪声采样偏移，单位 m |

初态厚度为 `max(0, Base Height + Height Offset + Noise Amplitude × noise)`；水平雾顶模式在裁零前再减地形局部高度。边界渐出随后在 GPU 查询时应用。

基础初态参数变化会在编辑器和运行时重新生成该盒体的初态厚度纹理，不重新烘焙地形；生成数据不写回共享资产，场景保存参数及地形纹理，初态纹理运行时重建。旧模式仍是静态初态显示。

保留 `presets/low_mist.tres`（有噪声）和 `presets/soft_layer.tres`（均匀薄雾），分层测试继续使用它们；森林示例的两个盒体改为共享 `presets/forest_mist.tres`。旧场景中的 `layer_height` 自动读取为新资源的 Base Height，不再写回旧属性。

## 自然薄雾

在 Initialization 的 **Natural Mist** 分组启用 **Natural Mist Enabled**。默认关闭，旧资源保持原有渲染。推荐同时启用 **Horizontal Top**，让雾顶减去地形高度后再裁零：低处积雾，高于雾顶的岩石不再被等厚覆盖。关闭 Horizontal Top 时仍可用于贴地层。

| 参数 | 含义与范围 |
| --- | --- |
| Top Variation | 雾顶最大起伏，0～2 m；0 为无起伏 |
| Top Scale | 世界空间大尺度起伏尺寸，4～80 m |
| Top Softness | 顶部渐淡带占层厚的比例，0.1～1；下部连续，顶部平滑变淡 |
| Detail Strength | 密度细节强度，0～0.8；0 为平滑连续层，不改变雾顶 |
| Detail Scale | 横风向细节尺度，1～16 m，避免过细结构被体积网格漏采 |
| Wind Stretch | 沿风向与横风向尺度比，1～8 |
| Wind Direction | 世界 X/Z 平面风向，−180～180°；0 为 +X，90 为 +Z |
| Wind Speed | 程序化漂移速度，0～1 m/s；0 静止，不是流体速度求解 |

以上参数实时生效，无需重烘焙，也不因逐帧动画重建厚度图。自然模式绕过旧 Initial Noise 的 Amplitude／Frequency／Octaves；Seed 与 Offset 仍用于新的世界空间噪声，Offset 单位为米。GPU 使用固定种子的平滑值噪声与两层低频细节，不逐帧随机换种子。

森林预设的基准雾顶为盒底上方 2.55 m；两个盒底均在世界 Y=−2 m，因此世界平均雾顶一致为 0.55 m，最大起伏 ±0.25 m。风向与纹理使用世界坐标，旋转盒体不旋转风向；不同高度盒底需要分别调整 Base Height 来对齐雾顶。共享资源编辑会影响两个盒体，可 Make Unique 分离。

自然模式保持竖向积分平均与盒边渐出，顶部留出起伏保护带；下部密度较连续，顶部密度细节更明显。森林节点 Brightness 降为 0.06，并保持时间重投影开启。漂移是程序化视觉动画，不包含绕障碍或质量守恒。

## GPU SWE 与起跳

森林两个雾盒均开启 **SWE Enabled**。每盒有独立厚度与 X/Z 动量场，使用 GPU 一阶浅水求解器推进。`swe_solver.gd` 调度，`shaders/swe.glsl` 计算，输出 Texture2DRD 直接供 FogVolume 读取，正常帧不回读 CPU。

| 参数 | 含义 |
| --- | --- |
| SWE Enabled | 默认关闭、森林启用；运行时模拟，编辑器仍为静态预览；开关会重置状态 |
| SWE Paused | 暂停推进但保留当前状态，不接受新跳跃冲量 |
| SWE Gravity | 约化重力，0.05～9.81 m/s²，默认 1.2；控制浅层波传播，不是环境重力 |
| SWE Drag | 动量阻尼，0～4 s⁻¹，默认 0.45；不删除质量 |
| SWE Render Height | 动态堆积的显示保护高度，1～32 m，默认 8；不裁切模拟厚度，极端堆积需调大 |
| Reset SWE State | 从当前初始化资产重新开始，不重烘焙地形 |
| Jump Radius | 径向冲量范围，0.2～6 m，默认 2.5 |
| Jump Speed | 速度增量，0～4 m/s，默认 1.8；0 关闭冲量 |

`disturb_mist(world_feet)` 将脚底转换为盒体局部坐标，向范围内已有厚度对应的动量注入一次向外冲量。高差 1.5 m 外不施加；每个模拟批次最多四个事件，溢出替换最旧。起跳不直接减厚度，后续由通量输送产生中心变薄、外围堆积和波动。无固定恢复时长；原 Jump Duration／Jump Strength 视觉方案已移除，未开启 SWE 时不响应跳跃。

SWE 开启时，厚度完全来自求解器：自然模式的 Top Variation 不再构造物理雾顶，Wind 参数只移动显示密度细节、不推动动量；软顶部剖面和边缘渐出仍保留。初态参数、烘焙图或尺寸变化会重建状态；共享资产不保存模拟结果。盒边／无效格是反射边界，盒间不交换通量。地形岩石可以形成承载高度障碍，但树干、倒木的角色碰撞不自动进入 SWE。

GPU 自适应 CFL 与排出量限制保证稳定性／非负；极端状态可能限速，卡顿超过追赶预算会记录丢时，不保证任意参数下实时追平。详见 [SWE 合约](../../doco/specs/heightfield-swe.md)。

## 高度与边界

- 网格位于盒体局部 X/Z，随 Y 旋转；底面高度为 0，顶面为 Size.y。逐采样点判断原始三角形与高度区间的交点，跨盒顶的斜面保留内部部分，不把超界高度压到盒顶。
- 只保留盒内最高一层；用不同高度范围的盒体隔离上下层。没有承载面的格子无效，整盒为空时保留上次烘焙并警告。
- 查询时取局部 X/Z 到最近侧边的距离 d，雾层厚度乘 `smoothstep(0, Edge Fade, d)`。边界处厚度为 0，地形高度不变；同时降低面雾量，不通过提高浓度补偿变薄。旋转后仍按局部侧边计算，不沿世界外接矩形渐出。
- 盒顶只限制**烘焙承载面**，不是动态雾层的硬顶盖。原生 FogVolume 在 Y 方向留有薄层过滤余量。旧模式对归一化平滑密度曲线做积分平均；自然模式对下部连续、顶部渐淡的曲线做积分平均，减少极薄层漏采样。

## 当前范围

支持静态初态、自然薄雾显示和可选的 GPU SWE 厚度／动量推进。没有三维空气模拟、持续物理风力、旧玩家交互求解器、专用阻挡面或四面体，不改变角色碰撞。旧 SWE 求解器及旧雾效已移除，本 addon 是当前唯一雾效实现。多个盒体使用独立高度纹理，由原生体积雾累积，重叠处更浓。

渐出用于软化盒边，不保证消除原生 froxel 的所有走样。内部地形洞口仍采用有效格掩码，没有额外距离场渐出；上下层之间仍须拆盒。烘焙同步执行，大模型／高分辨率可能暂时阻塞编辑器。

验证（在项目根运行，使用项目匹配的 Godot）：

```powershell
& G:\Tools\Godot_mono_v4.7.2\godot_console.exe --headless --path . --script res://addons/heightfield_fog/bake_test.gd
& G:\Tools\Godot_mono_v4.7.2\godot_console.exe --headless --path . --script res://addons/heightfield_fog/initialization_test.gd
# 真实 GPU：静水平衡、干湿、质量／非负与冲量。
& G:\Tools\Godot_mono_v4.7.2\godot_console.exe --path . --script res://addons/heightfield_fog/swe_test.gd --max-fps 120
# 真实 GPU：自然雾与 SWE 厚度显示／旋转盒扰动／暂停／重建。
& G:\Tools\Godot_mono_v4.7.2\godot_console.exe --path . --script res://addons/heightfield_fog/natural_mist_test.gd --max-fps 60
# 固定相机，暂停／运行／每秒起跳对照；真实 GPU timestamp 与 CPU 提交耗时分别输出。
& G:\Tools\Godot_mono_v4.7.2\godot_console.exe --path . --script res://tools/profile_forest_swe.gd
```

GPU timing 为每盒最近完成的模拟提交批次（可能含多个 tick），不是每渲染帧固定成本。无可用 timestamp 时报告不可用，不用 CPU 时间替代。`swe_snapshot()` 只供显式诊断，可能等待 GPU，不在常规更新／计时区间调用。首次使用需让 Godot 图形编辑器导入 `shaders/swe.glsl`；验证必须用 Forward+，不能用 headless 冒充 GPU 测试。
