# 实验计划：在 View 3 分开测采样、探针历史与屏幕滤波

## 1. Baseline and goals
`trace.inc::trace_tile` 目前每个 6×6 像素块发一条主射线；命中后可发次级射线。R2 序列来自 tile 与帧号。`merge.inc` 只累积局部区间，父级按置信度插值。`cascade_effect.gd` 的 Apply 在乘接收材质后写 HDR，移灯会重置探针历史。保留这些语义，只在每份工程副本替换一个环节。

## 2. Overall approach

| 原型 | 切入点与假设 | 参考与界限 |
| --- | --- | --- |
| A：自适应历史 | 方向桶的已有样本量和持续同向的亮度／透射率偏差控制历史衰减。样本充足、误差不持续时延长历史；突变时缩短。复用桶内两个空闲浮点数；重置时丢弃。只改 Merge，不同时放宽父探针有效期。 | [NVIDIA RTXGI 的探针更新](https://github.com/NVIDIAGameWorks/RTXGI-DDGI/blob/main/rtxgi-sdk/shaders/ddgi/ProbeBlendingCS.hlsl) 将历史稳定性与照明变化响应区别对待；不照搬其阈值。 |
| B：按探针推进方向 | 主、次级各用所属世界探针的键扰动 R2，原子领取不同序号；首次未分配的探针回退现有采样。复用槽位空闲计数，回收时清零；保持均匀半球 PDF，不改出发像素和间接积分。 | [Split Radiance Cascades：Choosing directions](https://www.jacktollenaar.top/articles/split-rc.html)；[STBN](https://research.nvidia.com/publication/2022-07_spatiotemporal-blue-noise-masks) 是另一种候选序列，并非本次 R2 实现的别名。 |
| C：简化 SVGF | Apply 先输出未乘底色的照明。用上帧相机矩阵重投影静态接收面；核对距离、世界法线、接收资格，累计亮度二阶矩。以方差、深度和法线约束 2 轮 à-trous（步长 1、2）；最后乘真实接收材质并合成。 | [Schied 等，SVGF](https://research.nvidia.com/labs/rtr/publication/schied2017spatiotemporal/)。这是静态网格实验，不宣称实现论文全部功能或支持运动物体。 |

## 3. APIs and data model
[实验工具目录](../../../../../tools/src_temporal_study/)存放副本准备、独立变体和测量脚本。新建目录才能写入；不让实验 shader 被正式 Godot 工程导入。每份副本独立导入、缓存、运行；对照不应用 shader 补丁。缺少 RT 能力、导入失败、画幅错误、数据缺失都不计作有效样本。C 使用渲染线程私有 ping-pong 纹理；尺寸、目标、快照、灯、调试模式中断或帧号复位时拒收旧历史，退出时释放。原场景和软件回退代码不变。

## 4. Algorithms and rules
- 固定 3 号 Arcade、426,964 面、三灯、多反弹、strength 3、LOD 7、stride 6，所有改动只在内存。**ctrl98、A、B、C 均从 0.98 出发**；另跑 ctrl99（保存值）。不靠降低亮度、减少反弹或停止更新换取低噪声。
- 720p 静置至少 384 帧，再取 120 帧。4×4 固定位置抽样；同一掩码由原生帧和独立高射线参考定义：原生亮度 <16、参考合成亮度 [4,40)。记录相邻帧平均绝对亮度差、8 帧差 P95 和均值。显示量纲为 0–255。
- 横移路径沿相机右轴 0.4 m / 32 帧；每 4 帧与**同一位姿**的独立收敛参考比较，统计显著变化边缘的 MAE。参考用原算法 stride 2，仅用于质量，不参与性能排行。边缘误差含采样偏差，不等于纯拖影。
- 回到初始视角，单独移动末端 GalleryLight，测变化明显且不受原生直射变化的区域。记录达到各算法新稳态误差阈值所需帧数，须连续 4 帧满足；没收敛标记超时，不能删掉慢样本。同时报相对独立参考的误差，避免把稳定偏差当优势。
- 720p、1080p 单独采 GPU 时间戳，此时不截图。按轮换顺序至少 3 轮，逐配置每轮每分辨率 ≥12 组有效样本，记 SRC 总计、Trace/Merge/Apply、视口中位数/P95。资源成本区分额外纹理的名义字节和实测耗时。绝不以 FPS 换算 GPU 时间。

**第二轮（用户指定叠加）：** 在同一个输入保留率 0.995 比较「无 / A / C / A+C」四种组合，重新跑独立参考、静置、横移、移灯与性能。A 不改映射：0.995 是基础值，并非硬上限，稳定方向最高到 0.9975；C 的屏幕历史仍最多 16 个样本，不把它也设为 0.995。四组使用相同 raygen。两种分辨率各跑四轮平衡次序，每组每轮 16 个 SRC GPU 样本；额外给出不加曝光的实录并标明差分放大。用本轮固定 0.995 作对照，不覆盖第一轮证据。

## 5. Fixed decisions and discretion

推荐门槛预先固定：相对 **ctrl99**，暗区平均帧差再降 ≥15%，均值偏移 ≤1 个显示亮度单位；横移边缘 MAE 增量 ≤0.5，移灯响应不慢于对照 4 帧以上；1080p SRC 中位数增加 ≤0.30 ms。各项结果照报，不保证有胜者。

## 6. Verification and documentation impact

以独立采样脚本、固定输入和汇总记录复核前三类测量。本轮不新增正式 Inspector 接口或修改现有契约。进入正式 addon 需要单独决策和编辑器、多视口、软件路径回归。
