#!/usr/bin/env python3
# Generates the wood wall texture: horizontal weathered planks, tiling
# seamlessly (every noise term repeats across the image, and the plank rows
# and butt joints divide it exactly). Writes the PNG to the paths given.
#   make_wood_texture.py [paths...]            "Wood": brown boards with growth
#                                              rings, knots, nails, checks and
#                                              bevelled seams (wood_wall.png)
# Walls tile the texture every 2 m (WorldShaders tile_scale), so 8 rows make
# boards 25 cm tall.
import sys
import numpy as np
from PIL import Image

SIZE = 1024
ROWS = 8                       # planks per tile, top to bottom
PX = SIZE / 512                # feature sizes below are in 512-texture pixels
rng = np.random.default_rng(11)


def periodic_noise(px, py, size=SIZE):
    """Smooth value noise with px cells across and py cells down, wrapping at the edges."""
    grid = rng.random((py, px))
    def axis(period):
        t = np.arange(size) * period / size
        i0 = np.floor(t).astype(int)
        f = t - i0
        return i0, (i0 + 1) % period, f * f * (3 - 2 * f)    # smoothstep
    y0, y1, fy = axis(py)
    x0, x1, fx = axis(px)
    fy, fx = fy[:, None], fx[None, :]
    a = grid[np.ix_(y0, x0)]; b = grid[np.ix_(y0, x1)]
    c = grid[np.ix_(y1, x0)]; d = grid[np.ix_(y1, x1)]
    return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy


def fbm(px, py, octaves):
    total, amp, norm = 0.0, 1.0, 0.0
    for o in range(octaves):
        total = total + amp * periodic_noise(px * 2 ** o, py * 2 ** o)
        norm += amp
        amp *= 0.5
    return total / norm


def fbm_1d(period, octaves):
    """fbm along x only (one row), wrapping across the image."""
    return fbm(period, 1, octaves)[0]


def wrapped(d):
    """Signed offset folded into -SIZE/2..SIZE/2, so shapes reappear across the seam."""
    return (d + SIZE / 2) % SIZE - SIZE / 2


def smoothstep(a, b, v):
    t = np.clip((v - a) / (b - a), 0.0, 1.0)
    return t * t * (3 - 2 * t)


paths = sys.argv[1:] or ['wood_wall.png']

y, x = np.mgrid[0:SIZE, 0:SIZE].astype(float)
xi = x.astype(int)
row_h = SIZE / ROWS
row = (y // row_h).astype(int)
in_row = (y % row_h) / row_h                       # 0 at a board's top edge, 1 at its bottom

# Butt joints: one or two per row at random spots, so boards have uneven lengths.
joint_d = np.full((SIZE, SIZE), float(SIZE))        # distance to the nearest joint in the row
board = np.zeros((SIZE, SIZE), dtype=int)          # an id per board
all_cuts = []
for r in range(ROWS):
    while True:                                    # no board shorter than ~40 cm
        cuts = np.sort(rng.integers(0, SIZE, rng.integers(1, 3)))
        gaps = np.diff(np.append(cuts, cuts[0] + SIZE))
        if gaps.min() >= 100 * PX: break
    all_cuts.append(cuts)
    rows = row == r
    xs = x[rows]
    joint_d[rows] = np.min([np.abs(wrapped(xs - c)) for c in cuts], axis=0)
    board[rows] = r * 4 + np.searchsorted(cuts, xs) % len(cuts)
NB = ROWS * 4

# Knots: a dark core with a darker rim; the growth rings bulge round them.
knot_core = np.zeros((SIZE, SIZE))
knot_bulge = np.zeros((SIZE, SIZE))
for _ in range(9):
    kx, ky = rng.uniform(0, SIZE), (rng.integers(0, ROWS) + rng.uniform(0.3, 0.7)) * row_h
    rx, ry = rng.uniform(5, 10) * PX, rng.uniform(3.5, 6) * PX
    d = np.sqrt((wrapped(x - kx) / rx) ** 2 + (wrapped(y - ky) / ry) ** 2)
    same = row == int(ky // row_h)                 # a knot stays inside its board
    knot_core = np.maximum(knot_core, same * (smoothstep(1.1, 0.6, d) * 0.7 + smoothstep(0.25, 0.0, np.abs(d - 0.9)) * 0.5))
    knot_bulge += same * 1.6 * np.exp(-(d / 2.8) ** 2)

# Growth rings: each board is a slice through a log, so its rings are contours
# of (height in the board) bent by a slow wave along it — cathedral arches
# where the wave peaks. Earlywood light, darkening to a crisp latewood line.
field = np.zeros((SIZE, SIZE))
density = np.zeros((SIZE, SIZE))                   # rings per unit of field: tighter on some boards
for k in range(NB):
    m = board == k
    if not m.any(): continue
    bend = fbm_1d(3, 4) - 0.5
    centre, depth = rng.uniform(0.2, 0.8), rng.uniform(1.5, 3.5)
    field[m] = (np.abs(in_row[m] - centre) * depth + bend[xi[m]] * rng.uniform(2.0, 4.0)
                + rng.uniform(0, 10))
    density[m] = rng.uniform(3.0, 5.5)
field += knot_bulge
field += 0.25 * (fbm(4, 16, 3) - 0.5) + 0.05 * (fbm(8, 64, 3) - 0.5)   # uneven seasons, wobbly lines
rings_f = (field * density) % 1.0
strength = 0.55 + 0.9 * fbm(6, 24, 2)               # some rings crisp, some barely there
rings = (rings_f ** 3 * 0.5 + smoothstep(0.90, 0.97, rings_f) * smoothstep(1.0, 0.97, rings_f) * 0.3) * strength
pores = fbm(6, 192, 2)                             # tight streaks along the boards

# Checks: a few thin splits running in from a board end, following the grain.
checks = np.zeros((SIZE, SIZE))
for r in range(ROWS):
    for c in all_cuts[r]:
        if rng.random() < 0.55: continue
        side = rng.choice((-1, 1))
        cy = (r + rng.uniform(0.3, 0.7)) * row_h
        length = rng.uniform(25, 70) * PX
        along = wrapped(x - c) * side              # distance into the board from the cut
        wave = 2.0 * PX * np.sin(along / (11 * PX) + rng.uniform(0, 6))
        width = 0.9 * PX * (1.0 - np.clip(along / length, 0.0, 1.0))   # tapers to nothing
        on = (along > 0) & (along < length) & (row == r)
        checks = np.maximum(checks, on * smoothstep(width + 0.8 * PX, width * 0.3, np.abs(y - cy - wave)))

# Nails: a pair through each board end, each with a little rust run below.
nails = np.zeros((SIZE, SIZE))
rust = np.zeros((SIZE, SIZE))
for r in range(ROWS):
    for c in all_cuts[r]:
        for side in (-1, 1):
            nx = c + side * rng.uniform(7, 10) * PX
            for fy in (0.3, 0.7):
                ny = (r + fy + rng.uniform(-0.04, 0.04)) * row_h
                dx, dy = wrapped(x - nx), wrapped(y - ny)
                d = np.hypot(dx, dy)
                nails = np.maximum(nails, smoothstep(2.4 * PX, 1.4 * PX, d))
                run = np.exp(-(dx / (2.2 * PX)) ** 2) * np.clip(1.0 - dy / (16 * PX), 0.0, 1.0) * (dy > 0)
                rust = np.maximum(rust, np.exp(-(d / (4 * PX)) ** 2) * 0.6 + run * 0.5 * rng.uniform(0.4, 1.0))

# Edges: a dark gap between rows, the board's top edge catching the light and
# its bottom edge in the shadow of its own thickness; joints likewise.
ey = in_row * row_h / PX                           # px from the board's top
eb = (1.0 - in_row) * row_h / PX                   # px from its bottom
gap = smoothstep(1.6, 0.4, np.minimum(ey, eb)) + smoothstep(1.4, 0.3, joint_d / PX)
bevel = 0.10 * smoothstep(4.0, 1.0, ey) - 0.16 * smoothstep(5.0, 1.0, eb) - 0.10 * smoothstep(4.0, 0.8, joint_d / PX)
shade = 0.05 * (0.5 - in_row)                      # a slight cup: lighter above, darker below

# Weathering: broad bleaching, plus more of it near the ends and edges where
# rain sits; per-board tone and hue.
weather = fbm(3, 6, 4)
edge_wear = np.clip(1.0 - np.minimum(np.minimum(ey, eb), joint_d / PX) / 14.0, 0.0, 1.0)
grey = np.clip((weather - 0.45) * 1.4 + 0.35 * edge_wear * (fbm(16, 32, 2) > 0.45), 0.0, 1.0) * 0.55
tone = rng.uniform(-0.07, 0.07, NB)[board]
hue = rng.uniform(-1.0, 1.0, NB)[board]            # redder or yellower boards

lum = (0.48 + tone + 0.07 * (weather - 0.5) + shade + bevel
       - 0.16 * rings - 0.10 * (pores - 0.5) * 2.0
       - 0.18 * knot_core - 0.30 * checks - 0.45 * gap - 0.18 * nails)
lum = np.clip(lum, 0.03, 1.0)
# Warm brown, drifting to silver-grey where weathered; knots and rust reddish.
base = np.stack([0.74 + 0.03 * hue, 0.53 + 0.01 * hue, 0.36 - 0.03 * hue], axis=-1)
silver = np.array([0.66, 0.62, 0.58])
col = base * (1 - grey[..., None]) + silver * grey[..., None]
img = lum[..., None] * col
rust_col = np.array([0.42, 0.22, 0.10])
rust_a = np.clip(rust * (1.0 - nails), 0.0, 1.0)[..., None] * 0.3
img = img * (1 - rust_a) + rust_col * lum[..., None] * 1.3 * rust_a
img = (np.clip(img, 0.0, 1.0) * 255.0 + 0.5).astype(np.uint8)

for path in paths:
    Image.fromarray(img, 'RGB').save(path)
    print(path)
print('luminance min %.3f  mean %.3f  max %.3f' % (lum.min(), lum.mean(), lum.max()))
