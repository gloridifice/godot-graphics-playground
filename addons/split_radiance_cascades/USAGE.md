# Split Radiance Cascades：Godot 4 漫反射间接光

打开 [`demo.tscn`](demo.tscn) 即可在 **3D 编辑视口**看到 GI。也可以按 **F6** 运行：**G** 对比原生照明与 GI，**B** 切换单次／多次反弹，**← →** 移动相机。先看矮台下方和两侧墙映到白色物体上的颜色；切换反弹模式后等几十帧再比较。

这是 [Ray Splitting 实现文章](https://www.jacktollenaar.top/articles/split-rc.html)中稀疏 3D 辐射级联的 Godot 实现。屏幕深度用于定位可见表面和匹配接收面材质；射线求交使用世界空间三角形，所以光源和遮挡物不必出现在画面里。不要求硬件光追，不修改引擎，也不替换 Godot 的直接照明。

## Sponza 预览与耗时

打开 [`scenes/sponza_src_preview.tscn`](../../scenes/sponza_src_preview.tscn)，切到 **3D**，无需按 F6。可用编辑器相机自由观察，或选中 `Camera3D` 并勾选视口里的 **Preview**，从中庭相机看背光布幔与柱子。选 `WorldEnvironment/SplitRadianceCascades`，在 Inspector 切换 **Preview In Editor** 对比原生照明；这不会关闭游戏里的 GI。要单看反弹光，在 **Debug → View** 选 **Indirect Only**。首次打开或重新启用时需构建静态快照。移动或调整 `Subject/GalleryLight` 时，间接光自动更新，不用点重建。相机和灯光停下后，视口会再绘制几十帧积累光照，随后恢复按需刷新，不必开启编辑器的持续更新。若更新 addon 脚本时场景已开着，且视口还在使用旧预览，把 **Preview In Editor** 关开一次即可，不必重启编辑器。

**F6 运行时**：**1 / 2 / 3** 切换中庭、上层回廊、底层拱廊；**WASD** 飞行、**方向键** 转向、**Q/E** 降低／升高、**Shift** 加速，不捕获鼠标。G/B/V/C 与小房间相同。按 G 观察背光布帘和柱廊的亮度变化。场景使用 Intel Sponza 2022 与 Colorful Curtains；约 43 万个可见三角形及 2K JPG（质量 85）PBR 贴图用于画面和接收面，隐藏的同源代理仅用于射线，没有上游烘焙 GI。[模型与授权说明](../../assets/sponza/SOURCE.md)。

两个场景运行时右上角默认显示毫秒表，**P** 隐藏面板并停止采样，再按恢复。`Viewport` 是 Godot 对该视口的渲染 CPU／GPU 时间，不是整个进程的 CPU 时间，也不是用 FPS 换算的帧间隔。`SRC total` 是同一个 SRC 回调内八段之和：Prepare（含绑定与参数更新）、Trace（含可选次级射线）、Gather、Parents（全部父级）、Deposit、Merge（全部级联）、Receiver（光栅化接收面底色）、Apply（探针插值与合成）。与旧版比较材质读取和合成开销时，用 **Receiver + Apply** 对照旧 Apply。CPU 列是渲染线程提交命令的时间，GPU 列来自设备时间戳，两列不能相加。

SRC 最快每 250 ms 采一次，异步读取已完成帧，不等待 GPU。视口与 SRC 两行不一定来自同一帧；首次预热、SRC 关闭、没有有效 GPU 时间等均显示 `—`，不是 0 ms。首帧主线程构建静态 BVH 的耗时不在逐帧 SRC 表内。普通场景没有面板时，`Profile Stages` 默认关闭；需要自定义 HUD 可开启它并订阅节点的 `timings_updated(times_ms)`。

## 接入自己的场景

1. 使用 **Forward+、单目、关闭 MSAA 3D**。将整个 `addons/split_radiance_cascades/` 放入项目，等待 Godot 导入 GLSL。无需启用编辑器插件。
2. 在生效的 `WorldEnvironment` 下添加一个 **SplitRadianceCascades** 子节点。保留相机的 Compositor 为空，让它使用世界的合成链。节点在运行时追加效果，退出时恢复原链。需要在 3D 编辑视口中查看时勾选 **Preview In Editor**（新节点默认关闭，两个示例均已开启）。预览只覆盖当前编辑世界的渲染合成链，不改写场景中保存的 Compositor；关闭预览或切换场景会撤下效果并释放其 GPU 资源。
3. `Source Root` 指向要参与 GI 的静态网格与灯光的共同父节点；留空取当前场景。用 `split_rc_ignore` 分组排除整个子树。高面数模型可另指定 `Trace Proxy Root`：提供世界位置对齐的低模，隐藏其根节点。此时所有射线只对代理求交，可见接收面与灯光仍取自 `Source Root`。留空则用同一几何显示和追踪。先用一块白色接收面和一块有面积的自发光面检查效果；对照时关闭其他 GI，避免间接光叠加。
4. `Source Root` 内的 Directional／Omni 灯可实时移动、调色、调能量（含 `Indirect Energy`）、调整点光源范围／衰减，以及显示／隐藏、添加／删除。有效灯光变化时只上传灯光数据、清空探针历史，不重建 BVH 或接收面。移动相机也不需要重建。修改静态几何、材质、网格可见性或源／代理路径后，才在 Inspector 点 **Rebuild GI Snapshot**，或在运行时调用 `rebuild()`。仅显示 `Strength` / `View` 的调整不清历史。

| 参数 | 调整效果 |
| --- | --- |
| Probe Spacing | 最近级联的格宽，默认 0.4 m。减小可保留细节，但更容易耗尽槽位。 |
| First Interval | 最近区间的终点，默认 0.6 m。LOD 0 的 C0／C1／C2 终点分别是它的 1、4、16 倍；再远的真实命中都归入 C3。它不限制射程。 |
| LOD Distance | 距离基准，默认 8 m。远处改用更大的格子，过渡带把同一射线的样本权重拆给两级（总和为 1），查询时再混合两个估计值。改变空间 LOD 不改变方向数。 |
| Ray Stride | 每个 N×N 像素块每帧追一条主射线，默认 N=4；采样点轮换。增大更快，稀疏区域收敛更慢。 |
| History Retention | 上一帧局部区间样本权重的保留率，默认 0.94；设为 0 可看单帧估计。 |
| Multi Bounce | 从主射线命中点再发一条射线，写入独立标识、粗两级的次级探针，并读取上一帧次级光照；不是每像素无限递归追踪。 |
| Prefer Hardware Trace | 默认关闭。设备支持 Godot 4.7 的 `SUPPORTS_RAYTRACING_PIPELINE` 时，单独的光追阶段处理主、次级和遮挡射线；其余阶段不变。切换会重建静态快照。不支持时仍使用软件 BVH；开关不会自动改变 `Trace Proxy Root`。 |

**V** 依次查看合成、仅间接光、稳定槽位颜色、距离 LOD、未合并的局部区间辐射；**C** 在槽位／区间视图中选择 C0–C3。槽位视图的黑洞通常意味着没有样本或哈希桶已满，可先增大 Probe Spacing。区间视图只显示命中落在所选距离段的辐射，不是最终亮度。

## 每帧实际计算什么

- [`scene_snapshot.gd`](scene_snapshot.gd) 按需收集三角形并构造带跳过索引的 BVH；[`scene_lights.gd`](scene_lights.gd) 通过节点进出树维护候选灯列表，主线程只检查这些灯，不逐帧扫描网格。数据未变时不上传。 [`cascade_effect.gd`](cascade_effect.gd) 在渲染线程用全局 RenderingDevice 调度射线、探针和接收面绘制。正常帧没有 GPU → CPU 读回。
- [`trace.inc`](shaders/trace.inc) 从反向 Z 深度和法线重建出发点，以扰动的 R2 序列采样半球并求最近交点。入射辐射来自自发光、命中面上带遮挡的近似直接光，以及可选的上一帧反弹。
- [`grid.inc`](shaders/grid.inc) 为采样到的表面分配底层格，再由活跃子格生成父格。四个级联的方向桶数为 **8 / 32 / 128 / 512**。完整格键包含有符号位置与 LOD／主次缓存标识；桶槽冲突时不借用别的格子的历史。
- [`merge.inc`](shaders/merge.inc) 在首次命中的区间记录光，在此前穿过的区间记录透射率。只累计**未合并的局部区间**，然后从远到近计算 `L近 + T近 × L远`。没有当前样本和有效历史的方向不参与合并；测得黑色遮挡仍是有效样本，只有测得透射才会引入远处光。四个子方向合为一个父方向；空间上只混合存在的邻居，按三线性权重与样本置信度归一化。
- [`receiver_pass.gd`](receiver_pass.gd) 按材质批绘制快照三角形，只在与视口深度匹配的像素写入底色；不改视口深度。Apply 按法线对底层方向积分，乘以采样到的线性漫反射率，再写回 HDR。没有匹配的接收面不加 GI；不再为每个像素追一条 BVH 射线，也不用已照亮的屏幕颜色代替 albedo。

## 适用范围

- 面向**静态、不透明、漫反射**场景。支持 `MeshInstance3D` 上的三角形 `ArrayMesh` / `PrimitiveMesh`（含表面材质覆盖）。可见接收面使用 `BaseMaterial3D` 底色 × (1 − 金属度)，支持普通 UV1 底色与金属度贴图及其选取的通道（含 UV 缩放、偏移和重复）。世界空间射线每次命中仍只读取一个材质反射率。重建快照时，对参与求交且有贴图的材质，[`hit_reflectance.glsl`](shaders/hit_reflectance.glsl) 用同一 UV 采样底色（sRGB 解码到线性）与金属度（线性指定通道 × 系数），取漫反射率的均值。清空 `Trace Proxy Root` 后使用原模型自己的材质，不依赖隐藏代理；不会把 glTF 的金属度系数 `1` 误当成每个纹素都是金属。仅在重建时计算，不逐帧读回，不按射线交点还原局部花纹。三平面映射回退到常量底色；不复现顶点色、细节层、自发光贴图、镜面反射或天光。自定义 ShaderMaterial、透明、蒙皮、MultiMesh、CSG 不作为追踪几何。光照按双面三角形近似；射线未命中返回黑。避免可见网格的原生几何 LOD 与接收面快照明显不一致，否则深度不匹配的像素不会叠加 GI。
- 软件 BVH 求交快照最多 65,536 个非退化三角形。可选的硬件路径没有这项软件预算：相同 Mesh 的同一表面共享 BLAS，TLAS 记录各实例的变换与材质映射。它仍受设备资源限制，且不会自动替换粗代理；独立的灯光缓冲最多 8 盏 Directional／Omni 灯。使用独立追踪代理时，此三角形预算不限制可见网格。灯光是漫反射近似，不复现全部 Godot 光度学、光照层或阴影选项。空快照或三角形超额会给出警告并停止该快照的间接光，而不是使用不完整的遮挡物。
- 每级固定 8,192 / 2,048 / 512 / 256 个槽；方向桶合计约 **20 MiB**，射线暂存最多 **16 MiB**，另需场景 BVH、静态接收面顶点与 UV（每顶点 20 字节，另加每三角形 12 字节索引），以及每个内部渲染像素 4 字节的底色附件。超大分辨率会自动增大实际 stride。未触及的槽保留 32 个渲染回调，之后回收；8 路哈希桶已满时丢弃新格。格网相对 Source Root 原点（非 Node3D 则为世界原点），每轴各 LOD 可表达 `[-256,255]` 个格，接近边界时优先用较粗 LOD，最粗层之外不回绕。
- 低角分辨率、格宽大于薄墙、屏幕上过小的表面都可能导致漏光或闪烁。固定点原子累加将单次入射辐射每通道裁在 `[0,64]`。这是间接漫反射实验，不是对文章画质或耗时的保证；也不改变雾、碰撞、主场景和输入映射。

## 验证

项目根目录运行（需要真实图形设备，不要加 `--headless`）：

```powershell
godot --path . --script res://addons/split_radiance_cascades/tests/interval_bins_test.gd
godot --path . --script res://addons/split_radiance_cascades/tests/render_test.gd --max-fps 90
godot --path . --script res://tests/sponza_src_preview_test.gd --max-fps 90
godot --path . --editor res://addons/split_radiance_cascades/tests/editor_preview_test.tscn -- --test-src-editor
```

最后一条启动独立编辑器并在检查后退出：从 3D 编辑视口读回照明，验证点光源切色及关闭间接光时无需重建、不留旧色；静态反射面仍需手动重建。也检查预览开关、默认 `Source Root` 和保存隔离。

方向桶测试让同一个亮父级对应未采样、遮挡和透射方向，回读真实 GPU 结果并检查过渡带的样本权重。运行时画面测试区分远处真实命中与未命中，也检查近遮挡、稳定世界格、次级反弹、贴图反射率、被排除表面、动态点光源的增删与父节点变换／可见性，以及卸载恢复。以上测试与 Sponza 预览测试均在 Godot 4.7.2 / Forward+ / RTX 3070 上通过 D3D12 和 Vulkan。修改共享的 `shaders/*.inc` 后重新导入 `cascades.glsl` 和 `hardware_trace.glsl`。运行时渲染测试、编辑器测试的用户参数可追加 `--prefer-hardware-trace` 检查硬件路径或设备回退。

### Sponza View 3：软件与硬件求交实测

Godot 4.7.2 Mono / Forward+ / Vulkan，RTX 3070，固定 Arcade 相机，单次反弹、stride 6、三盏点光源、LOD Distance 7，关闭垂直同步，渲染比例 1。三个配置轮换次序，各跑三次；每个分辨率先预热至少 100 帧且至少 2.4 秒。每格合并 84 个完整 SRC GPU 时间戳样本；视口用同一采集窗口内的独立 GPU 样本。单位 **ms**。不含首次加载、编译和建树，不是 FPS。

| 分辨率 | 射线求交几何 | Trace 中位数 | SRC 总计中位数 | 视口中位数 / P95 |
| --- | --- | ---: | ---: | ---: |
| 720p | 软件 · 51,372 面代理 | 3.280 | 3.707 | 4.342 / 5.006 |
| 720p | 硬件 · 相同代理 | 0.069 | 0.502 | 1.168 / 1.584 |
| 720p | 硬件 · 426,964 面可见不透明几何 | 0.082 | 0.527 | 1.298 / 1.698 |
| 1080p | 软件 · 51,372 面代理 | 4.862 | 5.689 | 6.955 / 9.978 |
| 1080p | 硬件 · 相同代理 | 0.124 | 0.992 | 2.317 / 2.923 |
| 1080p | 硬件 · 426,964 面可见不透明几何 | 0.144 | 1.028 | 2.559 / 3.371 |

可见画面始终是同一份 430,092 面模型。第三组仅在内存中用显示网格的不透明表面做射线求交（排除 3,128 面透明贴花），使用代理的同名常量命中材质，保持接收面、贴图和灯光不变。这样能区分硬件加速和使用贴合拱顶的几何带来的变化。要测**编辑器里实际清空代理**的路径，用 `no-proxy`：几何与 `visible` 相同，但使用原模型的贴图计算命中反射率，不替换材质。本机 D3D12 不提供光追管线，不应把 Vulkan 硬件结果套用到 D3D12。

```powershell
foreach ($mode in 'software', 'hardware', 'visible') {
    godot --path . --rendering-driver vulkan --disable-vsync --max-fps 0 --script res://tools/profile_sponza_src.gd -- $mode
}
```

无用户参数时仍测中庭 Nave。更换资产、视角、分辨率或反弹模式后应重新测量。
