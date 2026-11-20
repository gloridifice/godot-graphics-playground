# 执行清单

- [x] 1.1 固定输入与评价协议，建立独立工程、原算法和参考画面。
  - Acceptance: [实验设计](implement.md)通过检查；副本实测 RT、三灯、720p；高密度参考和原生对照可读。
- [x] 2.1 分别实现 A、B、C 三个渲染器原型。
  - Dependencies: 1.1
  - Acceptance: 每个原型独立导入并在真实 GPU 完成渲染；原 addon 和保存的场景不变。
- [x] 3.1 跑静帧、横移和移灯序列，评价收益和假象。
  - Dependencies: 2.1
  - Acceptance: 五个配置共用掩码和轨迹，记录明暗偏差、边缘误差和响应帧数。
- [x] 3.2 顺序轮换采集双分辨率性能。
  - Dependencies: 2.1
  - Acceptance: 达到计划的样本数，记录 GPU 中位数/P95 与额外存储。
- [x] 4.1 复核文件隔离、数据完整性，发布逐方案取舍与复跑命令。
  - Dependencies: 3.1, 3.2
  - Acceptance: 报告可追到原始计时及采样规则，明确未测边界和是否达到门槛。

- [x] 5.1 组合现有 A 和 C，在 0.995 下重新跑四种配置并记录动态画面和 GPU 时间。
  - Dependencies: 4.1
  - Acceptance: 四组同相机、同光线预算、同基础权重；确认组合加载了两种算法；报告固定 0.995 与各单项、组合的收益和代价，保留第一轮记录。

## Verification
1.1–3.1：Godot 4.7.2 Forward+ / Vulkan 实机运行 `measure.gd`。4 份工程的场景 SHA 相同，只有各变体声明的 addon 文件不同；实际编译产物中，仅 B 的 raygen 与对照不同。全部质量序列退出 0。高采样参考覆盖 9 个位姿；原生静帧差为 0，原生横移与相同固定位姿的采样亮度也逐点相等。报告另列数据看完后追加的固定 0.995 对照，不改变预设门槛。

3.2–4.1：每组 720p/1080p 各 48 组有效 SRC GPU 样本；前三个原型均通过 Vulkan RT 的 `render_test.gd`，A 另通过 `interval_bins_test.gd`。`analyze.py --with-ablation` 复核样本数量、八段总和、掩码与原生横移对齐；`git diff --check` 通过。场景、project.godot、water_playground 的 SHA 与开始时相同。见[质量、耗时、边界及复跑命令](../../../../guides/sponza-temporal-stability.md)。无正式接口或架构契约变更；未归档。

5.1：`run.py all --combo995` 的四种配方在副本运行；`settle` 另测第 64 和 2,048 帧后的行为并验证继承预览场景。`analyze.py --combo995` 核对实际加载的 SPIR-V、对照掩码与每组每分辨率 64 个时间戳。组合的 `render_test.gd`、`interval_bins_test.gd` 均为 0 failures，副本编辑器可打开。`compare_clip.py` 输出 259 帧并排实录。[报告、实录、数据和命令](../../../../guides/sponza-temporal-combo995.md)。
