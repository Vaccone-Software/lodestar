# RECOVERED FILE. This is scene3.py, the Blender script that rendered
# Lodestar's door pictures and loops (packaging/doors/door-*.png and
# lodestar-site/public/media/{doors,hero}/), recovered on 2026-10-03 from the
# Claude Code transcript d6f88618-a0d2-4811-8ace-83f8ba3b2979.jsonl
# (session of 2026-09-26). The original lived in that session's scratchpad
# (float/scene3.py), which no longer exists. It was rebuilt by replaying, in
# order, the transcript's Write of float/scene.py and every later in-place edit
# (python heredoc replacements and sed -i) through scene.py -> scene2.py ->
# scene3.py. The last edit to it is transcript line 13039 (the mark's
# full-turn loop). Checked against the transcript's own read-backs (grep -n
# line numbers for mark_pose and box() match exactly). The only change from
# the original is the font path block below. See STYLE.md in this folder.
#
# Blender 5.0.1, Cycles. Usage:
#   Blender -b -P scene3.py -- <write|move|keep|speak|markroot|still> <outdir> [width] [samples]
#   env: CLOSE=1 CW=1200 CH=900  door-page portrait (long lens, one door)
#        ONLY=<frame>             render one frame only
#        CLAY=pale|charcoal       clay palette (pale is the shipped one)
# Lodestar hero: the mark with the four doors floating around it.
# blender -b -P scene3.py -- <door|mark|still> <outdir> [width] [samples]
import bpy, bmesh, math, sys, os, random, json
from mathutils import Vector, Euler

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
VARIANT = argv[0] if argv else "pale"
OUT = argv[1] if len(argv) > 1 else "/tmp/out.png"
WIDTH = int(argv[2]) if len(argv) > 2 else 1600
SAMPLES = int(argv[3]) if len(argv) > 3 else 128
FRAME_T = float(argv[4]) if len(argv) > 4 else 0.0

# Recovery note: the original pointed "sans" and "serif" at absolute paths in
# the deleted scratchpad (<scratchpad>/float/fonts/...). They now resolve from
# FONT_DIR (default: ./fonts next to this script). See STYLE.md, "Fonts", for
# where each file comes from. Static TTFs only: Blender renders macOS variable
# fonts (SF, New York, Google's variable Inter) with holes in the glyphs.
FONT_DIR = os.environ.get("FONT_DIR") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "fonts")
FONTS = {
    "sans": os.path.join(FONT_DIR, "Inter-Medium.ttf"),            # rsms/inter v4.1, extras/ttf/Inter-Medium.ttf
    "mono": "/Users/vac/Library/Fonts/JetBrainsMono-Regular.ttf",  # JetBrains Mono, static
    "serif": os.path.join(FONT_DIR, "Newsreader_ital_wght_1_400.ttf"),  # Google Fonts css2 Newsreader:ital,wght@1,400
}

def lin(hexs):
    h = hexs.lstrip("#")
    c = [int(h[i:i + 2], 16) / 255 for i in (0, 2, 4)]
    return tuple(x / 12.92 if x <= 0.04045 else ((x + 0.055) / 1.055) ** 2.4 for x in c) + (1.0,)

# ---------- scene ----------
bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
scene.render.engine = "CYCLES"
prefs = bpy.context.preferences.addons["cycles"].preferences
try:
    prefs.compute_device_type = "METAL"
    prefs.get_devices()
    for d in prefs.devices: d.use = True
    scene.cycles.device = "GPU"
except Exception as e:
    print("GPU unavailable:", e)
scene.cycles.samples = SAMPLES
scene.cycles.use_denoising = True
scene.render.resolution_x = WIDTH
scene.render.resolution_y = int(WIDTH * 10 / 16)
scene.render.film_transparent = False
scene.view_settings.view_transform = "Standard"
scene.view_settings.look = "None"
scene.render.image_settings.file_format = "PNG"
scene.render.filepath = OUT

BG = "#121215"
world = bpy.data.worlds.new("w"); scene.world = world
world.use_nodes = True
wn = world.node_tree.nodes; wl = world.node_tree.links
for n in list(wn): wn.remove(n)
out = wn.new("ShaderNodeOutputWorld")
mixn = wn.new("ShaderNodeMixShader")
lp = wn.new("ShaderNodeLightPath")
bg_cam = wn.new("ShaderNodeBackground"); bg_cam.inputs[0].default_value = lin(BG); bg_cam.inputs[1].default_value = 1
bg_amb = wn.new("ShaderNodeBackground"); bg_amb.inputs[0].default_value = lin("#2a2830"); bg_amb.inputs[1].default_value = 0.35
wl.new(lp.outputs["Is Camera Ray"], mixn.inputs[0])
wl.new(bg_amb.outputs[0], mixn.inputs[1]); wl.new(bg_cam.outputs[0], mixn.inputs[2])
wl.new(mixn.outputs[0], out.inputs[0])

# ---------- materials ----------
def mat(name, color, rough=0.6, emit=None, emit_strength=0.0, coat=0.0, spec=0.5):
    m = bpy.data.materials.new(name); m.use_nodes = True
    b = m.node_tree.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = lin(color)
    b.inputs["Roughness"].default_value = rough
    if "Specular IOR Level" in b.inputs: b.inputs["Specular IOR Level"].default_value = spec
    if coat and "Coat Weight" in b.inputs:
        b.inputs["Coat Weight"].default_value = coat; b.inputs["Coat Roughness"].default_value = 0.15
    if emit:
        b.inputs["Emission Color"].default_value = lin(emit); b.inputs["Emission Strength"].default_value = emit_strength
    return m

PAL = {
    "pale":    dict(clay="#E6DFD6", bar="#BEB4AB", ink="#2A2522", title="#CFC6BC", keyink="#2A2522", cap="#2E2926", capink="#EFE9E2"),
    "charcoal": dict(clay="#3B3936", bar="#5A5652", ink="#E2DCD4", title="#4A4744", keyink="#E2DCD4", cap="#1E1D1C", capink="#E2DCD4"),
}[os.environ.get("CLAY", "pale")]
M = {
    "clay": mat("clay", PAL["clay"], 0.62),
    "bar": mat("bar", PAL["bar"], 0.7),
    "ink": mat("ink", PAL["ink"], 0.5),
    "title": mat("title", PAL["title"], 0.6),
    "cap": mat("cap", PAL["cap"], 0.45),
    "capink": mat("capink", PAL["capink"], 0.5),
    "orange": mat("orange", "#FF4F00", 0.45),
    "orangeInk": mat("orangeInk", "#2A0D00", 0.5),
    "red": mat("red", "#E0685C", 0.5), "amber": mat("amber", "#E8B44C", 0.5), "green": mat("green", "#6DBB5B", 0.5),
}
M["mark"] = mat("mark", "#FF4F00", 0.3, emit="#FF4400", emit_strength=0.35, coat=0.6)
M["wall"] = mat("wall", "#17171b", 0.75)
M["relief"] = mat("relief", "#1d1d22", 0.5)
iron = mat("iron", "#26262b", 0.42); iron.node_tree.nodes["Principled BSDF"].inputs["Metallic"].default_value = 1.0
M["iron"] = iron

# ---------- geometry helpers ----------
def link(ob, parent=None):
    scene.collection.objects.link(ob)
    if parent: ob.parent = parent
    return ob

def empty(name, loc, rot):
    e = bpy.data.objects.new(name, None)
    e.location = loc; e.rotation_euler = Euler([math.radians(a) for a in rot])
    return link(e)

def rrect(name, w, h, depth, radius, material, parent, loc=(0, 0, 0), rot=(0, 0, 0), bevel=0.012):
    """A rounded rectangle in the XZ plane, `depth` thick in Y, its front at -Y."""
    radius = min(radius, w / 2 - 1e-4, h / 2 - 1e-4)
    pts = []
    seg = 10
    for cx, cz, a0 in ((w / 2 - radius, h / 2 - radius, 0), (-w / 2 + radius, h / 2 - radius, 90),
                       (-w / 2 + radius, -h / 2 + radius, 180), (w / 2 - radius, -h / 2 + radius, 270)):
        for i in range(seg + 1):
            a = math.radians(a0 + 90 * i / seg)
            pts.append((cx + radius * math.cos(a), cz + radius * math.sin(a)))
    bm = bmesh.new()
    vs = [bm.verts.new((x, depth / 2, z)) for x, z in pts]
    face = bm.faces.new(vs)
    ext = bmesh.ops.extrude_face_region(bm, geom=[face])
    moved = [g for g in ext["geom"] if isinstance(g, bmesh.types.BMVert)]
    bmesh.ops.translate(bm, vec=(0, -depth, 0), verts=moved)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    me = bpy.data.meshes.new(name); bm.to_mesh(me); bm.free()
    ob = bpy.data.objects.new(name, me)
    ob.data.materials.append(material)
    if bevel > 0:
        mod = ob.modifiers.new("b", "BEVEL"); mod.width = min(bevel, depth * 0.45); mod.segments = 4; mod.limit_method = "ANGLE"; mod.angle_limit = math.radians(40)
    for p in ob.data.polygons: p.use_smooth = True
    try:
        ob.modifiers.new("n", "WEIGHTED_NORMAL");
    except Exception: pass
    ob.location = loc; ob.rotation_euler = Euler([math.radians(a) for a in rot])
    return link(ob, parent)

def text(body, font, size, material, parent, loc, align="LEFT", extrude=0.004):
    cu = bpy.data.curves.new("t", "FONT"); cu.body = body
    cu.font = bpy.data.fonts.load(FONTS[font], check_existing=True)
    cu.size = size; cu.extrude = 0; cu.align_x = align; cu.align_y = "CENTER"
    ob = bpy.data.objects.new("t", cu); ob.data.materials.append(material)
    ob.location = (loc[0], loc[1] + 0.0028, loc[2]); ob.rotation_euler = Euler((math.radians(90), 0, 0))
    link(ob, parent)
    return ob

def extent(body, font, size, parent):
    t = text(body, font, size, M["ink"], parent, (0, 5, 0))
    bpy.context.view_layer.update()
    ev = t.evaluated_get(bpy.context.evaluated_depsgraph_get()); me = ev.to_mesh()
    xs = [v.co.x for v in me.vertices]; ev.to_mesh_clear(); bpy.data.objects.remove(t)
    return (min(xs), max(xs)) if xs else (0, 0)

def width_of(ob):
    bpy.context.view_layer.update()
    return ob.dimensions.x

def sphere(r, material, parent, loc):
    bm = bmesh.new(); bmesh.ops.create_uvsphere(bm, u_segments=24, v_segments=12, radius=r)
    me = bpy.data.meshes.new("s"); bm.to_mesh(me); bm.free()
    ob = bpy.data.objects.new("s", me); ob.data.materials.append(material); ob.location = loc
    for p in ob.data.polygons: p.use_smooth = True
    return link(ob, parent)

def keycap(letter, parent, loc, s=0.13, material=None, ink=None):
    rrect("cap", s * 1.15, s, 0.03, s * 0.24, material or M["cap"], parent, loc=loc, bevel=0.008)
    text(letter, "mono", s * 0.62, ink or M["capink"], parent, (loc[0], loc[1] - 0.0195, loc[2] - s * 0.02), align="CENTER", extrude=0.002)

# ---------- the mark ----------
def mark(parent, radius):
    phi = (1 + 5 ** 0.5) / 2; ip = 1 / phi
    corners = [(x, y, z) for x in (-1, 1) for y in (-1, 1) for z in (-1, 1)]
    for a in (-1, 1):
        for b in (-1, 1):
            corners += [(0, a * ip, b * phi), (a * ip, b * phi, 0), (a * phi, 0, b * ip)]
    dirs = []
    for a in (-1, 1):
        for b in (-1, 1):
            dirs += [(0, a, b * phi), (a, b * phi, 0), (a * phi, 0, b)]
    V = lambda v: Vector(v)
    tris = []
    for d in dirs:
        n = V(d).normalized()
        face = sorted(corners, key=lambda c: -V(c).dot(n))[:5]
        c = sum((V(p) for p in face), Vector()) / 5
        u = (V(face[0]) - c).normalized(); w = n.cross(u)
        face.sort(key=lambda p: math.atan2((V(p) - c).dot(w), (V(p) - c).dot(u)))
        apex = n * 3.05
        for i in range(5):
            tris.append((V(face[i]), V(face[(i + 1) % 5]), apex))
    # Swift's frame: x right, y down, z toward the viewer; turned (24, -18, 8).
    def turn(p):
        x, y, z = p
        a, b, g = math.radians(24), math.radians(-18), math.radians(8)
        y, z = y * math.cos(a) - z * math.sin(a), y * math.sin(a) + z * math.cos(a)
        x, z = x * math.cos(b) + z * math.sin(b), -x * math.sin(b) + z * math.cos(b)
        x, y = x * math.cos(g) - y * math.sin(g), x * math.sin(g) + y * math.cos(g)
        return Vector((x, -z, -y)) * (radius / 3.05)
    bm = bmesh.new()
    for t in tris:
        vs = [bm.verts.new(turn(p)) for p in t]
        bm.faces.new(vs)
    me = bpy.data.meshes.new("mark"); bm.to_mesh(me); bm.free()
    ob = bpy.data.objects.new("mark", me); ob.data.materials.append(M["mark"])
    for p in ob.data.polygons: p.use_smooth = False
    return link(ob, parent)


# ---------- motion ----------
FPS = 24
def ease(x): x = min(1, max(0, x)); return 0.5 - 0.5 * math.cos(math.pi * x)
def ramp(x, a, b): return ease((x - a) / (b - a))
def mix3(a, b, u): return tuple(a[i] + (b[i] - a[i]) * u for i in range(4))
def own(base, name):
    m = M[base].copy(); m.name = name; return m
def alpha(m, v): m.node_tree.nodes["Principled BSDF"].inputs["Alpha"].default_value = max(0.0, min(1.0, v))
def color(m, c): m.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = c
ADV = 0.6  # JetBrains Mono's advance, in ems

POSES = {}
BASE = {}
def floating(g, t, T, amp=(1.2, 1.6, 0.03), phase=0.0):
    """A slow sway, whole cycles only, so it closes with the loop."""
    loc, rot = BASE[g.name]
    w = 2 * math.pi * t / T
    g.location = (loc[0], loc[1], loc[2] + amp[2] * math.sin(w + phase))
    g.rotation_euler = Euler((rot[0] + math.radians(amp[0]) * math.sin(w + phase + 1.3), rot[1], rot[2] + math.radians(amp[1]) * math.sin(w + phase + 0.4)))

# ---------- the doors ----------
def door_write(g):
    rrect("sheet", 2.1, 1.45, 0.05, 0.05, M["clay"], g, bevel=0.02)
    # Only the word changes: the typo and the fix cross over one another
    # where the word stands, and the rest of the line slides to make room.
    typo, fixed = own("ink", "typo"), own("ink", "fixed")
    X = -0.86
    s0, s1 = extent("See you tomorow", "sans", 0.19, g); w0, w1 = extent("tomorow", "sans", 0.19, g)
    wb = w1 - w0; xa = X + s1 - wb
    a0, a1 = extent("at", "sans", 0.19, g)
    def tail_at(line):
        e0, e1 = extent(line + " at", "sans", 0.19, g)
        return X + e1 - (a1 - a0) - a0
    tail_typo, tail_fix = tail_at("See you tomorow"), tail_at("See you tomorrow")
    text("See you", "sans", 0.19, M["ink"], g, (X, -0.03, 0.34))
    text("tomorow", "sans", 0.19, typo, g, (xa - w0, -0.03, 0.34))
    text("tomorrow", "sans", 0.19, fixed, g, (xa - w0, -0.03, 0.34))
    tail = text("at ten.", "sans", 0.19, M["ink"], g, (tail_typo, -0.03, 0.34))
    pen = empty("pen", (xa, 0, 0.235), (0, 0, 0)); pen.parent = g
    ink = own("orange", "underline")
    rrect("underline", wb, 0.022, 0.012, 0.011, ink, pen, loc=(wb / 2, -0.03, 0), bevel=0)
    for i, L in enumerate((1.5, 1.1, 1.3)):
        rrect("bar", L, 0.06, 0.012, 0.03, M["bar"], g, loc=(-0.86 + L / 2, -0.028, -0.02 - i * 0.2), bevel=0)
    T = 6.0
    def pose(t):
        t %= T
        line = ramp(t, 0.4, 1.5) if t < 2.7 else 1.0
        gone = ramp(t, 2.7, 3.1) if t < 4.9 else 1.0
        fix = ramp(t, 2.7, 3.1) if t < 4.9 else 1 - ramp(t, 4.9, 5.5)
        pen.scale = (max(line, 1e-3), 1, 1)
        alpha(ink, 0.0 if t < 0.4 else (1 - gone) if t >= 2.7 else 1.0)
        if t < 0.4: pen.scale = (1e-3, 1, 1)
        alpha(typo, 1 - fix); alpha(fixed, fix)
        tail.location.x = tail_typo + (tail_fix - tail_typo) * fix
        floating(g, t, T, phase=0.3)
    return pose, T

def window(g, name, letter, loc, rot):
    w = empty(name, loc, rot); w.parent = g
    rrect("win", 1.6, 1.08, 0.05, 0.07, M["clay"], w, bevel=0.018)
    bar = own("title", "title-" + name)
    rrect("title", 1.6, 0.2, 0.056, 0.07, bar, w, loc=(0, -0.004, 0.44), bevel=0.012)
    rrect("titlefix", 1.6, 0.1, 0.057, 0.0, bar, w, loc=(0, -0.004, 0.39), bevel=0)
    for i, m in enumerate(("red", "amber", "green")):
        sphere(0.028, M[m], w, (-0.68 + i * 0.09, -0.04, 0.44))
    text(name, "sans", 0.075, M["ink"], w, (0, -0.036, 0.44), align="CENTER", extrude=0.002)
    keycap(letter, w, (0.64, -0.035, 0.44), s=0.12)
    for i, L in enumerate((1.1, 1.3, 0.9, 1.2)):
        rrect("bar", L, 0.055, 0.012, 0.027, M["bar"], w, loc=(-0.66 + L / 2, -0.028, 0.18 - i * 0.17), bevel=0)
    return w, bar

def door_move(g):
    SLOTS = [((0, 0, 0), 0), ((0.17, 0.25, 0.15), 2), ((0.34, 0.5, 0.3), 4)]
    wins = [window(g, n, l, SLOTS[i][0], (0, SLOTS[i][1], 0)) for i, (n, l) in enumerate((("Mail", "M"), ("Notes", "N"), ("Browser", "B")))]
    grey, orange = lin(PAL["title"]), lin("#FF4F00")
    T = 9.0
    def pose(t):
        t %= T
        k = int(t // 3); y = t - 3 * k; u = ramp(y, 0.5, 1.7)
        for i, (w, bar) in enumerate(wins):
            a = (i + k) % 3; b = (a + 2) % 3  # the back one comes to the front
            if a == 2: b = 0
            else: b = a + 1
            sa, sb = SLOTS[a], SLOTS[b]
            p = [sa[0][j] + (sb[0][j] - sa[0][j]) * u for j in range(3)]
            s = a + (b - a) * u
            if a == 2:
                p[0] -= 0.95 * math.sin(math.pi * u); p[2] += 0.28 * math.sin(math.pi * u)
            w.location = p
            w.rotation_euler = Euler((0, math.radians(sa[1] + (sb[1] - sa[1]) * u), 0))
            color(bar, mix3(grey, orange, max(0.0, min(1.0, 1 - s))))
        floating(g, t, T, phase=1.1)
    return pose, T

def card(g, loc, rot, orange, fill):
    c = empty("card", loc, rot); c.parent = g
    rrect("card", 1.12, 0.74, 0.035, 0.07, M["orange"] if orange else M["clay"], c, bevel=0.014)
    fill(c)
    return c

def door_keep(g):
    def f_time(c):
        keycap("F", c, (-0.43, -0.03, 0.24), s=0.11)
        text("1790342057", "mono", 0.1, M["ink"], c, (-0.46, -0.022, 0.02), extrude=0.002)
        text("6 hours ago", "serif", 0.1, M["bar"], c, (-0.46, -0.022, -0.2), extrude=0.002)
    def f_color(c):
        keycap("D", c, (-0.43, -0.03, 0.24), s=0.11)
        rrect("sw", 0.22, 0.22, 0.03, 0.04, M["orange"], c, loc=(-0.35, -0.025, -0.02), bevel=0.006)
        text("#FF4F00", "mono", 0.085, M["ink"], c, (-0.18, -0.022, 0.02), extrude=0.002)
        text("International Orange", "serif", 0.075, M["bar"], c, (-0.18, -0.022, -0.1), extrude=0.002)
    def f_units(c):
        keycap("S", c, (-0.43, -0.03, 0.24), s=0.11)
        text("12 ft", "sans", 0.16, M["ink"], c, (-0.46, -0.022, 0.02), extrude=0.002)
        text("3.66 m", "serif", 0.1, M["bar"], c, (-0.46, -0.022, -0.2), extrude=0.002)
    def f_note(c):
        keycap("A", c, (-0.43, -0.03, 0.24), s=0.11, material=M["orangeInk"], ink=M["orange"])
        for i, s in enumerate(("Notes for Thursday:", "move the review,", "send the draft.")):
            text(s, "sans", 0.08, M["orangeInk"], c, (-0.46, -0.022, 0.06 - i * 0.12), extrude=0.002)
    cards = [card(g, (-0.62, 0.3, -0.08), (0, -14, 0), False, f_time),
             card(g, (-0.22, 0.2, 0.0), (0, -5, 0), False, f_color),
             card(g, (0.18, 0.1, 0.02), (0, 4, 0), False, f_units),
             card(g, (0.52, -0.12, 0.26), (0, 12, 0), True, f_note)]
    base = [(tuple(c.location), tuple(c.rotation_euler)) for c in cards]
    T = 8.0
    def pose(t):
        t %= T
        lift = ramp(t, 0.5, 1.5) if t < 3.0 else 1 - ramp(t, 3.0, 4.0)
        slide = ramp(t, 4.6, 5.4) if t < 6.2 else 1 - ramp(t, 6.2, 7.1)
        for i, c in enumerate(cards):
            (x, y, z), r = base[i]
            if i == 3:
                c.location = (x + 0.1 * lift, y - 0.35 * lift, z + 0.42 * lift)
                c.rotation_euler = Euler((r[0] + math.radians(-10) * lift, r[1] + math.radians(-6) * lift, r[2]))
            elif i == 1:
                c.location = (x - 0.12 * slide, y - 0.08 * slide, z + 0.55 * slide)
                c.rotation_euler = Euler((r[0], r[1] + math.radians(-8) * slide, r[2]))
            else:
                c.location = (x, y, z); c.rotation_euler = Euler(r)
        floating(g, t, T, phase=2.0)
    return pose, T

def door_speak(g):
    W, H = 2.6, 0.98
    rrect("draft", W, H, 0.07, 0.16, M["clay"], g, bevel=0.02)
    top = H / 2 - 0.15
    rrect("icon", 0.14, 0.14, 0.03, 0.035, M["title"], g, loc=(-W / 2 + 0.2, -0.04, top), bevel=0.006)
    text("Messages", "sans", 0.085, M["ink"], g, (-W / 2 + 0.32, -0.042, top))
    x0, x1 = extent("Messages", "sans", 0.085, g)
    cx = -W / 2 + 0.32 + x1 + 0.1
    rrect("chip", 0.34, 0.1, 0.02, 0.05, M["title"], g, loc=(cx + 0.17, -0.04, top), bevel=0.004)
    text("INSERT", "mono", 0.055, M["ink"], g, (cx + 0.17, -0.056, top), align="CENTER")
    feet = []
    for i in range(5):
        foot = empty("lvl", (W / 2 - 0.42 + i * 0.058, 0, top - 0.06), (0, 0, 0)); foot.parent = g
        rrect("lvl", 0.03, 0.14, 0.03, 0.015, M["orange"], foot, loc=(0, -0.045, 0.07), bevel=0)
        feet.append(foot)
    sphere(0.03, M["bar"], g, (W / 2 - 0.12, -0.05, top))
    rrect("rule", W - 0.24, 0.008, 0.01, 0.004, M["bar"], g, loc=(0, -0.036, top - 0.12), bevel=0)
    L, size = -W / 2 + 0.2, 0.1
    e0, e1 = extent("m" * 40, "mono", size, g); adv = (e1 - e0) / 40
    lines = ["Let’s move the review to Friday,", "and send the draft."]
    inkm, ghostm = own("ink", "settled"), own("bar", "ghost")
    rows = []
    for j in range(2):
        z = top - 0.29 - 0.18 * j
        a = text("", "mono", size, inkm, g, (L, -0.041, z))
        b = text("", "mono", size, ghostm, g, (L, -0.041, z))
        rows.append((a, b, z))
    caret = empty("caret", (L, 0, rows[0][2]), (0, 0, 0)); caret.parent = g
    rrect("caret", 0.014, 0.14, 0.012, 0.007, M["orange"], caret, loc=(0, -0.04, 0), bevel=0)
    words = [(j, w) for j, ln in enumerate(lines) for w in ln.split(" ")]
    T = 8.0
    def pose(t):
        t %= T
        n = max(0, min(len(words), math.floor((t - 0.3) / 0.38) + 1)) if t < 6.5 else 0
        fade = 1.0 if t < 5.6 else max(0.0, 1 - ramp(t, 5.6, 6.3))
        alpha(inkm, fade); alpha(ghostm, fade)
        cx, cz = L, rows[0][2]
        for j, (a, b, z) in enumerate(rows):
            got = [w for (jj, w) in words[:n] if jj == j]
            newest = n > 0 and words[n - 1][0] == j and t < 4.4
            settled = " ".join(got[:-1] if newest else got)
            ghost = got[-1] if newest else ""
            a.data.body = settled
            b.data.body = ghost
            b.location.x = L + (len(settled) + (1 if settled else 0)) * adv
            if got:
                cx = L + len(" ".join(got)) * adv + 0.03; cz = z
        caret.location = (cx, 0, cz)
        caret.hide_render = False
        level = 1.0 if t < 3.9 else (1 - 0.85 * ramp(t, 3.9, 4.4)) if t < 7.3 else 0.15 + 0.85 * ramp(t, 7.3, 8.0)
        for i, foot in enumerate(feet):
            h = 0.25 + 0.75 * level * abs(math.sin(2 * math.pi * (2 + i) * t / T + i * 1.3))
            foot.scale = (1, 1, max(0.08, h))
        floating(g, t, T, phase=0.7)
    return pose, T

# ---------- composition ----------
mk = empty("markroot", (0, 0, 1.25), (-4, 6, -8))
mark(mk, 1.0)
PLACES = {
    "write": ((-3.55, 0.7, 1.85), (12, 0, 30), 1.1),
    "move": ((3.55, 1.0, 1.95), (10, 0, -32), 1.1),
    "keep": ((-3.7, -0.9, -2.05), (-16, 6, 26), 1.1),
    "speak": ((3.55, -0.7, -2.05), (-12, -4, -26), 1.0),
}
BUILD = {"write": door_write, "move": door_move, "keep": door_keep, "speak": door_speak}
for k, (loc, rot, s) in PLACES.items():
    g = empty(k, loc, rot); g.scale = (s, s, s)
    BASE[k] = (Vector(loc), tuple(math.radians(a) for a in rot))
    POSES[k] = BUILD[k](g)
BASE["markroot"] = (Vector(mk.location), tuple(mk.rotation_euler))
MARK_T = 30.0
MARK_AXIS = Vector((math.sin(math.radians(12)), -math.sin(math.radians(25)), 1.0)).normalized()
mk.rotation_mode = "QUATERNION"
MARK_BASE_Q = Euler(BASE["markroot"][1]).to_quaternion()
def mark_pose(t):
    # One slow, whole turn about an axis leaning toward the viewer, so the
    # loop closes on itself instead of swinging back.
    from mathutils import Quaternion
    w = 2 * math.pi * (t % MARK_T) / MARK_T
    loc, rot = BASE["markroot"]
    mk.location = (loc[0], loc[1], loc[2] + 0.04 * math.sin(w))
    mk.rotation_quaternion = Quaternion(MARK_AXIS, w) @ MARK_BASE_Q
POSES["markroot"] = (mark_pose, MARK_T)

# ---------- lights ----------
def area(name, loc, target, power, size, color="#ffffff"):
    Lg = bpy.data.lights.new(name, "AREA"); Lg.energy = power; Lg.size = size; Lg.color = lin(color)[:3]
    ob = bpy.data.objects.new(name, Lg); ob.location = loc
    d = Vector(target) - Vector(loc); ob.rotation_euler = d.to_track_quat("-Z", "Y").to_euler()
    return link(ob)
area("key", (-6, -7, 7), (0, 0, 0.5), 2400, 6, "#fff6ee")
area("rim", (5, 7, 5), (0, 0, 0.5), 1200, 5, "#ffe2cc")
area("fill", (7, -6, -3), (0, 0, 0.5), 450, 8, "#dfe6ff")
P = bpy.data.lights.new("core", "POINT"); P.energy = 90; P.color = lin("#ff5a14")[:3]; P.shadow_soft_size = 0.6
link(bpy.data.objects.new("core", P)).location = Vector((0, -0.6, 1.25))

# ---------- camera ----------
cam = bpy.data.cameras.new("cam"); cam.lens = 50
cob = link(bpy.data.objects.new("cam", cam)); scene.camera = cob
cob.location = (0, -17, 1.6)
target = Vector((0, 0, 0.55))
cob.rotation_euler = (target - cob.location).to_track_quat("-Z", "Y").to_euler()
cam.dof.use_dof = True; cam.dof.focus_distance = (target - cob.location).length; cam.dof.aperture_fstop = 4.5

# ---------- rendering ----------
from bpy_extras.object_utils import world_to_camera_view
WHAT = VARIANT
OUTDIR = OUT
os.makedirs(OUTDIR, exist_ok=True)
groups = list(PLACES) + ["markroot"]
def members(k): return [bpy.data.objects[k]] + list(bpy.data.objects[k].children_recursive)
def pose_all(t):
    for k in groups: POSES[k][0](t)
def box(k, times):
    x0 = y0 = 1e9; x1 = y1 = -1e9
    for t in times:
        POSES[k][0](t); bpy.context.view_layer.update()
        for ch in bpy.data.objects[k].children_recursive:
            if ch.type != "MESH": continue
            for c in ch.bound_box:
                v = world_to_camera_view(scene, cob, ch.matrix_world @ Vector(c))
                x0 = min(x0, v.x); x1 = max(x1, v.x); y0 = min(y0, 1 - v.y); y1 = max(y1, 1 - v.y)
    return x0, x1, y0, y1
scene.render.film_transparent = True
scene.render.use_lock_interface = True
scene.render.fps = FPS
if WHAT == "still":
    pose_all(0.0)
    scene.render.filepath = os.path.join(OUTDIR, "still.png")
    bpy.ops.render.render(write_still=True)
else:
    k = WHAT
    if os.environ.get("CLOSE"):
        # A door page's portrait: the same camera and light, a long lens
        # aimed at the one door, framed around its whole motion.
        cam.dof.use_dof = False
        scene.render.resolution_x, scene.render.resolution_y = int(os.environ.get("CW", "1200")), int(os.environ.get("CH", "900"))
        c0 = Vector((0, 0, 0)); n = 0
        for t in [POSES[k][1] * i / 8 for i in range(8)]:
            POSES[k][0](t); bpy.context.view_layer.update()
            for ch in bpy.data.objects[k].children_recursive:
                if ch.type == "MESH":
                    for cc in ch.bound_box: c0 += ch.matrix_world @ Vector(cc); n += 1
        c0 /= n
        cob.rotation_euler = (c0 - cob.location).to_track_quat("-Z", "Y").to_euler()
        cam.lens = 50
        bpy.context.view_layer.update()
        def extent():
            x0 = y0 = 1e9; x1 = y1 = -1e9
            for t in [POSES[k][1] * i / 24 for i in range(24)]:
                POSES[k][0](t); bpy.context.view_layer.update()
                for ch in bpy.data.objects[k].children_recursive:
                    if ch.type != "MESH": continue
                    for cc in ch.bound_box:
                        v = world_to_camera_view(scene, cob, ch.matrix_world @ Vector(cc))
                        x0 = min(x0, v.x); x1 = max(x1, v.x); y0 = min(y0, v.y); y1 = max(y1, v.y)
            return x0, x1, y0, y1
        # Fit and center by turns: zoom to the whole motion, then shift the
        # frame onto it, until both settle.
        aspect = scene.render.resolution_y / scene.render.resolution_x
        for _ in range(4):
            x0, x1, y0, y1 = extent()
            cam.lens *= 0.84 / max(x1 - x0, y1 - y0)
            bpy.context.view_layer.update()
            x0, x1, y0, y1 = extent()
            cam.shift_x += (x0 + x1) / 2 - 0.5
            cam.shift_y += ((y0 + y1) / 2 - 0.5) * aspect
            bpy.context.view_layer.update()
        print("FRAMED", k, extent(), cam.lens)
        for j in groups:
            for ob in members(j): ob.hide_render = j != k
        pose, T = POSES[k]
        frames = int(round(T * FPS))
        bpy.app.handlers.frame_change_pre.append(lambda sc, *_: pose(sc.frame_current / FPS))
        scene.frame_start = int(os.environ.get("ONLY", "0")); scene.frame_end = int(os.environ["ONLY"]) if os.environ.get("ONLY") else frames - 1
        scene.render.filepath = os.path.join(OUTDIR, k, "f")
        bpy.ops.render.render(animation=True)
        raise SystemExit
    for j in groups:
        for ob in members(j): ob.hide_render = j != k
    pose, T = POSES[k]
    frames = int(round(T * FPS))
    x0, x1, y0, y1 = box(k, [T * i / 32 for i in range(32)])
    m = 0.012
    x0, x1, y0, y1 = max(0, x0 - m), min(1, x1 + m), max(0, y0 - m * 1.6), min(1, y1 + m * 1.6)
    # Even pixel sizes, for the video encoders.
    W, H = scene.render.resolution_x, scene.render.resolution_y
    px0, px1 = int(x0 * W) // 2 * 2, int(math.ceil(x1 * W / 2)) * 2
    py0, py1 = int(y0 * H) // 2 * 2, int(math.ceil(y1 * H / 2)) * 2
    scene.render.use_border = True; scene.render.use_crop_to_border = True
    scene.render.border_min_x, scene.render.border_max_x = px0 / W, px1 / W
    scene.render.border_min_y, scene.render.border_max_y = 1 - py1 / H, 1 - py0 / H
    json.dump({"x0": px0 / W, "x1": px1 / W, "y0": py0 / H, "y1": py1 / H, "frames": frames, "fps": FPS}, open(os.path.join(OUTDIR, f"{k}.json"), "w"))
    only = os.environ.get("ONLY")
    def handler(sc, *_):
        pose(sc.frame_current / FPS)
    bpy.app.handlers.frame_change_pre.append(handler)
    scene.frame_start = 0
    scene.frame_end = frames - 1 if not only else int(only)
    if only: scene.frame_start = int(only)
    scene.render.filepath = os.path.join(OUTDIR, k, "f")
    bpy.ops.render.render(animation=True)
