#!/usr/bin/env python3
# Generates the marble wall textures, tiling seamlessly (every noise term
# repeats across the image). Writes the PNG to the paths given.
#   make_marble_texture.py [paths...]          "Marble": white, soft light-grey
#                                              veins, gentle shading (marble_wall.png)
#   make_marble_texture.py --black [paths...]  "Black Marble": dark grey, crisp
#                                              near-black veins, an even, polished body
#                                              (black_marble_wall.png)
import sys
import numpy as np
from PIL import Image

SIZE = 512
rng = np.random.default_rng(7)


def periodic_noise(period, size=SIZE):
    """Smooth value noise with `period` cells across the image, wrapping at the edges."""
    grid = rng.random((period, period))
    t = np.arange(size) * period / size
    i0 = np.floor(t).astype(int)
    f = t - i0
    f = f * f * (3 - 2 * f)                      # smoothstep
    i1 = (i0 + 1) % period
    a = grid[np.ix_(i0, i0)]; b = grid[np.ix_(i0, i1)]
    c = grid[np.ix_(i1, i0)]; d = grid[np.ix_(i1, i1)]
    fy, fx = f[:, None], f[None, :]
    return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy


def fbm(base, octaves):
    total, amp, norm = 0.0, 1.0, 0.0
    for o in range(octaves):
        total = total + amp * periodic_noise(base * 2 ** o)
        norm += amp
        amp *= 0.5
    return total / norm


BLACK = '--black' in sys.argv
paths = [a for a in sys.argv[1:] if a != '--black'] or ['black_marble_wall.png' if BLACK else 'marble_wall.png']

v, u = np.mgrid[0:SIZE, 0:SIZE] / SIZE
turb = fbm(4, 6)
# Veins: a sine along a diagonal (whole periods across the tile, so it wraps),
# bent by turbulence; sharpened so they read as thin lines, not stripes.
vein = np.abs(np.sin(2 * np.pi * (2 * u + 1 * v) + 9.0 * turb))
vein_fine_raw = np.abs(np.sin(2 * np.pi * (3 * u - 2 * v) + 14.0 * fbm(8, 5)))
cloud = fbm(3, 5)                                 # broad, soft shading

if BLACK:
    # Veins as crisp lines with a hard edge (a clipped ramp, no soft halo);
    # the body gets far less cloud and only faint secondary veins, so it
    # reads clean and polished.
    vein = np.clip(1.0 - vein / 0.06, 0.0, 1.0) ** 0.6
    fine = np.clip(1.0 - vein_fine_raw / 0.04, 0.0, 1.0)
    lum = 0.13 + 0.01 * (cloud - 0.5) - 0.10 * vein - 0.025 * fine   # veins darker than the body
    lum = np.clip(lum, 0.0, 1.0)
    # Neutral grey body, veins a touch cool.
    r = lum - 0.004 * vein
    g = lum
    b = lum + 0.006 + 0.01 * vein
else:
    vein = 1.0 - vein ** 0.35                     # 1 on the vein, 0 between
    fine = 1.0 - vein_fine_raw ** 0.18
    lum = 0.955 + 0.04 * (cloud - 0.5) - 0.13 * vein - 0.05 * fine
    lum = np.clip(lum, 0.0, 1.0)
    # Veins lean a touch cool (blue-grey), the body a touch warm: "shades of white".
    r = lum + 0.006 - 0.012 * vein
    g = lum + 0.002 - 0.004 * vein
    b = lum - 0.004 + 0.012 * vein
img = np.stack([r, g, b], axis=-1)
img = (np.clip(img, 0.0, 1.0) * 255.0 + 0.5).astype(np.uint8)

for path in paths:
    Image.fromarray(img, 'RGB').save(path)
    print(path)
print('luminance min %.3f  mean %.3f  max %.3f' % (lum.min(), lum.mean(), lum.max()))
