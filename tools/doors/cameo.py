# The pictures as cameos: each door's and place's clay model, faced straight on,
# pressed to a low relief and lit by one light from above, the way Ceramic lights
# everything. This renders the relief on a flat grey ground; cameo.swift cuts it
# into the night and day pictures. See STYLE.md, "Cameo".
#
#   FONT_DIR=<fonts> Blender -b -P cameo.py -- <picture> <out.png>
#   MASK=1 ...   the relief's outline instead: the relief white, the ground black
#   pictures: door-write door-switch door-keep door-speak place-general place-operate
#             place-web place-meetings place-keys place-observations
#
# The models are scene3.py's doors and places.py's places, built unchanged:
# this file runs places.py up to its render, with the doors added to its builders.
import bpy, math, os, sys
from mathutils import Vector

HERE = os.path.dirname(os.path.abspath(__file__))
argv = sys.argv[sys.argv.index("--") + 1:]
PICTURE, TARGET = argv[0], os.path.abspath(argv[1])   # not OUT: scene3 sets its own
os.environ["STILL"] = "1"   # door_write shows its typo marked, not crossing over

# Which model each picture is, and for a door the moment of its loop to hold.
MODELS = {
    "door-write": ("write-door", 2.0), "door-switch": ("switch-door", 0.0),
    "door-keep": ("keep-door", 0.0), "door-speak": ("speak-door", 4.6),
    "place-general": ("general-3", None), "place-operate": ("operate-4", None),
    "place-web": ("web-2", None), "place-meetings": ("meetings-5", None),
    "place-keys": ("keys-4", None), "place-observations": ("observations-7", None),
}
NAME, MOMENT = MODELS[PICTURE]

scene3 = open(os.path.join(HERE, "scene3.py")).read()
doors = scene3[scene3.index("# ---------- motion ----------"):scene3.index("# ---------- composition ----------")] + f'''
BASE = {{}}
def _door(build, t):
    def made(g):
        BASE[g.name] = (tuple(g.location), tuple(g.rotation_euler))
        loop = build(g)
        if loop: loop[0](t)
    return made
BUILDERS.update({{"write-door": _door(door_write, {MOMENT}), "switch-door": _door(door_move, {MOMENT}),
                 "keep-door": _door(door_keep, {MOMENT}), "speak-door": _door(door_speak, {MOMENT})}})
SLOT_OF.update({{"write": "write", "switch": "move", "keep": "keep", "speak": "speak"}})
'''
places = open(os.path.join(HERE, "places.py")).read()
places = places.replace("HERE = os.path.dirname(os.path.abspath(__file__))", f"HERE = {HERE!r}")
cut = places.index("SLOTS = {")
places = places[:cut] + doors + places[cut:places.index("scene.render.filepath = OUTFILE")]
sys.argv = [sys.argv[0], "--", NAME, TARGET, "16"]
exec(places, globals())

# ---------- the relief: faced straight on, pressed to 0.3 of its depth ----------
s = g.scale[0]
g.location = (0, 0, 0); g.rotation_euler = (0, 0, 0); g.scale = (s, s * 0.3, s)
bpy.context.view_layer.update()
corners = [ob.matrix_world @ Vector(c) for ob in meshes for c in ob.bound_box]
x0, x1 = min(p.x for p in corners), max(p.x for p in corners)
z0, z1 = min(p.z for p in corners), max(p.z for p in corners)
back = max(p.y for p in corners)

def matte(name, rgb, rough=0.85):
    m = bpy.data.materials.new(name); m.use_nodes = True
    b = m.node_tree.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = rgb + (1,)
    b.inputs["Roughness"].default_value = rough
    b.inputs["Specular IOR Level"].default_value = 0.25
    return m

# One clay for the relief and its ground. The glaze, the letters and the letters
# on the glaze each get a hue of their own, which cameo.swift keys out and paints.
clay = matte("clay", (0.42, 0.42, 0.42))
glaze = matte("glaze", (1.0, 0.09, 0.0), rough=0.55)
inlay = matte("inlay", (0.0, 0.05, 0.9), rough=0.7)
onglaze = matte("onglaze", (0.0, 0.8, 0.05), rough=0.7)
marks = matte("marks", (0.8, 0.0, 0.8), rough=0.7)   # a page's lines and rules: quiet ink, keyed by magenta

def orange(m):
    name = m.name.lower()
    base = m.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value if m.use_nodes else (0, 0, 0, 1)
    return (base[0] > 0.5 and base[1] < 0.25 and base[2] < 0.1) or ("orange" in name and "ink" not in name) or "underline" in name

for ob in meshes:
    for slot in ob.material_slots:
        old = slot.material
        quiet = old is not None and old.name.split(".")[0] in ("bar", "ghost")
        inked = old is not None and old.name.split(".")[0] == "ink"   # a tick, a clock's hand: drawn in ink
        if ob.type == "FONT": slot.material = onglaze if old and "orangeink" in old.name.lower() else marks if quiet else inlay
        elif inked: slot.material = inlay
        elif old and orange(old): slot.material = glaze
        # A page's lines and rules are drawn; the slot a lifted meeting left is a hollow, so clay.
        elif quiet and not ob.name.startswith("slot"): slot.material = marks
        else: slot.material = clay

bpy.ops.mesh.primitive_plane_add(size=200, location=(0, back + 0.001, 0), rotation=(math.radians(90), 0, 0))
ground = bpy.context.active_object; ground.data.materials.append(clay)
for ob in list(bpy.data.objects):
    if ob.type == "LIGHT": bpy.data.objects.remove(ob)
    elif ob.type in ("MESH", "FONT", "CURVE") and ob not in meshes and ob is not ground: ob.hide_render = True

# ---------- one light, from above and a little left; a sun, so the ground is even ----------
sun = bpy.data.lights.new("sun", "SUN"); sun.energy = 3.2; sun.angle = math.radians(6)
so = bpy.data.objects.new("sun", sun); scene.collection.objects.link(so)
so.rotation_euler = (math.radians(30), 0, math.radians(-18))
world = scene.world
for n in list(world.node_tree.nodes): world.node_tree.nodes.remove(n)
sky = world.node_tree.nodes.new("ShaderNodeBackground"); sky.inputs[1].default_value = 0.25
world.node_tree.links.new(sky.outputs[0], world.node_tree.nodes.new("ShaderNodeOutputWorld").inputs[0])

# ---------- an orthographic camera, the relief filling 84% of a 4:3 frame ----------
W, H = 768, 576
scene.render.resolution_x, scene.render.resolution_y, scene.render.resolution_percentage = W, H, 100
cam.type = "ORTHO"; cam.shift_x = cam.shift_y = 0; cam.dof.use_dof = False
cam.ortho_scale = max(x1 - x0, (z1 - z0) * W / H) / 0.84
cob.location = ((x0 + x1) / 2, -30, (z0 + z1) / 2); cob.rotation_euler = (math.radians(90), 0, 0)
scene.render.engine = "CYCLES"; scene.cycles.samples = 96; scene.cycles.use_denoising = True
scene.render.film_transparent = False
scene.view_settings.view_transform = "Standard"

if os.environ.get("MASK"):
    def emit(name, rgb):
        m = bpy.data.materials.new(name); m.use_nodes = True
        nt = m.node_tree
        for n in list(nt.nodes): nt.nodes.remove(n)
        e = nt.nodes.new("ShaderNodeEmission"); e.inputs[0].default_value = rgb + (1,)
        nt.links.new(e.outputs[0], nt.nodes.new("ShaderNodeOutputMaterial").inputs[0])
        return m
    white = emit("white", (1, 1, 1))
    for ob in meshes:
        for slot in ob.material_slots: slot.material = white
    ground.data.materials[0] = emit("black", (0, 0, 0))
    scene.cycles.samples = 8; scene.cycles.use_denoising = False

scene.render.filepath = TARGET
bpy.ops.render.render(write_still=True)
