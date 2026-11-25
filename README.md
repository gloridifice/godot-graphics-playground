<div align="center">

# Godot Graphics Playground

</div>

<div align="center">

English | [简体中文](readme/zh-CN.md) | [日本語](readme/ja-JP.md) | [Français](readme/fr-FR.md)

</div>

Godot 4.7.2 Forward+ scenes for experimenting with real-time lighting, ground fog and character motion.

![Four views of Sponza: the nave, vaulted arcade, a wide view down the center of the atrium, and the sunlit courtyard](readme/images/sponza-restir.jpg)

*Intel Sponza 2022 · Vulkan · two-bounce GI with Split Radiance Cascades. Top: ReSTIR DI in the nave and arcade. Bottom left: a wide view of both levels from the center of the atrium, lit by the sun and the [Torch Walk](scenes/sponza_torch_walk.tscn) gallery lights. Bottom right: sunlight and its diffuse bounces only. Both bottom views have sky lighting and sky reflections disabled.*

**Direct lighting (DI):** ReSTIR DI reuses point-light samples from the previous frame and neighboring pixels, weights them by their contribution to the current surface, and tests visibility to resolve shadows.
**Indirect lighting (GI):** Split Radiance Cascades traces rays in world space, stores incoming light by direction in a hierarchy of probes, and reuses that light for a second diffuse bounce.

## Quick Start

### Install

Install Godot 4.7.2 and Git LFS, then clone the project with its assets:

```sh
git lfs install
git clone https://github.com/gloridifice/godot-graphics-playground.git
cd godot-graphics-playground
```

Open `project.godot`, wait for asset import to finish, then press **F5** to enter the fog playground.

### Update

Run `git pull --ff-only` and `git lfs pull` from the project directory.

## Features

- Compare ReSTIR DI with a reference that evaluates all 12 point lights in the Sponza arcade.
- Switch between one and two diffuse bounces to see how light reaches the vaulted ceiling.
- Walk or jump through ground fog and compare shallow-water and Stable Fluids simulations.
- Inspect motion matching, foot locking and climbing in the [character demo](addons/motion/demo.tscn).

## Vulkan GPU Timings

**RTX 5070 Ti Laptop GPU** (driver 621.01), Godot 4.7.2 Forward+, 1600 × 900 at native resolution. The camera stays in the arcade (top right of the cover), with 12 point lights, ReSTIR DI and two-bounce GI. HUD and VSync are off.

| GPU time per frame (ms) | Median | P95 |
|---|---:|---:|
| Entire viewport | 2.927 | 4.635 |
| GI: Prepare through Merge | 0.584 | 0.639 |
| DI: temporal reuse + shading | 1.059 | 2.643 |
| Shared: Receiver + Apply | 0.454 | 0.660 |

After 240 warm-up frames, the [profiler](tools/profile_sponza_restir.gd) collected 4,413 viewport readings and 64 pass samples. The viewport includes the rest of Godot’s rendering; the pass rows are not full-frame times with one effect enabled in isolation.

## Run the Cover Scene from Source

After import, run this from the project directory with the Godot executable on your `PATH`:

```sh
godot --rendering-driver vulkan scenes/sponza_restir_di.tscn
```

ReSTIR DI and two-bounce GI are on by default. Press **B** to switch to a single bounce, then let the lighting settle before comparing.

## License and Credits

See [third-party notices and asset usage restrictions](THIRD_PARTY.md), including the [Intel Sponza credits and license](assets/sponza/credits_license.txt).

## Development

- [Architecture](doco/architecture.md)
- [Split Radiance Cascades and ReSTIR DI](addons/split_radiance_cascades/USAGE.md)
- [Heightfield fog](addons/heightfield_fog/README.md)
