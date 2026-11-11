# 局部高度雾实验场

用 Godot 4.7.2 打开项目，按 **F5** 启动 `scenes/fog_playground.tscn`：默认自由鼠标，按 **F** 进入／退出控制，**Esc** 或失焦释放。WASD 移动、Shift 跑步、空格跳跃；起跳脚下雾气汇聚，落地向外扩散，均由真实 SWE 模拟。

森林示例仍可打开 `addons/heightfield_fog/demo.tscn` 按 **F6**。

```powershell
& G:\Tools\Godot_mono_v4.7.2\godot.exe --path .
```

## 森林示例

可选森林场景是程序化低多边形森林：48×48 米缓坡地形、蜿蜒土路、林间空地、针叶树、四处倒木、大小岩石和碎石。固定种子保证重复运行一致，编辑器也生成几何；所有几何由本项目生成，未引入外部美术资源。

启动时自动烘焙两个旋转雾盒：`ClearingMist` 覆盖林间空地，`DeepForestMist` 覆盖后方林地，共享自然薄雾预设 `forest_mist.tres`。低洼地形积雾、高处岩石露出；运行时使用每盒独立 GPU SWE 推进厚度与动量，自然密度细节沿世界风向缓慢漂移，保持时间重投影。烘焙来源为 `Landscape/Terrain` 的地面及岩石；树冠和倒木不作为承载面。倒木有角色碰撞，但不是雾动力障碍。

游戏和测试场景默认**不锁鼠标，光标保持可见**。按 **F** 才锁定并隐藏鼠标、进入控制；之后 **WASD 行走、鼠标环绕、空格跳跃**。**Esc** 释放鼠标，单击画面或切回窗口不会自动锁定，需要再次按 F。移动方向跟随相机，斜向不加速；释放鼠标或失焦后停止接受移动输入。角色在土路入口落地，正常重力与贴坡；地面、岩石、树干、倒木有物理碰撞，地图边缘有防跌落边界。相机由 Phantom Camera 跟随并避让这些碰撞体，不为树冠／细枝建立碰撞。在雾里按空格起跳会向脚边 SWE 场注入径向动量，由求解器输送厚度、形成堆积与波动，不再按固定时间恢复；行走和落地不触发。可在雾盒 Interaction 分组调整 Jump Radius（m）和 Jump Speed（m/s）。SWE Simulation 分组可暂停、重置、调整约化重力与阻尼；暂停保留状态，关闭模拟回到静态初态且不响应跳跃。原上下层分离场景保留为 `addons/heightfield_fog/fixtures/stacked_floors.tscn`，用于烘焙测试。

## CSG 雾实验场

**F5** 或打开 `scenes/fog_playground.tscn` 按 **F6**，体验基于第三方控制器测试地图的主场景与四片局部雾：地面、斜坡、出生高台和远处跳台。默认不捕获鼠标，**F** 切换控制／释放，**Esc** 或失焦释放；单击、Ctrl 或重新获得焦点不捕获。释放时不接受移动／跳跃／镜头输入，但保留重力、碰撞和落地扰雾。

`FogFields` 下四个节点可独立移动、调整 Size、Initialization 和外观；地面使用水平雾顶，高台及斜坡使用贴承载面的薄层。四片雾均开启 SWE，并有自然密度漂移。真实接地起跳会向脚下施加向内动量，使雾汇聚；落地施加向外动量，使雾扩散。初次出生接地、二段空中跳跃不施加地面冲量；高差 1.5 m 外的雾不受影响。根节点 **Player Mist Interaction** 的 **Takeoff Pull**（默认 0.8）与 **Landing Push**（默认 1）调整两种强度，设为 0 可分别关闭；作用范围及速度由各盒 **Jump Radius / Jump Speed** 控制。不额外生成或删除雾量。

每次在编辑器打开场景或运行场景，都会自动构建内存高度图，不会将烘焙数据保存到 `.tscn` 或 `.res`。修改 CSG 或雾盒布局后，选择 **FogPlayground 根节点**，点击 Inspector 的 **Bake all playground fog** 更新预览；只需保存布局／参数修改，不需保存烘焙结果。该按钮先刷新 CSG 的烘焙网格再重烘焙全部雾盒；不要仅依赖单盒按钮更新已编辑的 CSG。派生 `_FogCSGSurface` 无渲染层、不投影、不生成碰撞，也不随场景保存，原有 CSG 和碰撞保持不变。

## 编辑

1. 选中雾盒，用原生移动／Y 旋转工具放置，通过三个 gizmo 手柄调整宽高深。只支持单位缩放，不支持 X/Z 旋转。
2. 进入场景时自动烘焙并预览；修改盒体或源几何后，点击 Inspector 的 **Bake local heightfield** 更新内存高度图，或重新进入场景。烘焙结果不保存，场景只保存布局和参数。
3. 展开 **Initialization** 修改高度、厚度上限、浓度和噪波；也可拖入 `.tres`。所有模式都由同一套 Noise 参数生成初态，不再绕过自然薄雾／SWE。形状参数更新初态，外观参数只调显示，无需重烘焙地形。共享资源会影响所有引用者，需要独立编辑时选择 Make Unique。
4. 调整 **Edge Fade** 设置向内渐出宽度（米），边界处雾层厚度归零；设为 0 关闭。

贴地薄雾预设在 `addons/heightfield_fog/presets/forest_mist.tres`。两个盒体 Base Height=2.55 m、盒底 Y=−2 m，基准水平雾顶为 0.55 m；叠加 0.35 m 振幅、0.4 频率的噪波后减地形，再限制初始贴地厚度不超过 **Max Thickness=0.38 m**。**Coverage=0.5** 产生间隙，**Top Softness=0.85** 软化上沿，**Wind Stretch=4.5** 拉长雾带；降低 Concentration 可减淡。

高度、Max Thickness、Noise 全组、Wind Direction／Stretch 的修改会重建初态并重置 SWE；Concentration、Coverage／Softness、Top Softness、Detail Strength／Scale、Wind Speed 只改显示，保留模拟。SWE 开启后仍会把质量输送到低处，可能超过初始厚度上限；想保留设计好的厚度可关闭 SWE，但不能响应起跳。关闭 SWE 不会切回另一套噪波。风速只移动疏密纹理，不驱动物理；盒间无通量交换，树干／倒木碰撞不自动成为雾障碍。详细调参见 [addon 说明](../../addons/heightfield_fog/README.md#贴地雾带调参)。

添加新雾盒时创建 `HeightfieldFogBox` 节点。Source Root 留空使用场景根；不需要参与烘焙的 mesh 加入 `heightfield_fog_ignore` 分组。详见 [addon 使用说明](../../addons/heightfield_fog/README.md)。

## 验证

在项目根执行：

```powershell
& G:\Tools\Godot_mono_v4.7.2\godot_console.exe --headless --path . --script res://addons/heightfield_fog/bake_test.gd
& G:\Tools\Godot_mono_v4.7.2\godot_console.exe --headless --path . --script res://addons/heightfield_fog/initialization_test.gd
# SWE 真实 GPU 数值验证。
& G:\Tools\Godot_mono_v4.7.2\godot_console.exe --path . --script res://addons/heightfield_fog/swe_test.gd --max-fps 120
# 自然薄雾及 SWE 输出纹理的真实 GPU 行为验证。
& G:\Tools\Godot_mono_v4.7.2\godot_console.exe --path . --script res://addons/heightfield_fog/natural_mist_test.gd --max-fps 60
# 主场景：真实控制器起跳汇聚／落地扩散 GPU 状态、质量与 F／Esc／失焦输入控制。
& G:\Tools\Godot_mono_v4.7.2\godot_console.exe --path . --script res://tests/fog_playground_jump_test.gd --max-fps 60
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
