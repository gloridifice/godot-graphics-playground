# 水体迁移来源

算法参考用户指定的本地项目 `G:/MyProjects/Rust/water-simulation`，检查时 HEAD 为 `203429b`。这里只记录来源，不形成运行时绝对路径依赖。

- `src/ocean/simulation/spectral/{mod,spectrum}.rs` 与 `shaders/{evolve,ifft}.wgsl`：Phillips 波谱、六通道演化、匹配深度积分动量、输入低通与 radix-2 IFFT。迁移为本 addon 的 Resource／GDScript／GLSL；随机数改用 Godot 的确定性 RNG，不承诺与 Rust 种子逐位一致。
- `src/ocean/simulation/nearshore/shaders/shore_compute.wgsl`：水体静水重建、Rusanov、受限自由面／床面重构、配套床面源项、RK2 与 FFT 松弛输入。基础水体与独立泡沫状态分开，增加共享供给格排出量限制和 GPU 时钟管理；没有迁移湿沙／粒子状态。
- `src/ocean/render/water/shaders/{material,lighting}.wgsl` 及 `render/shaders/surface.wgsl`：介质积分、菲涅耳、介电高光、表面合成与快速折射思路，重新接入 Godot 的场景颜色／反向 Z 深度和灯光。不是原渲染管线的逐文件复制，也不是完整视觉等价移植。
- `src/ocean/simulation/nearshore/shaders/shore.wgsl::ocean_weight`：区分烘焙模型分支与旧沙坡深度混合，默认内部 SWE、边界／FFT 松弛带过渡；`render/shaders/surface.wgsl` 的一格／四格 FFT 差分、周期 Catmull–Rom 坡度、干湿／足迹渐隐与 `normal_strength` 接入水面、泡沫和光束。小波不改变基础几何／SWE；光束差分步长使用自身 FFT 格足迹，不固定取半格。参考真实 GPU 验证 `render/verification/surface.rs`，Godot 以实际命中点逆 Snell 与独立 Fourier 模式校验。
- `src/ocean/render/caustics/shaders/{trace,draw,height_trace}.wgsl`：折射光束、双线性高度场最近交点、光束面积比及浮点加法接收贴图。接入 Godot 独立 RD 光栅目标，使用共享水面采样；Godot 适配增加接收面积加权的共享顶点通量重建，避免逐三角形常量照度块。当前用双线性片 DDA，未移植高度 min/max 树。
- `src/ocean/simulation/offshore/shaders/foam.wgsl`、`nearshore/shaders/shore_compute.wgsl` 与 `render/shaders/render.wgsl`：独立远海雅可比历史，近岸泡沫量／动量通量、前沿生成、解析寿命／拖曳、N/R 实验与双相位材质坐标，NSH 微法线／不透明度及视觉抬高。未迁移所有实验性脊线源和 N/R 外观面板细项。
- `src/ocean/render/shaders/screen_trace.wgsl`：SSR 投影线段和重建世界空间命中判据；适配反向 Z 与正交视线，使用有界像素 DDA，未移植源屏幕 min/max 深度金字塔。实际原生镜面对照确认当前水面不能直接使用 Environment SSR 后，才接入水面自有 SSR。
- 本仓库 `addons/heightfield_fog/`：参考全局 RenderingDevice／Texture2DRD 生命周期、局部区域 Gizmo 和 CPU 三角形采样机制；水体拥有独立实现，不依赖雾求解器。

## 泡沫纹理

`textures/foam/{shorewaves_nsh,crest_foam_nsh,crest_foam2_nsh}.png` 原样复制自源项目 `assets/foam/baked/`。这是本地 water-simulation 离线加工的派生 NSH 数据，不是上游原版提供的 NSH；Soft 来自输入掩码，Height 与法线来自本地外观模型。导入按线性数据保留 RG 法线／B Soft／A Height，不进行透明边缘修复或预乘。

- Shorewaves 输入掩码：Reboot16 / Enrico K.，MIT；完整通知保留在 `textures/foam/LICENSE.Shorewaves.txt`。
- Crest 输入掩码：Wave Harmonic and contributors，MIT；上游 https://github.com/wave-harmonic/crest ，固定提交 `db0658ff0b2e93e4a9e28cc2867509658b0ecc00` 的公共 Crest 4 版本，完整通知保留在 `textures/foam/LICENSE.Crest.txt`。不能推广为其他版本／商业素材许可。
- 更早来源及源掩码映射可查指定 Rust 项目的 `assets/foam/SOURCES.md`。

没有迁移模型、字体、第三方 UI、HDRI 或其他外部美术；展示几何仍完全由 Godot CSG 和内建网格组成。

源本地仓库根目录未提供 LICENSE/COPYING，根 Cargo.toml 未声明许可；本次按用户要求进行同工作区迁移，不据此授予或假定额外的第三方再分发许可。若将来分发或移入其他项目，应由项目所有者确认源代码及其上游引用的授权范围。
