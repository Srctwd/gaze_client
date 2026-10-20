# PS2 rendering maths, for gaze_client

Sources: the PS2's publicly documented hardware behaviour (GS, VU1, VIF, GIF), as
described in the open-source ps2sdk and PCSX2 projects and in public homebrew
documentation. Nothing here comes from any commercial game's code or data.

Every PS2 3D game, *Curse of Darkness* included, ran through the pipeline below.
Each game chose its own constants (light count, fog range, bones per batch, and
so on), and those choices are **not** covered here. "Typical" means a common
choice, not one confirmed for any particular title.

---

## 1. The pipeline

```
 EE (MIPS CPU)                    VU1 (vector DSP)                GS (rasteriser)
 ─────────────                    ────────────────                ───────────────
 animation, AI, culling   DMA     VIF1 UNPACK → VU1 memory        triangle setup
 build matrices        ───────▶   microprogram per vertex:   ───▶ Gouraud colour
 pick lights per object  (VIF1)    · transform (MVP)       XGKICK  perspective UV (STQ)
 build display lists               · light                 (GIF)   Z test, alpha test
                                   · clip / cull flag              blend, fog, dither
                                   · write GIF packet              → VRAM (4 MB)
```

The key fact is that the GS has **no programmable pixel stage**. All the
"shader" maths is per vertex in VU1, and the GS can only interpolate, texture,
blend and fog. That is where the PS2 look comes from: Gouraud-lit, vertex-fogged,
overbright, with effects built from framebuffer passes.

---

## 2. Geometry and fixed-point formats

VIF `UNPACK` expands compressed vertex streams into 128-bit VU words
(4 × float32 or 4 × int32). The common formats are:

| Data     | Storage            | Decode in VU1                         |
|----------|--------------------|---------------------------------------|
| Position | `V3-16` (3 × s16)  | `p = s16 * scale + offset` (per mesh) |
| Normal   | `V3-8` (3 × s8)    | `n = s8 / 127`                        |
| UV       | `V2-16` (2 × s16)  | `uv = s16 / 4096` (1.3.12) or `/256`  |
| Colour   | `V4-8` (4 × u8)    | `0x80` means 1.0 (see §5)             |

The int-to-float conversion is `ITOF0`, `ITOF4`, `ITOF12` or `ITOF15`, which are
fixed shifts of 0, 4, 12 or 15 fractional bits. That's why mesh exporters
quantise to those exact precisions.

**Triangle strips and the ADC bit.** The GS draws strips (`PRIM = TRISTRIP`).
Every vertex has an ADC ("don't draw kick") flag, which in packed GIF mode is
bit 111 of the XYZ2 quadword. With ADC set, the vertex enters the strip but no
triangle is emitted. Uses:

- *Strip restart*: set ADC on the first two vertices of each new strip, so many
  strips go in one GIF packet.
- *Culling*: set ADC on a vertex to drop the triangle it would complete
  (back-facing, or outside the guard band).

---

## 3. Transforms, projection and screen mapping

### 3.1 One matrix per vertex
The EE combines `P · V · M` into one 4 × 4 matrix. VU1 applies it with four
fused multiply-adds (MULA, MADDA, MADDA, MADD):

```
clip = MVP · (x, y, z, 1)          // clip = (cx, cy, cz, cw)
q    = 1 / cw                      // VU DIV unit
```

### 3.2 GS coordinate space
The GS draws in a 4096 × 4096 virtual space at **12.4 fixed point** (1/16 pixel
sub-precision). The visible framebuffer is placed in the middle of it with
`XYOFFSET`, usually at (2048, 2048):

```
sx = (cx * q) *  (W/2) + 2048        // W, H = framebuffer size, e.g. 640 × 448
sy = (cy * q) * -(H/2) + 2048
X  = int(sx * 16)                    // XYZ2.X, 12.4 fixed point
Y  = int(sy * 16)
XYOFFSET = ((2048 - W/2) << 4, (2048 - H/2) << 4)
```

### 3.3 Depth
The GS Z buffer is an integer (16, 24 or 32 bits). It is compared with
`ZTST = GEQUAL` or `GREATER`, so **a bigger Z means closer**. Games usually
write a value proportional to `1/w`:

```
Z = Zmax * (near * q)    →  Z = Zmax at the near plane, falls toward 0 far away
```

This is a *reversed* depth buffer, the same idea Godot 4.3+ uses for precision.

### 3.4 Guard-band clipping
The GS can rasterise anywhere in its 4096² space and `SCISSOR` trims to the
screen, so there is a guard band of about 2048 px around the view. VU1's
`CLIP` instruction tests `|x|, |y|, |z| ≤ |w|` and keeps a rolling 3-vertex flag
history (18 bits), so per triangle you get:

```
k = guard-band factor (e.g. 2.0; the clip test uses w * k)
all 3 vertices outside the same plane   → set ADC (cull)
all 3 inside the guard band             → draw as-is; SCISSOR trims to screen
straddles the guard band or near plane  → clip in VU1 (slow path) or cull
```

Proper clipping is rare. Most triangles take the fast path, which is why PS2
geometry was cut into small pieces.

### 3.5 Back-face culling
The GS doesn't cull, so VU1 does it with the 2-D cross product:

```
area = (x1 - x0)(y2 - y0) - (x2 - x0)(y1 - y0)
area < 0 (for the chosen winding) → set ADC on vertex 2
```

### 3.6 Perspective-correct texturing
Unlike the PS1, the PS2 is perspective-correct. VU1 sends `S = u*q`, `T = v*q`
and `Q = q`, and the GS divides per pixel. So **affine texture wobble is not
part of a PS2 look**; don't imitate it.

---

## 4. Lighting (per vertex, in VU1)

### 4.1 The standard "3 directional + ambient" model
This is the layout used in Sony's sample code, and very common. The EE
transforms each light's direction into **object space** (inverse model
rotation), so normals never need transforming. VU1 then does two 3 × 3 matrix
multiplies per vertex:

```
        ⎡ l0 ⎤                        (rows = unit vectors pointing TOWARD each light)
   L =  ⎢ l1 ⎥        d = max(L · n, 0)              // three N·L in one multiply
        ⎣ l2 ⎦
   C = [ c0 c1 c2 ]   (columns = light colours)
   lit = ambient + C · d                             // three diffuse terms + ambient
   rgb = vertex_colour * lit                         // optional baked prelight
```

No specular. There is no per-pixel normal, so shiny surfaces used an
environment map instead (§6.3).

### 4.2 Point lights
These are done on the EE, per object. For each object, take the N strongest
point lights and **turn each into a pseudo-directional light** at the object
centre:

```
dir  = normalize(light_pos - object_centre)
att  = clamp(1 - dist / radius, 0, 1)           // linear, the cheapest
     or 1 / (k0 + k1*dist + k2*dist²)            // classic, needs a window to reach 0
                                                 // gaze_client: x = d/r, 1 - smoothstep(flat, 1, x),
                                                 //   r = omni_range × point_range (ps2.gd); N·L
                                                 //   wrapped by point_wrap (half-Lambert at 1)
colour_for_this_object = light_colour * att
// gaze_client: light_colour is blended toward white (point_white) and scaled
// (point_gain) on the EE side before upload, like any game picking its colours.
```

That's why torchlight on a PS2 character is uniform across the whole body.
gaze_client uploads the 64 point lights nearest the camera whose range
reaches into the view, as a texel table (`ps2_point_tex`, `ps2_point_count`)
rather than per-object sets, and scenery
evaluates them per vertex, so a village of torch posts all glow at once.
Overlapping point lights take the brightest one, not the sum, so a cluster
of torches is no brighter than a single one.

### 4.3 Static scenery
Scenery is usually **prelit**. Lighting is baked into vertex colours offline
(ambient occlusion, coloured fill, torch pools) and the VU1 lighting step is
skipped. Lightmaps (a second texture pass with multiplicative blending) existed
but cost fill rate, so they were rarer.

---

## 5. Texture × vertex colour (the "overbright" look)

Every GS texture function treats **`0x80` (128) as 1.0**:

```
TFX = MODULATE :  out.rgb = clamp(tex.rgb * vc.rgb / 128, 0, 255)
                  out.a   = tex.a * vc.a / 128
TFX = DECAL    :  out = tex
TFX = HIGHLIGHT:  out.rgb = tex.rgb * vc.rgb / 128 + vc.a      // adds a flat glow
```

A vertex colour of 255 therefore means **×2**. Lighting can push a texture to
double brightness, and that is the warm, punchy PS2 look. In normalised terms:

```
out = clamp(tex * vc * 2, 0, 1)        // vc in 0..1
```

Alpha is also 0..128 = 0..1. An alpha of 255 in a PS2 texture means ≈ 2.0
when blending.

**Paletted textures.** These are 4-bit or 8-bit indices into a 16- or
256-entry palette (CLUT). With `CSM1`, the 8-bit palette is stored
swizzled: in each group of 32 entries, entries 8–15 and 16–23 swap places.

**Mip LOD** is chosen from `Q`, not from screen derivatives:

```
LOD = (log2(1 / Q) << L) + K        // L and K set per texture in TEX1
```

That gives a whole triangle's mip choice depth bias with no anisotropy. Mips
tend to look "sticky" or blurry on floors.

---

## 6. Blending, alpha test and effects

### 6.1 The single blend equation
```
out = ((A - B) * C >> 7) + D
      A, B, D ∈ { Cs (source), Cd (destination), 0 }
      C       ∈ { As, Ad, FIX }              // 0x80 = 1.0
```

| Effect              | A  | B  | C   | D  | Godot `render_mode`        |
|---------------------|----|----|-----|----|----------------------------|
| Normal alpha        | Cs | Cd | As  | Cd | `blend_mix`                |
| Additive            | Cs | 0  | As  | Cd | `blend_add`                |
| Subtractive         | Cd | Cs | FIX | 0  | `blend_sub` (dst − src)    |
| Constant-alpha fade | Cs | Cd | FIX | Cd | `blend_mix` + uniform alpha|

`COLCLAMP` picks saturating or wrapping arithmetic. Saturating is almost always
used.

### 6.2 Alpha test with `AFAIL`
`ATST` tests source alpha against `AREF`. The special part is the fail action:
`AFAIL = FB_ONLY` still **writes colour but not Z**. The usual two-pass trick
for hair, foliage and fences:

1. Pass 1: alpha test `≥ AREF`, Z write on. This draws the solid core.
2. Pass 2: alpha test `< AREF`, Z write off, alpha blend on. This draws the
   soft edges.

In Godot, use the depth pre-pass (`depth_prepass_alpha`) or
`alpha_scissor` + `alpha_antialiasing_mode`.

### 6.3 Environment / sphere mapping
Used for "metal" and "wet" surfaces, as a second pass with additive blending:

```
n_view = normalize(ViewRotation · n)
uv     = n_view.xy * 0.5 + 0.5
```

### 6.4 Fog (per vertex)
VU1 writes one 8-bit fog value per vertex. 255 means no fog and 0 means full fog:

```
F   = clamp((fog_far - depth) / (fog_far - fog_near), 0, 1) * 255
out = (F * colour + (255 - F) * FOGCOL) >> 8
```

F is Gouraud-interpolated, so fog is **linear across each triangle**. On big
triangles you see fog bands. That's another reason levels were finely
tessellated.

### 6.5 Framebuffer passes (there are no pixel shaders)
- **Bloom/glow:** draw the framebuffer as a texture into a ¼- or ⅛-size
  buffer (the bilinear filter does the blur), draw it back blurred a few
  times with small offsets, then add it to the frame (`Cs·FIX + Cd`).
- **Motion blur / afterimage:** draw last frame over this one with
  `C = FIX ≈ 0x40–0x60`.
- **Depth of field:** VRAM is untyped, so the Z buffer can be **read as a
  colour texture**. Use it as an alpha mask to blend a blurred copy over the
  sharp one.
- **Colour grading:** reinterpret one 8-bit channel as an 8-bit indexed
  texture, and a 256-entry CLUT becomes a lookup table.
- **Dither:** when writing to 16-bit (RGB5551) buffers, `DTHE` adds a 4 × 4
  matrix (values −4..+3) before truncating to 5 bits per channel.
- **Output:** 640 × 448 or 512 × 448, often interlaced (field rendering).
  The CRTC can mix two read circuits (`PMODE`) for a flicker filter, which
  also softens the image.

---

## 7. Skinning (VU1 matrix palette)

VU1 data memory is 16 KB, which is 1024 quadwords, and it is double-buffered
(`BASE`/`OFFSET`, `ITOP`/`XTOP`). One 4 × 4 matrix is 4 quadwords, so after
room for vertices and constants a batch holds **about 16–32 bones**.

```
mesh  →  split into batches, each batch uses ≤ N bones
EE per frame:  palette[i] = MVP · bone_world[i] · inverse_bind[i]
               (or keep the MVP separate and use bone_world · inverse_bind)
VU1 per vertex:
    p' = Σ_{i<k} w_i · palette[b_i] · p          // k = 1 or 2 is typical, rarely 4
    n' = Σ_{i<k} w_i · R(palette[b_i]) · n       // R = upper 3×3
```

Weights are usually 8-bit (`w / 255`, with the last weight `1 − Σ others`) or
implied (rigid: 1 bone per vertex, vertices grouped by bone so there is no
per-vertex index). Rigid with 2-bone blending only at the joints is the
classic compromise.

---

## 8. In gaze_client (`res://ps2/`)

Press **F9** in game to toggle. Turning it off restores every original material and setting.

| File | PS2 part | Sections |
|---|---|---|
| `ps2_common.gdshaderinc` | VU1 constants (global uniforms), 3 dir + ambient + up to 64 point lights (a texel table), 8-bit fog, ×2 MODULATE | §4, §5, §6.4 |
| `ps2_model.gdshaderinc` + `ps2_model*.gdshader` | Models: opaque / double-sided / blended variants, HIGHLIGHT add, sphere map | §5, §6.1–6.3 |
| `ps2_world.gdshader` | Terrain: prelit-style zone lighting (caves get no sun), two-sided vertex light | §4.3 |
| `ps2_water.gdshader` | Alpha-blended water | §6.1 |
| `ps2_particle.gdshaderinc` + `ps2_particle*.gdshader` | Particles as GS SPRITE primitives: screen-aligned and unrotatable, particle vertex colour, flat per-emitter light, vertex fog (additive sprites fog to black) | §5, §6.1, §6.4 |
| `ps2_texture.gd` | Paletted textures: shrink to 32 px, MSDF baked to a plain sprite, k-means 16-colour CLUT (PSMT4) with 8-bit palette entries | §5 |
| `ps2_post.gdshader` | DTHE 4×4 dither + 5-bit truncate, CRTC flicker filter | §6.5 |
| `ps2_mesh.gd` | Geometry path: VIF quantisation (s16 pos, s8 normal, fixed-point UV, u8 colour, 2 bones / 8-bit weights), stripify with ADC restarts, VU1 batches (restart pair, plus a degenerate triangle for odd parity), GS-style decode with no index buffer | §2, §7 |
| `ps2_common.gdshaderinc` `ps2_snap()` | GS 12.4 fixed-point vertex positions (1/16 px of the 448-line grid) | §3.2 |
| `ps2.gd` (autoload `Ps2`) | The EE side: per-frame light upload, light selection, material swap, 448-line render | §1, §4.2 |

How the engine pieces stand in:

- **448 lines:** `Viewport.scaling_3d_scale = 448 / window height`, bilinear upscale.
- **No tonemapper:** the Environment switches to Linear tonemap, exposure 1, while on.
- **Godot fog is disabled** on PS2 materials (`fog_disabled`). Fog is per vertex instead.
- **Shadows (a non-PS2 addition):** the sun's Godot shadow map is layered on top of the PS2 lighting. Each pixel finishes two PS2 colours, `shade` (no sun) and `lit` (with sun), and outputs `EMISSION = shade`, `ALBEDO = lit − shade`. A custom `light()` sets `DIFFUSE_LIGHT` to the sun's shadow factor, so Godot's `ALBEDO·DIFFUSE + EMISSION` becomes exactly `mix(shade, lit, shadow)`. In full sun it is identical to the pure PS2 result. `shadow_strength` in `ps2.gd` sets how strongly shadows apply (0 turns them off). Caves still drop the sun as a zone light, and any object can be darkened with `mi.set_instance_shader_parameter("ps2_sun_scale", 0.0)`. The PS2-authentic alternative would be blob or projected-texture shadows.
- **Skinning:** Godot skins before `vertex()`, so nothing extra is needed. For the PS2 budget, export with Blender's *Limit Total* = 2 bones per vertex.
- **Particles** (`GPUParticles3D`, `CPUParticles3D`) are converted too. Still not converted: `Sprite3D`, `Label3D`, and unshaded or billboard materials on regular meshes (the moon).

**Every mesh goes through the PS2 geometry path:** while PS2 mode is on, models, terrain chunks, walls, water and blend-shape meshes are all rebuilt by `ps2_mesh.gd` and swapped in, with the originals restored on F9. The work runs on `WorkerThreadPool`: the main thread only snapshots the arrays and builds the final mesh, within 2 ms per frame.

- **Models** quantise around their own centre with one scale per mesh. Imported meshes are converted once and shared between instances.
- **Terrain and water** quantise on a **world-aligned 1/64-unit grid** (s16 relative to each chunk, ±512 units), so neighbouring chunks round their shared border to the same points and never crack. This is the PS2 terrain approach: chunk-relative s16 coordinates on a common grid.
- **Large primitives** (water planes, waterfall boxes) are first cut into 4-unit cells. The GS clipped nothing, so big polygons had to be split to stay in the guard band, and per-vertex fog and lighting need the vertices.
- **Blend shapes** (morph targets) get the same quantisation and stream order as their base mesh.

With `log_mesh_stats` on, each rebuild prints a line like `684 tris → 342 strips (avg 2.0 tris), 1368 stream verts (2.00/tri), 19 VU1 batches, 22.3 KB VIF`. Stream verts per triangle is the number PS2 developers optimised: 1.0 is the ideal (one long strip; terrain grids reach about 1.09) and 3.0 is plain triangles. Most of the visible difference comes from the 2-bone skinning limit and the 8-bit normals. Position and UV precision loss is below a pixel by design.

Tuning values (gains, fog distances and colours, resolution, dither, flicker) are the variables at the top of `ps2.gd`.

## 9. Porting to gaze_curse (the engine)

Each piece above has a natural home in the Forward+ renderer (`servers/rendering/renderer_rd/`):

1. **Light set → one uniform buffer.** Replace the 16 global uniforms with a `PS2LightSet` UBO that `RenderForwardClustered` fills once per frame, the same way it fills the scene data UBO.
2. **Light selection → C++ per instance.** Move "pick the N strongest point lights for this object" from `ps2.gd` into the instance setup, so each object gets its own set, which is exactly what the EE did.
3. **Shaders → a built-in `ps2` shading mode.** Add a render mode (for example `render_mode ps2;`) to the scene shader template that swaps the per-pixel light loop for the `ps2_light()` vertex path, so no material swap is needed.
4. **Dither and flicker → a post step.** Add them to the tonemap/output pass, or as a `CompositorEffect` first.
5. **Material swap → importer default.** Once the mode exists, `ps2.gd`'s conversion becomes an import option instead of runtime work.

Prototype each step here in GDScript and `.gdshader` first, where there's no compile wait, and port it once it looks right.
