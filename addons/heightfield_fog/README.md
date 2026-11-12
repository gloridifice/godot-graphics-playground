# Heightfield Fog

独立 GDScript addon，一个 `HeightfieldFogBox` 节点对应一个局部高度场。使用 Godot 原生 FogVolume 合成 **2.5D 高度层**，不使用四面体。需要 Forward+ 和开启体积雾的 WorldEnvironment。

## 使用

1. 启用 Heightfield Fog 插件（本项目已启用）。新建 `HeightfieldFogBox` 节点。
2. 节点原点是**底面中心**。原生 Move/Rotate gizmo 控制位置和 Y 旋转；三个自定义手柄调整宽、高、深，支持撤销。不要旋转 X/Z 或缩放节点／父级，用 Size 改尺寸。
3. Source Root 指向包含静态模型的节点，留空使用当前场景。自动选取可见 MeshInstance3D 的向上表面；蒙皮不参与。为不需要烘焙的 mesh 添加 `heightfield_fog_ignore` 分组（例如玩家、透明叶片）。
4. 每次进入场景（编辑器／运行时）会自动烘焙，延后两个处理帧等待场景几何就绪。高度图及烘焙签名只保存在节点内存中，不写入 `.tscn` 或独立资源；保存场景只保存参数，烘焙本身不会将场景标记为未保存。改变盒体位置／尺寸／旋转或分辨率后旧结果停止显示，可点击 Inspector 的 **Bake local heightfield** 更新当前内存缓存；修改源模型后同样手动重烘焙，或重新进入场景。
5. 在 **Initialization** 新建 `HeightfieldFogInitialization`，或拖入 `.tres` 初始化资产。展开资源调初态；外观仍由节点的 Extinction、Tint、Brightness 控制。**Edge Fade** 为向内渐出的宽度（米，默认 1，0 关闭），实时生效，无需重烘焙。

项目 F5 主场景为 `scenes/fog_playground.tscn`，雾盒开启 SWE：接地行走推动并产生尾流，起跳汇聚、落地扩散。启动鼠标自由可见，F 切换控制／释放，Esc 或失焦释放；本地控制器／相机子类保留第三方源码不变。

直接打开 `demo.tscn` 按 F6，可查看可选的程序化森林：缓坡、土路、针叶树、倒木、大小岩石和两片局部薄雾。示例复用项目 `scenes/player.tscn` 与 Phantom Camera 第三人称控制器：启动时鼠标自由可见，按 F 锁定并隐藏鼠标后，WASD 行走、鼠标环绕、空格跳跃；Esc 或窗口失焦释放鼠标，单击不再自动锁定；地面、岩石、树干及倒木有碰撞，边缘防跌落。森林已开启 GPU SWE；起跳向脚边注入径向动量，雾随后输送和堆积，不按计时器恢复。行走和落地不触发。核心雾盒仍独立于这些示例依赖。固定种子生成几何，不使用外部美术素材。所有雾盒在进入场景时自动烘焙；森林仅选择地面与岩石，不烘焙树冠／倒木。场景内编辑仍需手动重烘焙，不逐帧扫描几何。原桥下／桥面分层场景保留在 `fixtures/stacked_floors.tscn` 供测试使用。

## 初始化资产

`initialization.gd` 定义 `HeightfieldFogInitialization` Resource，可独立保存为 `.tres`。每个新盒体默认拥有独立资源；也可让多个盒体引用同一资产，编辑共享资产会更新所有引用它的盒体。需要单独修改时使用 Inspector 的 **Make Unique（设为唯一）**。

| 参数 | 含义 |
| --- | --- |
| Base Height | 默认 0.4 m；普通模式为地面上方厚度，Horizontal Top 模式为相对盒底的雾顶高度 |
| Height Offset | 有符号高度偏移，单位 m，最终厚度不小于 0 |
| Horizontal Top | 从设定雾顶减去每格承载高度；无噪声时雾顶水平 |
| Max Thickness | 初始及上风补入新雾的贴地厚度上限，单位 m；0 不限制，低洼处不会在初始化时灌成厚雾池；已有 SWE 状态仍可堆积 |
| Concentration | 显示浓度，无量纲，默认 1；0 为无雾，修改不会重置 SWE |
| Noise Amplitude | 有符号 fBm 的高度振幅，单位 m，默认 0（关闭） |
| Noise Frequency | 空间频率，单位 1/m；小值形成宽雾带，大值形成细碎纹理 |
| Noise Octaves / Seed | fBm 层数／随机种子，相同配置确定性重现 |
| Noise Offset | X/Z 噪声采样偏移，单位 m；自然模式使用世界坐标，普通模式使用盒局部坐标 |

初态厚度为 `max(0, Base Height + Height Offset + Noise Amplitude × noise)`；水平雾顶模式在裁零前再减地形局部高度，然后应用 Max Thickness。边界渐出随后在 GPU 查询时应用。所有模式都使用这些噪波参数，包括 Natural Mist 与 SWE 初态，没有另一套隐藏的雾顶生成方式。

基础初态参数变化会在编辑器和运行时重新生成该盒体的初态厚度纹理，不重新烘焙地形；生成数据不写回共享资产，场景只保存参数；地形纹理在每次进入场景时重新烘焙，初态纹理随后在内存中重建。旧模式仍是静态初态显示。

保留 `presets/low_mist.tres`（有噪声）和 `presets/soft_layer.tres`（均匀薄雾），分层测试继续使用它们；森林示例的两个盒体改为共享 `presets/forest_mist.tres`。旧场景中的 `layer_height` 自动读取为新资源的 Base Height，不再写回旧属性。

## 自然薄雾

在 Initialization 的 **Natural Mist** 分组启用 **Natural Mist Enabled**。默认关闭，旧资源保持原有渲染。推荐同时启用 **Horizontal Top**，让雾顶减去地形高度后再裁零：低处积雾，高于雾顶的岩石不再被等厚覆盖。关闭 Horizontal Top 时仍可用于贴地层。

| 参数 | 含义与范围 |
| --- | --- |
| Top Softness | 顶部渐淡带占层厚的比例，0.1～1；下部连续，顶部平滑变淡 |
| Coverage | 显示覆盖率控制，0 无雾、1 连续层，中间值产生留白和雾带；不是精确面积百分比，不删除模拟质量 |
| Coverage Softness | 雾带到透明区域的过渡宽度，0.01～0.5；越小边界越清晰 |
| Detail Strength | 额外密度细节强度，0～0.8；0 关闭额外调制，但保留 Coverage |
| Detail Scale | 密度纹理相对高度噪波的尺寸倍率，0.25～8；1 为同一尺度 |
| Wind Stretch | 沿风向与横风向尺度比，1～8；同时拉伸初态高度噪波与显示密度 |
| Wind Direction | 世界 X/Z 平面风向，−180～180°；0 为 +X，90 为 +Z |
| Wind Speed | 0～1 m/s；自然模式 SWE 中输送厚度／扰动并开启边界补充／排出，0 停止风补入但仍可向外排出；静态模式仅漂移密度 |

资源生成一张可平铺 FastNoiseLite fBm 纹理，CPU 初态和 GPU 密度读取同一信号；不再在 shader 中重造哈希噪波。种子／层数变化更新缓存，频率／偏移在采样坐标上生效。旧 `top_variation`／`top_scale` 读取时迁移为 Noise Amplitude／Noise Frequency（1 / scale），Inspector 不再出现两组相互竞争的高度噪波参数。旧图案不保证逐像素一致。

**会重建初态并重置 SWE**：高度、厚度上限、Noise 全组，以及自然模式的 Wind Direction／Stretch。**只改显示、不重置模拟**：Concentration、Coverage、Coverage Softness、Top Softness、Detail Strength／Scale。Wind Speed 实时改变输送与边界、不重置状态。都无需重烘焙地形；动画不逐帧重建厚度纹理。

### 贴地雾带调参

森林共享预设 `presets/forest_mist.tres` 已配置：Base Height=2.55 m、Horizontal Top 开启、Max Thickness=0.38 m、Noise Amplitude=0.35 m、Frequency=0.4、Octaves=3、Coverage=0.5、Coverage Softness=0.12、Top Softness=0.85、Wind Stretch=4.5、Concentration=1.8。盒底均为世界 Y=−2 m，基准水平雾顶为 0.55 m；实际初始厚度受噪波、地形和 0.38 m 上限共同限制，并不是整片恒高的雾池。

- 更薄：降低 Max Thickness；若已经运行 SWE，需要重建初态才应用新上限。
- 更多地面留白：降低 Coverage；更淡：降低 Concentration。
- 更宽、更长的雾带：降低 Noise Frequency、提高 Wind Stretch。
- 想随山坡铺开：关闭 Horizontal Top，把 Base Height 改为约 0.2～0.4 m。此模式也会给岩石顶铺雾。
- 想保留设计好的厚度：关闭 SWE；需要起跳扰动则保留 SWE。可提高 SWE Gravity Threshold，让静止且不超阈值的薄雾不因重力摊平；超过阈值的厚度仍产生重力压力。阈值不是厚度硬下限，冲量与已有动量仍可搬运薄雾。启用自然模式 SWE 时，Wind Speed 会搬运厚度并从上风侧补雾、下风侧排雾；未启用 SWE 时仅移动疏密纹理。

自然模式保持竖向积分平均与盒边渐出。纹理在噪声空间以 32 单位重复（横风向世界周期为 `32 / Frequency` m），512² 有限分辨率；过高频率或层数仍可能被高度网格／froxel 漏采。森林保持时间重投影开启。完整边界见 [薄雾生成合约](../../doco/specs/heightfield-mist.md)。

## GPU SWE 与角色交互

主场景三个雾盒及森林两个雾盒均开启 **SWE Enabled**。每盒有独立厚度与相对背景风的 X/Z 扰动动量场，使用 GPU 浅水求解器推进，默认一阶，可选带 MC 限制器的二阶空间重建。`swe_solver.gd` 调度，`shaders/swe.glsl` 计算，输出 Texture2DRD 直接供 FogVolume 读取，正常帧不回读 CPU。

| 参数 | 含义 |
| --- | --- |
| SWE Enabled | 仅控制运行时模拟，默认关闭、主场景及森林启用；开关会重置运行时状态 |
| SWE Editor Enabled | 独立控制编辑器模拟，默认关闭；开启从初态运行，关闭回到静态初态，两次切换均重置厚度、动量与风偏移，不影响运行时开关 |
| SWE Paused | 暂停推进但保留当前状态，不接受新跳跃冲量或行走轨迹 |
| SWE Second Order | 默认关闭；开启 MC 限制器的二阶空间重建以减少输送模糊。切换重置物理初态，保留噪波显示相位；编辑器／运行时均生效，GPU 成本更高 |
| SWE Gravity | 约化重力，0.05～9.81 m/s²，默认 1.2；控制浅层波传播，不是环境重力 |
| SWE Gravity Threshold | 离承载面的厚度阈值，0～8 m，默认 0（关闭阈值）；只有超出部分产生重力压力。实时生效、不重置状态，不限制起跳／落地冲量或已有动量输送 |
| SWE Drag | 动量阻尼，0～4 s⁻¹，默认 0.45；不删除质量 |
| SWE Render Height | 动态堆积的显示保护高度，1～32 m，默认 8；不裁切模拟厚度，极端堆积需调大 |
| Reset SWE State | 从当前初始化资产重新开始，不重烘焙地形 |
| Jump Radius | 径向冲量范围，0.2～6 m，默认 2.5 |
| Jump Speed | 速度增量，0～4 m/s，默认 1.8；0 关闭冲量 |
| Movement Radius | 行走的有效近地体宽尺度，0.2～2 m，默认 0.65，与 Jump Radius 独立 |
| Movement Coupling | 行走动量耦合率，0～20 s⁻¹，默认 7；0 关闭行走推动 |
| Movement Wake | 平面尾流拖曳／环流强度，0～1，默认 0.65；0 保留前推／侧向分流 |

`disturb_mist(world_feet, radial_strength=1)` 将脚底转换为盒体局部坐标，向范围内已有厚度对应的动量注入一次径向冲量。有符号强度限定为 [−1, 1]：负值汇聚、正值扩散，0 不施加；省略时维持向外冲量。高差 1.5 m 外不施加；每个模拟批次最多四个事件，溢出替换最旧。厚度增减由后续 SWE 通量输送产生，不直接生成或删除雾量，无固定恢复时长。

主场景的控制器子类检测真实接地起跳／落地，分别发送 −0.8／+1 强度；可在根节点 **Player Mist Interaction** 调整。出生初次接地和空中二段跳不触发地面扰雾，落地向下速度需超过 1 m/s。释放鼠标期间仍会落地并扩散；森林保留原来的只在起跳向外扩散行为。未开启 SWE 时没有视觉替代。

主场景另将碰撞后真实接地轨迹送入 `push_mist(from_feet, to_feet, duration)`（世界脚底坐标、秒）。GPU 交换水平动量，形成前方推动、两侧分流及身后拖曳／反向平面环流；厚度由原 SWE 通量重分布，不直接清空路径。施力按物理时长积分，不按渲染帧重复叠加；站立、完全顶墙、空中不持续施力，高差 0.8 m 外隔离。停步后原尾流自然衰减，暂停期间不缓存轨迹。该近似不模拟三维下洗或热羽流；[调研依据与调参](../../doco/guides/playground.md#行走气流调研与二维近似)见实验场指南。森林示例未连接行走接口。

SWE 从与编辑器预览相同的噪波厚度启动，随后厚度完全来自求解器；不再被程序化雾顶覆盖。软顶部剖面和边缘渐出仍保留。初态参数、烘焙图或尺寸变化会重建状态；共享资产不保存模拟结果。地形岩石可以形成承载高度障碍，但树干、倒木的角色碰撞不自动进入 SWE。

### 输送细节对照

如果雾随风很快变平，可先把 **SWE Gravity Threshold** 设得高于初始最大厚度，排除重力压力，再使用相同风速切换 **SWE Second Order** 对比。每次切换都会从相同物理初态开始，暂停时切换也会重置。开启后用 MC 斜率限制器重建自由面和速度；干湿边、无效格和盒边附近回退到一阶。它减少数值扩散，不持续重加噪波，不阻止真实的重力流动。

这里只升级空间重建，时间子步仍为显式一阶；CFL 从 0.45 收紧到 0.3，模板采样更多，运行成本会上升。固定 GPU 正弦平移测试的 L1 误差从约 0.05556 降至 0.00931（约减少 83%），不保证每个场景都有相同比例改善。

### 风输送与边界补雾

在初始化资源中开启 **Natural Mist Enabled**，运行时开启节点 **SWE Enabled**；若要直接在编辑器预演，则开启独立的 **SWE Editor Enabled**：

- **Wind Direction** 为世界 X/Z 风向（0° 朝 +X、90° 朝 +Z），**Wind Speed** 为真实输送速度（m/s）。厚度和玩家扰动一起移动，盒体旋转不改变世界风向。
- 上风侧连续补入新雾，沿用 Base Height、Horizontal Top、Max Thickness、Noise 等初始化配置；连续采样同一张无缝噪波，不逐帧随机刷新。Horizontal Top 模式下，高于雾顶的入口补入厚度为零，可能形成下风缺雾带；这不代表入口未开放。Coverage、浓度及密度细节仍是显示控制。
- **无实体格的交界面与高度场盒边，都是生成／消失的位置**：风吹入有效格时补雾，雾流出时直接移除，不反弹，盒间不传递。
- 封闭孔洞同样适用，不要求与盒外连通；无效格本身始终不存雾，也不作为无限高的实体。重烘焙直接使用新的有效格分布，无需空域分类。
- **Wind Speed=0** 停止风补入，不重置已有雾；无风／横风的开放面仍允许重力与玩家扰动向外排出，不恢复反射墙。SWE Gravity Threshold 不阻止风搬运薄雾。
- **SWE Paused** 同时冻结厚度、边界补充／排出及密度漂移，静态预览、编辑器模拟与运行时均生效。编辑器模拟关闭时仍只漂移密度，不预演真实输送；开关模拟都会重建物理初态，但保留开启前的密度噪波起点，避免零步推进时细节突然变平／换图案。显式 **Reset SWE State**、形状参数变化或重新进入场景，才连同该密度起点一起归零。
- 风速实时生效、不重置；风向／拉伸属于初态形状参数，修改仍会重建。背景风不受 SWE Drag 衰减，Drag 只衰减相对风的扰动。开放盒总雾量允许变化。

手动验证建议：先设 Wind Direction=0°、Wind Speed=1 m/s、SWE Gravity Threshold 高于初始厚度，观察 +X 输送及跳跃扰动随风离开；再改为斜向风观察两边补入，最后将风速归零确认停止风补入与背景输送，但扰动仍可向外排出。纯风输送已做解析平移 GPU 对照，实际场景的边界画面仍由用户验证。

GPU 自适应 CFL 与排出量限制保证稳定性／非负；极端状态可能限速，卡顿超过追赶预算会记录丢时，不保证任意参数下实时追平。详见 [SWE 合约](../../doco/specs/heightfield-swe.md)。

## 高度与边界

- 网格位于盒体局部 X/Z，随 Y 旋转；底面高度为 0，顶面为 Size.y。逐采样点判断原始三角形与高度区间的交点，跨盒顶的斜面保留内部部分，不把超界高度压到盒顶。
- 只保留盒内最高一层；用不同高度范围的盒体隔离上下层。没有承载面的格子无效，整盒为空时保留上次烘焙并警告。
- 查询时取局部 X/Z 到最近侧边的距离 d，雾层厚度乘 `smoothstep(0, Edge Fade, d)`。边界处厚度为 0，地形高度不变；同时降低面雾量，不通过提高浓度补偿变薄。旋转后仍按局部侧边计算，不沿世界外接矩形渐出。
- 盒顶只限制**烘焙承载面**，不是动态雾层的硬顶盖。原生 FogVolume 在 Y 方向留有薄层过滤余量。旧模式对归一化平滑密度曲线做积分平均；自然模式对下部连续、顶部渐淡的曲线做积分平均，减少极薄层漏采样。

## 当前范围

支持静态初态、自然薄雾显示和可选的 GPU SWE 厚度／动量推进。没有三维空气模拟、旧玩家交互求解器、专用阻挡面或四面体，不改变角色碰撞。旧 SWE 求解器及旧雾效已移除，本 addon 是当前唯一雾效实现。多个盒体使用独立高度纹理，由原生体积雾累积，重叠处更浓。

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

GPU timing 为每盒最近完成且有时间戳采样的模拟提交批次（可能含多个 tick），不是每渲染帧固定成本。无可用 timestamp 时报告不可用，不用 CPU 时间替代。`swe_snapshot()` 只供显式诊断，可能等待 GPU，不在常规更新／计时区间调用。首次使用需让 Godot 图形编辑器导入 `shaders/swe.glsl`；验证必须用 Forward+，不能用 headless 冒充 GPU 测试。
