# View 3：把 A、C 与 0.995 放在一起

[四组并排实录，10.8 秒](../../tools/src_temporal_study/results/combo995/view3.mp4) · [A+C 稳定后的 720p 原图](../../tools/src_temporal_study/results/combo995/arcade.png)

**固定相机拍暗部，A+C 最稳；在编辑器里走动或调灯，我会选 A + 0.995。** 只用 A 时，相比固定 0.995，暗部平均帧差少了 27%，移灯只多等 1 帧。再打开 C，静止画面进一步稳定，但反弹光跟灯要多等 19 帧。视频上排是相同曝光下的合成画面，下排按段分别放大静帧变化、横移参考误差和移灯后的残差；计量用未压缩 RGB8，不用视频反推。

## 同一基础权重的四组对照

A 是**世界探针的自适应历史**：输入 0.995，稳定且样本充足的方向最高可达 0.9975，并非所有方向都固定 0.995。C 是**屏幕空间时空滤波**：保留原实现的最多 16 个历史样本、两轮几何边缘引导滤波，再乘接收材质底色。不启用 B，不改曝光或采样密度。重新加载并核对了四种实际 compute SPIR-V；四组 raygen 相同，两组 C 使用同一份 filter SPIR-V。

| 配置（输入均为 0.995） | 静止暗部平均帧差 ↓ | 横移边缘 MAE ↓ | 移灯收敛帧数 ↓ | 720p SRC GPU ms 中位数 / P95 | 1080p SRC GPU ms 中位数 / P95 |
| --- | ---: | ---: | ---: | ---: | ---: |
| 固定，对照 | 0.005525 | 0.349 | 22 | 0.641 / 1.014 | 1.234 / 1.788 |
| A | 0.004027 | **0.347** | 23 | 0.637 / 0.885 | 1.241 / 1.678 |
| C | 0.000410 | 0.504 | 41 | 0.948 / 1.470 | 1.894 / 2.575 |
| A + C | **0.000259** | 0.505 | 42 | 0.947 / 1.323 | 1.912 / 2.447 |

- **组合相对固定 0.995：** 静帧差降低 **95.3%**。暗区平均亮度从 20.448 到 20.364（0–255），不是把画面大幅压黑。代价是移灯多 **20 帧**，1080p SRC 多 **0.678 ms**；含原生渲染的视口中位数由 2.781 到 3.430 ms。
- **组合相对仅 C：** 再加 A，帧差又降低 36.7%，但绝对差只有 **0.000150** 个显示亮度单位，不能读成肉眼能看到同等幅度的改善。移灯 41 → 42 帧，横移边缘误差几乎不变。交互代价主要来自 C；组合并没有抵消 C 的滞后。1080p Apply 为 1.135 ms（固定对照 0.463 ms），C 的五张 RGBA16F 纹理仍为约 79.1 MiB，A 不再增加图像。
- **稳定与准确要分开看：** 静止时对高采样参考的暗部 MAE 分别为 0.106 / 0.095 / 0.231 / 0.234。组合最不闪，但不是最接近参考的。运行时重新开启 GI 后，第 64 帧距各自长期稳态的暗部 MAE 分别为 0.291 / 0.325 / 0.430 / 0.463；预热到 2,048 帧再录 120 帧，组合的帧差仍最低（0.000229）。这是冷启动测试，不等同于编辑器相机移动，也不是说一定要等待 2,048 帧。

同一 RTX 3070、Godot 4.7.2 Forward+ / Vulkan、完整可见网格的 426,964 个不透明三角形、三盏点灯、stride 6、多次反弹。720p 画质对照固定相机、灯光轨迹、射线预算和输入场景；使用独立 stride 2 参考，34,648 个暗部测点、7,710 个移灯响应测点。横移按同一位姿比较；原生静帧差、原生横移对齐误差均为 0。移灯后达到各自新稳态误差阈值、连续保持 4 帧才计为收敛。性能与画质分开采：独立进程、四种顺序轮换；每个分辨率每组 4 × 16 个完整 GPU 时间戳，不以 FPS 换算。测试的是该视角的一次移灯，不代表所有动态场景。

[画质汇总](../../tools/src_temporal_study/results/combo995/quality.csv) · [逐帧记录](../../tools/src_temporal_study/results/combo995/per_frame.csv) · [冷启动与长预热](../../tools/src_temporal_study/results/combo995/settle.csv) · [GPU 分段](../../tools/src_temporal_study/results/combo995/gpu.csv) · [原始时间戳](../../tools/src_temporal_study/results/combo995/gpu-samples.json.gz) · [输入与加载的着色器指纹](../../tools/src_temporal_study/results/combo995/inputs.json) · [前一轮独立实验和方法](sponza-temporal-stability.md)

## 直接看和复跑

本机已经准备好的组合副本：

```powershell
& 'G:/Tools/Godot_mono_v4.7.2/godot.exe' --editor --path 'G:/tmp/src-ts-combo995/adaptive_screen_long' --rendering-driver vulkan res://scenes/sponza_temporal_preview.tscn
```

在 3D 编辑视口选 `Camera3D` 并勾 **Preview**，就是测量用的 View 3。去掉 `--editor` 可直接运行并用 WASD 走动。把目录末段换成 `adaptive_long` 是 A 单项；`screen_long` 是 C 单项；`long_history` 是固定 0.995。各副本都有独立的继承场景，已预置数值，不需要手改 Inspector 或重建正式场景。

从项目根在**新的仓库外目录**重做整组：

```powershell
$t = 'tools/src_temporal_study'; $out = 'G:/tmp/sponza-combo995-replay'
$exe = 'G:/Tools/Godot_mono_v4.7.2/godot_console.exe'
python "$t/run.py" all --combo995 --out $out --godot $exe
python "$t/analyze.py" $out "$out/summary" --combo995
# 可选，需 Pillow、NumPy 和带 libx264 的 ffmpeg
python "$t/compare_clip.py" $out "$out/summary/view3.mp4"
```
