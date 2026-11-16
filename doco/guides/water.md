# 水体使用指南

## 入口

用 Godot 4.7.2 / Forward+ 打开 `scenes/water_playground.tscn`，F6 运行。项目 F5 主场景仍是原来的雾实验场。

- 鼠标右键拖动：环绕；滚轮：缩放。
- P：暂停／恢复 FFT 与 SWE。
- R：重置整个水体及时间。
- B：重烘焙当前 CSG 地形并重建水体。
- C／F／S：分别开关物理焦散、泡沫、自定义 SSR；V：切换正常／焦散照度／泡沫不透明度／SSR only。
- 左上角 Sim GPU 是 FFT／SWE／泡沫及发布的真实时间，另列 CPU 提交时间；不包含焦散、SSR 和整帧渲染。初次无样本为 −1，不把 CPU 时间当 GPU 成本。

默认示例包含可编辑 CSG 沙坡、方岩、球形岩石和水下标记，开启折射光束焦散、近／远海泡沫和水面自定义 SSR。几何仍为内建网格，新带三种有来源／许可记录的 NSH 数据纹理；没有湿沙、粒子浪花或角色控制器。

## 在自己的场景中使用

1. 启用 `addons/water/plugin.cfg`（本项目已启用）。新建 `WaterBody3D`，将节点 Y 放到平均水位。节点及祖先只使用平移／Y 旋转，保持单位缩放。
2. 给水体设置 `WaterSurfaceSettings` 与 `WaterMaterialSettings`。默认创建的内嵌资源可直接编辑；需要复用时 Save As `.tres`。
3. 添加直接子节点 `FFTDeformer3D`，分配 `WaterFFTSettings`。不需要远海波浪时可禁用该节点。
4. 添加直接子节点 `SWEDeformer3D`，分配 `WaterSWESettings` 和 `WaterBakeSettings`，把区域盒底放在海床下。首版每个水体最多启用一个 FFT 和一个 SWE 区域。
5. 给 SWE 的 **Source Root** 指定静态场景几何；可以是包含 MeshInstance3D 和 CSG 的父节点。用区域 Gizmo 的宽／高／深手柄调整范围，或直接修改 Bake Settings 的 Size。高度区间应覆盖海床和岸上障碍顶面。
6. 点击 **Bake water bed**（或父水体 **Bake water bed + reset**）。首次进入场景自动等待两帧烘焙；之后编辑几何需要显式重烘焙。
7. 编辑器默认显示 t=0 静态水面；水体的 **Editor Simulate** 可开启 GPU 预览。**Paused** 可冻结状态进行材质对比。预览历史不随场景保存。

8. 效果按需启用：给水体分配 Caustics／Foam／Foam Material／SSR 资产。物理焦散还需将 **Sun Path** 指向场景 DirectionalLight3D；没有 SWE 时明确指定 Flat Bed Depth，不能从任意不透明几何自动推断海床。

Source Root 的引用和节点变换属于场景；数值配置属于参数资产。共享 `.tres` 的修改会影响全部引用者，单独调参先 Make Unique。

## 九类资产

| 类型 | 主要参数 | 修改效果 |
| --- | --- | --- |
| `WaterFFTSettings` | 分辨率、周期长度、Phillips 功率／长度、风向、种子、波高增益 | 重建波谱及 SWE；已有有效实例时保留共同时间，从当前 FFT 相位初始化 |
| 同上 | Choppiness | 改水平挤浪及远海泡沫雅可比输入，不重置 SWE／历史 |
| `WaterSWESettings` | 分辨率、一阶／二阶、重力、Manning、子步预算、FFT 边界、松弛、过滤和输入增益 | 重建 SWE；分辨率变化还使烘焙失效 |
| 同上 | Surface Mode、Normal Strength、Blend Depth | 实时显示／光学，不改模拟；Blend Depth 仅用于旧 Depth Blend |
| `WaterBakeSettings` | 区域尺寸、缺失格补底及高度、忽略分组 | 旧烘焙失效，需重烘焙 |
| `WaterSurfaceSettings` | 显示尺寸、网格精度、位移包围盒余量 | 只重建显示网格，保留模拟 |
| `WaterMaterialSettings` | RGB 消光、散射、反射、折射率、粗糙度、快速折射、干水阈值、调试视图 | 实时更新显示，保留模拟 |
| `WaterCausticsSettings` | 光束／接收精度、范围、平底深度、光程／遍历预算、强度／过滤 | 只更新或重建焦散，不重置水体 |
| `WaterFoamSettings` | 背景／前沿源、寿命／拖曳、输送阶数、周期、远海雅可比、N/R | 普通编辑保留历史；N/R 模式切换重建近岸 |
| `WaterFoamMaterialSettings` | 三种 NSH、颜色、尺寸、微法线、粗糙度、不透明度、视觉抬高 | 只改显示，不改变泡沫量／动量 |
| `WaterSSRSettings` | 开关、米制距离、像素步数、容差／偏移、强度 | 只更新水面 SSR 材质参数 |

`presets/` 内的 beach_* 和 clear_water 是实际可保存、共享的示例资产，不是代码中隐藏的另一套默认配置。

### 常用调节

- **FFT 输入**：默认过滤掉 ≤12 m 的短波，24 m 以上完全通过；SWE 不能恢复深水色散。Input Gain 对波高和匹配动量共同生效，0 使 SWE 静水化，但不关闭远海显示波浪。
- **水面组合**：烘焙区域默认 **Surface Mode = Heightfield**，与 Rust 模型分支一致：区域内部使用 SWE，边界渐回 FFT，不按水深把粗 FFT 几何混回来。Depth Blend 仅为兼容旧沙坡显示，使用 Blend Depth。
- **近岸小波法线**：SWE 资产的 **Normal Strength** 默认 1；源于参考项目的一格／四格 FFT 坡度差和周期 Catmull–Rom 重建，水面、泡沫、焦散共用。0 关闭，3 为上限；只改法线，不额外加波高或重置 SWE。画面与光束各用自身足迹做抗走样。
- **边界**：FFT Edges 的 −X／+X／−Z／+Z 是区域局部坐标。没勾选的外边界反射；勾选的边界使用 FFT 松弛带。没有 FFT 时域外封闭。内部缺失床面不是开放排水口。
- **地形缺口**：默认保持无效，不当作高度零的床面。只有明确开启 Fallback 才填补。一个格子只有一个最高床面，不支持桥下穿流、洞穴或薄竖墙。
- **二阶**：启用真正的 MUSCL + RK2，而非只有二阶空间插值；会增加计算成本。
- **反射**：可给材质资产分配经纬 HDR Reflection Panorama；没有纹理时使用 Reflection Color。不会自动获取场景天空；有效 SSR 命中会先与该环境反射混合，再进入菲涅耳合成。
- **焦散**：真实光束折射并与烘焙高度场求交，不是滚动噪声；接收范围世界固定。共享顶点按面积重建照度，不再每个光束三角形整片同色。示例 Ray Resolution=512、Texture Resolution=2048、Filter Radius=0.5；64 m 接收范围对应光束格约 18.75 cm、贴图像素 3.125 cm。光斑粗时优先提高光束精度／缩小覆盖范围，单独放大接收贴图不会补出光束细节；Filter Radius 以接收 texel 为单位，不宜靠大模糊消块。提高每轴精度有约四倍相应成本，锐利折叠仍会欠采样，真实水面的波长也限制细纹。可用 Caustics irradiance 看原始照度；Godot 背景的完整颜色调制不等于精确替换单光源直射项。
- **泡沫**：近岸量允许超过 1，Emission Enabled 关闭只停发，不清空；关闭整个模块则冻结历史并隐藏。远海是独立有界覆盖率，不与近岸密度混用。N/R 是非严格守恒 SL 实验，R 不是湿沙。周期变化保留相位；周期 0 持续输运，坐标使用开关只影响显示。
- **SSR**：原生镜面对照确认当前水面不能只靠 Environment 的 SSR 开关直接接入，所以这里使用水面自有 SSR，不改全局环境。只反射屏内可见不透明物体，miss 保留环境反射。当前逐像素 DDA 没有源项目 min/max 金字塔；步数太低会漏掉命中，太高会增加渲染成本。示例为 128 步，可用 SSR only／hits 调节。
- **调试**：材质支持水深、光程、透射率、世界法线、SWE 过渡权重、烘焙覆盖、焦散照度、泡沫密度／不透明度／坐标网格、SSR only／hits。先检查覆盖和水深，再调外观。
- **位移裁剪**：如果很大的波峰在相机边缘消失，提高 Surface Settings 的 Displacement Margin；这只扩展显示包围盒，不裁切或放大物理波高。

## 重建、时间与内存

显式 R／Reset 重启共同时间。普通物理／波谱／输入参数重建若仍有有效旧 GPU 实例，会在 GPU 内复制当前时钟，使用该相位的 FFT 初始化 SWE，不回读 CPU、不保留旧水流历史。移动区域／水位使烘焙失效时旧实例会关闭；烘焙恢复后从 t=0 开始。

近岸重建清空近岸泡沫；原始 FFT 波谱及共同时钟未变时保留独立远海覆盖历史。焦散和 SSR 编辑不清空任何模拟历史，普通泡沫源／寿命／外观编辑亦不清空。显式水体 Reset 清空并重启。

高度场、GPU 水深／动量、波场、泡沫历史、焦散目标和生成网格都只在内存中。保存场景只保存节点和资产参数；重载及重新进入场景会重新烘焙、初始化。

每轴分辨率翻倍至少使格点和主要场存储变为四倍，也通常需要更多 CFL 子步。若子步预算用尽，GPU 只接受稳定步长并报告丢时，显示 FFT 会跟随实际接受时间，而不是先于 SWE。`WaterGPU.snapshot(callback)` 可显式查看 `simulated_time`、`faults`、`dropped_gpu_time` 等诊断；它可能等待 GPU，不能每帧调用。正常渲染只采样 Texture2DRD。

## 验证命令

把下列 `godot` 替换为本机 Godot 4.7.2 控制台可执行文件：

```powershell
# 先导入资源；导入成功不能替代实际 GPU 验证。
godot --editor --path . --import --quit

# 仅 CPU 烘焙和资产持久化检查可以 headless。
godot --headless --path . --script res://tests/water_bake_test.gd

# 必须使用实际 GPU，不能用 headless 编译检查替代。
godot --path . --script res://tests/water_gpu_test.gd
godot --path . --script res://tests/water_scene_test.gd
godot --path . --script res://tests/water_caustics_test.gd
godot --path . --script res://tests/water_foam_test.gd
godot --path . --script res://tests/water_effects_scene_test.gd
godot --path . --script res://tests/water_ssr_test.gd

# 有限帧展示；不写个人参数或修改主场景。
godot --path . res://scenes/water_playground.tscn --quit-after 180
```

上述七组水体检查已在 Windows / Godot 4.7.2 / Forward+ / D3D12 / RTX 3070 通过，并检查实际展示窗口。原生 SSR 正对照能反射目标，而同一原生开关不改变当前水面；迁移后的水面自有 SSR 能产生有效反射。焦散与 SSR 未移植源 min/max 树加速，不承诺原渲染器的性能等价。基础版曾额外运行 Vulkan 数值检查，但本轮效果没有完整 Vulkan／其他硬件验收。编辑器手柄拖拽／撤销仍未人工键鼠验收，水体测试也不替代原雾及其他并行改动的回归。焦散、泡沫和原生 SSR 对照／移植的精确边界另见[效果合约](../specs/water-effects.md)，基础边界见[水体合约](../specs/water.md)。
