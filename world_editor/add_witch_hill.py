#!/usr/bin/env python3
# Patches the Witch's hill into an existing village.bin (the editor has taken
# village.bin past make_village.py's output, so this adds to it in place
# instead of regenerating): a rocky plateau west of the goblin camp, cobbled on
# top, a ramp up its east face, a fire pit, a cauldron, and a witch hut with a
# crooked stepped roof at its north end. Also paints its cells (village.cells.bin)
# and points the Witch spawn (village.spawns.json) at the hut.
#   add_witch_hill.py [village.bin]
# Refuses to run twice on the same file (the plateau is already there).
import json, math, os, random, struct, sys
import gwl

path = sys.argv[1] if len(sys.argv) > 1 else 'village.bin'
cells_path = os.path.splitext(path)[0] + '.cells.bin'
spawns_path = os.path.splitext(path)[0] + '.spawns.json'
W = gwl.load(path)
CC, CS = W['cc'], W['cs']
STRIDE = CC + 1
SPAN = CC * CS
STONE, CAVE_ROCK, MARBLE_BLACK, WOOD, STONE_WALL = 0, 1, 6, 7, 8   # wall_types.json (2 is the Ladder)
POST_T, SCONCE_T = W['ptypes'].index('res://assets/props/TorchPost.tscn'), W['ptypes'].index('res://assets/props/TorchSconce.tscn')
BUSH_T = W['ptypes'].index('res://assets/props/bush.glb')
TREE_O, ROCK_O = 0, 1
rng = random.Random(7)

# ── layout ──────────────────────────────────────────────────────────────────────
# The plateau: a rounded square around (CX, CZ), in the world's south-west
# corner, well clear of the town and the goblin camp. Flat at TOP, its edge
# wobbling by up to ~0.9 m, then a near-sheer drop over CLIFF metres — too
# tall and steep to jump up, so the ramp is the only way on. The ramp hugs the
# east cliff, from the plain at RAMP_FOOT_Z (north) up to the top at RAMP_TOP_Z.
CX, CZ, HALF, CORNER = -44.0, 110.0, 13.0, 5.0
TOP, CLIFF = 5.0, 0.8
RAMP_X0, RAMP_X1 = CX + 11.0, CX + 17.5
RAMP_FOOT_Z, RAMP_TOP_Z = CZ - 14.0, CZ + 4.0
HUT_X0, HUT_X1, HUT_Z0, HUT_Z1 = CX - 3.5, CX + 3.5, CZ - 10.0, CZ - 4.5   # north end, door facing south
GRAVEL = (CX - 1.0, CX + 7.0, CZ - 2.0, CZ + 6.0)                          # the square in the middle
FIRE_X, FIRE_Z = CX - 8.0, CZ + 4.0

def edge_dist(x, z):
    """Signed distance to the plateau's (wobbly) edge: < 0 on top."""
    qx, qz = abs(x - CX) - (HALF - CORNER), abs(z - CZ) - (HALF - CORNER)
    d = math.hypot(max(qx, 0.0), max(qz, 0.0)) + min(max(qx, qz), 0.0) - CORNER
    a = math.atan2(z - CZ, x - CX)
    return d - 0.5 * math.sin(5 * a) - 0.4 * math.sin(9 * a + 1.3)

def plateau(x, z):
    d = edge_dist(x, z)
    if d <= 0: return TOP
    if d >= CLIFF: return 0.0
    f = 1.0 - d / CLIFF
    # rough rock: a little bumpy, never above the top or below the plain
    return max(0.0, min(TOP, TOP * f + 0.35 * math.sin(x * 2.1) * math.cos(z * 1.7) * f * (1 - f) * 4))

def ramp(x, z):
    if not (RAMP_FOOT_Z - 1.0 <= z <= RAMP_TOP_Z + 4.0): return 0.0
    out = max(RAMP_X0 - x, x - RAMP_X1, 0.0)        # metres beside the corridor
    if out >= 0.8: return 0.0
    h = TOP * min(1.0, max(0.0, (z - RAMP_FOOT_Z) / (RAMP_TOP_Z - RAMP_FOOT_Z)))
    return h * (1.0 - out / 0.8)

def height(x, z):
    return max(plateau(x, z), ramp(x, z))

def on_ramp(x, z):
    return RAMP_X0 - 1 <= x <= RAMP_X1 + 1.5 and RAMP_FOOT_Z - 2 <= z <= RAMP_TOP_Z + 5

# ── terrain ─────────────────────────────────────────────────────────────────────
ci, cj = int((CX // SPAN)) - W['ox'], int((CZ // SPAN)) - W['oz']
chunk = W['chunks'][cj * W['cx'] + ci]
assert chunk['type'] == 1, chunk['type']
cx0, cz0 = (W['ox'] + ci) * SPAN, (W['oz'] + cj) * SPAN
k = int((CZ - cz0) / CS) * STRIDE + int((CX - cx0) / CS)
if chunk['h1'][k] != 0.0:
    sys.exit(f'{path}: the witch hill is already there (height {chunk["h1"][k]} at its centre)')
for vz in range(STRIDE):
    for vx in range(STRIDE):
        h = height(cx0 + vx * CS, cz0 + vz * CS)
        if h > 0: chunk['h1'][vz * STRIDE + vx] = h

def ground(x, z):
    """Terrain height as the client and server sample it (anti-diagonal split)."""
    i, j = int(x // SPAN) - W['ox'], int(z // SPAN) - W['oz']
    lx, lz = (x - (W['ox'] + i) * SPAN) / CS, (z - (W['oz'] + j) * SPAN) / CS
    gx, gz = min(int(lx), CC - 1), min(int(lz), CC - 1)
    rx, rz = lx - gx, lz - gz
    h = W['chunks'][j * W['cx'] + i]['h1']
    h00, h10 = h[gz * STRIDE + gx], h[gz * STRIDE + gx + 1]
    h01, h11 = h[(gz + 1) * STRIDE + gx], h[(gz + 1) * STRIDE + gx + 1]
    if rx + rz < 1: return h00 + (h10 - h00) * rx + (h01 - h00) * rz
    return h11 + (h01 - h11) * (1 - rx) + (h10 - h11) * (1 - rz)

# ── walls (absolute heights, made ground-relative at the end) ───────────────────
walls = []
def rbox(x, z, hx, hz, ry, y0, y1, t, op=()):
    walls.append(dict(type=t, x=x, z=z, hx=hx, hz=hz, ry=ry, h=y1 - y0, yo=y0, op=list(op)))
def box(x0, x1, z0, z1, y0, y1, t, holes=()):
    """Axis-aligned box; holes are absolute (x0, x1, y0, y1, z0, z1) openings."""
    cx, cz = (x0 + x1) / 2, (z0 + z1) / 2
    rbox(cx, cz, (x1 - x0) / 2, (z1 - z0) / 2, 0.0, y0, y1, t,
         [(a - cx, b - cx, c - y0, d - y0, e - cz, f - cz) for a, b, c, d, e, f in holes])
def wall(axis, at, a0, a1, y0, y1, holes=(), th=0.3, t=WOOD):
    """Wall along x (at = z) or z (at = x); holes are (b0, b1, hy0, hy1) along it."""
    if axis == 'x':
        box(a0, a1, at - th / 2, at + th / 2, y0, y1, t, [(b0, b1, h0, h1, at - th, at + th) for b0, b1, h0, h1 in holes])
    else:
        box(at - th / 2, at + th / 2, a0, a1, y0, y1, t, [(at - th, at + th, h0, h1, b0, b1) for b0, b1, h0, h1 in holes])

# the hut: wood walls on a wood floor, door south, a window east and west
T, WH = TOP, 3.2
mx, mz = (HUT_X0 + HUT_X1) / 2, (HUT_Z0 + HUT_Z1) / 2
box(HUT_X0, HUT_X1, HUT_Z0, HUT_Z1, T, T + 0.12, WOOD)
wall('x', HUT_Z0, HUT_X0, HUT_X1, T, T + WH)
wall('x', HUT_Z1, HUT_X0, HUT_X1, T, T + WH, [(mx - 0.7, mx + 0.7, 0.0 + T, 2.2 + T)])
wall('z', HUT_X0, HUT_Z0, HUT_Z1, T, T + WH, [(mz - 0.4, mz + 0.4, 1.2 + T, 2.0 + T)])
wall('z', HUT_X1, HUT_Z0, HUT_Z1, T, T + WH, [(mz - 0.4, mz + 0.4, 1.2 + T, 2.0 + T)])
# the roof: a flat black slab with an overhang
rbox(mx, mz, (HUT_X1 - HUT_X0) / 2 + 0.6, (HUT_Z1 - HUT_Z0) / 2 + 0.6, 0.0, T + WH, T + WH + 0.3, MARBLE_BLACK)
# a stone chimney through the west side of the roof
box(HUT_X0 + 0.3, HUT_X0 + 1.1, HUT_Z0 + 0.8, HUT_Z0 + 1.6, T, T + WH + 2.0, STONE_WALL)

# a cauldron by the door: a black pot, hollow on top, on three stone feet
KX, KZ = HUT_X0 - 1.0, HUT_Z1 + 2.2
for a in (0.0, 2.1, 4.2):
    fx, fz = KX + 0.45 * math.cos(a), KZ + 0.45 * math.sin(a)
    box(fx - 0.1, fx + 0.1, fz - 0.1, fz + 0.1, T, T + 0.25, STONE)
box(KX - 0.6, KX + 0.6, KZ - 0.6, KZ + 0.6, T + 0.25, T + 1.05, MARBLE_BLACK,
    [(KX - 0.45, KX + 0.45, T + 0.45, T + 1.2, KZ - 0.45, KZ + 0.45)])

# the fire pit: a ring of stones and two log seats
for i in range(9):
    a = i * 2 * math.pi / 9
    rbox(FIRE_X + 1.0 * math.cos(a), FIRE_Z + 1.0 * math.sin(a), 0.2, 0.16, a, T, T + 0.28, STONE)
rbox(FIRE_X, FIRE_Z - 2.3, 0.9, 0.22, 0.15, T, T + 0.4, WOOD)
rbox(FIRE_X + 2.2, FIRE_Z + 0.4, 0.9, 0.22, 1.75, T, T + 0.4, WOOD)

# rock outcrops standing out of the cliff (not by the ramp)
for a, w_, d_ in [(2.6, 1.6, 1.1), (3.4, 1.2, 1.4), (4.3, 1.8, 1.0), (5.2, 1.3, 1.2), (1.9, 1.5, 1.0), (0.9, 1.2, 1.3)]:
    r = 0.0
    while edge_dist(CX + r * math.cos(a), CZ + r * math.sin(a)) < 1.2: r += 0.1
    ox, oz = CX + r * math.cos(a), CZ + r * math.sin(a)
    if on_ramp(ox, oz): continue
    rbox(ox, oz, w_, d_, a + 0.4, -0.5, TOP + 0.7, CAVE_ROCK)

for w in walls:
    w['yo'] -= ground(w['x'], w['z'])
W['walls'] += walls

# ── objects: boulders round the foot and the rim, trees on the plain ────────────
# The foot's boulders keep a couple of metres off the cliff, so none of them
# is a step up it.
def at_edge(a, d):
    r = 0.0
    while edge_dist(CX + r * math.cos(a), CZ + r * math.sin(a)) < d: r += 0.1
    return CX + r * math.cos(a), CZ + r * math.sin(a)
objs = []
for i in range(34):                              # round the foot of the cliff
    r = rng.uniform(0.8, 1.4)
    x, z = at_edge(i * 2 * math.pi / 34 + rng.uniform(-0.05, 0.05), CLIFF + r + 1.5 + rng.uniform(0, 1.5))
    if on_ramp(x, z): continue
    objs.append(dict(type=ROCK_O, x=x, z=z, radius=r, height=r * 1.2))
for i in range(16):                              # the rim, smaller
    x, z = at_edge(i * 2 * math.pi / 16 + 0.2, -0.7)
    if on_ramp(x, z) or (HUT_X0 - 2 < x < HUT_X1 + 2 and z < HUT_Z1 + 1): continue
    r = rng.uniform(0.5, 0.9)
    objs.append(dict(type=ROCK_O, x=x, z=z, radius=r, height=r * 1.2))
for x, z in [(-60, 97), (-61, 112), (-56, 126), (-40, 127), (-26, 125), (-22, 106), (-24, 89), (-48, 88), (-60, 86)]:
    s = rng.uniform(1.1, 1.4)                    # the model scales with the radius
    objs.append(dict(type=TREE_O, x=x, z=z, radius=s, height=2.5 * s))
W['objs'] += objs

# ── props: the fire, torches, bushes ────────────────────────────────────────────
props = []
# TorchPost at scale 0.5 has its head ~2.65 m up and its flame ~2.8 m: sunk
# into the pit so only the flame shows
for dx, dz, ry in [(0.15, 0.0, 0.0), (-0.2, 0.15, 1.3)]:
    props.append(dict(t=POST_T, x=FIRE_X + dx, y=TOP - 2.75, z=FIRE_Z + dz, ry=ry, sx=0.5, sy=0.5, sz=0.5))
def post(x, z):
    g = ground(x, z)
    W['walls'].append(dict(type=STONE, x=x, z=z, hx=0.25, hz=0.25, ry=0.0, h=0.4, yo=0.0, op=[]))
    props.append(dict(t=POST_T, x=x, y=g + 0.4, z=z, ry=0.0, sx=0.5, sy=0.5, sz=0.5))
post(RAMP_X1 + 1.0, RAMP_FOOT_Z - 0.5)           # foot of the ramp
post(RAMP_X0 - 0.8, RAMP_TOP_Z + 0.8)            # top of the ramp, on the plateau
post(GRAVEL[0] - 0.6, GRAVEL[2] - 0.6)           # the square's corners
post(GRAVEL[1] + 0.6, GRAVEL[3] + 0.6)
for sx in (-1.1, 1.1):                           # either side of the hut door
    props.append(dict(t=SCONCE_T, x=mx + sx, y=T + 2.3, z=HUT_Z1 + 0.25, ry=math.atan2(0, -1), sx=0.25, sy=0.25, sz=0.25))
for dx, dz, ry in [(9.0, 7.0, 0.3), (9.5, 9.0, 2.0), (7.5, 10.5, 4.1), (8.5, -7.0, 1.0),
                   (-9.5, -5.0, 2.6), (-10.5, -3.0, 0.7), (-20.0, 2.0, 1.5), (20.0, -16.0, 3.3)]:
    x, z = CX + dx, CZ + dz
    props.append(dict(t=BUSH_T, x=x, y=ground(x, z), z=z, ry=ry, sx=0.2, sy=0.2, sz=0.2))
W['props'] += props

gwl.save(W, path)
gwl.load(path)   # sanity: parses back

# ── cells: cobbles on top and up the ramp, gravel square, rock on the cliffs ────
COBBLE, GRAVEL_C, MOSSY_ROCK = 'city_ph.png', 'cave_texture.jpg', 'rock01_RockMossy0033_1_350.jpg'
b = open(cells_path, 'rb').read()
magic, ccells = struct.unpack_from('<II', b, 0)
assert magic == 0x31435747 and ccells == CC
pal = []
p = 8; n = b[p]; p += 1
for _ in range(n):
    l = struct.unpack_from('<H', b, p)[0]; p += 2
    pal.append((b[p:p + l].decode(), struct.unpack_from('<f', b, p + l)[0])); p += l + 4
head_end = p
cnt = struct.unpack_from('<I', b, p)[0]; p += 4
entries = {}
for _ in range(cnt):
    key = struct.unpack_from('<ii', b, p); p += 8
    entries[key] = bytearray(b[p:p + CC * CC]); p += CC * CC
assert p == len(b)
def val(name):
    return next(i + 1 for i, (pth, _) in enumerate(pal) if pth.endswith('/' + name))
key = (W['ox'] + ci, W['oz'] + cj)
cells = entries.setdefault(key, bytearray(CC * CC))
for j in range(CC):
    for i in range(CC):
        x, z = cx0 + (i + 0.5) * CS, cz0 + (j + 0.5) * CS
        d = edge_dist(x, z)
        if ramp(x, z) > plateau(x, z) + 0.05 and RAMP_X0 <= x <= RAMP_X1: v = val(COBBLE)
        elif d < -0.6: v = val(GRAVEL_C) if GRAVEL[0] <= x <= GRAVEL[1] and GRAVEL[2] <= z <= GRAVEL[3] else val(COBBLE)
        elif d < CLIFF + 0.4: v = val(MOSSY_ROCK)
        else: continue
        cells[j * CC + i] = v
out = bytearray(b[:head_end]) + struct.pack('<I', len(entries))
for (kx, kz), c in entries.items():
    out += struct.pack('<ii', kx, kz) + c
open(cells_path, 'wb').write(out)

# ── spawn: the Witch, anywhere on her hilltop ───────────────────────────────────
spawns = json.load(open(spawns_path))
spawns = [s for s in spawns if s['name'] not in ('Witch_123_8', 'WitchHut')]
spawns.append(dict(name='WitchHut', monster='Witch', layer='upper',
                   area=dict(x=CX + 1.0, z=CZ + 3.0, radius=7.0), max=1, interval=300.0, prob=1.0, level=5))
open(spawns_path, 'w').write(json.dumps(spawns, indent=2) + '\n')

print(f'{path}: +{len(walls) + 4} walls, +{len(objs)} objects, +{len(props)} props; {cells_path}, {spawns_path} updated')
