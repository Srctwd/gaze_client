#!/usr/bin/env python3
# Generates village.bin (GWL9, via gwl.py): a small walled village + a rat hill with a cave.
# Writes ONLY world_editor/village.bin and gaze_client/village.bin (never world.bin).
# Also writes world_editor/village.spawns.json (the server's spawns.json).
#   make_village.py [out.bin]     both
#   make_village.py --spawns      only the spawns, for a village.bin that the
#                                 editor has taken past this script's output
import math, sys, shutil, json, os
sys.path.insert(0, os.path.dirname(__file__))
import gwl

# ── spawns ──────────────────────────────────────────────────────────────────────
# Nothing spawns inside the town walls (x 2..66, z 2..80) or in the sewer
# under them. Rats keep to the hill and its cave east of the gate; goblins
# camp on the open ground south of the town; snakes nest in the hill's
# southeast corner; slimes sit in the meadow between the hill and the nest,
# east of the town's south wall. The Witch, the final boss, holds the cave's
# south chamber, past the rats (Belch's quest).
def spawn(name, monster, layer, area, mx, interval, level=1):
    return dict(name=name, monster=monster, layer=layer, area=area, max=mx,
                interval=interval, prob=1.0, level=level)
SPAWNS = [
    spawn('RatCave_Chamber', 'Rat', 'lower', dict(x=110.0, z=32.0, radius=11.0), 4, 6.0),
    spawn('RatCave_SideChamber', 'Rat', 'lower', dict(x=99.0, z=11.0, radius=6.0), 2, 10.0, level=2),
    spawn('RatCave_CaveRat_Main', 'CaveRat', 'lower', dict(x=110.0, z=32.0, radius=6.0), 1, 120.0),
    spawn('RatCave_CaveRat_Side', 'CaveRat', 'lower', dict(x=99.0, z=11.0, radius=3.0), 1, 120.0),
    spawn('RatCave_Witch', 'Witch', 'lower', dict(x=116.0, z=55.0, radius=3.0), 1, 300.0, level=5),
    spawn('RatHill', 'Rat', 'upper', dict(x0=92.0, z0=40.0, x1=124.0, z1=60.0), 4, 8.0),
    spawn('GoblinCamp_South', 'Goblin', 'upper', dict(x0=12.0, z0=92.0, x1=56.0, z1=120.0), 4, 20.0),
    spawn('SnakeNest_SouthEast', 'Snake', 'upper', dict(x0=80.0, z0=80.0, x1=120.0, z1=120.0), 4, 15.0),
    spawn('SlimeMeadow_East', 'Slime', 'upper', dict(x0=70.0, z0=64.0, x1=88.0, z1=78.0), 3, 15.0),
]
with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'village.spawns.json'), 'w') as f:
    json.dump(SPAWNS, f, indent=2)
    f.write('\n')
if '--spawns' in sys.argv:
    print(f'village.spawns.json: {len(SPAWNS)} spawners')
    sys.exit(0)

NAN = float('nan')
CC, CS = 128, 0.5            # same chunk layout as rats.bin: 64m chunks, 0.5m cells
STRIDE = CC + 1
SPAN = CC * CS

walls = []

def box(x0, x1, z0, z1, y0, y1, t=0):
    walls.append(dict(type=t, x=(x0 + x1) / 2, z=(z0 + z1) / 2, hx=(x1 - x0) / 2, hz=(z1 - z0) / 2,
                      ry=0.0, h=y1 - y0, yo=y0, op=[]))

def wall(axis, at, a0, a1, y0, y1, holes=(), th=0.2):
    """Straight wall along x (axis='x', at=z) or along z (axis='z', at=x) from a0..a1,
    with rectangular holes (b0, b1, hy0, hy1) built by splitting into solid pieces."""
    def piece(b0, b1, py0, py1):
        if b1 - b0 < 1e-3 or py1 - py0 < 1e-3: return
        if axis == 'x': box(b0, b1, at - th / 2, at + th / 2, py0, py1)
        else:           box(at - th / 2, at + th / 2, b0, b1, py0, py1)
    cur = a0
    for b0, b1, hy0, hy1 in sorted(holes):
        piece(cur, b0, y0, y1)
        piece(b0, b1, y0, hy0)      # sill
        piece(b0, b1, hy1, y1)      # lintel
        cur = b1
    piece(cur, a1, y0, y1)

def obox(x0, x1, z0, z1, y0, y1, holes=(), t=0):
    """Box with openings instead of split pieces. Each hole is an absolute
    (x0, x1, y0, y1, z0, z1); give a thin axis its full range to cut right through."""
    cx, cz = (x0 + x1) / 2, (z0 + z1) / 2
    box(x0, x1, z0, z1, y0, y1, t)
    walls[-1]['op'] = [(a - cx, b - cx, c - y0, d - y0, e - cz, f - cz) for a, b, c, d, e, f in holes]

def owall(axis, at, a0, a1, y0, y1, holes=(), th=0.5, t=0):
    """wall() as one box with carved openings — holes may overlap, so a stack of
    narrowing ones makes a pointed arch."""
    if axis == 'x':
        obox(a0, a1, at - th / 2, at + th / 2, y0, y1, [(b0, b1, h0, h1, at - th, at + th) for b0, b1, h0, h1 in holes], t)
    else:
        obox(at - th / 2, at + th / 2, a0, a1, y0, y1, [(at - th, at + th, h0, h1, b0, b1) for b0, b1, h0, h1 in holes], t)

def slab(x0, x1, z0, z1, y0, y1, holes=(), t=0):
    """Floor slab; holes are (x0, x1, z0, z1) cut through its full thickness."""
    obox(x0, x1, z0, z1, y0, y1, [(a, b, y0 - 1, y1 + 1, c, d) for a, b, c, d in holes], t)

def rbox(x, z, hx, hz, ry, y0, y1, t=0):
    """Box turned by yaw ry (radians) about its centre."""
    walls.append(dict(type=t, x=x, z=z, hx=hx, hz=hz, ry=ry, h=y1 - y0, yo=y0, op=[]))

def lancet(c, w, y0, y1):
    """Pointed (gothic) window or door centred at c: a w-wide opening from y0 to
    y1, topped by two narrowing ones that step up to a point."""
    return [(c - w / 2, c + w / 2, y0, y1),
            (c - w * 0.32, c + w * 0.32, y1, y1 + w * 0.3),
            (c - w * 0.12, c + w * 0.12, y1 + w * 0.3, y1 + w * 0.55)]

DOOR = (0.0, 2.2)

def shifted(build, dx=0.0, dz=0.0, t=None):
    """Runs build() (which places boxes at fixed coordinates) and moves
    everything it added by (dx, dz); `t` gives it all that wall type."""
    first = len(walls)
    build()
    for w in walls[first:]:
        w['x'] += dx
        w['z'] += dz
        if t is not None:
            w['type'] = t

def cottage(x0, x1, z0, z1, door_side, door_at, h=3.0):
    """One-room house: 4 walls, a door, a window opposite, flat roof."""
    d = (door_at, door_at + 1.6, *DOOR)
    sides = {
        'n': ('x', z0, x0, x1), 's': ('x', z1, x0, x1),
        'w': ('z', x0, z0, z1), 'e': ('z', x1, z0, z1),
    }
    opposite = {'n': 's', 's': 'n', 'e': 'w', 'w': 'e'}
    for k, (ax, at, a0, a1) in sides.items():
        holes = []
        if k == door_side: holes.append(d)
        if k == opposite[door_side]:
            mid = (a0 + a1) / 2
            holes.append((mid - 0.6, mid + 0.6, 1.0, 2.0))
        wall(ax, at, a0, a1, 0.0, h, holes)
    box(x0 - 0.3, x1 + 0.3, z0 - 0.3, z1 + 0.3, h, h + 0.2)   # roof with a little overhang

# ── the inn: two storeys, stairs, stairwell, railing, roof access by vines ──────
STAIR_W = 1.0   # every staircase's width: room for a player (0.8 m) with the floor beside it free

def inn():
    x0, x1, z0, z1 = 26.0, 40.0, 6.0, 18.0
    F2, TOP = 3.0, 6.2
    win2 = lambda c: (c, c + 1.5, 4.0, 5.2)
    # front (south, faces plaza): door + ground window + two upstairs windows
    wall('x', z1, x0, x1, 0, TOP, [(32.2, 33.8, *DOOR), (36.0, 37.5, 1.0, 2.0), win2(28.0), win2(35.5)])
    wall('x', z0, x0, x1, 0, TOP, [win2(34.0)])                        # back
    wall('z', x0, z0, z1, 0, TOP, [(11.0, 12.5, 1.0, 2.0), win2(14.0)])  # west
    wall('z', x1, z0, z1, 0, TOP, [(11.0, 12.5, 1.0, 2.0), win2(9.0), win2(14.0)])  # east
    # stairs along the back wall, climbing +x: 15 steps x 0.2m rise, 0.4m run, STAIR_W wide
    sx0, sz0 = 27.0, 6.1
    sz1 = sz0 + STAIR_W
    for i in range(1, 16):
        box(sx0 + 0.4 * (i - 1), sx0 + 0.4 * i, sz0, sz1, 0.0, 0.2 * i)
    sx1 = sx0 + 0.4 * 15                     # 33.0 — top step lands flush with the floor
    # upper floor slab (top at F2) with a stairwell hole over the run
    hole_z = sz1 + 0.2
    box(x0, x1, hole_z, z1, F2 - 0.2, F2)           # main floor
    box(sx1, x1, z0, hole_z, F2 - 0.2, F2)          # landing beside the stair top
    box(x0, 26.6, z0, hole_z, F2 - 0.2, F2)         # sliver at the stair foot
    box(26.6, sx1 - 0.6, hole_z, hole_z + 0.15, F2, F2 + 1.0)   # railing upstairs
    # an upstairs partition with a doorway — a bedroom on the east side
    wall('z', 36.0, hole_z, z1, F2, TOP, [(12.0, 13.6, F2, F2 + 2.2)])
    # bar counter downstairs
    box(28.0, 31.0, 14.0, 14.6, 0.0, 1.1)
    # roof + a short parapet, vines on the back wall to climb up there
    box(x0 - 0.2, x1 + 0.2, z0 - 0.2, z1 + 0.2, TOP, TOP + 0.2)
    for ax, at, a0, a1 in [('x', z0 - 0.1, x0 - 0.2, x1 + 0.2), ('x', z1 + 0.1, x0 - 0.2, x1 + 0.2),
                           ('z', x0 - 0.1, z0, z1), ('z', x1 + 0.1, z0, z1)]:
        wall(ax, at, a0, a1, TOP + 0.2, TOP + 0.8, [(37.5, 39.5, TOP + 0.2, TOP + 0.8)] if at == z0 - 0.1 else [])
    box(37.6, 39.4, z0 - 0.35, z0 - 0.2, 0.0, TOP + 0.4, t=4)   # climbable vines -> roof gap in parapet

# ── the temple: a gothic church, three storeys over a crypt ─────────────────────
# Outer walls x 20.5..30.5, z 4.5..18.5 (0.5 thick), portal facing south (+z).
# The crypt is dug into the terrain: every vertex of the interior footprint
# CRYPT is lowered to BASE (see the heightmaps), so the dug-out edge slopes
# away inside the outer walls, which run down to BASE too.
CRYPT = (21.0, 30.0, 5.0, 18.0)
CRYPT_FLOOR = -4.2     # 4.2 m under the nave floor's underside; a multiple of the 0.2 m step below F0
def gothic_temple():
    X0, X1, Z0, Z1 = 20.5, 30.5, 4.5, 18.5
    IX0, IX1, IZ0, IZ1 = CRYPT
    CX = (X0 + X1) / 2
    BASE, F0, F1, F2, EAVE, TT = CRYPT_FLOOR, 0.4, 4.4, 8.0, 11.4, 20.0   # TT: tower top
    S, M, LADDER = 0, 5, 2          # stone, marble, climbable (wall_types.json)
    BAYS = (6.25, 9.5, 12.5, 16.25)          # window bays between the side buttresses

    # ── shell: one window per bay and storey, rose window and portal in front
    for x in (X0 + 0.25, X1 - 0.25):
        holes = []
        for z in BAYS:
            holes += lancet(z, 1.0, 1.6, 3.4) + lancet(z, 1.0, 5.2, 7.0) + lancet(z, 0.8, 9.0, 10.4)
        owall('z', x, Z0, Z1, BASE, EAVE, holes)
    owall('x', Z0 + 0.25, X0, X1, BASE, EAVE,       # apse end, behind the altar
          lancet(22.5, 1.0, 1.6, 3.4) + lancet(28.5, 1.0, 1.6, 3.4) + lancet(CX, 1.6, 4.8, 7.6)
          + lancet(23.5, 0.8, 9.0, 10.4) + lancet(27.5, 0.8, 9.0, 10.4))
    rose = [(CX - 1.0, CX + 1.0, 6.1, 7.1), (CX - 0.6, CX + 0.6, 5.7, 7.5), (CX - 0.3, CX + 0.3, 5.5, 7.7)]
    owall('x', Z1 - 0.25, X0, X1, BASE, EAVE,
          lancet(CX, 2.0, F0, 3.2) + rose + lancet(22.5, 1.0, 1.6, 3.4) + lancet(28.5, 1.0, 1.6, 3.4)
          + lancet(22.5, 0.8, 9.0, 10.4) + lancet(28.5, 0.8, 9.0, 10.4))

    # portal: jambs, a stepped gable over the door, a stoop up from the street
    box(CX - 1.6, CX - 1.1, Z1, Z1 + 0.6, 0.0, 4.2)
    box(CX + 1.1, CX + 1.6, Z1, Z1 + 0.6, 0.0, 4.2)
    for i, half in enumerate((1.6, 1.2, 0.8, 0.4)):
        box(CX - half, CX + half, Z1, Z1 + 0.6, 4.2 + 0.3 * i, 4.5 + 0.3 * i)
    box(CX - 1.5, CX + 1.5, Z1, Z1 + 0.8, 0.0, 0.2)

    # buttresses: stepped piers between the bays, a pinnacle above the eaves
    def buttress(x_wall, out, z):
        for reach, y0, y1 in ((1.2, 0.0, 4.5), (0.8, 4.5, 8.5), (0.5, 8.5, EAVE + 0.6)):
            a, b = sorted((x_wall, x_wall + out * reach))
            box(a, b, z - 0.3, z + 0.3, y0, y1)
        xc = x_wall + out * 0.25
        box(xc - 0.15, xc + 0.15, z - 0.15, z + 0.15, EAVE + 0.6, EAVE + 1.8)
    for z in (8.0, 11.0, 14.0):
        buttress(X0, -1, z)
        buttress(X1, +1, z)
    # corner buttresses run out diagonally; centred 0.35 m out on the diagonal
    # so the inner end stays buried in the corner instead of poking indoors
    for sx, sz in ((-1, -1), (1, -1), (-1, 1), (1, 1)):
        x, z = (X0 if sx < 0 else X1) + sx * 0.35, (Z0 if sz < 0 else Z1) + sz * 0.35
        ry = -math.pi / 4 if sx == sz else math.pi / 4
        rbox(x, z, 0.9, 0.35, ry, 0.0, 6.0)
        rbox(x + sx * 0.2, z + sz * 0.2, 0.6, 0.3, ry, 6.0, 10.0)
        box(x - 0.15, x + 0.15, z - 0.15, z + 0.15, 10.0, EAVE + 1.8)

    # ── crypt (BASE..0): tombs along the west wall. The middle (around
    # (CX, 11.5)) is kept clear so players can spawn there.
    for z in (7.0, 10.5, 14.0):                                  # west wall tombs
        box(IX0, IX0 + 1.0, z - 1.0, z + 1.0, BASE, BASE + 0.9, t=M)
        box(IX0, IX0 + 1.05, z - 1.05, z + 1.05, BASE + 0.9, BASE + 1.05, t=M)
    box(CX - 1.0, CX + 1.0, IZ0, IZ0 + 0.6, BASE, BASE + 1.2, t=M)  # ossuary altar
    # stairs down, along the east wall, from the nave floor heading north; the
    # last step's top is BASE + 0.2, the floor is the next one
    SE, SW = IX1 - STAIR_W, IX0 + STAIR_W     # inner edges of the east- and west-wall stairs
    for i in range(1, round((F0 - BASE) / 0.2)):
        box(SE, IX1, 17.5 - 0.4 * i, 17.5 - 0.4 * (i - 1), BASE, F0 - 0.2 * i)
    CRYPT_HOLE = (SE, IX1, 11.1, 17.5)

    # ── ground storey (F0): the nave. Stairs up along the west wall, climbing north
    slab(IX0, IX1, IZ0, IZ1, 0.0, F0, [CRYPT_HOLE])
    # railing round the crypt stairs; it stops 1 m short of the top step so
    # there's room to turn off the stairs between it and the south wall
    box(SE - 0.15, SE, 11.1, 16.5, F0, F0 + 1.0)
    box(SE - 0.15, IX1, 10.95, 11.1, F0, F0 + 1.0)
    for i in range(1, 21):
        box(IX0, SW, 17.5 - 0.4 * i, 17.5 - 0.4 * (i - 1), F0, F0 + 0.2 * i)
    box(24.1, 26.9, 7.0, 9.2, F0, F0 + 0.2, t=M)                  # dais
    box(CX - 0.8, CX + 0.8, 7.6, 8.4, F0 + 0.2, F0 + 1.2, t=M)    # altar
    obox(CX - 1.2, CX + 1.2, IZ0, IZ0 + 0.3, F0, 4.2,             # reredos, pierced by a lancet
         [(a, b, c, d, IZ0 - 1, IZ0 + 1) for a, b, c, d in lancet(CX, 0.6, 2.0, 3.2)], t=M)
    for z in (11.9, 12.9, 15.0, 16.0):                            # pews, aisle down the middle
        box(24.1, 25.0, z - 0.25, z + 0.25, F0, F0 + 0.5)
        box(26.0, 26.9, z - 0.25, z + 0.25, F0, F0 + 0.5)

    # ── second storey (F1): galleries round an open nave, choir loft over the door
    VOID = (23.4, 27.6, 7.0, 14.0)
    slab(IX0, IX1, IZ0, IZ1, F1 - 0.2, F1, [VOID, (IX0, SW, 9.9, 14.7)])
    vx0, vx1, vz0, vz1 = VOID
    box(vx0 - 0.15, vx0, vz0, vz1, F1, F1 + 1.0)                 # railing round the open nave
    box(vx1, vx1 + 0.15, vz0, vz1, F1, F1 + 1.0)
    box(vx0 - 0.15, vx1 + 0.15, vz0 - 0.15, vz0, F1, F1 + 1.0)
    box(vx0 - 0.15, vx1 + 0.15, vz1, vz1 + 0.15, F1, F1 + 1.0)
    box(SW, SW + 0.15, 9.9, 14.7, F1, F1 + 1.0)                     # railing round the stairwell
    box(IX0, SW + 0.15, 14.7, 14.85, F1, F1 + 1.0)
    for i in range(1, 19):                                        # stairs up, east gallery, climbing south
        box(SE, IX1, 7.0 + 0.4 * (i - 1), 7.0 + 0.4 * i, F1, F1 + 0.2 * i)

    # ── third storey (F2): the library
    slab(IX0, IX1, IZ0, IZ1, F2 - 0.2, F2, [(SE, IX1, 9.4, 13.8)])
    box(SE - 0.15, SE, 9.4, 13.8, F2, F2 + 1.0)
    box(SE - 0.15, IX1, 9.25, 9.4, F2, F2 + 1.0)
    for z in (7.2, 11.2):                                         # bookshelves, and a reading table
        box(22.0, 27.0, z - 0.2, z + 0.2, F2, F2 + 2.0)
    box(24.5, 26.5, 9.0, 10.0, F2, F2 + 0.8)

    # ── roof: ceiling slab, a steep stepped gable, a bell tower over the portal
    TX0, TX1, TZ0 = 23.5, 27.5, 14.5         # tower: x TX0..TX1, z TZ0..Z1
    # the belfry hatch: wide enough beside the ladder to drop back down through
    slab(X0 - 0.2, X1 + 0.2, Z0 - 0.2, Z1 + 0.2, EAVE - 0.2, EAVE, [(24.6, 26.4, 16.8, IZ1)])
    box(25.0, 26.0, IZ1 - 0.15, IZ1, F2, EAVE + 0.4, t=LADDER)    # ladder up into the belfry
    k = 0
    while 5.0 - 0.45 * k > 0.2:
        half, y = 5.0 - 0.45 * k, EAVE + 0.6 * k
        box(CX - half, CX + half, Z0 - 0.2, TZ0, y, y + 0.6)      # nave roof up to the tower
        if half > TX1 - CX:                                       # either side of the tower
            box(CX - half, TX0, TZ0, Z1 + 0.2, y, y + 0.6)
            box(TX1, CX + half, TZ0, Z1 + 0.2, y, y + 0.6)
        k += 1
    belfry = lambda c: lancet(c, 1.4, 16.0, 18.4) + lancet(c, 0.5, 12.6, 13.8)
    TZC = (TZ0 + Z1) / 2
    owall('x', Z1 - 0.25, TX0, TX1, EAVE, TT, belfry(CX))
    owall('x', TZ0 + 0.2, TX0, TX1, EAVE, TT, belfry(CX), th=0.4)
    owall('z', TX0 + 0.2, TZ0, Z1, EAVE, TT, belfry(TZC), th=0.4)
    owall('z', TX1 - 0.2, TZ0, Z1, EAVE, TT, belfry(TZC), th=0.4)
    box(TX0 + 0.4, TX1 - 0.4, TZC - 0.1, TZC + 0.1, 18.4, 18.6)       # bell beam
    box(CX - 0.5, CX + 0.5, TZC - 0.5, TZC + 0.5, 16.2, 17.2)          # bell
    box(CX - 0.25, CX + 0.25, TZC - 0.25, TZC + 0.25, 17.2, 18.4)
    box(TX0 - 0.2, TX1 + 0.2, TZ0 - 0.2, Z1 + 0.2, TT, TT + 0.3)      # cornice
    for x in (TX0 + 0.2, TX1 - 0.2):                                   # corner pinnacles
        for z in (TZ0 + 0.2, Z1 - 0.2):
            box(x - 0.2, x + 0.2, z - 0.2, z + 0.2, TT + 0.3, TT + 2.0)
            box(x - 0.1, x + 0.1, z - 0.1, z + 0.1, TT + 2.0, TT + 2.6)
    half, y = 1.8, TT + 0.3                                            # spire
    while half > 0.15:
        box(CX - half, CX + half, TZC - half, TZC + half, y, y + 0.7)
        half -= 0.15
        y += 0.7
    box(CX - 0.06, CX + 0.06, TZC - 0.06, TZC + 0.06, y, y + 1.4)      # cross
    box(CX - 0.4, CX + 0.4, TZC - 0.06, TZC + 0.06, y + 0.8, y + 0.95)

# ── town layout ─────────────────────────────────────────────────────────────────
WOOD = 7                     # the houses are timber (wall_types.json id 7)
first = len(walls)
cottage(6.0, 14.0, 24.0, 32.0, 'e', 27.2)    # Monet's cottage (healer)
cottage(6.0, 14.0, 37.0, 45.0, 'e', 40.2)    # Feras's cottage (trader)
cottage(26.0, 35.0, 46.0, 54.0, 'n', 29.7)   # spare cottage, south of the plaza
cottage(44.0, 51.0, 44.0, 51.0, 'w', 46.7)   # little shed by the gate
# The inn was designed around x = 33 and moved east to make room for the
# temple: it stands at x 36.3..50.7 (roof edges), the temple at x 19.3..31.7
# (buttresses), both centred on z = 12.
shifted(inn, dx=10.5)
for w in walls[first:]:      # all but the inn's vines
    if w['type'] == 0:
        w['type'] = WOOD
first = len(walls)
gothic_temple()
for w in walls[first:]:      # its stone is black marble (wall_types.json id 6)
    if w['type'] == 0:
        w['type'] = 6

# perimeter wall, gate on the east side facing the rat hill. The east wall
# stays short of x = 70, where the hill starts to rise; the south wall runs
# into the second chunk row (z 64..128).
VX0, VX1, VZ0, VZ1, VH = 2.0, 66.0, 2.0, 80.0, 4.0
STONE_WALL = 8               # cut stone blocks (wall_types.json id 8)
first = len(walls)
wall('x', VZ0, VX0, VX1, 0, VH)
wall('x', VZ1, VX0, VX1, 0, VH)
wall('z', VX0, VZ0, VZ1, 0, VH)
wall('z', VX1, VZ0, VZ1, 0, VH, [(30.0, 34.0, 0.0, VH)])
# gate posts a bit taller
box(VX1 - 0.3, VX1 + 0.3, 29.4, 30.0, 0, VH + 0.9)
box(VX1 - 0.3, VX1 + 0.3, 34.0, 34.6, 0, VH + 0.9)
for w in walls[first:]:
    w['type'] = STONE_WALL

# ── sewer ───────────────────────────────────────────────────────────────────────
# Tunnels under the streets, in the town chunks' cave layers (h2 ceiling, h3
# floor) so the streets above stay whole: a walkway each side of a shallow
# channel, under a low vault. Way in: down the well shaft (see below), or the
# grate in the south cross street. Segments are axis-aligned so each channel
# can carry a WaterRect.
SEWER = [((10.0, 32.0), (60.0, 32.0)),     # under the plaza and the gate road
         ((17.0, 32.0), (17.0, 72.0)),     # west street
         ((58.0, 32.0), (58.0, 72.0)),     # east, by the shed
         ((17.0, 72.0), (58.0, 72.0))]     # south cross street
SEWER_HW = 2.1           # tunnel half width
CHANNEL_HW = 0.75        # channel half width
SEWER_WALK, SEWER_CHANNEL, SEWER_WATER = -5.5, -5.8, -5.6   # water 0.2 deep: wet, not swimming
GX, GZ = 40.0, 72.0     # sewer grate: a 2 m square manhole over the south cross street

def sewer_floor(d):
    return SEWER_CHANNEL if d < CHANNEL_HW else SEWER_WALK

def sewer_ceiling(d):
    return -2.0 - 0.25 * d * d                     # vault: 2.0 under the street at the crown

def grate_hole(x, z):
    """Open vertices of the manhole: the cells they touch span GX±1, GZ±1."""
    return abs(x - GX) <= 0.5 and abs(z - GZ) <= 0.5

# Its shaft: a stone frame lining the rock between the street and the vault,
# a little proud of the street. The south half is covered by an iron grate
# you can walk on, the north half is open over a ladder down, and the lifted
# lid lies beside it.
LINE = sewer_ceiling(1.2) - 0.3
box(GX - 1.2, GX + 1.2, GZ - 1.2, GZ - 1.0, LINE, 0.08)
box(GX - 1.2, GX + 1.2, GZ + 1.0, GZ + 1.2, LINE, 0.08)
box(GX - 1.2, GX - 1.0, GZ - 1.0, GZ + 1.0, LINE, 0.08)
box(GX + 1.0, GX + 1.2, GZ - 1.0, GZ + 1.0, LINE, 0.08)
box(GX - 0.4, GX + 0.4, GZ - 1.0, GZ - 0.85, SEWER_WALK, 0.6, t=2)   # ladder, poking up to grab from the street
def grate(z0, z1, y0, y1):
    for x in (GX - 0.96, GX, GX + 0.96):                               # bars: 2 openings across
        box(x - 0.04, x + 0.04, z0, z1, y0, y1, t=6)
    for k in range(4):                                                 # cross bars: 3 openings along
        z = z0 + (z1 - z0) * k / 3
        box(GX - 1.0, GX + 1.0, z - 0.05, z + 0.05, y0, y1, t=6)
grate(GZ + 0.05, GZ + 0.95, 0.0, 0.08)        # fixed half, flush with the frame
grate(GZ - 2.25, GZ - 1.35, 0.0, 0.06)        # the lid, lying on the street

# well in the plaza: an octagonal stone curb lining a shaft that drops into the
# sewer, under a windlass and a little stepped roof. The lining stops just
# under the sewer's vault (WELL_BASE). The curb's sides sit at apothem
# sqrt(2), 0.4 thick, so the diagonal ones are centred exactly on the grid
# vertices (WX±1, WZ±1).
WX, WZ = 32.0, 32.0
CURB_TOP, CURB_OUT = 0.9, math.sqrt(2) + 0.2
WELL_BASE = sewer_ceiling(CURB_OUT) - 0.3

def under_curb(dx, dz):
    return all(dx * math.cos(k * math.pi / 4) + dz * math.sin(k * math.pi / 4) <= CURB_OUT + 1e-9 for k in range(8))

def well_hole(x, z):
    """Open a vertex (NaN surface) only if every cell it touches stays under
    the curb: a cell with any NaN corner isn't drawn at all, so the hole
    reaches all 8 neighbours."""
    dx, dz = x - WX, z - WZ
    return all(under_curb(dx + a * CS, dz + b * CS) for a in (-1, 0, 1) for b in (-1, 0, 1))
for k in range(8):
    a = k * math.pi / 4
    x, z = WX + math.sqrt(2) * math.cos(a), WZ + math.sqrt(2) * math.sin(a)
    if k % 2: x, z = round(x * 2) / 2, round(z * 2) / 2   # the exact vertex
    rbox(x, z, 0.67, 0.2, math.pi / 2 - a, WELL_BASE, CURB_TOP)
box(WX - 0.25, WX + 0.25, WZ - 1.214, WZ - 1.064, SEWER_WALK, CURB_TOP + 0.1, t=2)   # rungs down to the sewer
for sx in (-1, 1):                                          # posts on the curb
    px = WX + sx * math.sqrt(2)
    box(px - 0.13, px + 0.13, WZ - 0.13, WZ + 0.13, CURB_TOP, 3.1)
box(WX - 1.6, WX + 1.6, WZ - 0.1, WZ + 0.1, 2.4, 2.6)       # windlass
box(WX + 1.6, WX + 1.72, WZ - 0.06, WZ + 0.45, 2.44, 2.56)   # its crank
box(WX - 0.03, WX + 0.03, WZ - 0.03, WZ + 0.03, 0.75, 2.4)   # rope
box(WX - 0.18, WX + 0.18, WZ - 0.18, WZ + 0.18, 0.4, 0.75)   # bucket
for i, hz in enumerate((1.5, 1.05, 0.6, 0.2)):              # roof, ridge along x
    box(WX - 1.9, WX + 1.9, WZ - hz, WZ + hz, 3.1 + 0.15 * i, 3.25 + 0.15 * i)
# The channels' water. None in the well any more: water has no floor, so a
# rect at the well's mouth would make the whole shaft, and the sewer under it,
# swimmable.
water = []
for (ax, az), (bx, bz) in SEWER:
    if az == bz: water.append(dict(x=(ax + bx) / 2, z=az, width=bx - ax, depth=2 * CHANNEL_HW, y=SEWER_WATER, wf=0))
    else:        water.append(dict(x=ax, z=(az + bz) / 2, width=2 * CHANNEL_HW, depth=bz - az, y=SEWER_WATER, wf=0))

# ── torches ─────────────────────────────────────────────────────────────────────
# Props, y absolute. A sconce leans out along (dx, dz), away from its wall;
# Torch scenes lean towards local -z, so that's a yaw of atan2(-dx, -dz).
POST, SCONCE = 'res://assets/props/TorchPost.tscn', 'res://assets/props/TorchSconce.tscn'
ptypes = [POST, SCONCE]
props = []
def post(x, z):
    box(x - 0.25, x + 0.25, z - 0.25, z + 0.25, 0.0, 0.4)  # stone plinth
    props.append(dict(t=0, x=x, y=0.4, z=z, ry=0.0, sx=0.5, sy=0.5, sz=0.5))
def sconce(x, y, z, dx, dz):
    props.append(dict(t=1, x=x, y=y, z=z, ry=math.atan2(-dx, -dz), sx=0.25, sy=0.25, sz=0.25))
for x, z in [(27.5, 27.5), (36.5, 27.5), (27.5, 36.5), (36.5, 36.5),   # plaza
             (23.0, 21.8), (28.0, 21.8),                               # temple steps
             (54.0, 29.0), (34.0, 10.0), (56.0, 12.0), (10.5, 12.0),    # gate road, by the inn and temple
             (18.0, 34.5), (17.5, 51.5), (39.5, 50.0), (58.0, 46.0),
             (30.0, 62.0), (50.0, 65.0), (15.0, 68.0), (38.0, 74.0), (58.0, 74.0)]:
    post(x, z)
for x, z, dx in [(VX1 - 0.35, 29.7, -1), (VX1 - 0.35, 34.3, -1), (VX1 + 0.35, 29.7, 1), (VX1 + 0.35, 34.3, 1)]:
    sconce(x, 2.4, z, dx, 0)                                   # gate posts, inside and out
sconce(41.9, 2.2, 18.15, 0, 1); sconce(45.1, 2.2, 18.15, 0, 1)  # inn door
sconce(14.15, 2.0, 26.6, 1, 0)                                  # Monet's door
sconce(14.15, 2.0, 39.6, 1, 0)                                  # Feras's door
sconce(32.0, 2.0, 45.85, 0, -1)                                 # spare cottage
sconce(43.85, 2.0, 46.1, -1, 0)                                 # shed
sconce(36.6, 1.8, 15.0, 1, 0); sconce(50.4, 4.8, 12.0, -1, 0)   # inside the inn, both floors
sconce(23.6, 2.0, 18.6, 0, 1); sconce(27.4, 2.0, 18.6, 0, 1)    # temple portal
# temple, inside, on the inner wall faces, clear of the stairs along them
for z in (7.2, 8.6): sconce(21.05, 1.8, z, 1, 0)                    # nave, west: between a window and the stairs
for z in (8.0, 14.0): sconce(29.95, 1.8, z, -1, 0)                  # nave, east
for z in (8.0, 14.0): sconce(21.05, CRYPT_FLOOR + 1.8, z, 1, 0)     # crypt, west, over the tombs
for z in (6.5, 9.5): sconce(29.95, CRYPT_FLOOR + 1.8, z, -1, 0)     # crypt, east (stairs from z 11.1)
sconce(22.0, 5.6, 5.05, 0, 1); sconce(29.0, 5.6, 5.05, 0, 1)       # galleries
sconce(21.05, 9.2, 16.0, 1, 0); sconce(29.95, 9.2, 16.0, -1, 0)    # library
# sewer: on the tunnel sides, head high over the walkway. The street above
# faces away from them, so their light doesn't show through it.
SW = SEWER_HW - 0.05
for x, z, dx, dz in [(14.0, 32.0 - SW, 0, 1), (46.0, 32.0 + SW, 0, -1), (17.0 + SW, 52.0, -1, 0),
                     (58.0 - SW, 52.0, 1, 0), (28.0, 72.0 - SW, 0, 1), (48.0, 72.0 + SW, 0, -1),
                     (GX + 2.5, 72.0 - SW, 0, 1)]:
    sconce(x, SEWER_WALK + 1.8, z, dx, dz)

# ── heightmaps ──────────────────────────────────────────────────────────────────
def hill(x, z):
    if x <= 70: return 0.0
    f = min(1.0, (x - 70) / 8)
    return f * (2.8 * math.exp(-((x - 106) ** 2 + (z - 30) ** 2) / (2 * 13 ** 2)) + 0.4 * math.sin(x * 0.3) * math.cos(z * 0.25) + 0.4)

# cave: ramp + tunnel paths + chambers. The ramp stays narrow (rocks flank
# its mouth); the tunnels inside are wider.
RAMP = (74.0, 88.0, 32.0, 2.2)            # x0, x1, z centre, half width
# Tunnels are round tubes: across the width the floor curves up and the
# ceiling arches down until they meet at TUNNEL_HW. The centre-line floor stays
# at FLOOR; TUNNEL_UNDER is how far the tube's sides climb above it, and
# TUNNEL_UNDER + TUNNEL_OVER the headroom in the middle.
TUNNEL_HW = 3.0
TUNNEL_UNDER, TUNNEL_OVER = 1.0, 2.6

def smooth(path, step=0.5):
    """Catmull-Rom curve through the path's points, as a dense polyline — bends
    become curves but still pass through every point (where branches join)."""
    pts = [path[0]] + list(path) + [path[-1]]
    out = []
    for i in range(1, len(pts) - 2):
        p0, p1, p2, p3 = pts[i - 1:i + 3]
        n = max(1, int(math.dist(p1, p2) / step))
        for k in range(n):
            t = k / n
            out.append(tuple(0.5 * (2 * b + (c - a) * t + (2 * a - 5 * b + 4 * c - d) * t * t
                                    + (3 * b - a - 3 * c + d) * t ** 3)
                             for a, b, c, d in zip(p0, p1, p2, p3)))
    out.append(path[-1])
    return out

TUNNEL = smooth([(88.0, 32.0), (97.0, 26.0), (108.0, 31.0)])
BRANCH = smooth([(97.0, 26.0), (99.0, 13.0)])
SOUTH = smooth([(104.0, 42.0), (99.0, 49.0), (104.0, 57.0), (116.0, 55.0)])   # main chamber -> south chamber
CHAMBERS = [(110.0, 32.0, 12.0), (99.0, 11.0, 7.0), (116.0, 55.0, 7.0)]
PILLARS = [(107.0, 28.0), (113.0, 35.0), (111.0, 26.5), (106.0, 36.0), (102.5, 33.0), (117.0, 31.0),
           (113.0, 53.0), (119.0, 57.5)]
FLOOR = -5.0

def seg_dist(px, pz, a, b):
    ax, az = a; bx, bz = b
    dx, dz = bx - ax, bz - az
    t = max(0.0, min(1.0, ((px - ax) * dx + (pz - az) * dz) / (dx * dx + dz * dz)))
    return math.hypot(px - (ax + t * dx), pz - (az + t * dz))

def cave_at(x, z):
    """-> (h1, h2, h3) for a cave-chunk vertex."""
    s = hill(x, z)
    rx0, rx1, rz, rhw = RAMP
    if rx0 <= x < rx1 and abs(z - rz) <= rhw:          # open ramp: no surface, no ceiling
        top = hill(rx0, rz)
        return NAN, NAN, top + (FLOOR - top) * (x - rx0) / (rx1 - rx0)
    if any(math.hypot(x - px, z - pz) < 0.9 for px, pz in PILLARS):
        return s, s - 0.3, s - 0.3
    # Open span at this point as (floor, ceiling) above the base floor — the
    # union of every tunnel and chamber covering it — or None in solid rock.
    lo = hi = None
    def open_span(f, c):
        nonlocal lo, hi
        lo = f if lo is None else min(lo, f)
        hi = c if hi is None else max(hi, c)
    near_tube = False
    if x >= rx1:   # not back past the mouth, beside the ramp's trench
        for path in (TUNNEL, BRANCH, SOUTH):
            d = min(seg_dist(x, z, a, b) for a, b in zip(path, path[1:]))
            near_tube = near_tube or d < TUNNEL_HW + 1.0
            if d < TUNNEL_HW:
                r = math.sqrt(1 - (d / TUNNEL_HW) ** 2)
                open_span(TUNNEL_UNDER * (1 - r), TUNNEL_UNDER + TUNNEL_OVER * r)
    for cx, cz, r in CHAMBERS:
        d = math.hypot(x - cx, z - cz)
        if d < r: open_span(0.0, 3.0 + 2.5 * math.sqrt(1 - (d / r) ** 2))
    if abs(z - rz) <= rhw and rx1 <= x < rx1 + 2.5:     # mouth: ceiling arches up to meet the surface
        t = (x - rx1) / 2.5                              # and the ramp's flat floor rounds into the tube's
        base = FLOOR + 0.15 * math.sin(x * 1.3 + z)
        ceil = (s - 0.01) * (1 - t) + (base + hi) * t
        return s, ceil, base + lo * t
    base = FLOOR + 0.15 * math.sin(x * 1.3 + z) + 0.1 * math.cos(z * 2.1)
    if lo is None:
        # Solid rock: collapsed layers. Just outside a tube they sit where its
        # floor and ceiling meet, so the tube closes there — up under the
        # surface, the cell between would open a thin crevice along each side.
        if near_tube: return s, base + TUNNEL_UNDER, base + TUNNEL_UNDER
        return s, s - 0.3, s - 0.3
    return s, min(base + hi, s - 0.5), base + lo

chunks = []
# town chunks: flat streets but for the temple's crypt, with the sewer in the
# cave layers under them. Off the tunnels the layers lie collapsed just under
# the ground, like the rat cave's solid rock.
def town(x, z):
    """-> (h1, h2, h3) for a town-chunk vertex."""
    if grate_hole(x, z):
        return NAN, NAN, sewer_floor(abs(z - GZ))
    if well_hole(x, z):
        d = abs(z - WZ)                                        # the shaft sits on the plaza tunnel
        return NAN, NAN, sewer_floor(d)
    cx0, cx1, cz0, cz1 = CRYPT
    s = CRYPT_FLOOR if cx0 <= x <= cx1 and cz0 <= z <= cz1 else 0.0
    d = min(seg_dist(x, z, a, b) for a, b in SEWER)
    if d > SEWER_HW: return s, s - 0.3, s - 0.3
    return s, sewer_ceiling(d), sewer_floor(d)

def town_chunk(ox, oz):
    H1, H2, H3 = [], [], []
    for vz in range(STRIDE):
        for vx in range(STRIDE):
            a, b, c = town(ox + vx * CS, oz + vz * CS)
            H1.append(a); H2.append(b); H3.append(c)
    return dict(type=2, biome=6, h1=H1, h2=H2, h3=H3)
chunks.append(town_chunk(0.0, 0.0))
# chunk 1: rat hill with the cave under it
H1, H2, H3 = [], [], []
for vz in range(STRIDE):
    for vx in range(STRIDE):
        a, b, c = cave_at(SPAN + vx * CS, vz * CS)
        H1.append(a); H2.append(b); H3.append(c)
chunks.append(dict(type=2, biome=7, h1=H1, h2=H2, h3=H3))
# chunks 2 and 3, the row south of those (z 64..128): the village's south end
# (and the sewer's grate), and the hill continuing (no cave) next to it
chunks.append(town_chunk(0.0, SPAN))
chunks.append(dict(type=1, biome=7, h2=[], h3=[],
                   h1=[hill(SPAN + vx * CS, SPAN + vz * CS) for vz in range(STRIDE) for vx in range(STRIDE)]))

# trees: some inside the walls, a little grove outside, rocks around the cave mouth
objs = []
def tree(x, z): objs.append(dict(type=0, x=x, z=z, radius=0.5, height=1.25))
def rock(x, z, r=1.0): objs.append(dict(type=1, x=x, z=z, radius=r, height=r * 1.2))
# (18.5, 22) and (32.5, 22) flank the temple steps; trees that stood at (44, 8),
# (52, 14), (19, 9) and (20, 22) had to make room for the buildings there.
for x, z in [(5, 6), (5, 15), (16, 9), (5, 52), (14, 57), (22, 58), (18.5, 22), (32.5, 22),
             (53, 24), (45, 58), (53, 56), (19, 47), (40, 39)]:
    tree(x, z)
for x, z in [(68, 10), (68, 50), (72, 20), (70, 42), (84, 52), (90, 8), (124, 46), (122, 12), (80, 58), (95, 46)]:
    tree(x, z)
for x, z, r in [(73.0, 28.5, 1.2), (73.5, 35.5, 1.0), (79.0, 28.6, 0.8), (82.0, 35.6, 0.9)]:
    rock(x, z, r)
# FrozenStarlight (talent tree) inside the spare cottage, against its west wall,
# on a wooden table (the client rests objects on a wall top under them)
SLX, SLZ = 26.8, 50.0
objs.append(dict(type=2, x=SLX, z=SLZ, radius=1.0, height=2.0))
box(SLX - 0.6, SLX + 0.6, SLZ - 0.6, SLZ + 0.6, 0.7, 0.8, t=WOOD)  # top
for sx in (-1, 1):                                                 # legs
    for sz in (-1, 1):
        lx, lz = SLX + sx * 0.5, SLZ + sz * 0.5
        box(lx - 0.07, lx + 0.07, lz - 0.07, lz + 0.07, 0.0, 0.7, t=WOOD)

# Walls stand on the terrain under their centre (base = ground + yo, in the
# client and the server alike), but everything above is laid out in absolute
# heights — so take that ground back out. Only matters over the crypt and the
# well; the rest of the town is flat at 0.
def ground(x, z):
    """Terrain height as WorldData._get_height_at / World::get_height_world
    sample it: the cell's two triangles, split along its anti-diagonal."""
    span = CC * CS
    ci, cj = int(x // span), int(z // span)
    lx, lz = (x - ci * span) / CS, (z - cj * span) / CS
    gx, gz = min(int(lx), CC - 1), min(int(lz), CC - 1)
    rx, rz = lx - gx, lz - gz
    h = chunks[cj * 2 + ci]['h1']
    h00, h10 = h[gz * STRIDE + gx], h[gz * STRIDE + gx + 1]
    h01, h11 = h[(gz + 1) * STRIDE + gx], h[(gz + 1) * STRIDE + gx + 1]
    if any(math.isnan(v) for v in (h00, h10, h01, h11)): return 0.0   # over a hole: both treat it as 0
    if rx + rz < 1: return h00 + (h10 - h00) * rx + (h01 - h00) * rz
    return h11 + (h01 - h11) * (1 - rx) + (h10 - h11) * (1 - rz)
for w in walls:
    w['yo'] -= ground(w['x'], w['z'])

src = gwl.load(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'rats.bin'))
biomes = src['biomes'] + [
    dict(id=6, name='Village', props=[]),
    dict(id=7, name='RatHill', props=[('res://assets/meshes/fern01.glb', 1.0), ('res://assets/meshes/fern02.glb', 1.0)]),
]
W = dict(cc=CC, cx=2, cz=2, cs=CS, ox=0, oz=0, chunks=chunks, objs=objs, water=water, biomes=biomes,
         ptypes=ptypes, props=props,
         otypes=[(0, 'res://assets/meshes/tree01.glb', 2.0), (1, 'res://assets/meshes/rock01.glb', 1.0),
                 (2, 'res://assets/meshes/frozenstarlight.glb', 1.0)],
         walls=walls,
         wtypes=[(0, 'res://assets/textures/rock01_RockMossy0033_1_350.jpg'), (2, 'res://assets/textures/rock01_RockMossy0033_1_350.jpg'),
                 (4, 'res://assets/textures/climbable_vine_wall.png'),
                 (5, 'res://assets/textures/marble_wall.png'), (6, 'res://assets/textures/black_marble_wall.png'),
                 (WOOD, 'res://assets/textures/wood_wall.png'),
                 (STONE_WALL, 'res://assets/textures/stone_wall.png')])

out = sys.argv[1] if len(sys.argv) > 1 else 'village.bin'
gwl.save(W, out)
gwl.load(out)   # sanity: parses back
print(f'{out}: {len(walls)} walls, {len(objs)} objects, {len(props)} torches')
