# Shooting Impact Asset Review

Reviewed on 2026-08-04 for the shooting-impact and blood-VFX pass.

## Integrated asset

### Kenney — Splat Pack

- Source: https://kenney.nl/assets/splat-pack
- License: Creative Commons Zero (CC0)
- Imported file: `assets/fx/blood/kenney_splat29.png`
- Usage: camera-facing blood impact sprite, tinted dark red and combined with native Godot 3D droplets.
- Local license record: `assets/fx/blood/License.txt`

This was the strongest direct match: the pack provides transparent splat silhouettes that remain readable in the project's low-poly visual style and can be recolored without editing the source bitmap.

## 原型枪声

- 文件：`assets/sfx/weapons/impactMetal_heavy_002.ogg`
- 来源：现有Kenney impact音效档案
- 授权：CC0，授权副本位于`assets/sfx/weapons/License.txt`
- 用途：作为原型阶段每发步枪的机械瞬态；正式音频可以替换该流，但不得改变`ShotAudio`节点和触发接口。

## Reviewed alternatives

### Quaternius — Zombie Apocalypse Kit

- Source: https://quaternius.com/packs/zombieapocalypsekit.html
- License shown on source page: CC0
- Contents shown on source page: 60 animated/textured models in FBX, OBJ, Blend, and glTF formats.
- Decision: useful for future zombie, character, vehicle, and environment expansion, but not a dedicated blood-impact pack. The current project already uses matching Quaternius zombie-apocalypse assets.

### Quaternius — Toon Shooter Game Kit

- Source: https://quaternius.com/packs/toonshootergamekit.html
- License shown on source page: CC0
- Contents shown on source page: 74 animated/textured models in FBX, OBJ, Blend, and glTF formats.
- Decision: a good future source for stylized shooter props and characters, but it does not replace a dedicated splat texture for the current blood effect.

### Kenney — VFX series

- Source: https://kenney.nl/assets/series:VFX
- Relevant listings observed: Splat Pack, Particle Pack, Smoke Particles, and Light Masks.
- Decision: Splat Pack was integrated now. Particle Pack and Smoke Particles are suitable follow-up candidates for muzzle smoke, wall impact dust, and explosions.

### Poly Haven

- Blood search: https://polyhaven.com/textures?q=blood
- License: https://polyhaven.com/license
- Result: the `blood` texture search returned 0 results during review.
- Decision: no blood asset was imported. Poly Haven remains a strong CC0 source for arena surfaces, props, HDRIs, and realistic environment materials.

## Implementation note

Only the Kenney bitmap is third-party VFX content. Motion, fading, directional emission, gravity, and color treatment are implemented with native Godot nodes and GDScript, so the effect is lightweight and easily tunable.
