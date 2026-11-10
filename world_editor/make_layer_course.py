# Rebuilds the rat-hill cave chunk of village.bin (x 64..128, z 0..64) as a
# terrain-layer course: one hall under the hill plus a station for each way the
# h1 / h2 / h3 sheets can meet. Only this chunk's interior
# vertices are rewritten (its border stays stitched to its neighbours);
# everything else in the file is copied through.
#
#   A  main mouth, through the east gate (z 30..34): an open ramp (no h2) whose
#      floor h3 starts at the plaza and runs down to the hall, with h1 tucked
#      under it (h3 > h1). North bank: a slope too steep to stand on (slides).
#      South side: a cliff. A hole strip (x 84) parts the ramp from the hall's
#      roof — h1 must not rise straight from under h3 to a roof, or it would
#      read as crossing up through the floor.
#   B  hole entrance (z 46..50): h1 and h2 open over a ramp whose top sits
#      0.2 under the surface — stepped up onto on the way out.
#   C  pit: a hole through the roof (h1 and h2) into the hall at (96, 14).
#   D  dome (x 106..118, z 40..52): the hall ceiling rises to 0.1 under the
#      surface — thin rock (h1 just above h2).
#   E  big hole (x 93..108, z 22..32): h1 and h2 open over the hall, except a
#      platform of h2 at -3.5 (x 100..106, z 24..30) — walked on from above,
#      fallen onto from the hill, a ceiling to the floor under it — and an h2
#      ramp rising out of the floor to it from the west (h2 crossing up
#      through h3).
#   F  raised slabs on the hill (x 73..77): h2 a step above h1 (z 12..16, walked
#      up onto), a jump (0.8) above it (z 22..25) and a wall's height above it
#      (z 18..20, blocks); and a pit (z 4..8): a hole in h1 over h2 a jump
#      below it.
#   G  floor hole: h3 open at (116, 14) — nothing to stand on.
#   H  low passage (x 86..92, z 54..60): ceiling 1.5 over the floor.
#
# Usage: python3 make_layer_course.py [village.bin]  (rewrites it in place)
import math
import sys

import gwl

NAN = float('nan')
CX, CZ = 2, 1                 # the rat-hill chunk in the 3x3 grid
X0, Z0 = 64.0, 0.0            # its world origin

HALL = (84.5, 124.0, 4.0, 60.0)
FLOOR, CEIL = -6.0, -1.5
ROCK = 0.3                    # solid rock: h2 = h3 this far under h1

RAMP_A = (68.0, 84.0, 30.0, 34.0)       # x0, x1 (hole strip at x1), z0, z1
BANK = 1.4                              # north bank slope
RAMP_B = (70.0, 84.0, 46.0, 50.0)       # lip vertex at x0, hole from x0 + 0.5
LIP = 0.2
PIT, PIT_R = (96.0, 14.0), 1.25
DOME = (106.0, 118.0, 40.0, 52.0)
BIG_HOLE = (93.0, 108.0, 22.0, 32.0)
PLAT, PLAT_Y = (100.0, 106.0, 24.0, 30.0), -3.5
PLAT_RAMP = (94.0, 100.0, 26.0, 28.0)   # h2 from FLOOR - 0.5 up to PLAT_Y
SLAB_STEP, SLAB_WALL = (73.0, 77.0, 12.0, 16.0), (73.0, 77.0, 18.0, 20.0)
SLAB_JUMP, SLAB_PIT = (73.0, 77.0, 22.0, 25.0), (73.0, 77.0, 4.0, 8.0)
FLOOR_HOLE, FLOOR_HOLE_R = (116.0, 14.0), 1.0
LOW = (86.0, 92.0, 54.0, 60.0)
LOW_CEIL = FLOOR + 1.5
OLD_MOUTH = (66.0, 90.0, 26.0, 38.0)    # the dug funnel this replaces


def hill(x, z):
    """make_village.py's rat hill."""
    if x <= 70: return 0.0
    f = min(1.0, (x - 70) / 8)
    return f * (2.8 * math.exp(-((x - 106) ** 2 + (z - 30) ** 2) / (2 * 13 ** 2)) + 0.4 * math.sin(x * 0.3) * math.cos(z * 0.25) + 0.4)


def inside(box, x, z, pad=0.0):
    x0, x1, z0, z1 = box
    return x0 - pad <= x <= x1 + pad and z0 - pad <= z <= z1 + pad


def ramp_a(x):
    x0, x1, _, _ = RAMP_A
    return FLOOR * (x - x0) / (x1 - x0)


def vertex(x, z, s):
    """-> (h1, h2, h3) at a vertex whose surface is s."""
    if inside(RAMP_A, x, z):
        if x == RAMP_A[1]: return NAN, NAN, FLOOR
        # h1 meets h3 at the top and dives under it from there, so the swap
        # onto h3 comes right at the top instead of after a steep h1 dip.
        y = ramp_a(x)
        return (y if x == RAMP_A[0] else y - 1.0), NAN, y
    if inside(SLAB_STEP, x, z): return s, s + 0.2, s - ROCK
    if inside(SLAB_WALL, x, z): return s, s + 1.0, s - ROCK
    if inside(SLAB_JUMP, x, z): return s, s + 0.8, s - ROCK
    if inside(SLAB_PIT, x, z): return NAN, s - 0.6, s - 0.9
    if inside(SLAB_STEP, x, z, 0.5) or inside(SLAB_WALL, x, z, 0.5) or inside(SLAB_JUMP, x, z, 0.5):
        return s, s - 0.05, s - ROCK  # h2 just under h1: the slab's edge is a step, not a slope
    if RAMP_A[0] <= x < RAMP_A[1] and z < RAMP_A[2]:
        s = min(s, ramp_a(x) + BANK * (RAMP_A[2] - z))
        return s, s - ROCK, s - ROCK
    bx0, bx1, _, _ = RAMP_B
    if inside(RAMP_B, x, z):
        top = s - LIP
        if x == bx0: return s, top, top
        return NAN, NAN, top + (FLOOR - top) * (x - bx0) / (bx1 - bx0)
    if inside(BIG_HOLE, x, z):
        if inside(PLAT, x, z): return NAN, PLAT_Y, FLOOR
        if inside(PLAT_RAMP, x, z):
            x0, x1, _, _ = PLAT_RAMP
            return NAN, FLOOR - 0.5 + (PLAT_Y - FLOOR + 0.5) * (x - x0) / (x1 - x0), FLOOR
        return NAN, NAN, FLOOR
    if not inside(HALL, x, z): return s, s - ROCK, s - ROCK
    h1, h2, h3 = s, CEIL, FLOOR
    if math.dist((x, z), PIT) <= PIT_R: h1 = h2 = NAN
    if math.dist((x, z), FLOOR_HOLE) <= FLOOR_HOLE_R: h3 = NAN
    if inside(DOME, x, z):
        x0, x1, z0, z1 = DOME
        t = min(1.0, min(x - x0, x1 - x, z - z0, z1 - z) / 2.0)
        h2 = CEIL + t * (s - 0.1 - CEIL)
    if inside(LOW, x, z): h2 = LOW_CEIL
    return h1, h2, h3


path = sys.argv[1] if len(sys.argv) > 1 else 'village.bin'
W = gwl.load(path)
cc, cs = W['cc'], W['cs']
S = cc + 1
chunk = W['chunks'][CZ * W['cx'] + CX]
assert chunk['type'] == 2, 'expected the rat-hill cave chunk'
h1, h2, h3 = list(chunk['h1']), list(chunk['h2']), list(chunk['h3'])
for gz in range(1, cc):
    for gx in range(1, cc):
        i = gz * S + gx
        x, z = X0 + gx * cs, Z0 + gz * cs
        # The surface as sculpted, except where a station (or the old funnel)
        # rewrites h1 — there the hill itself, so a rerun gives the same file.
        rewritten = inside(OLD_MOUTH, x, z) or inside(RAMP_B, x, z, 0.5) or math.dist((x, z), PIT) <= PIT_R + 0.5 \
            or inside(BIG_HOLE, x, z)
        s = hill(x, z) if rewritten or math.isnan(h1[i]) else h1[i]
        h1[i], h2[i], h3[i] = vertex(x, z, s)
chunk['h1'], chunk['h2'], chunk['h3'] = h1, h2, h3
gwl.save(W, path)
print('wrote', path)
