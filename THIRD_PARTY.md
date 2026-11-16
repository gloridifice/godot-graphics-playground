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
- Imported as a scene asset, not an editor plugin. The upstream demo remains unchanged: it captures the mouse on startup and uses Ctrl. The project's main scene is now `scenes/fog_playground.tscn`; local subclasses in `scripts/player/fog_playground_player.gd` and `scripts/camera/fog_playground_camera.gd` add SWE takeoff/landing events and a free-on-start F-toggle/Esc-release control policy, without modifying upstream scripts. The forest's `scenes/player.tscn` remains separate.
- `scenes/fog_playground.tscn` is based on the upstream test map, with a renamed root, no shared scene UID, and a local four-field fog setup; it still references the vendored addon assets. `scripts/fog_playground.gd` bridges its CSG surfaces to the heightfield baker without changing upstream assets.
- Usage and detailed provenance: `addons/JehenoThirdPersonController/SOURCE.md`; upstream documentation is retained in its `README.md`.

## Water foam NSH data

- Installed: `addons/water/textures/foam/{shorewaves_nsh,crest_foam_nsh,crest_foam2_nsh}.png`, copied from the designated local water-simulation project's offline-baked derivatives, not the upstream original NSH products.
- Shorewaves mask: Copyright 2026 Reboot16 / Enrico K., MIT; full notice in `addons/water/textures/foam/LICENSE.Shorewaves.txt`.
- Crest masks: Copyright 2019 Wave Harmonic and contributors, MIT, public Crest 4 commit `db0658ff0b2e93e4a9e28cc2867509658b0ecc00`; full notice in `addons/water/textures/foam/LICENSE.Crest.txt`.
- Packed normal/Soft/Height provenance and local shader adaptations: `addons/water/SOURCE.md`. No source project's models, HDRI, fonts or UI library are bundled with water.
