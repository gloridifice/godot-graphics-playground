# Third-party dependencies

## Phantom Camera

- Upstream: https://github.com/ramokz/phantom-camera
- Version: v0.11.0.4, commit archive `d20277e` (official release zipball).
- Installed directory: `addons/phantom_camera/` (unmodified upstream addon).
- License: MIT; full copyright and permission notice in `addons/phantom_camera/LICENSE`.
- Uses Third Person Follow, its built-in SpringArm3D, and PhantomCameraHost.
- No upstream examples are used by the playground. The vendored addon includes upstream assets and examples.
- Updates are explicit; do not run automatic updater in this project.

## Jeheno Third Person Controller

- Upstream: https://github.com/Jeh3no/Godot-Third-Person-Controller
- Commit: `380d949d2324a4ee6264d96753217ddfbaaab9ab`.
- Installed directory: `addons/JehenoThirdPersonController/` (controller, camera, HUD, character model and animations, textures, font, audio, VFX, and test map).
- License: MIT; Jeh3no's notice is retained in `addons/JehenoThirdPersonController/LICENSE`. The upstream root `license.md` is retained as `addons/JehenoThirdPersonController/LICENSE.Gtibo` (Copyright 2024-present Tibo).
- Original project and character model: Gtibo, https://github.com/gtibo/Godot-Plush-Character.
- Prototype textures: PiCode, https://godotengine.org/asset-library/asset/2480. Demo audio: Kenney, https://kenney.nl/assets/category:Audio?sort=update. The bundled font has no separate license notice in upstream.
- Local adaptations: rebased resource paths and the binary animation-library dependency; regenerated import metadata and duplicate promotional-image UIDs. GDScript, shaders, and original art/audio are unchanged; the unused `.depren` editor artifact is omitted.
- Imported as a scene asset, not an editor plugin. The upstream demo remains unchanged: it captures the mouse on startup and uses Ctrl. The project's `scenes/fog_playground.tscn` now uses the independent native `addons/motion/` controller and Mixamo model, retaining only the vendored map layout and ground texture. The forest's `scenes/player.tscn` remains separate.
- `scenes/fog_playground.tscn` is based on the upstream test map, with a renamed root, no shared scene UID, and three local fog fields; it still references the vendored addon assets. `scripts/fog_playground.gd` bridges its CSG surfaces to the heightfield baker without changing upstream assets.
- Usage and detailed provenance: `addons/JehenoThirdPersonController/SOURCE.md`; upstream documentation is retained in its `README.md`.

## Mixamo character and animations

- Installed directory: `addons/motion/assets/mixamo/`; derived native resources in `addons/motion/assets/guard.scn` and `addons/motion/animations/`.
- Source: Adobe Mixamo. Guard, walk/crouch/jump/fall and left/right strafe FBX files and texture come from https://github.com/aaronsnoswell/3DCharacter at `1902fb9674350f2b68b5a26b8eccd64570ac8dd4`. The backward walk comes from https://github.com/ArielOliveira/3rdPersonController at `c4858b658abe4165a6e32892e2becad3250665b3` and is retargeted to the Guard locally. Forward running is now the user-provided `Run Forward.fbx` (local `run.fbx`, SHA-256 in SOURCE.md), replacing the upstream Running clip; its original asset rights must be verified by the provider. No upstream controller code, Unity project, Blender file, or Collada scene is used.
- Mixamo art is governed by Adobe's terms, not the MIT licenses of other addons. The upstream repository has no separate open-source license. Do not redistribute these assets as a standalone model/animation library; verify rights before publicly distributing the source project or a reusable asset package.
- Exact file mapping, local processing, and official usage references: `addons/motion/SOURCE.md`. Controller, motion-matching search/bake, and camera logic are local GDScript using native Godot nodes. The offline motion database is derived from the same animation assets and does not grant separate redistribution rights.
