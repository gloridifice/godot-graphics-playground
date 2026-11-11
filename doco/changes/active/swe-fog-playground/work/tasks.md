# Execution tasks

已按用户后续请求开始执行；用户另批准了黄绿色网格地面、脚踝高浓白雾、初始化噪波/负高度 offset UI 和实时约化重力开关。目前打开运行场景交用户验收，未完成或归档变更。仅实际验证覆盖的整项任务可勾选。

## 1. 基础实验场

- [x] 1.1 建立可运行的网格平面主场景和胶囊玩家
  - Design: [场景与移动](implement.md#41-平面场景玩家和相机)
  - Acceptance: 设置主场景和输入动作；64 米平面、米制网格、静态碰撞、边界及胶囊匹配，通过 [P1](specs/playground.md#p1-启动与尺度)。先可运行，再接入雾。

- [ ] 1.2 接入第三人称相机适配器与相机相对移动
  - Dependencies: 1.1
  - Design: [相机与依赖策略](implement.md#41-平面场景玩家和相机)
  - Acceptance: 锁定并记录 Phantom Camera 的实际发行版本/来源/许可；若兼容失败，记录证据并使用已设计原生回退。通过 [P2](specs/playground.md#p2-相机相对移动)、[P3](specs/playground.md#p3-环绕与碰撞) 和 [P5](specs/playground.md#p5-依赖与故障) 的相机部分。

- [ ] 1.3 完成输入捕获、失焦、UI 隔离并验证基础场景
  - Dependencies: 1.2
  - Acceptance: 真实 GUI 检查鼠标释放/恢复、俯仰限制、移动帧率与相机抖动，通过 [P4](specs/playground.md#p4-输入与暂停) 的输入部分；雾尚未实现也能独立行走观察。

## 2. 离线高度场

- [ ] 2.1 定义版本化高度场资源、验证与编辑器烘焙工具
  - Dependencies: 1.1
  - Design: [资源与接口](implement.md#3-apis-and-data-model)、[烘焙流程](implement.md#42-离线高度场与初始化)
  - Acceptance: 实现显式分组、世界坐标高度、有效格、保守障碍格面、来源摘要及安全保存；失败不损坏旧资产，满足[高度场需求](specs/terrain-bake.md#requirements)。

- [ ] 2.2 烘焙实验场并验证高度场边界与失效路径
  - Dependencies: 2.1
  - Acceptance: 通过 [T1～T4](specs/terrain-bake.md#acceptance-scenarios)，包括平面、非等格距、斜坡、台阶、薄墙、缺失覆盖、损坏资源和场景变换过期；玩家移动不使缓存过期。保存首个真实平面烘焙资产。

## 3. GPU 接线门槛

- [ ] 3.1 验证主 RenderingDevice 计算纹理到 FogVolume 的最小链路
  - Dependencies: 1.1
  - Design: [数据流](implement.md#2-overall-approach)、[生命周期](implement.md#生命周期与兼容)
  - Acceptance: 在当前 4.7/Forward+/D3D12 上由 compute 更新测试密度并通过 Texture2DRD 驱动 fog shader；确认格式、线程、屏障、发布延迟和释放行为，无逐帧同步回读，覆盖 [F6](specs/fog-field.md#f6-性能与故障) 接线部分。失败则停止下游 GPU 实现并报告，不切换后端掩盖问题。

## 4. 雾场模拟

- [ ] 4.1 建立雾参数、生命周期和运行时初始化
  - Dependencies: 2.2, 3.1
  - Design: [API/数据](implement.md#3-apis-and-data-model)、[参数](implement.md#46-初始参数与调参边界)
  - Acceptance: 加载并校验高度场，建立 F32 状态与发布纹理；实现两种初始化、错误状态、暂停/重置和 generation 保护。满足 [F4](specs/fog-field.md#f4-时间与生命周期) 的初始化/重置部分，失败时基础场景仍可玩。

- [ ] 4.2 实现平衡保持的 SWE 与守恒雾量输送
  - Dependencies: 4.1
  - Design: [动力与浓度](implement.md#43-雾动力与浓度)
  - Acceptance: 实现统一有效重力、Rusanov/静水重构、一阶诊断、受限二阶 SSP-RK2、共享面通量/正性限制及开放/封闭/障碍边界；无海洋造波、泡沫或 Manning 依赖。具备验证 [F1](specs/fog-field.md#f1-静止平衡与地形)、[F2](specs/fog-field.md#f2-守恒正性与障碍) 的生产路径。

- [ ] 4.3 实现微风、半衰期、可选混合与稳定时间调度
  - Dependencies: 4.2
  - Design: [源项](implement.md#43-雾动力与浓度)、[时间调度](implement.md#44-时间推进与-gpu-调度)
  - Acceptance: 风/衰减使用实际子步且不重复积分；GPU 步长选择不依赖同步回读；预算、积压、候选失败重试和暂停行为明确。具备 [F3](specs/fog-field.md#f3-微风与半衰期)、[F4](specs/fog-field.md#f4-时间与生命周期) 的生产验证入口。

- [ ] 4.4 验证数值行为与资源生命周期
  - Dependencies: 4.3
  - Acceptance: 用实际 shader 完成 [F1～F4](specs/fog-field.md#acceptance-scenarios)，核对静止平衡、质量收支、非负、薄墙、风解析解、半衰期、固定模拟时间与重建/退出；保留参数、误差与失败证据。未验证项不能标记通过，不靠放宽容差隐藏问题。

## 5. 体积渲染与观察

- [ ] 5.1 将真实二维状态接入无噪声体积密度映射
  - Dependencies: 1.3, 4.4
  - Design: [体积映射](implement.md#45-体积密度映射)
  - Acceptance: 由高度/厚度/雾量构造层内密度，正确处理无效格与障碍；全局基底雾为 0，进入雾内和绕胶囊观察符合 [F5](specs/fog-field.md#f5-体积映射与遮挡)，不以平面透明度替代体积。

- [ ] 5.2 添加诊断控制与可关闭的低频雾细节
  - Dependencies: 5.1
  - Acceptance: 厚度/雾量/速度/雾顶视图、关键参数、暂停/重置和错误提示可用；噪声不回写状态，暂停时不继续动画。完成 [P4](specs/playground.md#p4-输入与暂停)、[P5](specs/playground.md#p5-依赖与故障) 及 [F5](specs/fog-field.md#f5-体积映射与遮挡) 的组合验收。

- [ ] 5.3 进行视觉调参与分项性能测量
  - Dependencies: 5.2
  - Acceptance: 固定视角/时间比较 128² 与 256²、薄层/掠地视角、froxel 和重投影配置；分别记录模拟与体积渲染 GPU 耗时、设备及有效子步，满足 [F6](specs/fog-field.md#f6-性能与故障)。计时不可用或 GUI 未验证须明确，不扩展到自研渲染器。

## 6. 文档与最终验证

- [ ] 6.1 同步实际交付的当前架构、规格与使用说明
  - Dependencies: 5.3
  - Acceptance: 将通过验收的边界写入[当前架构](../../../../architecture.md)和相关当前 specs；记录启动、烘焙、操作、参数单位、相机插件固定版本/许可和实际限制，不写入未实现设想。

- [ ] 6.2 完成整体功能/文档核验并记录交付结果
  - Dependencies: 6.1
  - Acceptance: 从干净启动运行实验场并覆盖 [P/T/F 全部场景](specs/playground.md#acceptance-scenarios)（另见[高度场](specs/terrain-bake.md#acceptance-scenarios)、[雾场](specs/fog-field.md#acceptance-scenarios)）；记录实际命令、硬件、数值与 GUI 结果，检查文档和代码一致并运行 `doco check swe-fog-playground`。仍有失败或未运行的必要验证不得宣称完成；生命周期完成/归档须遵循后续明确请求。

## Execution evidence and remaining acceptance

- Blocked: none
- 仍有未验证验收项，不将局部验证替代完整任务完成。
- `1.1`：实际主场景截图已检查黄绿色米制网格、胶囊与白雾。GUI 测试确认胶囊 Y≈0.9、站立和边界不坠落。
- 任务 1.2、1.3：Phantom Camera v0.11.0.4 已安装并在 4.7.2 运行；GUI 测试验证直行位移 `(0,0,-2.999998)`、斜行 `(2.12132,0,-2.121327)`、旋转后 `(-2.999999,0,0)`，Esc、UI 不捕获、空白场景捕获、俯仰和暂停行为通过。完整环绕平滑度及用户输入体验留待用户验收，任务保留未勾选。
- 任务 2.1、2.2：真实平面已烘焙为 16384 格；高度场测试通过世界变换/矩形格距、斜坡解析值、未命中有效位、薄墙共享面、来源过期、损坏数据和安全覆盖保存。独立台阶夹具/更多无效输入尚未覆盖。
- `3.1`：独立主 RD 接线原型在 D3D12 运行并截图确认；一次异步读回 h=0.25、中心雾量>0、角落雾量=0。后续生产路径同样已运行；完整重复创建/释放压力验证尚未进行。
- `4.1～4.4`：生产 GPU 初始化、正性/共享通量、二阶 SSP-RK2、微风、半衰期、GPU CFL/重试和重力开关已实现。实际 GPU 测试通过平面/斜坡 60 秒静止、封闭域 60 秒雾量/体积守恒、初始化复现、负 offset 裁切、关闭重力的非均匀场静止、开启后演化、风解析解和半衰期。尚未覆盖完整 F4 的多 FPS 对照、薄墙真实 GPU 输送和异常重建压力场景。
- 任务 5.1、5.2：真实二维场驱动原生体积雾，浓白脚踝高外观及参数/诊断面板已接入；所有数字可左右拖拽/精确输入并在改值时即时重置（不等松手），取消初始化草稿；开关仍实时生效且不重置。没有加入额外三维渲染噪声；最终画面由用户验收。
- `5.3`：尚未做分项 GPU timestamp 性能测量，UI 明确显示未测量，不宣称毫秒预算。
- 任务 6.1、6.2：已同步当前架构与实际使用指南；完整交付/验收仍未完成，不执行完成/归档。

### Actual commands and results

- Godot 路径：`G:\\Tools\\Godot_mono_v4.7.2\\godot_console.exe`；实际版本 `4.7.2.stable.mono.official.ed1daf0bf`，Forward+ / D3D12 / NVIDIA RTX 3070。PATH 中 4.5.2 未用于实现验证。
- `--headless --editor --import`：通过脚本与着色器导入。
- `--headless --script res://tools/bake_terrain.gd`：成功保存真实平面浮点资产。
- `--headless --script res://tests/terrain_bake_test.gd`：PASS，0 failures。
- `--script res://tests/fog_gpu_test.gd`：最终 PASS，0 failures。首次噪波正/零并存夹具因小区域/低频未跨零点失败；增加该夹具采样频率后重跑全部通过，未放宽数值容差。
- `--script res://tests/playground_test.gd`：单独运行最终 PASS，0 failures。曾并行弹出 GPU 测试窗口导致焦点丢失和 4 项输入失败；独立运行并获取测试窗口焦点后全部通过，未修改生产移动语义。
- 数字拖拽改动后再次单独运行 GUI 测试：PASS，0 failures。新增 P6 通过真实 UI 输入验证松手前负 offset 已清空 GPU 厚度、拖回立即恢复雾、暂停/鼠标/角色状态不变，以及双击精确输入；没有新增测试专用生产接口。频率控件步长改为 0.001，以准确显示默认 0.08 而非舍入到 0.081。
- 重力可观察性/接地闪烁：旧实现的真实主场景在无风、无消散条件下，重力开后 10 秒 max Δh≈0.08587 m，证明并非未推进；原画面几乎饱和，固定视角暂停的地面帧差 MAE≈0.001335（0..1）使[真实场景渲染检查](../../../../../tests/fog_render_test.gd)的稳定性检查失败。修复使用垂直区间解析过滤、显式 SDF 保护带、关闭重投影抖动、192/192 froxel，并消除二次密度自发光放大。保留 g=0.02 与求解器动力学；默认频率/offset 改为 0.32/m、-0.2 m，以空隙和较小尺度梯度观察真实摊平。顶部显示真实模拟秒、g、h 范围和最大速度。
- `--script res://tests/fog_render_test.gd`：D3D12 实际运行 PASS，0 failures；无重力场不变，开启后画面 ROI 差≈0.00889，层厚峰值从≈0.26976 m 降至≈0.228 m；暂停连续 32 帧 MAE=0，环绕后回到同一视角 MAE=0；GPU 高度/速度归约与发布快照一致。数值及 GUI 测试也再次各自 PASS。截图和这些固定夹具不代表所有掠地角度/快速移动质量或性能预算均已验收。
- 用户验收运行已打开，无有限帧自动退出；截图确认 UI、胶囊与白色低雾，启动日志无报错。用户尚未给出验收结论。

## Creation-phase verification (historical)

- 创建阶段已检查当前项目配置、doco 基线及参考仓库算法；已检索 Phantom Camera 官方安装、第三人称模式和兼容说明。
- 尚未安装插件、编写或运行实现、执行数值测试、启动 Godot 或测量 GPU 性能；所有实现任务保持未勾选。
- 已在本项目库运行 `doco check swe-fog-playground`（显式选择本项目根目录）：机械检查通过，唯一警告为 15 项实现任务尚未完成，符合仅创建阶段。
- 已使用 tgrep 的无索引模式检查变更包，没有遗留待填模板内容；未改动运行时代码或当前架构事实。结构通过不代表功能、性能或语义验收通过。
