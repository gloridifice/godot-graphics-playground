# 资源驱动的贴地薄雾

本文的初态公式、烘焙生命周期和外观合约适用于两种模拟后端。`simulation_method` 默认 SWE，另可选 Stable Fluids；原 `swe_enabled`／`swe_editor_enabled`／`swe_paused` 名称兼容保留，控制当前后端。下文有关压力、堆积和 SWE 风输送的描述专指 SWE；Stable Fluids 的被动基础厚度、临时高度乘数、局部材质输送和开放回溯规则见 [独立合约](heightfield-stable-fluid.md)。两后端切换重建同一资源初态、保留预览密度起点，不迁移动态状态。

## 唯一生成入口

`HeightfieldFogInitialization` 是可保存、共享和 Make Unique 的 `.tres` 资源。普通模式、Natural Mist 静态预览、SWE 与 Stable Fluids 初态都调用 `create_thickness(terrain, extent, box_transform)`；Natural Mist 不得绕过 Noise 参数，也不得在显示 shader 中重新构造另一套高度。SWE 上风边界在计算 shader 中复用同一资源的高度公式及噪波信号，连续生成新厚度，不引入第二套噪波参数。

每个有效承载格的初态厚度：

1. `top = base_height + height_offset + noise_amplitude × n`，其中 `n` 为 [-1, 1] 的确定性 fBm 信号。
2. Horizontal Top 开启时 `h = max(top - ground, 0)`，否则 `h = max(top, 0)`。所有高度均相对盒底。
3. Max Thickness 大于零时 `h = min(h, max_thickness)`；零表示不限。先减地形再裁零／限厚，高于雾顶的岩石和无承载格不因此获得雾层。

Max Thickness 限制**初始及上风边界新补入**的贴地厚度，不是已有 SWE 状态的质量裁切或显示截断，也不裁切 Stable Fluids 高度增益后的厚度。模拟可继续向低处输送、堆积，不能承诺长期保持初始形状。关闭 SWE 可保留设计厚度；这时没有起跳响应。

## 高度场生命周期

承载高度图及其烘焙签名只驻留在每个雾盒节点的内存中，不序列化到 PackedScene、`.tscn` 或高度图资源文件。保存并重新加载场景时，进入场景树前不能保留上次烘焙结果；初始化参数仍正常保存。

编辑器与运行时每次进入场景树都会清空旧缓存，延后两个处理帧等待静态源几何生成后自动烘焙；复用同一实例重新进入也必须重新采样。CSG 雾实验场在此前刷新派生网格。烘焙本身不将编辑器场景标记为未保存。场景停留期间不逐帧重烘焙；布局或源几何编辑仍通过手动烘焙更新，无承载面时不替换当前内存缓存。

## 噪波信号与坐标

资源内部用 FastNoiseLite Smooth Simplex / fBm 生成 512² 无缝噪波图，使用固定 [-1, 1] 到 [0, 1] 映射，不按每张图的极值归一化对比度。噪声空间周期为 32；种子、层数决定缓存内容，频率以每米单位作用于采样坐标。

普通模式采样盒局部 X/Z；自然模式先把格中心变换到世界 X/Z，加 Noise Offset，再投影到风向／横风向，沿风向除以 Wind Stretch。之后乘 `Noise Frequency / 32` 取得纹理坐标。CPU 使用与 GPU 一致的重复、双线性采样；相同世界位置不因盒平移、Y 旋转而改变信号。不同分辨率的地形厚度插值仍可能产生边界差异。

共享资源仅缓存盒体无关的噪波图／纹理，不缓存某盒的地形、厚度或模拟状态。编辑种子／层数会使缓存失效；无需重新烘焙地形。Noise Amplitude=0 关闭高度扰动，但不关闭独立的显示覆盖率和密度细节。

## 自然模式显示

shader 始终读取初始厚度纹理或所选求解器的 Texture2DRD 输出。Stable Fluids 另输出局部流场输送的世界反向材质位移，用于 Coverage／密度细节，并替代全局 GPU 风位移，不能双加；零步初始化时位移为零，切换保留相同显示起点。沿地形上方的薄层计算下部连续、顶部 smoothstep 衰减的密度，并对竖向过滤区间做解析积分平均。盒侧边渐出作用于厚度，不抬高地形；FogVolume 预留完整初态厚度和过滤余量。

显示密度从同一噪波纹理采样。Detail Scale 是相对高度噪波的尺寸倍率，1 表示相同尺度。未启用 SWE 时，按节点处理帧的 delta 积分世界风速来平移**密度**采样坐标，不使用进程启动时间、不平移静态厚度；SWE Paused 同样冻结该预览偏移。启用 SWE 时保留当前预览密度偏移作为固定显示起点，异步 GPU 初始化期间也不继续漂移，随后仅叠加 GPU 积分的输送偏移，因此零步推进时切换前后画面一致。Wind Speed 控制真实厚度及扰动输送，上风补雾、下风排雾；边界用资源的同一高度公式和无缝噪波连续生成，密度显示与边界共享 GPU 积分的输送偏移，不再另叠一层持续运行的时间漂移。关闭 SWE 清除输送偏移，恢复该固定显示起点及资源初始厚度。显式 Reset simulation state、形状参数变化或重新进入场景会同时清零预览密度偏移。暂停同时冻结模拟和密度风偏移。详见 [SWE 风输送合约](heightfield-swe.md#风输送与开放边界)。

Coverage=0 时没有可见雾；Coverage=1 时连续覆盖；阈值为 `lerp(1 + Coverage Softness, -Coverage Softness, Coverage)`，在阈值 ±Coverage Softness 间做 smoothstep 过渡，端点无突变。Coverage 是艺术控制量，不是实际可见面积百分比。Detail Strength 再对层内密度作有限调制；浓度与覆盖率均不改动 SWE 质量。

## 编辑与兼容

- **重建初态／重置 SWE**：Base Height、Height Offset、Horizontal Top、Max Thickness、Noise 全组、Natural Mist Enabled，以及自然模式下的 Wind Direction／Stretch。换初始化资源、重烘焙、改盒尺寸／变换和开关 SWE 也会重建。
- **只改显示、保留物理状态**：Concentration、Coverage／Softness、Top Softness、Detail Strength／Scale，以及节点外观参数。
- **实时改变模拟、不重置状态**：Wind Speed 控制自然模式的背景输送速度及上风补入；设为 0 停止风补入，无实体处及盒边仍允许压力／扰动向外排出，不恢复反射墙。SWE Gravity Threshold 控制超出部分的重力压力，不阻止风输送。
- 编辑器默认显示静态初态，可通过独立的 SWE Editor Enabled 开启同一 GPU 模拟；开启与关闭均重置厚度、动量及风偏移，关闭回到静态初态。该开关不影响运行时 SWE Enabled，动态预览不序列化。编辑器与运行时 SWE 的第一份状态都来自同一资源初态，之后按求解器推进；SWE Paused 均适用。暂停不应令外观编辑丢失已经产生的扰动。
- 旧节点 `layer_height` 读取为 Base Height。旧自然资源 `top_variation` 读取为 Noise Amplitude，`top_scale` 读取为 Noise Frequency 的倒数；不再导出第二组高度噪波控件。噪波算法统一后不保证旧图案逐像素相同，Detail Scale 现在是倍率而非米。

## 验证与边界

- `initialization_test.gd`：厚度公式、限厚与无效格／高岩石、确定性、种子／层数／偏移编辑、旋转／平移共享场、资源持久化、旧资产迁移。
- `natural_mist_test.gd`：真实 Forward+ 图像中频率影响静态和暂停的 SWE 初态；低处有雾／高岩石干燥；顶部软化、世界坐标一致性、零风／漂移；非零风、零步推进下启用／关闭 SWE 保持预览密度相位，且诊断时钟确为 0；覆盖率端点；调浓度／覆盖率后恢复原值仍保留暂停的已扰动状态。
- 森林预设使用水平雾顶加限厚生成薄层，密度遮罩形成间隙，不引入新的外部贴图或美术素材。

噪波有限分辨率且周期重复，横风向世界周期为 `32 / Frequency` m，沿风向再乘 Stretch。高频率／高层数可能超过高度网格或体积 froxel 的采样能力；不承诺任意参数、视角下无走样。重叠盒仍累积浓度；内部无效格没有额外距离场羽化；这是 2.5D 层而非三维湍流、浮力混合或绕障碍空气模拟。SWE 边界见 [局部高度雾 SWE 合约](heightfield-swe.md)。
