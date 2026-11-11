# 局部高度雾实验场

用 Godot 4.7.2 打开项目，按 **F5** 启动当前主场景；也可打开 `addons/heightfield_fog/demo.tscn` 按 **F6**。

```powershell
& G:\Tools\Godot_mono_v4.7.2\godot.exe --path .
```

主场景是程序化低多边形森林：48×48 米缓坡地形、蜿蜒土路、林间空地、针叶树、四处倒木、大小岩石和碎石。固定种子保证重复运行一致，编辑器也生成几何；所有几何由本项目生成，未引入外部美术资源。

启动时自动烘焙两个旋转雾盒：`ClearingMist` 覆盖林间空地，`DeepForestMist` 覆盖后方林地，共享自然薄雾预设 `forest_mist.tres`。低洼地形积雾、高处岩石露出；运行时使用每盒独立 GPU SWE 推进厚度与动量，自然密度细节沿世界风向缓慢漂移，保持时间重投影。烘焙来源为 `Landscape/Terrain` 的地面及岩石；树冠和倒木不作为承载面。倒木有角色碰撞，但不是雾动力障碍。

运行时使用第三人称胶囊角色：**WASD 行走、鼠标环绕、空格跳跃、Esc 释放鼠标、单击画面恢复控制**。移动方向跟随相机，斜向不加速；释放鼠标或失焦后停止接受移动输入。角色在土路入口落地，正常重力与贴坡；地面、岩石、树干、倒木有物理碰撞，地图边缘有防跌落边界。相机由 Phantom Camera 跟随并避让这些碰撞体，不为树冠／细枝建立碰撞。在雾里按空格起跳会向脚边 SWE 场注入径向动量，由求解器输送厚度、形成堆积与波动，不再按固定时间恢复；行走和落地不触发。可在雾盒 Interaction 分组调整 Jump Radius（m）和 Jump Speed（m/s）。SWE Simulation 分组可暂停、重置、调整约化重力与阻尼；暂停保留状态，关闭模拟回到静态初态且不响应跳跃。原上下层分离场景保留为 `addons/heightfield_fog/fixtures/stacked_floors.tscn`，用于烘焙测试。

## 编辑

1. 选中雾盒，用原生移动／Y 旋转工具放置，通过三个 gizmo 手柄调整宽高深。只支持单位缩放，不支持 X/Z 旋转。
2. 点击 Inspector 的 **Bake local heightfield** 在编辑器预览，然后保存场景。盒体变化后需重烘焙。
3. 展开 **Initialization** 修改初始高度、浓度和噪声；也可拖入 `.tres`。基础参数更新初态，Natural Mist 参数实时调整 GPU 形状，无需重烘焙地形。共享资源会影响所有引用者，需要独立编辑时选择 Make Unique。
4. 调整 **Edge Fade** 设置向内渐出宽度（米），边界处雾层厚度归零；设为 0 关闭。

初始薄雾调节：**Base Height** 控制基准雾顶（相对盒底）；两个盒体使用 Base Height=2.55 m、盒底 Y=−2 m，初始世界雾顶均为 0.55 m。SWE 开启后，厚度由物理状态决定，Top Variation 不再改变物理雾顶；Detail Strength／Scale 与 Wind 参数仅调显示密度细节，不推动模拟。关闭 SWE 后才回到原先程序化雾顶模式。基础初态修改会重置模拟；参数范围见 addon 说明。盒间没有通量交换，树干／倒木角色碰撞不会自动成为雾的物理障碍。

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
# 需要有焦点的图形窗口：验证落地、行走、跳跃、鼠标释放／恢复和地图边界。
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

本机 RTX 3070 / Godot 4.7.2 / D3D12 / 1280×720 的参考结果：每个 60 Hz 模拟批次，ClearingMist GPU 约 0.061～0.063 ms，DeepForestMist 约 0.092～0.094 ms，合计约 0.155 ms；起跳负载相近。两个场的 CPU 提交合计约 0.08～0.11 ms／批次，不能当成 GPU 耗时。测量批次中无 fault、CFL 限速或新增追赶丢时；另一轮启动预热发生约 9.8 ms 的追赶截断，稳定采样段该计数未再增加。关闭两盒 SWE 后，显存统计减少约 2.5 MiB。

整帧受环境负载影响较明显：两轮运行组约 241～341 FPS，起跳组约 241～330 FPS；最近一轮暂停组约 251～257 FPS、运行组约 241～246 FPS；不能用不同阶段的 FPS 差直接推算求解器成本。上述是固定视角短测，不是最坏场景或低端 GPU 保证。完整数值与计时语义见 [SWE 合约](../specs/heightfield-swe.md)。
