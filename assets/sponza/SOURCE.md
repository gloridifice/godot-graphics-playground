# Intel Sponza 2022：中庭与彩色布幔

[预览场景](../../scenes/sponza_src_preview.tscn)直接使用本目录的资源，无需联网或安装转换工具。来源是 [Intel GPU Research Samples](https://www.intel.com/content/www/us/en/developer/topic-technology/graphics-research/samples.html) 的两个官方包：

| 下载 | 使用的 glTF | glTF JSON 的 SHA-256 |
| --- | --- | --- |
| [Sponza Base Scene](https://cdrdv2.intel.com/v1/dl/getContent/830833?fileName=main_sponza.zip) | `main_sponza/NewSponza_Main_glTF_003.gltf` | `e04c4c540c74bdddcbd3f590a85c14119bfd5839702246a23b3a737c0cce2400` |
| [Colorful Curtains](https://cdrdv2.intel.com/v1/dl/getContent/726650) | `pkg_a_curtains/NewSponza_Curtains_glTF.gltf` | `b56968aeb691970b63027ae3ffbb0d77f1d736e7bdace5c70be106d6dcfbb516` |

**署名与许可。** Intel Sample Library (2022)，Frank Meinl、Anton Kaplanyan；布幔包另署 Katica Putica、Cristiano Siqueira、Timothy Heath、Justin Prazen、Sebastian Herholz、Bruce Cherniak、Anton Kaplanyan。参考摄影：Katica Putica / Princino.photo。两个下载包附带相同的 [原始署名与许可全文](credits_license.txt)，包含引用格式、[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) 正文，以及关于个人、教育和有限商业用途的说明。商用前请核实适用条款；本项目未另行授予美术资源许可。

## 场景中实际使用什么

[中庭实机截图（Godot Forward+，1280 × 720）](preview/nave.jpg)

| | 上游三角形 | 可见网格 | 仅用于间接光求交 |
| --- | ---: | ---: | ---: |
| 建筑 | 3,747,018 | 288,666 (`palace.gltf`) | 33,582 (`palace_trace.glb`) |
| 布幔与挂件 | 1,997,366 | 141,426 (`curtains.gltf`) | 17,790 (`curtains_trace.glb`) |
| 合计 | 5,744,384 | **430,092** | **51,372** |

共享的 `textures/` 有 78 张 2048 × 2048 的 JPG，均从上游原图以质量 85 编码，保留底色、切线空间法线及粗糙度／金属度。JPG 没有透明通道，污渍贴花单独保存一张灰度 JPG；Godot 导入建筑时用 [`dirt_decal.tres`](dirt_decal.tres) 组合底色和线性透明度，保留原材质的 0.35 透明度系数。纹理继续使用 mipmaps 和显存压缩。两个 `.bin` 是 glTF 必需的网格数据，不能单独移动。没有导入上游相机、灯光、HDR 或烘焙照明。

两个 `*_trace.glb` 从**同一版**建筑与布幔生成，以米为单位、与可见网格对齐，只保留不透明表面，用线性底色和金属度的贴图均值近似离屏反弹。它们在 `Subject/TraceProxy` 下隐藏，不参与相机、直接光阴影或接收面绘制。间接光仍落在实际显示的高精度网格上；小褶皱或细雕花的间接遮挡是近似的。

## 从上游重新生成（可选）

解压上述两个包并保留其中 `.bin` 和 `textures/` 的相对路径。用 Python 3、NumPy、Pillow 和 [gltfpack 1.2](https://github.com/zeux/meshoptimizer/releases/tag/v1.2)，从项目根目录执行：

```powershell
python tools/bake_sponza.py <main_sponza/NewSponza_Main_glTF_003.gltf> <pkg_a_curtains/NewSponza_Curtains_glTF.gltf> --gltfpack <gltfpack可执行文件路径>
```

工具从原始网格减面：建筑锁定边界，避免独立表面的拱券和墙体接缝张开；布幔单独控制误差，保留褶皱。输出前按场景实例计数，检查建筑与布幔合计在 30 万至 50 万个可见三角形之间。求交代理独立减面，总预算仍为 65,536。保留本目录的 `.import` 设置：可见模型不再生成第二套显示 LOD，以保证接收面深度匹配。重新导入后用真实 Forward+ 设备运行 `godot --path . --script res://tests/sponza_src_preview_test.gd`。
