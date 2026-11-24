# The settings pictures: one still per place, in the doors' clay.
#
# Everything that makes the doors look the way they do (world, materials,
# geometry helpers, the three area lights, the camera and the close-up
# framing) is taken from scene3.py unchanged: this file executes its setup
# and its light and camera blocks, then builds one object at a door's slot
# and frames it the way CLOSE=1 frames a door. Nothing here animates.
#
#   FONT_DIR=<fonts> Blender -b -P places.py -- <name> <out.png> [samples]
#   names: general-1..3 operate-1..3 web-1..3 meetings-1..3 keys-1..3 observations-1..3
import bpy, bmesh, math, os, sys
from mathutils import Vector, Euler

HERE = os.path.dirname(os.path.abspath(__file__))
argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
NAME = argv[0] if argv else "general-1"
OUTFILE = argv[1] if len(argv) > 1 else "/tmp/place.png"
SAMPLES_ = int(argv[2]) if len(argv) > 2 else 48

src = open(os.path.join(HERE, "scene3.py")).read()
setup = src[:src.index("# ---------- motion ----------")]
rig = src[src.index("# ---------- lights ----------"):src.index("# ---------- rendering ----------")]
sys.argv = [sys.argv[0], "--", "pale", "/tmp", "1200", str(SAMPLES_)]
exec(setup, globals())

# ---------- extra shapes, in the same idiom as scene3's ----------
def disc(name, d, depth, material, parent, loc=(0, 0, 0), rot=(0, 0, 0), bevel=0.012):
    return rrect(name, d, d, depth, d / 2, material, parent, loc=loc, rot=rot, bevel=bevel)

def torus(name, R, r, material, parent, loc=(0, 0, 0), rot=(0, 0, 0), arc=360.0, a0=0.0, seg=72, ring=14):
    """A ring in the XZ plane (facing -Y), optionally only an arc of it."""
    bm = bmesh.new(); rows = []
    n = max(8, int(seg * arc / 360))
    for i in range(n + 1):
        a = math.radians(a0 + arc * i / n)
        c = Vector((R * math.cos(a), 0, R * math.sin(a))); out = Vector((math.cos(a), 0, math.sin(a)))
        rows.append([bm.verts.new(c + out * r * math.cos(2 * math.pi * j / ring) + Vector((0, r * math.sin(2 * math.pi * j / ring), 0))) for j in range(ring)])
    for i in range(n):
        for j in range(ring):
            bm.faces.new((rows[i][j], rows[i][(j + 1) % ring], rows[i + 1][(j + 1) % ring], rows[i + 1][j]))
    if arc < 360:
        for row in (rows[0], rows[-1]): bm.faces.new(row)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    me = bpy.data.meshes.new(name); bm.to_mesh(me); bm.free()
    ob = bpy.data.objects.new(name, me); ob.data.materials.append(material)
    for p in ob.data.polygons: p.use_smooth = True
    ob.location = loc; ob.rotation_euler = Euler([math.radians(a) for a in rot])
    return link(ob, parent)

def gear(name, r_out, r_root, teeth, depth, material, parent, loc=(0, 0, 0), rot=(0, 0, 0)):
    pts = []
    for i in range(teeth):
        for f, rr in ((0.0, r_root), (0.18, r_out), (0.5, r_out), (0.68, r_root)):
            a = 2 * math.pi * (i + f) / teeth
            pts.append((rr * math.cos(a), rr * math.sin(a)))
    bm = bmesh.new()
    face = bm.faces.new([bm.verts.new((x, depth / 2, z)) for x, z in pts])
    ext = bmesh.ops.extrude_face_region(bm, geom=[face])
    bmesh.ops.translate(bm, vec=(0, -depth, 0), verts=[g for g in ext["geom"] if isinstance(g, bmesh.types.BMVert)])
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    me = bpy.data.meshes.new(name); bm.to_mesh(me); bm.free()
    ob = bpy.data.objects.new(name, me); ob.data.materials.append(material)
    mod = ob.modifiers.new("b", "BEVEL"); mod.width = 0.02; mod.segments = 4; mod.limit_method = "ANGLE"; mod.angle_limit = math.radians(40)
    for p in ob.data.polygons: p.use_smooth = True
    try: ob.modifiers.new("n", "WEIGHTED_NORMAL")
    except Exception: pass
    ob.location = loc; ob.rotation_euler = Euler([math.radians(a) for a in rot])
    return link(ob, parent)

def bars(g, x, z, lengths, step=0.17, y=-0.028, h=0.055):
    for i, L in enumerate(lengths):
        rrect("bar", L, h, 0.012, h / 2, M["bar"], g, loc=(x + L / 2, y, z - i * step), bevel=0)

def chip(letter, parent, loc, s=0.13, orange=False):
    if orange: keycap(letter, parent, loc, s=s, material=M["orangeInk"], ink=M["orange"])
    else: keycap(letter, parent, loc, s=s)

def tab(parent, w, h, material, loc):
    rrect("tab", w, h, 0.056, 0.06, material, parent, loc=(loc[0], loc[1] - 0.006, loc[2]), bevel=0.012)

def sub(parent, loc, rot=(0, 0, 0)):
    e = empty("part", loc, rot); e.parent = parent; return e

# ---------- General ----------
def general_1(g):  # sliders
    rrect("panel", 2.1, 1.4, 0.05, 0.08, M["clay"], g, bevel=0.02)
    for i, (k, orange) in enumerate(((0.62, False), (0.28, True), (0.8, False))):
        z = 0.38 - i * 0.38
        rrect("track", 1.6, 0.05, 0.016, 0.025, M["bar"], g, loc=(0, -0.03, z), bevel=0)
        rrect("fill", 1.6 * k, 0.05, 0.02, 0.025, M["orange"] if orange else M["title"], g, loc=(-0.8 + 0.8 * k, -0.034, z), bevel=0)
        disc("knob", 0.22, 0.09, M["orange"] if orange else M["clay"], g, loc=(-0.8 + 1.6 * k, -0.07, z), bevel=0.03)

def general_2(g):  # one toggle
    rrect("panel", 2.1, 1.4, 0.05, 0.08, M["clay"], g, bevel=0.02)
    rrect("track", 1.1, 0.56, 0.08, 0.28, M["orange"], g, loc=(0.32, -0.05, 0.12), bevel=0.02)
    disc("knob", 0.46, 0.14, M["clay"], g, loc=(0.56, -0.12, 0.12), bevel=0.05)
    bars(g, -0.86, 0.22, (0.6, 0.42), step=0.17)
    rrect("track2", 0.62, 0.32, 0.06, 0.16, M["title"], g, loc=(0.56, -0.04, -0.4), bevel=0.015)
    disc("knob2", 0.25, 0.09, M["clay"], g, loc=(0.4, -0.08, -0.4), bevel=0.03)
    bars(g, -0.86, -0.36, (0.7,), step=0.17)

def general_3(g):  # gears
    gear("gear", 0.62, 0.5, 12, 0.14, M["clay"], g, loc=(-0.3, 0, 0.05), rot=(0, 7, 0))
    disc("hub", 0.34, 0.18, M["orange"], g, loc=(-0.3, -0.03, 0.05), bevel=0.03)
    gear("gear2", 0.38, 0.3, 9, 0.12, M["title"], g, loc=(0.62, 0.06, -0.42), rot=(0, -12, 0))
    disc("hub2", 0.18, 0.15, M["clay"], g, loc=(0.62, 0.03, -0.42), bevel=0.02)

# ---------- Operate ----------
def operate_1(g):  # a button wearing its letter
    rrect("panel", 2.1, 1.4, 0.05, 0.08, M["clay"], g, bevel=0.02)
    bars(g, -0.86, 0.42, (1.3, 0.9), step=0.17)
    rrect("button", 0.9, 0.34, 0.06, 0.1, M["title"], g, loc=(-0.3, -0.04, -0.2), bevel=0.015)
    text("Send", "sans", 0.13, M["ink"], g, (-0.3, -0.09, -0.2), align="CENTER")
    c = sub(g, (0.24, -0.26, 0.02), (6, 0, -10))
    chip("F", c, (0, 0, 0), s=0.26, orange=True)

def operate_2(g):  # controls, each with a letter
    rrect("panel", 2.1, 1.4, 0.05, 0.08, M["clay"], g, bevel=0.02)
    # checkbox
    rrect("box", 0.2, 0.2, 0.04, 0.04, M["title"], g, loc=(-0.72, -0.03, 0.36), bevel=0.008)
    rrect("tick", 0.11, 0.035, 0.02, 0.017, M["ink"], g, loc=(-0.74, -0.06, 0.34), rot=(0, -45, 0), bevel=0)
    rrect("tick2", 0.06, 0.035, 0.02, 0.017, M["ink"], g, loc=(-0.78, -0.06, 0.34), rot=(0, 45, 0), bevel=0)
    bars(g, -0.52, 0.36, (0.6,))
    chip("A", g, (0.62, -0.06, 0.36), s=0.15)
    # toggle
    rrect("tg", 0.34, 0.19, 0.05, 0.095, M["title"], g, loc=(-0.65, -0.03, 0.0), bevel=0.01)
    disc("tk", 0.15, 0.07, M["clay"], g, loc=(-0.72, -0.07, 0.0), bevel=0.02)
    bars(g, -0.4, 0.0, (0.5,))
    chip("S", g, (0.62, -0.06, 0.0), s=0.15, orange=True)
    # button
    rrect("bt", 0.62, 0.22, 0.05, 0.07, M["title"], g, loc=(-0.52, -0.03, -0.38), bevel=0.012)
    text("Save", "sans", 0.09, M["ink"], g, (-0.52, -0.06, -0.38), align="CENTER")
    chip("D", g, (0.62, -0.06, -0.38), s=0.15)

def operate_3(g):  # a selection in text
    rrect("sheet", 2.1, 1.45, 0.05, 0.05, M["clay"], g, bevel=0.02)
    X = -0.86
    # The word's place, measured the way door_write measures the typo:
    # a trailing space has no ink, so the word is found from the line's end.
    s0, s1 = extent("Move the review", "sans", 0.17, g); w0, w1 = extent("review", "sans", 0.17, g)
    wb = w1 - w0; xa = X + s1 - wb
    text("Move the", "sans", 0.17, M["ink"], g, (X, -0.03, 0.36))
    rrect("sel", wb + 0.05, 0.25, 0.012, 0.04, M["orange"], g, loc=(xa + wb / 2, -0.022, 0.36), bevel=0)
    text("review", "sans", 0.17, M["orangeInk"], g, (xa - w0, -0.034, 0.36))
    text("to Thursday", "sans", 0.17, M["ink"], g, (X, -0.03, 0.1))
    rrect("caret", 0.016, 0.24, 0.012, 0.008, M["ink"], g, loc=(xa + wb + 0.06, -0.04, 0.36), bevel=0)
    bars(g, X, -0.2, (1.5, 1.1, 1.3), step=0.17)

# ---------- Web ----------
def web_1(g):  # an address and the profile it opens in
    w = sub(g, (0.2, 0.3, 0.28), (0, 3, 0))
    rrect("win", 2.0, 1.25, 0.05, 0.07, M["clay"], w, bevel=0.018)
    bars(w, -0.8, -0.05, (1.4, 1.1, 1.25), step=0.17)
    rrect("bar", 2.3, 0.4, 0.08, 0.2, M["clay"], g, loc=(0, -0.2, 0.42), bevel=0.02)
    text("github.com", "mono", 0.13, M["ink"], g, (-0.95, -0.245, 0.42))
    rrect("tag", 0.56, 0.24, 0.05, 0.12, M["orange"], g, loc=(0.74, -0.255, 0.42), bevel=0.012)
    text("Work", "sans", 0.1, M["orangeInk"], g, (0.74, -0.285, 0.42), align="CENTER")

def web_2(g):  # a globe and a route
    sphere(0.72, M["clay"], g, (0, 0, 0))
    for tilt in (0, 60, 120):
        torus("meridian", 0.725, 0.012, M["bar"], g, rot=(0, 0, tilt))
    for z in (-0.36, 0.0, 0.36):
        R = math.sqrt(max(0.0, 0.725 ** 2 - z * z))
        torus("parallel", R, 0.012, M["bar"], g, loc=(0, 0, z), rot=(90, 0, 0))
    torus("route", 0.92, 0.03, M["orange"], g, rot=(22, 0, -18), arc=150, a0=20)
    sphere(0.06, M["orange"], g, (0.92 * math.cos(math.radians(20)), -0.1, 0.92 * math.sin(math.radians(20)) * 0.9))

def web_3(g):  # windows and their tabs
    for i, (dx, dy, dz, ry, active) in enumerate(((-0.3, 0.3, 0.2, -4, None), (0.2, 0.0, -0.1, 3, 1))):
        w = sub(g, (dx, dy, dz), (0, ry, 0))
        rrect("win", 1.9, 1.15, 0.05, 0.07, M["clay"], w, bevel=0.018)
        for j in range(3):
            m = M["orange"] if active == j else M["title"]
            tab(w, 0.5, 0.2, m, (-0.62 + j * 0.56, -0.012 if active == j else 0.0, 0.52))
            if active == j: text("Docs", "sans", 0.075, M["orangeInk"], w, (-0.62 + j * 0.56, -0.05, 0.52), align="CENTER")
        bars(w, -0.78, 0.22, (1.3, 1.0, 1.15, 0.8), step=0.17)

# ---------- Meetings ----------
def meetings_1(g):  # a day and one block in it
    rrect("card", 1.8, 1.55, 0.05, 0.08, M["clay"], g, bevel=0.02)
    rrect("head", 1.8, 0.3, 0.056, 0.08, M["title"], g, loc=(0, -0.004, 0.625), bevel=0.012)
    rrect("headfix", 1.8, 0.12, 0.057, 0.0, M["title"], g, loc=(0, -0.004, 0.53), bevel=0)
    text("Thursday", "sans", 0.11, M["ink"], g, (-0.75, -0.04, 0.625))
    for i in range(5):
        z = 0.32 - i * 0.24
        text(f"{9 + i}", "mono", 0.07, M["bar"], g, (-0.78, -0.03, z))
        rrect("rule", 1.38, 0.008, 0.01, 0.004, M["bar"], g, loc=(0.12, -0.03, z), bevel=0)
    rrect("block", 1.2, 0.36, 0.05, 0.06, M["orange"], g, loc=(0.16, -0.06, 0.2), bevel=0.012)
    text("Standup", "sans", 0.09, M["orangeInk"], g, (-0.36, -0.09, 0.24))
    text("10:00", "mono", 0.065, M["orangeInk"], g, (-0.36, -0.09, 0.12))

def meetings_2(g):  # a clock before a calendar
    c = sub(g, (0.35, 0.35, 0.15), (0, 4, 0))
    rrect("cal", 1.4, 1.3, 0.05, 0.08, M["clay"], c, bevel=0.02)
    rrect("head", 1.4, 0.26, 0.056, 0.08, M["title"], c, loc=(0, -0.004, 0.52), bevel=0.012)
    for r in range(3):
        for k in range(4):
            rrect("day", 0.22, 0.18, 0.012, 0.03, M["bar"], c, loc=(-0.45 + k * 0.3, -0.028, 0.2 - r * 0.28), bevel=0)
    disc("face", 1.1, 0.12, M["clay"], g, loc=(-0.38, -0.25, -0.12), bevel=0.04)
    for i in range(12):
        a = math.radians(90 - i * 30)
        L = 0.09 if i % 3 == 0 else 0.05
        rrect("tick", 0.022, L, 0.012, 0.011, M["bar"], g, loc=(-0.38 + 0.44 * math.cos(a), -0.31, -0.12 + 0.44 * math.sin(a)), rot=(0, -(90 - i * 30) + 90, 0), bevel=0)
    rrect("hour", 0.04, 0.28, 0.02, 0.02, M["ink"], g, loc=(-0.38 + 0.1, -0.33, -0.12 + 0.07), rot=(0, 55, 0), bevel=0)
    rrect("minute", 0.03, 0.42, 0.02, 0.015, M["orange"], g, loc=(-0.38, -0.335, -0.12 + 0.19), rot=(0, 0, 0), bevel=0)
    disc("pin", 0.07, 0.04, M["ink"], g, loc=(-0.38, -0.345, -0.12), bevel=0.01)

def meetings_3(g):  # a camera, on
    rrect("body", 1.5, 1.0, 0.5, 0.18, M["clay"], g, loc=(-0.2, 0, 0), bevel=0.04)
    disc("lensring", 0.62, 0.14, M["title"], g, loc=(-0.2, -0.3, 0), bevel=0.03)
    disc("lens", 0.4, 0.1, M["cap"], g, loc=(-0.2, -0.36, 0), bevel=0.03)
    disc("glint", 0.1, 0.02, M["capink"], g, loc=(-0.28, -0.42, 0.08), bevel=0)
    rrect("wing", 0.5, 0.7, 0.4, 0.12, M["clay"], g, loc=(0.82, 0.02, 0), rot=(0, 0, 0), bevel=0.04)
    sphere(0.065, M["orange"], g, (0.3, -0.27, 0.34))

# ---------- Keys ----------
def keys_1(g):  # one key
    rrect("base", 1.3, 1.15, 0.36, 0.2, M["clay"], g, bevel=0.05)
    rrect("top", 1.04, 0.88, 0.1, 0.17, M["clay"], g, loc=(0, -0.22, 0.04), bevel=0.04)
    text("esc", "sans", 0.2, M["orange"], g, (-0.36, -0.275, 0.22))

def keys_2(g):  # a split board
    for side, ry in ((-1, 10), (1, -10)):
        h = sub(g, (side * 0.62, 0, 0), (0, ry * side * -1, 0))
        rrect("half", 1.05, 0.78, 0.08, 0.1, M["clay"], h, bevel=0.025)
        for r in range(3):
            for k in range(5):
                orange = side == 1 and r == 2 and k == 0
                x = -0.4 + k * 0.2; z = 0.24 - r * 0.2
                rrect("k", 0.16, 0.16, 0.05, 0.035, M["orange"] if orange else M["cap"], h, loc=(x, -0.06, z), bevel=0.01)

def keys_3(g):  # a row, one modifier
    rrect("strip", 2.4, 0.6, 0.06, 0.1, M["clay"], g, bevel=0.02)
    xs = [(-0.92, 0.32, "A"), (-0.56, 0.32, "S"), (-0.2, 0.32, "D"), (0.16, 0.32, "F")]
    for x, w, L in xs:
        rrect("cap", w, 0.32, 0.06, 0.07, M["cap"], g, loc=(x, -0.06, 0), bevel=0.012)
        text(L, "mono", 0.13, M["capink"], g, (x, -0.096, 0), align="CENTER")
    rrect("shift", 0.62, 0.32, 0.06, 0.07, M["orange"], g, loc=(0.71, -0.06, 0), bevel=0.012)
    text("shift", "sans", 0.1, M["orangeInk"], g, (0.71, -0.096, 0), align="CENTER")

# ---------- Observations ----------
def observations_1(g):  # a logbook, open
    # Two leaves meeting at the spine, their outer edges toward you.
    for side in (-1, 1):
        p = sub(g, (side * 0.49, 0.0, 0), (0, 0, -side * 18))
        rrect("page", 1.0, 1.36, 0.04, 0.06, M["clay"], p, bevel=0.015)
        bars(p, -0.36, 0.42, (0.72, 0.56, 0.66, 0.48, 0.62), step=0.16, h=0.04)
    rrect("ribbon", 0.08, 0.95, 0.016, 0.02, M["orange"], g, loc=(0.06, 0.1, -0.42), bevel=0)

def observations_2(g):  # a rhythm
    rrect("card", 2.1, 1.3, 0.05, 0.08, M["clay"], g, bevel=0.02)
    text("Tuesday", "sans", 0.11, M["bar"], g, (-0.86, -0.03, 0.44))
    hs = [0.22, 0.38, 0.3, 0.52, 0.44, 0.6, 0.35, 0.48, 0.26, 0.4, 0.56, 0.32, 0.2]
    for i, h in enumerate(hs):
        rrect("b", 0.075, h, 0.02, 0.0375, M["orange"] if i == 5 else M["bar"], g, loc=(-0.78 + i * 0.13, -0.034, -0.42 + h / 2), bevel=0)

def observations_3(g):  # a lens over the page
    rrect("card", 2.1, 1.4, 0.05, 0.08, M["clay"], g, bevel=0.02)
    bars(g, -0.86, 0.42, (1.5, 1.2, 1.4, 0.9, 1.3), step=0.19)
    torus("rim", 0.36, 0.045, M["orange"], g, loc=(0.25, -0.3, 0.05), rot=(0, 0, 0))
    rrect("handle", 0.09, 0.6, 0.08, 0.04, M["cap"], g, loc=(0.25 + 0.36 + 0.18, -0.3, 0.05 - 0.36 - 0.18), rot=(0, -45, 0), bevel=0.02)


# ---------- round two: sculptural, same vocabulary ----------
def tube(name, pts, r, material, parent, smooth=True):
    """A rounded rod along points given in the group's frame (x, y, z)."""
    cu = bpy.data.curves.new(name, "CURVE"); cu.dimensions = "3D"
    cu.bevel_depth = r; cu.bevel_resolution = 6; cu.use_fill_caps = True
    if smooth:
        sp = cu.splines.new("BEZIER"); sp.bezier_points.add(len(pts) - 1)
        for bp, q in zip(sp.bezier_points, pts):
            bp.co = q; bp.handle_left_type = bp.handle_right_type = "AUTO"
    else:
        sp = cu.splines.new("POLY"); sp.points.add(len(pts) - 1)
        for pt, q in zip(sp.points, pts): pt.co = (q[0], q[1], q[2], 1)
    ob = bpy.data.objects.new(name, cu); ob.data.materials.append(material)
    return link(ob, parent)

def curved(name, w, h, sag, thick, material, parent, loc=(0, 0, 0), rot=(0, 0, 0), nx=24):
    """A page that curls: a sheet in XZ whose depth follows a sine across its width."""
    bm = bmesh.new(); rows = []
    for i in range(nx + 1):
        x = -w / 2 + w * i / nx
        y = -sag * math.sin(math.pi * i / nx)
        rows.append((bm.verts.new((x, y, -h / 2)), bm.verts.new((x, y, h / 2))))
    for i in range(nx):
        bm.faces.new((rows[i][0], rows[i + 1][0], rows[i + 1][1], rows[i][1]))
    me = bpy.data.meshes.new(name); bm.to_mesh(me); bm.free()
    ob = bpy.data.objects.new(name, me); ob.data.materials.append(material)
    sol = ob.modifiers.new("s", "SOLIDIFY"); sol.thickness = thick; sol.offset = 1
    bev = ob.modifiers.new("b", "BEVEL"); bev.width = thick * 0.4; bev.segments = 3; bev.limit_method = "ANGLE"
    for f in ob.data.polygons: f.use_smooth = True
    ob.location = loc; ob.rotation_euler = Euler([math.radians(a) for a in rot])
    return link(ob, parent)

def wedge(name, r, a0, a1, depth, material, parent, loc=(0, 0, 0)):
    pts = [(0.0, 0.0)] + [(r * math.cos(math.radians(a0 + (a1 - a0) * i / 24)), r * math.sin(math.radians(a0 + (a1 - a0) * i / 24))) for i in range(25)]
    bm = bmesh.new()
    face = bm.faces.new([bm.verts.new((x, depth / 2, z)) for x, z in pts])
    ext = bmesh.ops.extrude_face_region(bm, geom=[face])
    bmesh.ops.translate(bm, vec=(0, -depth, 0), verts=[g for g in ext["geom"] if isinstance(g, bmesh.types.BMVert)])
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    me = bpy.data.meshes.new(name); bm.to_mesh(me); bm.free()
    ob = bpy.data.objects.new(name, me); ob.data.materials.append(material)
    ob.location = loc
    return link(ob, parent)

def operate_4(g):  # the controls themselves, floating, each wearing its letter
    a = sub(g, (-0.78, 0.25, 0.42), (0, -8, 0))
    rrect("box", 0.5, 0.5, 0.16, 0.1, M["clay"], a, bevel=0.03)
    rrect("tick", 0.26, 0.07, 0.04, 0.035, M["ink"], a, loc=(0.04, -0.1, -0.02), rot=(0, -48, 0), bevel=0.01)
    rrect("tick2", 0.14, 0.07, 0.04, 0.035, M["ink"], a, loc=(-0.1, -0.1, -0.05), rot=(0, 42, 0), bevel=0.01)
    chip("A", a, (0.3, -0.16, 0.28), s=0.16)
    b = sub(g, (0.05, 0.0, 0.05), (0, 6, 0))
    rrect("track", 0.9, 0.46, 0.16, 0.23, M["clay"], b, bevel=0.03)
    disc("knob", 0.36, 0.2, M["title"], b, loc=(0.2, -0.12, 0), bevel=0.05)
    chip("S", b, (0.5, -0.2, 0.3), s=0.18, orange=True)
    c = sub(g, (0.62, -0.25, -0.42), (0, -4, 0))
    rrect("button", 0.9, 0.36, 0.16, 0.12, M["clay"], c, bevel=0.03)
    text("Save", "sans", 0.13, M["ink"], c, (0, -0.1, 0), align="CENTER")
    chip("D", c, (0.48, -0.16, 0.22), s=0.16)

def operate_5(g):  # a panel, its letters lifted off it toward you
    rrect("panel", 2.1, 1.4, 0.06, 0.08, M["clay"], g, bevel=0.02)
    rrect("box", 0.22, 0.22, 0.05, 0.05, M["title"], g, loc=(-0.7, -0.035, 0.36), bevel=0.01)
    bars(g, -0.5, 0.36, (0.55,))
    rrect("tg", 0.4, 0.22, 0.05, 0.11, M["title"], g, loc=(-0.6, -0.035, 0.0), bevel=0.012)
    disc("tk", 0.17, 0.08, M["clay"], g, loc=(-0.68, -0.07, 0.0), bevel=0.02)
    bars(g, -0.32, 0.0, (0.45,))
    rrect("bt", 0.66, 0.24, 0.06, 0.08, M["title"], g, loc=(-0.48, -0.035, -0.4), bevel=0.012)
    text("Save", "sans", 0.09, M["ink"], g, (-0.48, -0.075, -0.4), align="CENTER")
    for (x, z, L, lift, o) in ((-0.82, 0.5, "A", 0.22, False), (-0.36, 0.16, "S", 0.48, True), (-0.12, -0.26, "D", 0.32, False)):
        c = sub(g, (x, -lift, z), (8, 0, -6))
        chip(L, c, (0, 0, 0), s=0.2 if o else 0.15, orange=o)

def meetings_4(g):  # a clock with a bezel, before a bound calendar
    c = sub(g, (0.4, 0.4, 0.2), (0, 5, 0))
    rrect("cal", 1.45, 1.35, 0.07, 0.08, M["clay"], c, bevel=0.02)
    rrect("head", 1.45, 0.28, 0.076, 0.08, M["title"], c, loc=(0, -0.004, 0.535), bevel=0.012)
    for x in (-0.42, 0.42):
        torus("ring", 0.09, 0.022, M["cap"], c, loc=(x, -0.02, 0.7), rot=(0, 0, 90))
    for r in range(3):
        for k in range(4):
            orange = (r, k) == (1, 2)
            rrect("day", 0.24, 0.2, 0.03 if orange else 0.012, 0.03, M["orange"] if orange else M["bar"], c, loc=(-0.47 + k * 0.31, -0.04 if orange else -0.03, 0.2 - r * 0.29), bevel=0.006 if orange else 0)
    disc("face", 1.1, 0.16, M["clay"], g, loc=(-0.4, -0.28, -0.14), bevel=0.04)
    torus("bezel", 0.56, 0.05, M["clay"], g, loc=(-0.4, -0.37, -0.14))
    for i in range(12):
        a = math.radians(90 - i * 30); L = 0.09 if i % 3 == 0 else 0.05
        rrect("tick", 0.024, L, 0.012, 0.012, M["bar"], g, loc=(-0.4 + 0.42 * math.cos(a), -0.37, -0.14 + 0.42 * math.sin(a)), rot=(0, -(90 - i * 30) + 90, 0), bevel=0)
    rrect("hour", 0.05, 0.26, 0.025, 0.025, M["ink"], g, loc=(-0.4 + 0.1, -0.39, -0.14 + 0.07), rot=(0, 55, 0), bevel=0)
    rrect("minute", 0.036, 0.4, 0.025, 0.018, M["orange"], g, loc=(-0.4, -0.40, -0.14 + 0.18), bevel=0)
    sphere(0.05, M["ink"], g, (-0.4, -0.42, -0.14))

def meetings_5(g):  # the day, its meeting lifted off it
    rrect("card", 1.8, 1.55, 0.07, 0.08, M["clay"], g, bevel=0.02)
    rrect("head", 1.8, 0.3, 0.076, 0.08, M["title"], g, loc=(0, -0.004, 0.625), bevel=0.012)
    text("Thursday", "sans", 0.11, M["ink"], g, (-0.75, -0.05, 0.625))
    for i in range(5):
        z = 0.32 - i * 0.24
        text(f"{9 + i}", "mono", 0.07, M["bar"], g, (-0.78, -0.04, z))
        rrect("rule", 1.38, 0.008, 0.01, 0.004, M["bar"], g, loc=(0.12, -0.04, z), bevel=0)
    rrect("slot", 1.2, 0.34, 0.01, 0.06, M["bar"], g, loc=(0.16, -0.035, 0.2), bevel=0)
    b = sub(g, (0.3, -0.42, 0.42), (-8, 0, -6))
    rrect("block", 1.2, 0.36, 0.07, 0.07, M["orange"], b, bevel=0.015)
    text("Standup", "sans", 0.09, M["orangeInk"], b, (-0.5, -0.04, 0.04))
    text("10:00", "mono", 0.065, M["orangeInk"], b, (-0.5, -0.04, -0.08))
    disc("clock", 0.5, 0.1, M["clay"], g, loc=(0.72, -0.18, -0.55), bevel=0.03)
    rrect("h", 0.03, 0.14, 0.02, 0.015, M["ink"], g, loc=(0.75, -0.24, -0.52), rot=(0, 50, 0), bevel=0)
    rrect("m", 0.025, 0.2, 0.02, 0.012, M["orange"], g, loc=(0.72, -0.245, -0.46), bevel=0)

LEGENDS = ("QWERT", "ASDFG", "ZXCVB"), ("YUIOP", "HJKL;", "NM,./")
def half(g, side, loc, rot, orange_thumb=False, lifted=None):
    h = sub(g, loc, rot)
    rrect("case", 1.12, 0.84, 0.16, 0.12, M["clay"], h, bevel=0.035)
    rows = LEGENDS[0 if side < 0 else 1]
    for r in range(3):
        for k in range(5):
            x = -0.42 + k * 0.21; z = 0.25 - r * 0.21
            if lifted == (r, k):
                continue
            keycap(rows[r][k], h, (x, -0.1, z), s=0.17)
    # The thumb cluster sits on its own plate, tucked under the inner corner.
    rrect("thumbs", 0.6, 0.3, 0.14, 0.1, M["clay"], h, loc=(0.31 if side < 0 else -0.31, 0.01, -0.5), bevel=0.03)
    for k in range(2):
        x = (0.2 if side < 0 else -0.2) + (k * 0.22 if side < 0 else -k * 0.22)
        o = orange_thumb and k == 0
        keycap("", h, (x, -0.1, -0.5), s=0.17, material=M["orange"] if o else None)
    return h

def keys_4(g):  # a tented split board, an orange thumb key
    half(g, -1, (-0.66, 0.05, 0.02), (0, 9, 18))
    half(g, 1, (0.66, 0.05, 0.02), (0, -9, -18), orange_thumb=True)

def keys_5(g):  # one key lifted out of its board
    half(g, -1, (-0.64, 0.1, 0), (0, 6, 14))
    h = half(g, 1, (0.64, 0.1, 0), (0, -6, -14), lifted=(1, 1))
    hole = (-0.42 + 1 * 0.21, -0.07, 0.25 - 0.21)
    rrect("socket", 0.15, 0.13, 0.02, 0.03, M["ink"], h, loc=hole, bevel=0)
    k = sub(h, (hole[0], -0.55, hole[2] + 0.12), (14, 8, -10))
    keycap("J", k, (0, 0, 0), s=0.24, material=M["orange"], ink=M["orangeInk"])

def observations_4(g):  # a pulse drawn across the logbook's pages
    for i, (dx, dy, dz, ry) in enumerate(((-0.35, 0.3, 0.15, -10), (0.0, 0.15, 0.0, -2), (0.35, 0.0, -0.15, 7))):
        c = sub(g, (dx, dy, dz), (0, ry, 0))
        rrect("page", 1.3, 0.92, 0.04, 0.07, M["clay"], c, bevel=0.015)
        bars(c, -0.5, 0.28, (0.8, 0.6, 0.7), step=0.15, h=0.045)
    pts = [(-1.15, -0.32, -0.05), (-0.55, -0.32, -0.05), (-0.42, -0.34, 0.25), (-0.28, -0.36, -0.42), (-0.12, -0.36, 0.5), (0.04, -0.34, -0.2), (0.16, -0.32, -0.05), (1.15, -0.32, -0.05)]
    tube("pulse", pts, 0.035, M["orange"], g, smooth=False)

def observations_5(g):  # a scope: rings, a sweep, one blip
    disc("base", 1.7, 0.18, M["clay"], g, bevel=0.05)
    for r in (0.28, 0.52, 0.76):
        torus("ring", r, 0.014, M["bar"], g, loc=(0, -0.1, 0))
    wedge("sweep", 0.8, 50, 95, 0.02, M["title"], g, loc=(0, -0.095, 0))
    sphere(0.04, M["ink"], g, (0, -0.11, 0))
    sphere(0.06, M["orange"], g, (0.52 * math.cos(math.radians(70)), -0.14, 0.52 * math.sin(math.radians(70))))
    sphere(0.035, M["bar"], g, (-0.4, -0.11, -0.3))
    sphere(0.03, M["bar"], g, (0.55, -0.11, -0.35))

def observations_6(g):  # keys pressed to different depths: a rhythm of the hands
    rrect("deck", 2.4, 0.62, 0.14, 0.12, M["clay"], g, bevel=0.03)
    for i in range(9):
        press = 0.5 + 0.5 * math.sin(i * 0.9 + 0.4)
        o = i == 5
        x = -1.0 + i * 0.25
        keycap("", g, (x, -0.13 + 0.07 * press, 0.0), s=0.2, material=M["orange"] if o else None)
        h = 0.08 + 0.32 * (1 - press)
        rrect("hold", 0.06, h, 0.06, 0.03, M["orange"] if o else M["bar"], g, loc=(x, 0.0, 0.3 + h / 2), bevel=0.01)

def ribbon(name, path, width, material, parent, thick=0.008, fork=0.06):
    """A flat bookmark ribbon lying along `path` (in the page's plane, facing -Y),
    its free end cut into a fork."""
    bm = bmesh.new(); left = []; right = []
    P = [Vector(q) for q in path]
    for i, q in enumerate(P):
        t = (P[min(i + 1, len(P) - 1)] - P[max(i - 1, 0)]).normalized()
        side = t.cross(Vector((0, 1, 0))).normalized() * (width / 2)
        left.append(bm.verts.new(q + side)); right.append(bm.verts.new(q - side))
    tip = P[-1] + (P[-1] - P[-2]).normalized() * fork
    notch = bm.verts.new(P[-1] - (P[-1] - P[-2]).normalized() * fork * 0.4)
    lt = bm.verts.new(tip + (left[-1].co - P[-1])); rt = bm.verts.new(tip + (right[-1].co - P[-1]))
    for i in range(len(P) - 1):
        bm.faces.new((left[i], right[i], right[i + 1], left[i + 1]))
    bm.faces.new((left[-1], right[-1], notch)); bm.faces.new((left[-1], notch, lt)); bm.faces.new((right[-1], rt, notch))
    me = bpy.data.meshes.new(name); bm.to_mesh(me); bm.free()
    ob = bpy.data.objects.new(name, me); ob.data.materials.append(material)
    sol = ob.modifiers.new("s", "SOLIDIFY"); sol.thickness = thick
    for f in ob.data.polygons: f.use_smooth = True
    return link(ob, parent)

def prism(name, r1, r2, length, segments, material, parent, x0, bevel=0.006, turn=0.0):
    """A solid of revolution (or a prism) along +X from x0, `length` long."""
    bm = bmesh.new()
    bmesh.ops.create_cone(bm, cap_ends=True, cap_tris=False, segments=segments, radius1=r1, radius2=max(r2, 1e-4), depth=length)
    bmesh.ops.rotate(bm, verts=bm.verts, cent=(0, 0, 0), matrix=Euler((0, 0, math.radians(turn))).to_matrix())
    bmesh.ops.rotate(bm, verts=bm.verts, cent=(0, 0, 0), matrix=Euler((0, math.radians(90), 0)).to_matrix())
    bmesh.ops.translate(bm, verts=bm.verts, vec=(x0 + length / 2, 0, 0))
    me = bpy.data.meshes.new(name); bm.to_mesh(me); bm.free()
    ob = bpy.data.objects.new(name, me); ob.data.materials.append(material)
    if bevel:
        mod = ob.modifiers.new("b", "BEVEL"); mod.width = bevel; mod.segments = 3; mod.limit_method = "ANGLE"; mod.angle_limit = math.radians(35)
    for f in ob.data.polygons: f.use_smooth = segments > 8
    return link(ob, parent)

M["wood"] = mat("wood", "#E8D3B8", 0.7)

def pencil(parent, length=1.15, r=0.05):
    tipL, leadL, ferL, erL = 0.17, 0.045, 0.09, 0.08
    body = length - tipL - ferL - erL
    x = -length / 2
    prism("eraser", r * 0.92, r * 0.92, erL, 24, M["title"], parent, x, bevel=0.012); x += erL
    prism("ferrule", r * 1.04, r * 1.04, ferL, 24, M["bar"], parent, x, bevel=0.004)
    for k in (0.25, 0.5, 0.75):
        prism("ridge", r * 1.07, r * 1.07, 0.008, 24, M["bar"], parent, x + ferL * k - 0.004, bevel=0)
    x += ferL
    prism("body", r, r, body, 6, M["clay"], parent, x, bevel=0.008, turn=30); x += body
    prism("wood", r, 0.016, tipL - leadL, 6, M["wood"], parent, x, bevel=0.0, turn=30); x += tipL - leadL
    prism("lead", 0.016, 0.002, leadL, 12, M["ink"], parent, x, bevel=0.0)

def observations_7(g):  # a logbook, open: its pages curling, a ribbon, a pencil
    rrect("cover", 2.32, 1.52, 0.07, 0.08, M["title"], g, loc=(0, 0.16, 0), bevel=0.022)
    for side in (-1, 1):
        # A few leaves under each page, so the book has a thickness.
        for k, (dy, inset) in enumerate(((0.1, 0.03), (0.06, 0.018), (0.0, 0.0))):
            p = sub(g, (side * 0.555, dy, 0), (0, 0, 0))
            curved("leaf", 1.07 - inset, 1.38 - inset, 0.05, 0.03 if k < 2 else 0.05, M["clay"] if k == 2 else M["bar"] if k == 0 else M["title"], p)
            if k == 2:
                bars(p, -0.38, 0.42, (0.7, 0.54, 0.64, 0.46, 0.6, 0.5), step=0.15, h=0.036, y=-0.125)
    # The ribbon lies down the gutter, then falls over the bottom edge.
    path = [(0.03, -0.06, 0.66), (0.035, -0.07, 0.3), (0.045, -0.075, -0.1), (0.06, -0.08, -0.5),
            (0.085, -0.12, -0.69), (0.14, -0.19, -0.78), (0.23, -0.23, -0.86)]
    ribbon("ribbon", path, 0.085, M["orange"], g)
    q = sub(g, (0.6, -0.22, -0.18), (0, 24, 0))
    pencil(q, length=1.3, r=0.056)

BUILDERS = {k.replace("_", "-"): v for k, v in list(globals().items())
            if callable(v) and k.split("_")[0] in ("general", "operate", "web", "meetings", "keys", "observations") and k.split("_")[-1].isdigit()}
SLOT_OF = {"general": "write", "operate": "move", "web": "keep", "meetings": "speak", "keys": "write", "observations": "move"}
SLOTS = {
    "write": ((-3.55, 0.7, 1.85), (12, 0, 30), 1.1),
    "move": ((3.55, 1.0, 1.95), (10, 0, -32), 1.1),
    "keep": ((-3.7, -0.9, -2.05), (-16, 6, 26), 1.1),
    "speak": ((3.55, -0.7, -2.05), (-12, -4, -26), 1.0),
}
loc, rot, s = SLOTS[SLOT_OF[NAME.split("-")[0]]]
g = empty("place", loc, rot); g.scale = (s, s, s)
BUILDERS[NAME](g)

exec(rig, globals())

# ---------- framing: CLOSE=1's portrait, for a still ----------
from bpy_extras.object_utils import world_to_camera_view
scene.render.film_transparent = True
cam.dof.use_dof = False
scene.render.resolution_x, scene.render.resolution_y = 1200, 900
bpy.context.view_layer.update()
meshes = [o for o in g.children_recursive if o.type in ("MESH", "FONT", "CURVE")]
c0 = Vector((0, 0, 0)); n = 0
for ob in meshes:
    for cc in ob.bound_box: c0 += ob.matrix_world @ Vector(cc); n += 1
c0 /= n
cob.rotation_euler = (c0 - cob.location).to_track_quat("-Z", "Y").to_euler()
cam.lens = 50
def frame():
    bpy.context.view_layer.update()
    x0 = y0 = 1e9; x1 = y1 = -1e9
    for ob in meshes:
        for cc in ob.bound_box:
            v = world_to_camera_view(scene, cob, ob.matrix_world @ Vector(cc))
            x0 = min(x0, v.x); x1 = max(x1, v.x); y0 = min(y0, v.y); y1 = max(y1, v.y)
    return x0, x1, y0, y1
aspect = scene.render.resolution_y / scene.render.resolution_x
for _ in range(4):
    x0, x1, y0, y1 = frame()
    cam.lens *= 0.84 / max(x1 - x0, (y1 - y0))
    x0, x1, y0, y1 = frame()
    cam.shift_x += (x0 + x1) / 2 - 0.5
    cam.shift_y += ((y0 + y1) / 2 - 0.5) * aspect
print("FRAMED", NAME, frame(), cam.lens)
for ob in bpy.data.objects:
    if ob.type in ("MESH", "FONT", "CURVE") and ob not in meshes: ob.hide_render = True
scene.render.filepath = OUTFILE
bpy.ops.render.render(write_still=True)
