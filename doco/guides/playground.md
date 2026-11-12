# 局部高度雾实验场

用 Godot 4.7.2 打开项目，按 **F5** 启动 `scenes/fog_playground.tscn`：默认自由鼠标，按 **F** 进入／退出控制，**Esc** 或失焦释放。WASD 移动、Shift 跑步、空格跳跃；接地行走推开前方／两侧雾气并拖出尾流，起跳脚下汇聚，落地向外扩散，均作用于真实 SWE 状态。

运行中按 **F2** 在 SWE / Stable Fluids 间切换，左下角显示当前后端。切换会将全部雾盒重置到同一资源初态。Stable Fluids 使用二维不可压空气与独立近地径向交互驱动采样坐标，适合观察漂移、尾流和起跳／落地对噪波的向内／向外搬运。基础厚度沿轨迹保留来源值；起跳挑高、落地压低由独立可恢复的高度乘数实现，不依赖 SWE 式水平压缩增厚。要直接启动新版：

```powershell
& G:\Tools\Godot_mono_v4.7.2\godot.exe --path . -- --stable-fluids
```

Inspector 的 **Simulation / Simulation Method** 可逐盒选择。**SWE Enabled / SWE Editor Enabled / SWE Paused** 为保存兼容保留名称，现在控制所选后端；**Reset simulation state** 重置当前模式。新版的 **Stable Pressure Iterations**（默认 48）和 **Stable Drag**（默认 0.45 s⁻¹）实时生效；SWE 的重力、阈值、阶数、Drag 不作用于新版。两种模式均不是三维空气模拟；新版不通过水平压缩堆高；高度从不可变初态 `h₀` 按回溯坐标重建，不再逐 tick 插值高度，纯风噪波不会持续磨平。入口雾使用独立参考坐标和入口承载高度从资源公式重建。跳跃／落地径向分量不受空气压力投影消除，只参与坐标输送，随流传播并受 Stable Drag 衰减；不会定时复原图案。合成速度不宣称严格二维无散，不以水平压缩补偿厚度。坐标场长期仍有插值误差／拉伸，且不严格守恒总雾量。详见 [Stable Fluids 合约](../specs/heightfield-stable-fluid.md)。下文汇聚／扩散及重力调参专指默认 SWE。

Stable Fluids 的高度乘数 `G` 直接编码于 `[0,2]`，最终厚度乘 `G`，`1` 为中性。**Stable Takeoff Height Gain** 默认 `1.75`，**Stable Landing Height Gain** 默认 `0.25`；都设为 `1` 可禁用新的高度响应，保留平面扰流。**Stable Height Gain Half Life** 默认 `0.8 s`，控制增益向 `1` 恢复，与速度阻尼独立。增益随风和局部流动搬运，只恢复乘数，不复位原始噪波或坐标；零基础厚度仍为零。暂停冻结恢复，重置／切换回 `1`。参数实时生效，无须重新烘焙。

森林示例仍可打开 `addons/heightfield_fog/demo.tscn` 按 **F6**，可通过 Inspector 选择后端，未连接主场景 F2 快捷键。

```powershell
& G:\Tools\Godot_mono_v4.7.2\godot.exe --path .
```

## 森林示例

可选森林场景是程序化低多边形森林：48×48 米缓坡地形、蜿蜒土路、林间空地、针叶树、四处倒木、大小岩石和碎石。固定种子保证重复运行一致，编辑器也生成几何；所有几何由本项目生成，未引入外部美术资源。

启动时自动烘焙两个旋转雾盒：`ClearingMist` 覆盖林间空地，`DeepForestMist` 覆盖后方林地，共享自然薄雾预设 `forest_mist.tres`。低洼地形积雾、高处岩石露出；运行时使用每盒独立 GPU SWE 推进厚度与动量，自然密度细节沿世界风向缓慢漂移，保持时间重投影。烘焙来源为 `Landscape/Terrain` 的地面及岩石；树冠和倒木不作为承载面。倒木有角色碰撞，但不是雾动力障碍。

游戏和测试场景默认**不锁鼠标，光标保持可见**。按 **F** 才锁定并隐藏鼠标、进入控制；之后 **WASD 行走、鼠标环绕、空格跳跃**。**Esc** 释放鼠标，单击画面或切回窗口不会自动锁定，需要再次按 F。移动方向跟随相机，斜向不加速；释放鼠标或失焦后停止接受移动输入。角色在土路入口落地，正常重力与贴坡；地面、岩石、树干、倒木有物理碰撞，地图边缘有防跌落边界。相机由 Phantom Camera 跟随并避让这些碰撞体，不为树冠／细枝建立碰撞。在雾里按空格起跳会向脚边 SWE 场注入径向动量，由求解器输送厚度、形成堆积与波动，不再按固定时间恢复；行走和落地不触发。可在雾盒 Interaction 分组调整 Jump Radius（m）和 Jump Speed（m/s）。Simulation 分组可暂停、重置，SWE Simulation 分组调整约化重力与阻尼；暂停保留状态，关闭模拟回到静态初态且不响应跳跃。原上下层分离场景保留为 `addons/heightfield_fog/fixtures/stacked_floors.tscn`，用于烘焙测试。

## CSG 雾实验场

**F5** 或打开 `scenes/fog_playground.tscn` 按 **F6**，体验基于第三方控制器测试地图的主场景与三片局部雾：基础平台、斜坡和出生高台。默认不捕获鼠标，**F** 切换控制／释放，**Esc** 或失焦释放；单击、Ctrl 或重新获得焦点不捕获。释放时不接受移动／跳跃／镜头输入，但保留重力、碰撞和落地扰雾。

`FogFields` 下三个节点可独立移动、调整 Size、Initialization 和外观；当前均使用贴承载面的薄层，也可开启 Horizontal Top 改用水平雾顶。三片雾均开启 SWE，并有自然密度漂移。真实接地起跳会向脚下施加向内动量，使雾汇聚；落地施加向外动量，使雾扩散。初次出生接地、二段空中跳跃不施加地面冲量；高差 1.5 m 外的雾不受影响。根节点 **Player Mist Interaction** 的 **Takeoff Pull**（默认 0.8）与 **Landing Push**（默认 1）调整两种强度，设为 0 可分别关闭；作用范围及速度由各盒 **Jump Radius / Jump Speed** 控制。不额外生成或删除雾量。

在雾盒的 **Simulation** 分组开启 **SWE Editor Enabled**，可直接在编辑器预演重力、风输送及边界补雾；开启与关闭都会重置场，关闭回到静态初态。默认关闭，与运行时 **SWE Enabled** 独立；**SWE Paused** 可暂停并保留预览状态。若需减轻风输送导致的细节模糊，可开启 **SWE Second Order** 试用 MC 限制器的二阶空间重建；默认关闭，切换时重置物理场、保留噪波显示相位，编辑器与运行时均适用，GPU 成本更高。

每次在编辑器打开场景或运行场景，都会自动构建内存高度图，不会将烘焙数据保存到 `.tscn` 或 `.res`。修改 CSG 或雾盒布局后，选择 **FogPlayground 根节点**，点击 Inspector 的 **Bake all playground fog** 更新预览；只需保存布局／参数修改，不需保存烘焙结果。该按钮先刷新 CSG 的烘焙网格再重烘焙全部雾盒；不要仅依赖单盒按钮更新已编辑的 CSG。派生 `_FogCSGSurface` 无渲染层、不投影、不生成碰撞，也不随场景保存，原有 CSG 和碰撞保持不变。

**生成与消失的位置均包括：无实体格的交界面，以及矩形高度场边界。** 风从这些位置吹入有效格时，按初始化配置生成雾；雾流出时直接消失。孔洞是否与盒外连通没有区别，不再把无实体处作为墙反弹。无风／横风时，压力或玩家动量仍可把雾推出边界；无实体格本身始终为空。重烘焙后使用新高度场的有效标志，无需手动分类。

**上风侧有入口却不补雾时，先检查 Horizontal Top。** 开启后，入口厚度为雾顶减承载高度再裁零；雾顶相对盒底计算，并叠加 Noise。高坡入口若高于雾顶，补入厚度就是零，下游已有雾仍会随风离开，形成缺雾带。这不是入口漏判，也不是 Coverage 把物理厚度删掉。需要沿各承载面铺雾时关闭 Horizontal Top，或提高 Base Height／Height Offset 使上风入口低于雾顶。

### 行走推动调参

`fog_playground` 已连接真实接地位移到各雾盒；静止、完全顶墙或空中不会持续推雾。进入控制后沿薄雾行走，观察前方与侧边堆积、经过处变薄，以及停步后仍随模拟演化的尾流。没有贴在角色身上的密度清空遮罩。

选中 `FogFields` 中的雾盒，在 **Interaction / Movement** 调整：

| 参数 | 默认值 | 用途 |
| --- | --- | --- |
| Movement Radius | 0.65 m | 有效体宽尺度；越大推开的通道越宽，与 Jump Radius 独立 |
| Movement Coupling | 7 s⁻¹ | 人体与雾的动量耦合率；越大推动越强，0 关闭行走推动 |
| Movement Wake | 0.65 | 身后拖曳／平面环流强度；0 只保留前推与侧向分流 |

参数实时生效，不重置雾。为了单看行走，可临时设 Initialization 的 **Wind Speed=0**，将 **SWE Gravity Threshold** 设得高于初始厚度，排除背景输送和重力摊平；这不是运行条件。走出雾区、松开按键或释放鼠标后不再注入运动源，已有尾流由阻尼和通量自然衰减。暂停不接收新轨迹，恢复不会补放暂停期间的移动。行走作用的承载高差在 0.15～0.8 m 渐出，避免影响上下层；森林示例没有接入行走。

### 行走气流调研与二维近似

人体不是在脚下持续制造圆形爆炸。移动时会在前方排挤空气，空气沿身体两侧绕过，身后出现卷吸和拖曳尾流；停步也不会让尾流立即消失。研究还观察到成对涡结构、明显的向下气流，以及尾流向地面和侧方扩散。可参考：

- [The influence of human walking on the flow and airborne transmission in a six-bed isolation room](https://pmc.ncbi.nlm.nih.gov/articles/PMC7126717/)：行走假人引发的前方气流与尾流输送，属于特定病房条件下的 CFD 模拟。
- [Human-walking-induced wake flow – PIV experiments and CFD simulations](https://doi.org/10.1177/1420326X17701279)：PIV／CFD 对人体替身尾流的研究，报告下洗与涡结构；替身与控制环境不等同于任意真实步态。
- [Three-dimensional analysis of the effect of human movement on indoor airflow patterns](https://pubmed.ncbi.nlm.nih.gov/32870542/)：真实人体行走的三维气流测量，报告经过后最长约 10 秒的扰动。该时间受测点、步速和环境影响，不用作游戏中的固定恢复计时。

当前 SWE 只保存近地雾的厚度与水平动量，无法表达真实尾流的竖向下洗、热羽流和完整三维涡旋。实现将上述形态投影为可调的前推／侧向分流／顺行尾流加反向平面环流，源项不直接增减雾量，质量只通过开放边界生成／移除；平面环流与各项系数是游戏近似，不声称复现论文中的涡轴、湍流频率或定量速度。完整输入与时间合约见 [SWE 合约](../specs/heightfield-swe.md#接地行走推动与尾流)。

## 编辑

1. 选中雾盒，用原生移动／Y 旋转工具放置，通过三个 gizmo 手柄调整宽高深。只支持单位缩放，不支持 X/Z 旋转。
2. 进入场景时自动烘焙并预览；修改盒体或源几何后，点击 Inspector 的 **Bake local heightfield** 更新内存高度图，或重新进入场景。烘焙结果不保存，场景只保存布局和参数。
3. 展开 **Initialization** 修改高度、厚度上限、浓度和噪波；也可拖入 `.tres`。所有模式都由同一套 Noise 参数生成初态，不再绕过自然薄雾／SWE。形状参数更新初态，外观参数只调显示，无需重烘焙地形。共享资源会影响所有引用者，需要独立编辑时选择 Make Unique。
4. 调整 **Edge Fade** 设置向内渐出宽度（米），边界处雾层厚度归零；设为 0 关闭。

贴地薄雾预设在 `addons/heightfield_fog/presets/forest_mist.tres`。两个盒体 Base Height=2.55 m、盒底 Y=−2 m，基准水平雾顶为 0.55 m；叠加 0.35 m 振幅、0.4 频率的噪波后减地形，再限制初始贴地厚度不超过 **Max Thickness=0.38 m**。**Coverage=0.5** 产生间隙，**Top Softness=0.85** 软化上沿，**Wind Stretch=4.5** 拉长雾带；降低 Concentration 可减淡。

高度、Max Thickness、Noise 全组、Wind Direction／Stretch 的修改会重建初态并重置 SWE；Concentration、Coverage／Softness、Top Softness、Detail Strength／Scale 只改显示，保留模拟。自然模式 SWE 中，Wind Speed 实时控制真实厚度与扰动输送，上风边界连续补入同配置的噪波雾，下风边界排出；设为 0 停止风补入且不重置，但无实体处和盒边仍可向外排出。SWE Gravity Threshold 只抑制阈值以下的重力压力，不阻止风搬运薄雾。SWE 仍可能堆积到初始上限以上；Max Thickness 同时限制初态与新补入雾，不裁切已有状态。想保留设计厚度可关闭 SWE，但不能响应起跳；静态模式风速只移动疏密纹理。盒间无通量交换，树干／倒木碰撞不自动成为雾障碍。详细调参见 [addon 说明](../../addons/heightfield_fog/README.md#风输送与边界补雾)。

添加新雾盒时创建 `HeightfieldFogBox` 节点。Source Root 留空使用场景根；不需要参与烘焙的 mesh 加入 `heightfield_fog_ignore` 分组。详见 [addon 使用说明](../../addons/heightfield_fog/README.md)。

## 验证

在项目根执行：

```powershell
& G:\Tools\Godot_mono_v4.7.2\godot_console.exe --headless --path . --script res://addons/heightfield_fog/bake_test.gd
& G:\Tools\Godot_mono_v4.7.2\godot_console.exe --headless --path . --script res://addons/heightfield_fog/initialization_test.gd
# Stable Fluids：真实 GPU 数值、开放回溯与主场景 F2／暂停／重置。
& G:\Tools\Godot_mono_v4.7.2\godot_console.exe --path . --script res://addons/heightfield_fog/stable_fluid_test.gd --max-fps 120
# SWE 真实 GPU 数值验证。
& G:\Tools\Godot_mono_v4.7.2\godot_console.exe --path . --script res://addons/heightfield_fog/swe_test.gd --max-fps 120
# 自然薄雾及 SWE 输出纹理的真实 GPU 行为验证。
& G:\Tools\Godot_mono_v4.7.2\godot_console.exe --path . --script res://addons/heightfield_fog/natural_mist_test.gd --max-fps 60
# 主场景：同一真实控制器，SWE 验证动量／质量，Stable Fluids 验证径向速度／坐标搬运及起跳升高／落地压低。
& G:\Tools\Godot_mono_v4.7.2\godot_console.exe --path . --script res://tests/fog_playground_jump_test.gd --max-fps 60
& G:\Tools\Godot_mono_v4.7.2\godot_console.exe --path . --script res://tests/fog_playground_jump_test.gd --max-fps 60 -- --stable-fluids
# 森林：需要有焦点的图形窗口，验证默认自由鼠标、物理 F／Esc、行走、跳跃和边界。
& G:\Tools\Godot_mono_v4.7.2\godot_console.exe --path . --script res://tests/forest_walk_test.gd --max-fps 60
# 有限帧真实 GPU 冒烟运行，使用当前主场景。
& G:\Tools\Godot_mono_v4.7.2\godot_console.exe --path . --quit-after 120 --max-fps 60
```

旧全局雾场及旧 SWE／玩家扰动实现已删除；当前使用 addon 内的新局部 SWE，不再使用旧实验场命令。

## 性能采集

```powershell
& G:\Tools\Godot_mono_v4.7.2\godot_console.exe --path . --script res://tools/profile_forest_swe.gd
```

固定出生点相机，两个 128² 雾场，关闭 VSync／FPS 上限，每组 6 秒，交替暂停／运行，并加入每秒一次起跳冲量负载。保持时间重投影，暂停时保留同一 SWE 厚度纹理与渲染路径。采集后才回读状态诊断；不覆盖场景或个人配置。

当前资源噪波预设在 RTX 5070 Ti Laptop GPU / Godot 4.7.2 / D3D12 / 1280×720 的参考结果：每个 60 Hz 模拟批次，ClearingMist GPU 约 0.055 ms，DeepForestMist 约 0.071～0.073 ms，合计约 0.126～0.128 ms；起跳负载相近。两场 CPU 提交合计约 0.041～0.043 ms／批次，不能当成 GPU 耗时。诊断无 fault／CFL 限速；启动预热约 6.84 ms 追赶截断，稳定采样段未增加。关闭两盒 SWE 后显存统计减少约 2.5 MiB。

本轮暂停约 775～782 FPS、运行约 772～774 FPS、起跳约 792 FPS；环境波动可大于场景差异，不能从阶段间 FPS 差推算求解器成本，也不能当成旧实现同机前后对比。采集结束时最大模拟厚度约 0.97～1.01 m，说明初始 0.38 m 上限不会截断后续物理堆积。上述是固定出生点视角短测，不是最坏场景或低端 GPU 保证。完整数值与计时语义见 [SWE 合约](../specs/heightfield-swe.md)。
