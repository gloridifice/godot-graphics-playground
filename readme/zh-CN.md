<div align="center">

# Godot Graphics Playground

</div>

<div align="center">

[English](../README.md) | 简体中文 | [日本語](ja-JP.md) | [Français](fr-FR.md)

</div>

一组 Godot 4.7.2 Forward+ 实验场景，用于观察实时光照、贴地雾和角色运动。

![Sponza 四个视角：中庭、拱廊、沿中庭中轴拍摄的广角全景和阳光下的庭院](images/sponza-restir.jpg)

*Intel Sponza 2022 · Vulkan · Split Radiance Cascades 双反弹 GI。上排：ReSTIR DI 照亮的中庭和拱廊。左下：从中庭中央用广角拍下地面和上层拱廊，由太阳光和[火把步行场景](../scenes/sponza_torch_walk.tscn)的廊灯照明。右下：仅太阳直射及其漫反射反弹。下排两图均关闭天空环境光和天空反射。*

**直接光照（DI）：** ReSTIR DI 复用上一帧和相邻像素的点光源样本，按各光源对当前表面的贡献重新采样，再通过遮挡检测计算阴影。
**间接光照（GI）：** Split Radiance Cascades 在世界空间追踪射线，用多级探针按方向缓存入射光，并复用这些光照数据计算第二次漫反射反弹。

## 快速开始

### 安装

安装 Godot 4.7.2 和 Git LFS，然后克隆项目及其资源：

```sh
git lfs install
git clone https://github.com/gloridifice/godot-graphics-playground.git
cd godot-graphics-playground
```

打开 `project.godot`，等资源导入完成后按 **F5** 进入雾实验场。

### 更新

在项目目录中依次运行 `git pull --ff-only` 和 `git lfs pull`。

## 实验内容

- 在 Sponza 拱廊中对比 ReSTIR DI 与逐一计算 12 盏点光源的参考结果。
- 切换一次和两次漫反射反弹，观察间接光如何照亮拱顶。
- 走过贴地雾或在雾中起跳，对比浅水方程与 Stable Fluids 两种模拟的响应。
- 在[角色演示场景](../addons/motion/demo.tscn)中查看运动匹配、脚部锁定和攀爬。

## Vulkan GPU 实测

**RTX 5070 Ti Laptop GPU**（驱动 621.01），Godot 4.7.2 Forward+，原生分辨率 1600 × 900。相机固定在封面右上角的拱廊，启用 12 盏点光源、ReSTIR DI 和双反弹 GI，关闭 HUD 和垂直同步。

| 每帧 GPU 耗时（ms） | 中位数 | P95 |
|---|---:|---:|
| 整个视口 | 2.927 | 4.635 |
| GI：Prepare 至 Merge | 0.584 | 0.639 |
| DI：时域复用与着色 | 1.059 | 2.643 |
| 共用阶段：Receiver 与 Apply | 0.454 | 0.660 |

预热 240 帧后，[测量脚本](../tools/profile_sponza_restir.gd)记录了 4,413 次视口读数和 64 组分阶段样本。视口总耗时包含 Godot 的其余渲染工作；GI 和 DI 两行是各自阶段的耗时，不是单独开启某一效果时的整帧耗时。

## 从源码运行封面场景

资源导入完成后，确保 Godot 可执行文件在 `PATH` 中，在项目目录运行：

```sh
godot --rendering-driver vulkan scenes/sponza_restir_di.tscn
```

场景默认开启 ReSTIR DI 和双反弹 GI。按 **B** 可切换到单次反弹，等光照稳定后再比较。

## 许可与致谢

见[第三方声明与资源使用限制](../THIRD_PARTY.md)，其中包括 [Intel Sponza 署名与许可](../assets/sponza/credits_license.txt)。

## 开发文档

- [项目架构](../doco/architecture.md)
- [Split Radiance Cascades 与 ReSTIR DI](../addons/split_radiance_cascades/USAGE.md)
- [高度场雾](../addons/heightfield_fog/README.md)
