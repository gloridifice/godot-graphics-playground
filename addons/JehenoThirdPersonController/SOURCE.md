# 第三方来源与本地导入说明

## 来源与许可

- 项目：[Jeh3no / Godot-Third-Person-Controller](https://github.com/Jeh3no/Godot-Third-Person-Controller)
- 导入提交：[`380d949d2324a4ee6264d96753217ddfbaaab9ab`](https://github.com/Jeh3no/Godot-Third-Person-Controller/tree/380d949d2324a4ee6264d96753217ddfbaaab9ab)
- 上游目录：`addons/JehenoThirdPersonController/`；本项目保留相同目录名。
- Jeh3no 的 MIT 许可全文保留在 [LICENSE](LICENSE)。
- 上游基于 [Gtibo / Godot-Plush-Character](https://github.com/gtibo/Godot-Plush-Character)，角色模型与原始项目来自 Gtibo。上游根目录 `license.md` 中的 Tibo MIT 版权声明另存为 [LICENSE.Gtibo](LICENSE.Gtibo)。
- 原型贴图：PiCode 的 [Godot Theme Prototype Textures](https://godotengine.org/asset-library/asset/2480)。
- 示例音效：[Kenney](https://kenney.nl/assets/category:Audio?sort=update)。
- 字体、宣传图等其他文件随同该上游目录导入；上游未附单独的字体许可说明。
- 上游 [README.md](README.md) 原样保留，包含完整功能、默认按键与致谢。

## 导入范围与适配

包含状态机控制器、第三人称相机、HUD、Godot Plush 模型及动画、材质／贴图、字体、音效、粒子效果和测试地图。没有复制上游 Git 元数据或生成缓存，省略了编辑器遗留文件 `custom_animations.res.depren`。

本地适配仅涉及资源导入，不修改上游 GDScript 或 shader 行为：

- 场景与文本资源中的旧 `res://Godot-State-Machine-Third-Person-Controller/addons/...` 引用改为 `res://addons/...`。
- 通过 Godot 重新保存 `custom_animations.res`，将旧 `res://components/godot_plush/...` 动画依赖指向本目录。
- Godot 重新生成 `.import` 中的源文件／缓存路径；为 `Arts/StoreImages/` 生成独立 UID，避免与上游 `Arts/Images/` 重复。
- 不透明位图以质量 85 的 JPG 保存，原型贴图位于 `Arts/godot-prototype-texture/JPG/`。场景、材质与导入文件已更新路径，保留贴图 UID；有透明像素的图标仍为 PNG。
- 新增本说明及 `LICENSE.Gtibo`，项目根目录的 `THIRD_PARTY.md` 同步登记来源。

## 使用

这是场景型资产，没有 `plugin.cfg`，无需在编辑器插件列表中启用。

- 角色入口：`res://addons/JehenoThirdPersonController/PlayerCharacter/player_character_scene.tscn`。
- 测试入口：打开 `res://addons/JehenoThirdPersonController/Map/test_map_scene.tscn`，按 **F6**。
- 输入组件在运行时补齐缺失的 `play_char_*` 动作，并输出对应警告；不会写入 `project.godot`。默认 WASD／方向键移动、Shift 跑步、空格跳跃，其他操作见上游 README。
- 注意：上游相机启动即捕获鼠标，**Ctrl** 切换释放／捕获。这与本项目森林示例的 **F / Esc** 约定不同。

本目录保留上游脚本行为。项目主场景 `scenes/fog_playground.tscn` 仅沿用本目录测试地图布局和地面贴图，角色／相机改由独立的 `addons/motion/` 原生控制器与 Mixamo 模型实现，场景脚本转发行走／起跳／落地信号到雾盒；没有直接修改本目录控制器／相机源码。森林仍使用独立的 `scenes/player.tscn`。
