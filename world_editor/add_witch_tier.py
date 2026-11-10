#!/usr/bin/env python3
# Raises the north end of the Witch's hill (add_witch_hill.py), where her hut
# stands, into a second, higher level: TIER_TOP, sheer on every side, merging
# into the hill's outer cliff on the north. A second ramp climbs its east side
# from the top of the first one. Patches village.bin in place (editor edits
# kept): walls stand on the terrain under them, so the hut rises with the
# ground; props are absolute, so the ones up there are lifted by hand. The
# cauldron and the square's north-west torch post, which the new edge would
# cut through, are moved. Also paints the new cliffs and ramp (cells).
#   add_witch_tier.py [village.bin]
# Refuses to run twice (the hut's floor is already up).
import math, os, struct, sys
import gwl

path = sys.argv[1] if len(sys.argv) > 1 else 'village.bin'
cells_path = os.path.splitext(path)[0] + '.cells.bin'
W = gwl.load(path)
CC, CS = W['cc'], W['cs']
STRIDE = CC + 1
SPAN = CC * CS
POST_T, SCONCE_T = W['ptypes'].index('res://assets/props/TorchPost.tscn'), W['ptypes'].index('res://assets/props/TorchSconce.tscn')
BUSH_T = W['ptypes'].index('res://assets/props/bush.glb')
ROCK_O = 1

# the hill, as add_witch_hill.py laid it out
CX, CZ, HALF, CORNER = -44.0, 110.0, 13.0, 5.0
TOP, CLIFF = 5.0, 0.8
HUT_X0, HUT_X1, HUT_Z0, HUT_Z1 = CX - 3.5, CX + 3.5, CZ - 10.0, CZ - 4.5
GRAVEL = (CX - 1.0, CX + 7.0, CZ - 2.0, CZ + 6.0)

# the new level: a rounded box round the hut, running off the hill's north edge
TIER_TOP, TIER_CLIFF = 10.0, 0.6
TX, TZ, THX, THZ, TCORNER = CX - 1.5, CZ - 9.5, 8.5, 8.0, 3.0   # x -54..-37, z 92.5..108.5 (north part off the hill)
# the second ramp: up the tier's east side, from the plateau at R2_FOOT_Z (south)
# to the tier at R2_TOP_Z, then level on to it. Its west side runs a metre
# into the tier, so the level top joins it without a dip (lower down, the
# tier's cliff just stands over that strip).
R2_X0, R2_X1, R2_FOOT_Z, R2_TOP_Z, R2_END_Z = TX + THX - 1.0, CX + 11.4, CZ + 4.0, CZ - 9.0, CZ - 13.0

def wobble(x, z, cx, cz):
    a = math.atan2(z - cz, x - cx)
    return 0.5 * math.sin(5 * a) + 0.4 * math.sin(9 * a + 1.3)

def rrect(x, z, cx, cz, hx, hz, r):
    qx, qz = abs(x - cx) - (hx - r), abs(z - cz) - (hz - r)
    return math.hypot(max(qx, 0.0), max(qz, 0.0)) + min(max(qx, qz), 0.0) - r

def edge_dist(x, z):    # the hill's edge (add_witch_hill.py)
    return rrect(x, z, CX, CZ, HALF, HALF, CORNER) - wobble(x, z, CX, CZ)

def tier_dist(x, z):    # the tier's edge, a gentler wobble
    return rrect(x, z, TX, TZ, THX, THZ, TCORNER) - 0.6 * wobble(x, z, TX, TZ)

def ramp2(x, z):
    if not (R2_END_Z <= z <= R2_FOOT_Z + 1.0): return 0.0
    out = max(R2_X0 - x, x - R2_X1, 0.0)
    if out >= 0.8: return 0.0
    f = min(1.0, max(0.0, (R2_FOOT_Z - z) / (R2_FOOT_Z - R2_TOP_Z)))
    return (TOP + (TIER_TOP - TOP) * f) * (1.0 - out / 0.8)

def tier(x, z, h):
    """New height where the tier is, given the current height h."""
    d = tier_dist(x, z)
    if d >= TIER_CLIFF: return h
    if edge_dist(x, z) > 0:             # off the hill: its outer cliff, scaled up
        return h * TIER_TOP / TOP
    if d <= 0: return TIER_TOP
    return TOP + (TIER_TOP - TOP) * (1.0 - d / TIER_CLIFF)

def on_ramp2(x, z):
    return R2_X0 - 1.0 <= x <= R2_X1 + 1.0 and R2_END_Z - 1.0 <= z <= R2_FOOT_Z + 1.5

# ── terrain ─────────────────────────────────────────────────────────────────────
ci, cj = int(CX // SPAN) - W['ox'], int(CZ // SPAN) - W['oz']
chunk = W['chunks'][cj * W['cx'] + ci]
cx0, cz0 = (W['ox'] + ci) * SPAN, (W['oz'] + cj) * SPAN
def vidx(x, z): return int(round((z - cz0) / CS)) * STRIDE + int(round((x - cx0) / CS))
hut_h = chunk['h1'][vidx((HUT_X0 + HUT_X1) / 2, (HUT_Z0 + HUT_Z1) / 2)]
if hut_h != TOP:
    sys.exit(f'{path}: expected the hut on the hill at {TOP}, found {hut_h} (tier already there?)')

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

# Walls keep their height above the terrain under their centre, so note the
# ground under every wall first: the ones that should ride up with the tier keep
# their yo, the ones whose ground changed otherwise are re-based to stay put,
# and the rest (every wall off the hill, and any over a hole, where ground is
# NaN) are left alone.
was = [ground(w['x'], w['z']) for w in W['walls']]
nan_before = sum(math.isnan(w['yo']) for w in W['walls'])
old = list(chunk['h1'])
for vz in range(STRIDE):
    for vx in range(STRIDE):
        x, z = cx0 + vx * CS, cz0 + vz * CS
        k = vz * STRIDE + vx
        chunk['h1'][k] = max(tier(x, z, old[k]), ramp2(x, z), old[k])

def moved(x, z, nx, nz):
    """The cauldron and the torch post the new edge cuts through: walls within
    0.9 m of (x, z) shift by (nx - x, nz - z)."""
    for w in W['walls']:
        if math.hypot(w['x'] - x, w['z'] - z) < 0.9:
            w['x'] += nx - x; w['z'] += nz - z
KX, KZ = HUT_X0 - 1.0, HUT_Z1 + 2.2                          # the cauldron, by the door
NKX, NKZ = HUT_X0 - 2.0, HUT_Z1 - 1.0                        # -> beside the hut
PX, PZ = GRAVEL[0] - 0.6, GRAVEL[2] - 0.6                    # the square's NW torch post
NPX, NPZ = PX, GRAVEL[2] + 1.8                               # -> down on the square's edge
RPX, RPZ = CX + 11.0 - 0.8, CZ + 4.0 + 0.8                   # the first ramp's top post, which the
NRPX, NRPZ = R2_X0 - 1.2, CZ + 2.0                           # second one's foot runs into -> beside that foot
before = [(w['x'], w['z']) for w in W['walls']]
moved(KX, KZ, NKX, NKZ)
moved(PX, PZ, NPX, NPZ)
moved(RPX, RPZ, NRPX, NRPZ)
for w, g, (x0, z0) in zip(W['walls'], was, before):
    now = ground(w['x'], w['z'])
    if (w['x'], w['z']) != (x0, z0) and tier_dist(w['x'], w['z']) < 0:
        w['yo'] += g + (TIER_TOP - TOP) - now                   # moved onto the tier: up with it
    elif tier_dist(w['x'], w['z']) < -0.3:
        pass                                                    # on the tier: rides up
    elif not (math.isnan(g) or math.isnan(now)) and now != g:
        w['yo'] += g - now                                      # ground changed under it: stays put
assert sum(math.isnan(w['yo']) for w in W['walls']) == nan_before, 'a wall lost its height'

# ── props: lift what's up there, move the post's torch and a bush off the ramp ──
for p in W['props']:
    if p['t'] == POST_T and math.hypot(p['x'] - PX, p['z'] - PZ) < 0.5:
        p['x'], p['z'] = NPX, NPZ
    elif p['t'] == POST_T and math.hypot(p['x'] - RPX, p['z'] - RPZ) < 0.5:
        p['x'], p['z'] = NRPX, NRPZ
    elif p['t'] == BUSH_T and on_ramp2(p['x'], p['z']):
        p['x'], p['z'], p['y'] = CX - 7.0, CZ - 12.0, p['y'] + (TIER_TOP - TOP)
    elif tier_dist(p['x'], p['z']) < -0.3 and p['y'] > TOP - 1.0:
        p['y'] += TIER_TOP - TOP

# ── objects: rim rocks that the ramp now runs through go ────────────────────────
W['objs'] = [o for o in W['objs'] if not (o['type'] == ROCK_O and on_ramp2(o['x'], o['z']))]

gwl.save(W, path)
gwl.load(path)   # sanity: parses back

# ── cells: rock on the new cliffs, cobbles up the ramp ──────────────────────────
b = open(cells_path, 'rb').read()
magic, ccells = struct.unpack_from('<II', b, 0)
assert magic == 0x31435747 and ccells == CC
pal = []
p = 8; n = b[p]; p += 1
for _ in range(n):
    l = struct.unpack_from('<H', b, p)[0]; p += 2
    pal.append(b[p:p + l].decode()); p += l + 4
head_end = p
cnt = struct.unpack_from('<I', b, p)[0]; p += 4
entries = {}
for _ in range(cnt):
    key = struct.unpack_from('<ii', b, p); p += 8
    entries[key] = bytearray(b[p:p + CC * CC]); p += CC * CC
assert p == len(b)
def val(name): return next(i + 1 for i, pth in enumerate(pal) if pth.endswith('/' + name))
COBBLE, MOSSY_ROCK = val('city_ph.png'), val('rock01_RockMossy0033_1_350.jpg')
cells = entries[(W['ox'] + ci, W['oz'] + cj)]
for j in range(CC):
    for i in range(CC):
        x, z = cx0 + (i + 0.5) * CS, cz0 + (j + 0.5) * CS
        d = tier_dist(x, z)
        if R2_X0 <= x <= R2_X1 and ramp2(x, z) > TOP + 0.05 and d > 0: cells[j * CC + i] = COBBLE
        elif -0.3 < d < TIER_CLIFF + 0.4 and edge_dist(x, z) < -0.6: cells[j * CC + i] = MOSSY_ROCK
out = bytearray(b[:head_end]) + struct.pack('<I', len(entries))
for (kx, kz), c in entries.items():
    out += struct.pack('<ii', kx, kz) + c
open(cells_path, 'wb').write(out)
print(f'{path}: tier up to {TIER_TOP} m round the hut, second ramp; {cells_path} painted')
