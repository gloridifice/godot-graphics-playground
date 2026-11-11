# 资源驱动的贴地薄雾

## 唯一生成入口

`HeightfieldFogInitialization` 是可保存、共享和 Make Unique 的 `.tres` 资源。普通模式、Natural Mist 静态预览、SWE 初态都调用 `create_thickness(terrain, extent, box_transform)`；Natural Mist 不得绕过 Noise 参数，也不得在 shader 中重新构造另一套高度。

每个有效承载格的初态厚度：

1. `top = base_height + height_offset + noise_amplitude × n`，其中 `n` 为 [-1, 1] 的确定性 fBm 信号。
2. Horizontal Top 开启时 `h = max(top - ground, 0)`，否则 `h = max(top, 0)`。所有高度均相对盒底。
3. Max Thickness 大于零时 `h = min(h, max_thickness)`；零表示不限。先减地形再裁零／限厚，高于雾顶的岩石和无承载格不因此获得雾层。

Max Thickness 是**初始**贴地厚度上限，不是 SWE 的质量裁切或显示截断。模拟可继续向低处输送、堆积，不能承诺长期保持初始形状。关闭 SWE 可保留设计厚度；这时没有起跳响应。

## 高度场生命周期

承载高度图及其烘焙签名只驻留在每个雾盒节点的内存中，不序列化到 PackedScene、`.tscn` 或高度图资源文件。保存并重新加载场景时，进入场景树前不能保留上次烘焙结果；初始化参数仍正常保存。

编辑器与运行时每次进入场景树都会清空旧缓存，延后两个处理帧等待静态源几何生成后自动烘焙；复用同一实例重新进入也必须重新采样。CSG 雾实验场在此前刷新派生网格。烘焙本身不将编辑器场景标记为未保存。场景停留期间不逐帧重烘焙；布局或源几何编辑仍通过手动烘焙更新，无承载面时不替换当前内存缓存。

## 噪波信号与坐标

资源内部用 FastNoiseLite Smooth Simplex / fBm 生成 512² 无缝噪波图，使用固定 [-1, 1] 到 [0, 1] 映射，不按每张图的极值归一化对比度。噪声空间周期为 32；种子、层数决定缓存内容，频率以每米单位作用于采样坐标。

普通模式采样盒局部 X/Z；自然模式先把格中心变换到世界 X/Z，加 Noise Offset，再投影到风向／横风向，沿风向除以 Wind Stretch。之后乘 `Noise Frequency / 32` 取得纹理坐标。CPU 使用与 GPU 一致的重复、双线性采样；相同世界位置不因盒平移、Y 旋转而改变信号。不同分辨率的地形厚度插值仍可能产生边界差异。

共享资源仅缓存盒体无关的噪波图／纹理，不缓存某盒的地形、厚度或模拟状态。编辑种子／层数会使缓存失效；无需重新烘焙地形。Noise Amplitude=0 关闭高度扰动，但不关闭独立的显示覆盖率和密度细节。

## 自然模式显示

shader 始终读取初始厚度纹理或 SWE 的 Texture2DRD 输出。沿地形上方的薄层计算下部连续、顶部 smoothstep 衰减的密度，并对竖向过滤区间做解析积分平均。盒侧边渐出作用于厚度，不抬高地形；FogVolume 预留完整初态厚度和过滤余量。

显示密度从同一噪波纹理采样。Detail Scale 是相对高度噪波的尺寸倍率，1 表示相同尺度。Wind Speed 仅随共享引擎时间沿世界风向平移**密度**采样坐标，不平移静态厚度，不向 SWE 注入动量。零风速与暂停的物理状态共同保证静止画面。

Coverage=0 时没有可见雾；Coverage=1 时连续覆盖；阈值为 `lerp(1 + Coverage Softness, -Coverage Softness, Coverage)`，在阈值 ±Coverage Softness 间做 smoothstep 过渡，端点无突变。Coverage 是艺术控制量，不是实际可见面积百分比。Detail Strength 再对层内密度作有限调制；浓度与覆盖率均不改动 SWE 质量。

## 编辑与兼容

- **重建初态／重置 SWE**：Base Height、Height Offset、Horizontal Top、Max Thickness、Noise 全组、Natural Mist Enabled，以及自然模式下的 Wind Direction／Stretch。换初始化资源、重烘焙、改盒尺寸／变换和开关 SWE 也会重建。
- **只改显示、保留物理状态**：Concentration、Coverage／Softness、Top Softness、Detail Strength／Scale、Wind Speed，以及节点外观参数。
- 编辑器显示静态初态；运行时 SWE 的第一份状态来自同一初态，之后按求解器推进。暂停不应令外观编辑丢失已经产生的扰动。
- 旧节点 `layer_height` 读取为 Base Height。旧自然资源 `top_variation` 读取为 Noise Amplitude，`top_scale` 读取为 Noise Frequency 的倒数；不再导出第二组高度噪波控件。噪波算法统一后不保证旧图案逐像素相同，Detail Scale 现在是倍率而非米。

## 验证与边界

- `initialization_test.gd`：厚度公式、限厚与无效格／高岩石、确定性、种子／层数／偏移编辑、旋转／平移共享场、资源持久化、旧资产迁移。
- `natural_mist_test.gd`：真实 Forward+ 图像中频率影响静态和暂停的 SWE 初态；低处有雾／高岩石干燥；顶部软化、世界坐标一致性、零风／漂移；覆盖率端点；调浓度／覆盖率后恢复原值仍保留暂停的已扰动状态。
- 森林预设使用水平雾顶加限厚生成薄层，密度遮罩形成间隙，不引入新的外部贴图或美术素材。

噪波有限分辨率且周期重复，横风向世界周期为 `32 / Frequency` m，沿风向再乘 Stretch。高频率／高层数可能超过高度网格或体积 froxel 的采样能力；不承诺任意参数、视角下无走样。重叠盒仍累积浓度；内部无效格没有额外距离场羽化；这是 2.5D 层而非三维湍流、浮力混合或绕障碍空气模拟。SWE 边界见 [局部高度雾 SWE 合约](heightfield-swe.md)。
