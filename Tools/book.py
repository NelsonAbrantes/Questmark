"""Renders the Glass Forever Tracker quest book with Blender (Cycles).

A heavy old tome lying open, seen from the front and above with an
orthographic camera tilted 20 deg. Thick page blocks swell up from a deep,
dark gutter and roll over at their edges; the leaf walls on the fore-edges
and the tail are built from 7 stepped bundles of leaves. Dark leather boards
carry dark iron fittings with a pewter shine on worn edges: crowned edge
rails with an engraved groove and domed rivets, waymark (four-point star)
bosses, corner pieces with pierced legs, arrow-leaf terminals and a domed
corner knob with a garnet, side catches with an amethyst, a head crest and a
tail plate over the spine. Two silk ribbons (purple, crimson) run off the
pages, over the tail rail and onto the table. A shadow catcher bakes a soft
shadow into the alpha (straight alpha); after the render the shadow is
faded out so it stays inside the frame bound.

Run: blender -b -P book.py -- <out.tga> <width> <samples> [--overlay] [--clay] [--paint]
  --overlay  draws the page text rectangles as thin red lines (layout check)
  --clay     one grey clay material on everything (grey-box check)
  --paint    Kuwahara painterly pass on metal, leather, gems and ribbons
             (tested: no visible gain at 2048 px, so the shipped texture is
             rendered without it)
  --wearviz  debug: the metal shows its worn-edge / cavity masks
  --norender build and print the LAYOUT lines only
Final texture: 2048 wide, 256 samples, no flags.

View: 16 x 10 units; the image is width x width/2 with tall pixels (1.25),
stretched back to 16 x 10 in the game (880 x 550 UI units, 1 unit = 55 UI px).
Screen position of a world point:
  sx = x,  sv = y*cos(TILT) + z*sin(TILT) - CAM_C
  UI x = (sx + 8) * 55,  UI y = (5 - sv) * 55   (top-left origin)
Text rectangles (UI): x 110..374 and 506..770, y 60..446. The script prints
LAYOUT lines (edges, margins, bounds) and STATS lines (paper luminance in
the text rectangles, anything outside the frame bound).

Metal ornaments are built as height fields (2.5D relief meshes) from signed
distance functions, so crowned tops, rounded edges, beads, holes and grooves
are real geometry; a per-vertex 'wear' attribute (convex curvature) drives
the bright worn edges in the metal shader.
"""
import bpy, bmesh, math, sys, random
import numpy as np
from mathutils import Vector

args = sys.argv[sys.argv.index('--') + 1:]
OUT, PIXELS, SAMPLES = args[0], int(args[1]), int(args[2])
OVERLAY = '--overlay' in args
CLAY = '--clay' in args

# ---------------------------------------------------------------- layout (world units)

TILT = math.radians(20)
CAM_C = 0.05
COS, SIN = math.cos(TILT), math.sin(TILT)
SPINE = 0.12                  # half the gap between the boards
OUTER = 7.40                  # fore-edge board edge
HB = 4.70                     # boards span y = +/-HB
BOARD_T = 0.35
U_DIVE, U_ROLL, U_EDGE, U_FOOT = 0.95, 6.35, 6.55, 7.12   # page block, u = |x|
Y_ROLL, Y_EDGE, Y_FOOT = 4.05, 4.20, 4.43
R_FORE, R_HEAD = 0.20, 0.15   # roll-over radii
BUNDLES = 7
ZLOW = -0.06                  # relief meshes fall to here (hidden in the board / under the table)
TABLE = -0.02
HF = 0.01                     # relief grid spacing
TEXT_UI = [(110, 374), (506, 770)], (60, 446)
BOUND_SX, BOUND_SV = 7.85, 4.92

def clamp01(x):
    return np.clip(x, 0.0, 1.0)

def smooth(a, b, x):
    t = clamp01((np.asarray(x, dtype=float) - a) / (b - a))
    return t * t * (3 - 2 * t)

def screen(x, y, z):
    return x, y * COS + z * SIN - CAM_C

def ui(sx, sv):
    return (sx + 8) * 55, (5 - sv) * 55

# ---------------------------------------------------------------- page surface

def base_h(u, y):
    u = np.asarray(u, dtype=float); y = np.asarray(y, dtype=float)
    s = clamp01(u / U_DIVE)
    dive = 1 - (1 - s) ** 2.5
    swell = 0.14 * np.sin(np.pi * clamp01((u - 0.4) / 6.2)) ** 0.8
    yy = np.minimum(np.abs(y), Y_ROLL)
    dome = 0.04 * (1 - (yy / Y_ROLL) ** 2)
    dip = 1 - 0.18 * smooth(3.6, 4.2, np.abs(y)) * (1 - smooth(0.0, 1.0, u))
    return BOARD_T + (0.30 + 0.62 * dive) * dip + swell + dome

def roll_drop(e, r):
    e = np.clip(e, 0.0, r)
    return r - np.sqrt(r * r - e * e)

def lift(u, y):
    """The top leaf lifts a little at the right page's outer tail corner."""
    d = np.sqrt((u - U_EDGE) ** 2 + (y + Y_EDGE) ** 2)
    return 0.10 * clamp01(1 - d / 0.55) ** 2

def page_top(u, y, side=1):
    u = np.asarray(u, dtype=float); y = np.asarray(y, dtype=float)
    z = base_h(np.minimum(u, U_ROLL), y)
    du = roll_drop(u - U_ROLL, R_FORE)
    dy = roll_drop(np.abs(y) - Y_ROLL, R_HEAD)
    z = z - (np.maximum(du, dy) + 0.35 * np.minimum(du, dy))
    if side > 0:
        z = z + lift(u, y)
    return z

def world_on_page(sx, sv):
    """The point of the top page seen at screen (sx, sv)."""
    u, side = abs(sx), (1 if sx > 0 else -1)
    lo, hi = -Y_EDGE, Y_EDGE
    for _ in range(60):
        mid = (lo + hi) / 2
        if screen(sx, mid, float(page_top(u, mid, side)))[1] < sv:
            lo = mid
        else:
            hi = mid
    y = (lo + hi) / 2
    return Vector((sx, y, float(page_top(u, y, side))))

# ---------------------------------------------------------------- scene

bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
scene.render.engine = 'CYCLES'
scene.cycles.device = 'CPU'
try:  # use a GPU when there is one
    prefs = bpy.context.preferences.addons['cycles'].preferences
    for kind in ('OPTIX', 'CUDA', 'HIP', 'ONEAPI', 'METAL'):
        try:
            prefs.compute_device_type = kind
        except TypeError:
            continue
        prefs.get_devices()
        gpus = [d for d in prefs.devices if d.type == kind]
        if gpus:
            for d in prefs.devices:
                d.use = d.type == kind
            scene.cycles.device = 'GPU'
            break
except Exception as e:
    print('GPU setup skipped:', e)
print('Cycles device:', scene.cycles.device)
scene.cycles.samples = SAMPLES
scene.cycles.use_denoising = True
for attr, val in (('denoiser', 'OPENIMAGEDENOISE'), ('denoising_input_passes', 'RGB_ALBEDO_NORMAL')):
    try:
        setattr(scene.cycles, attr, val)
    except Exception as e:
        print('denoise setting skipped:', attr, e)
scene.render.film_transparent = True
scene.view_settings.view_transform = 'AgX'
for _look in ('AgX - Base Contrast', 'Base Contrast'):
    try:
        scene.view_settings.look = _look
        break
    except TypeError:
        pass
scene.view_settings.exposure = 0.0
print('Look:', scene.view_settings.look)
scene.render.image_settings.file_format = 'TARGA_RAW'
scene.render.image_settings.color_mode = 'RGBA'
scene.render.resolution_x = PIXELS
scene.render.resolution_y = PIXELS // 2
scene.render.pixel_aspect_y = 1.25
scene.render.resolution_percentage = 100

# world: a warm gradient for the metal to reflect (the camera sees transparency)
world = bpy.data.worlds.new('World')
scene.world = world
if world.node_tree is None:
    world.use_nodes = True
wn, wl = world.node_tree.nodes, world.node_tree.links
bg = wn['Background']
wdir = wn.new('ShaderNodeTexCoord')
wsep = wn.new('ShaderNodeSeparateXYZ')
wl.new(wdir.outputs['Generated'], wsep.inputs['Vector'])
wmap = wn.new('ShaderNodeMapRange')
wmap.inputs['From Min'].default_value, wmap.inputs['From Max'].default_value = -1.0, 1.0
wl.new(wsep.outputs['Z'], wmap.inputs['Value'])
wramp = wn.new('ShaderNodeValToRGB')
el = wramp.color_ramp.elements
el[0].position, el[0].color = 0.0, (0.03, 0.025, 0.02, 1)
el[1].position, el[1].color = 1.0, (0.85, 0.70, 0.50, 1)
el.new(0.5).color = (0.28, 0.21, 0.15, 1)
wl.new(wmap.outputs['Result'], wramp.inputs['Fac'])
wl.new(wramp.outputs['Color'], bg.inputs['Color'])
bg.inputs['Strength'].default_value = 0.45

def sun(name, direction, energy, color, angle):
    """A sun light; direction is the way the light travels."""
    data = bpy.data.lights.new(name, 'SUN')
    data.energy, data.color, data.angle = energy, color, math.radians(angle)
    obj = bpy.data.objects.new(name, data)
    obj.rotation_euler = Vector(direction).normalized().to_track_quat('-Z', 'Y').to_euler()
    scene.collection.objects.link(obj)
    return obj

KEY_ENERGY = 4.0
KEY = sun('Key', (0.45, -0.30, -0.84), KEY_ENERGY, (1.00, 0.84, 0.64), 10)
FILL = sun('FrontFill', (0.10, 0.75, -0.65), 0.8, (1.00, 0.78, 0.55), 25)
SKY = sun('Sky', (-0.50, 0.20, -0.84), 0.35, (0.75, 0.82, 1.00), 40)
KICK = sun('Kicker', (-0.20, -0.90, -0.40), 1.0, (1.00, 0.80, 0.55), 3)

cam_data = bpy.data.cameras.new('Camera')
cam_data.type = 'ORTHO'
cam_data.ortho_scale = 16.0
cam = bpy.data.objects.new('Camera', cam_data)
target = Vector((0, CAM_C / COS, 0))          # screen centre: sv = 0 there
cam.location = target + Vector((0, -SIN, COS)) * 40
cam.rotation_euler = (TILT, 0, 0)
cam_data.clip_end = 100
scene.collection.objects.link(cam)
scene.camera = cam

# ---------------------------------------------------------------- node helpers

class Nodes:
    def __init__(self, name):
        self.mat = bpy.data.materials.new(name)
        if self.mat.node_tree is None:   # older Blender
            self.mat.use_nodes = True
        self.nodes, self.links = self.mat.node_tree.nodes, self.mat.node_tree.links
        self.bsdf = self.nodes['Principled BSDF']

    def node(self, kind, inputs=None, **props):
        n = self.nodes.new(kind)
        for k, v in props.items():
            setattr(n, k, v)
        for k, v in (inputs or {}).items():
            self.put(v, n.inputs[k])
        return n

    def put(self, value, socket):
        if hasattr(value, 'is_output'):
            self.links.new(value, socket)
        else:
            socket.default_value = value

    def set(self, name, value):
        if name in self.bsdf.inputs:
            self.put(value, self.bsdf.inputs[name])
        else:
            print('BSDF input missing:', name)

    def math(self, op, a, b=0.0, c=None):
        n = self.node('ShaderNodeMath', operation=op)
        self.put(a, n.inputs[0])
        self.put(b, n.inputs[1])
        if c is not None:
            self.put(c, n.inputs[2])
        return n.outputs[0]

    def maprange(self, v, a, b, lo=0.0, hi=1.0, kind='LINEAR'):
        n = self.node('ShaderNodeMapRange', interpolation_type=kind)
        self.put(v, n.inputs['Value'])
        n.inputs['From Min'].default_value, n.inputs['From Max'].default_value = a, b
        n.inputs['To Min'].default_value, n.inputs['To Max'].default_value = lo, hi
        return n.outputs['Result']

    def ramp(self, fac, stops):
        r = self.nodes.new('ShaderNodeValToRGB')
        el = r.color_ramp.elements
        stops = [(p, c if len(c) == 4 else tuple(c) + (1,)) for p, c in stops]
        el[0].position, el[0].color = stops[0]
        el[1].position, el[1].color = stops[-1]
        for p, c in stops[1:-1]:
            el.new(p).color = c
        self.put(fac, r.inputs['Fac'])
        return r.outputs['Color']

    def mix(self, a, b, factor=1.0, blend='MIX'):
        m = self.node('ShaderNodeMix', data_type='RGBA', blend_type=blend)
        self.put(factor, m.inputs['Factor'])
        self.put(a, m.inputs[6])
        self.put(b, m.inputs[7])
        return m.outputs[2]

    def mixf(self, a, b, factor):
        m = self.node('ShaderNodeMix', data_type='FLOAT')
        self.put(factor, m.inputs['Factor'])
        self.put(a, m.inputs[2])
        self.put(b, m.inputs[3])
        return m.outputs[0]

    def rgb(self, c):
        n = self.nodes.new('ShaderNodeRGB')
        n.outputs[0].default_value = tuple(c) + (1,)
        return n.outputs[0]

    def noise(self, co, scale, detail=2.0, rough=0.5):
        return self.node('ShaderNodeTexNoise', {'Vector': co, 'Scale': scale, 'Detail': detail, 'Roughness': rough}).outputs['Fac']

    def xyz(self, co):
        s = self.node('ShaderNodeSeparateXYZ', {'Vector': co})
        return s.outputs['X'], s.outputs['Y'], s.outputs['Z']

    def bump(self, height, strength, distance=0.1, normal=None):
        b = self.node('ShaderNodeBump', {'Height': height, 'Strength': strength, 'Distance': distance})
        if normal is not None:
            self.put(normal, b.inputs['Normal'])
        return b.outputs['Normal']

    def edge_mask(self, radius):
        """1 on rounded convex edges, from a Bevel normal vs the true normal."""
        bev = self.node('ShaderNodeBevel', {'Radius': radius}, samples=8)
        geo = self.node('ShaderNodeNewGeometry')
        dot = self.node('ShaderNodeVectorMath', operation='DOT_PRODUCT')
        self.put(bev.outputs['Normal'], dot.inputs[0])
        self.put(geo.outputs['Normal'], dot.inputs[1])
        return self.math('SUBTRACT', 1.0, dot.outputs['Value'])

    def ao(self, distance, local=False):
        n = self.node('ShaderNodeAmbientOcclusion', {'Distance': distance}, only_local=local, samples=8)
        return n.outputs['AO']

    def attr(self, name):
        return self.node('ShaderNodeAttribute', attribute_name=name).outputs['Fac']

def obj_coords(n):
    return n.node('ShaderNodeTexCoord').outputs['Object']

def world_pos(n):
    return n.node('ShaderNodeNewGeometry').outputs['Position']

# ---------------------------------------------------------------- materials

def metal():
    """Dark aged iron with a pewter shine on worn edges, green-black cavities."""
    n = Nodes('Metal')
    co = world_pos(n)
    wy = n.xyz(co)[1]
    worn = n.math('MAXIMUM', n.attr('wear'), n.maprange(n.edge_mask(0.025), 0.0, 0.05))
    breakup = n.maprange(n.noise(co, 6.0, 2, 0.5), 0.35, 0.62, 0.12, 1.0)
    edge = n.math('MULTIPLY', worn, breakup)
    cavity = n.maprange(n.ao(0.12), 0.85, 0.4)                      # 1 in the deepest cavities
    toplight = n.maprange(wy, -4.9, 4.9, 0.88, 1.12)               # painted top light
    body = n.mix((0.070, 0.078, 0.070, 1), toplight, 1.0, 'MULTIPLY')
    color = n.mix(body, (0.52, 0.50, 0.43, 1), edge)
    color = n.mix(color, (0.020, 0.028, 0.024, 1), cavity)
    verd = n.math('MULTIPLY', n.maprange(cavity, 0.7, 1.0), 0.35)
    color = n.mix(color, (0.10, 0.16, 0.12, 1), verd)
    n.set('Base Color', color)
    if '--wearviz' in args:   # debug: show the worn-edge mask (red) and cavity mask (green)
        viz = n.node('ShaderNodeCombineXYZ', {'X': edge, 'Y': cavity, 'Z': n.attr('wear')}).outputs['Vector']
        n.set('Emission Color', viz)
        n.set('Emission Strength', 1.0)
        n.set('Base Color', (0, 0, 0, 1))
    n.set('Metallic', 1.0)
    n.set('Specular Tint', (0.45, 0.46, 0.42, 1))   # grazing reflections stay iron, not white
    rough = n.mixf(0.42, 0.26, edge)
    n.set('Roughness', n.mixf(rough, 0.65, cavity))
    n.set('Normal', n.bump(n.noise(co, 5.0, 2, 0.5), 0.12, 0.02))
    return n.mat

def leather():
    n = Nodes('Leather')
    co = obj_coords(n)
    x, y, z = n.xyz(co)
    patches = n.noise(co, 1.2, 3, 0.5)
    color = n.ramp(patches, [(0.3, (0.050, 0.022, 0.013)), (0.5, (0.070, 0.032, 0.018)), (0.72, (0.105, 0.048, 0.026))])
    # worn rounded edges: the normal is between two axes on the board bevel
    geo = n.node('ShaderNodeNewGeometry')
    nx, ny, nz = n.xyz(geo.outputs['Normal'])
    dom = n.math('MAXIMUM', n.math('ABSOLUTE', nx), n.math('MAXIMUM', n.math('ABSOLUTE', ny), n.math('ABSOLUTE', nz)))
    wear = n.maprange(dom, 0.97, 0.80)
    color = n.mix(color, (0.20, 0.10, 0.05, 1), wear)
    # one tooled groove at mid-thickness on the board faces
    groove = n.maprange(n.math('ABSOLUTE', n.math('SUBTRACT', z, BOARD_T / 2)), 0.015, 0.008, 0.0, 1.0)
    color = n.mix(color, n.math('SUBTRACT', 1.0, n.math('MULTIPLY', groove, 0.45)), 1.0, 'MULTIPLY')
    n.set('Base Color', color)
    normal = n.bump(n.noise(co, 5.0, 3, 0.55), 0.12, 0.05)
    normal = n.bump(n.math('SUBTRACT', 1.0, groove), 0.4, 0.01, normal)
    n.set('Normal', normal)
    n.set('Roughness', 0.60)
    n.set('Specular IOR Level', 0.35)
    return n.mat

def paper():
    n = Nodes('Paper')
    co = obj_coords(n)
    x, y, z = n.xyz(co)
    u = n.math('ABSOLUTE', x)
    ay = n.math('ABSOLUTE', y)
    color = n.ramp(n.noise(co, 0.4, 2, 0.5), [(0.3, (0.74, 0.60, 0.34)), (0.7, (0.80, 0.66, 0.385))])
    # distance (units) to the nearest cut edge: fore-edge, head or tail
    d = n.math('MINIMUM', n.math('SUBTRACT', U_EDGE, u), n.math('SUBTRACT', Y_EDGE, ay))
    aged = n.math('MULTIPLY', n.maprange(d, 0.42, 0.10, 0.0, 1.0, 'SMOOTHSTEP'), 0.65)
    color = n.mix(color, (0.62, 0.45, 0.24, 1), aged)
    # burnt rims, the boundary wobbled by noise
    dd = n.math('ADD', d, n.math('MULTIPLY', n.math('SUBTRACT', n.noise(co, 3.0, 2, 0.5), 0.5), 0.10))
    rim = n.ramp(n.maprange(dd, 0.0, 0.07), [(0.0, (0.10, 0.045, 0.015)), (0.5, (0.30, 0.17, 0.07)), (1.0, (0.30, 0.17, 0.07))])
    color = n.mix(color, rim, n.maprange(dd, 0.07, 0.025, 0.0, 1.0, 'SMOOTHSTEP'))
    # scorch bites near the fore-edge and the outer corners
    dfore = n.math('SUBTRACT', U_EDGE, u)
    dcx = n.math('SUBTRACT', U_EDGE, u)
    dcy = n.math('SUBTRACT', Y_EDGE, ay)
    dcorner = n.math('SQRT', n.math('ADD', n.math('MULTIPLY', dcx, dcx), n.math('MULTIPLY', dcy, dcy)))
    zone = n.math('MAXIMUM', n.maprange(dfore, 0.15, 0.08), n.maprange(dcorner, 0.35, 0.2))
    bite = n.maprange(n.noise(n.node('ShaderNodeMapping', {'Vector': co, 'Location': (3.1, 7.7, 0)}).outputs['Vector'], 4.0, 2, 0.5), 0.64, 0.70)
    bite = n.math('MULTIPLY', bite, zone)
    color = n.mix(color, (0.16, 0.08, 0.03, 1), n.math('MULTIPLY', bite, 0.85))
    # the gutter shade (multiplier on u); nothing past U_DIVE
    fold = n.ramp(u, [(0.0, (0.05, 0.035, 0.02)), (0.25, (0.32, 0.24, 0.15)), (0.60, (0.72, 0.66, 0.58)), (0.95, (1, 1, 1))])
    color = n.mix(color, fold, 1.0, 'MULTIPLY')
    # foxing: a few faint tea spots, only outside the text rectangles
    for (sx, sy, r) in ((-0.62, 1.45, 0.16), (0.66, 2.55, 0.13), (-6.20, -2.35, 0.11), (6.21, 2.95, 0.10)):
        dx = n.math('SUBTRACT', x, sx)
        dy2 = n.math('SUBTRACT', y, sy)
        dist = n.math('SQRT', n.math('ADD', n.math('MULTIPLY', dx, dx), n.math('MULTIPLY', dy2, dy2)))
        spot = n.maprange(dist, r, r * 0.4, 0.0, 1.0, 'SMOOTHSTEP')
        color = n.mix(color, n.math('SUBTRACT', 1.0, n.math('MULTIPLY', spot, 0.04)), 1.0, 'MULTIPLY')
    color = n.mix(color, n.ao(0.3), 0.6, 'MULTIPLY')
    n.set('Base Color', color)
    stretch = n.node('ShaderNodeMapping', {'Vector': co, 'Scale': (1.0, 6.0, 1.0)})
    fibres = n.noise(stretch.outputs['Vector'], 30, 2, 0.5)
    n.set('Normal', n.bump(fibres, 0.015, 0.01))
    n.set('Roughness', 0.92)
    n.set('Specular IOR Level', 0.15)
    n.set('Subsurface Weight', 0.02)
    return n.mat

def leaves():
    """Leaf walls: per bundle light lip to dark underside, fine leaf lines."""
    n = Nodes('Leaves')
    uv = n.node('ShaderNodeUVMap', uv_map='UVMap').outputs['UV']
    bu, along, _ = n.xyz(uv)       # bu: bundle coordinate 0..7 (fraction = height inside the bundle)
    local = n.math('FRACT', bu)
    color = n.ramp(local, [(0.0, (0.70, 0.57, 0.37)), (0.25, (0.62, 0.49, 0.30)), (0.75, (0.40, 0.28, 0.15)), (1.0, (0.22, 0.14, 0.07))])
    # each bundle a slightly different tone
    tone = n.node('ShaderNodeTexWhiteNoise', noise_dimensions='1D')
    n.put(n.math('FLOOR', bu), tone.inputs['W'])
    color = n.mix(color, n.maprange(tone.outputs['Value'], 0.0, 1.0, 0.92, 1.04), 1.0, 'MULTIPLY')
    lines = n.math('SINE', n.math('MULTIPLY', bu, 2 * math.pi * 3.0))
    color = n.mix(color, n.maprange(lines, -1.0, 1.0, 0.93, 1.0), 1.0, 'MULTIPLY')
    t = n.math('DIVIDE', bu, BUNDLES)
    burn = n.math('MAXIMUM', n.maprange(t, 0.05, 0.0), n.maprange(t, 0.95, 1.0))
    color = n.mix(color, (0.14, 0.07, 0.025, 1), n.math('MULTIPLY', burn, 0.85))
    color = n.mix(color, n.ao(0.15), 1.0, 'MULTIPLY')
    n.set('Base Color', color)
    n.set('Roughness', 0.95)
    n.set('Specular IOR Level', 0.2)
    return n.mat

def silk(name, rgb, width):
    n = Nodes(name)
    uv = n.node('ShaderNodeUVMap', uv_map='UVMap').outputs['UV']
    s, v, _ = n.xyz(uv)   # s: units along the ribbon (0 at its tip, negative before); v: 0..1 across
    edge_d = n.math('MULTIPLY', n.math('MINIMUM', v, n.math('SUBTRACT', 1.0, v)), width)
    selvedge = n.maprange(edge_d, 0.03, 0.022, 0.0, 1.0)
    weave = n.node('ShaderNodeTexWave', {'Vector': uv, 'Scale': 40.0}, wave_type='BANDS', bands_direction='X').outputs['Fac']
    color = n.mix(n.rgb(rgb), n.maprange(weave, 0.0, 1.0, 0.95, 1.0), 1.0, 'MULTIPLY')
    color = n.mix(color, n.math('SUBTRACT', 1.0, n.math('MULTIPLY', selvedge, 0.4)), 1.0, 'MULTIPLY')
    n.set('Base Color', color)
    n.set('Roughness', 0.35)
    n.set('Sheen Weight', 0.6)
    n.set('Sheen Tint', tuple(min(1.0, c * 3 + 0.3) for c in rgb) + (1,))
    n.set('Anisotropic', 0.5)
    tan = n.node('ShaderNodeTangent', direction_type='UV_MAP', uv_map='UVMap')
    n.set('Tangent', tan.outputs['Tangent'])
    return n.mat

def headband():
    n = Nodes('Headband')
    x = n.xyz(obj_coords(n))[0]
    stripes = n.math('GREATER_THAN', n.math('SINE', n.math('MULTIPLY', x, 2 * math.pi / 0.16)), 0.0)
    n.set('Base Color', n.mix((0.30, 0.03, 0.03, 1), (0.75, 0.65, 0.45, 1), stripes))
    n.set('Roughness', 0.55)
    n.set('Sheen Weight', 0.4)
    return n.mat

def gem(name, rgb):
    n = Nodes(name)
    n.set('Base Color', tuple(rgb) + (1,))
    n.set('Roughness', 0.10)
    n.set('Transmission Weight', 0.40)
    n.set('IOR', 1.6)
    n.set('Emission Color', tuple(rgb) + (1,))
    n.set('Emission Strength', 0.02)
    return n.mat

def flat(name, rgb, emit=0.0, rough=1.0):
    n = Nodes(name)
    n.set('Base Color', tuple(rgb) + (1,))
    n.set('Roughness', rough)
    n.set('Specular IOR Level', 0.0 if rough >= 1 else 0.5)
    if emit:
        n.set('Emission Color', tuple(rgb) + (1,))
        n.set('Emission Strength', emit)
    return n.mat

if CLAY:
    _clay = flat('Clay', (0.5, 0.5, 0.5), rough=0.8)
    METAL = LEATHER = PAPER = LEAVES = PURPLE = RED = BAND = GARNET = AMETHYST = _clay
    CREASE = flat('Crease', (0.015, 0.01, 0.008))
else:
    METAL, LEATHER, PAPER, LEAVES = metal(), leather(), paper(), leaves()
    GARNET, AMETHYST = gem('Garnet', (0.30, 0.025, 0.04)), gem('Amethyst', (0.18, 0.05, 0.28))
    PURPLE, RED = silk('Purple', (0.15, 0.04, 0.22), 0.30), silk('Crimson', (0.38, 0.035, 0.03), 0.26)
    BAND, CREASE = headband(), flat('Crease', (0.015, 0.01, 0.008))
MARK = flat('Overlay', (1, 0, 0), 4.0)

# ---------------------------------------------------------------- mesh helpers

def link(obj, *mats, smooth_shade=True):
    for m in mats:
        obj.data.materials.append(m)
    scene.collection.objects.link(obj)
    if obj.type == 'MESH' and smooth_shade:
        for p in obj.data.polygons:
            p.use_smooth = True
    return obj

def mesh_obj(name, verts, faces, mats, attrs=None, uvs=None):
    me = bpy.data.meshes.new(name)
    me.from_pydata([tuple(v) for v in verts], [], [tuple(f) for f in faces])
    if attrs:
        for key, vals in attrs.items():
            a = me.attributes.new(key, 'FLOAT', 'POINT')
            a.data.foreach_set('value', np.asarray(vals, dtype=np.float32).ravel())
    if uvs is not None:   # per-vertex UVs
        layer = me.uv_layers.new(name='UVMap')
        vi = np.empty(len(me.loops), dtype=np.int64)
        me.loops.foreach_get('vertex_index', vi)
        uvs = np.asarray(uvs, dtype=np.float32)
        layer.data.foreach_set('uv', uvs[vi].ravel())
    me.update()
    obj = bpy.data.objects.new(name, me)
    return link(obj, *mats)

def hard_bevel(obj, width, segments=3, angle=40):
    mod = obj.modifiers.new('Bevel', 'BEVEL')
    mod.width, mod.segments = width, segments
    mod.limit_method = 'ANGLE'
    mod.angle_limit = math.radians(angle)
    mod.harden_normals = True
    wn = obj.modifiers.new('WeightedNormal', 'WEIGHTED_NORMAL')
    wn.keep_sharp = True

def box(name, x0, y0, x1, y1, z0, z1, mat, bevel=0.03):
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    for v in bm.verts:
        v.co.x = x0 if v.co.x < 0 else x1
        v.co.y = y0 if v.co.y < 0 else y1
        v.co.z = z0 if v.co.z < 0 else z1
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    obj = bpy.data.objects.new(name, me)
    if bevel:
        hard_bevel(obj, bevel, 3)
    return link(obj, mat)

def wear_from_profile(prof):
    """Convex curvature per profile point (n, z) -> 0..1 wear."""
    P = np.asarray(prof, dtype=float)
    w = np.zeros(len(P))
    for i in range(1, len(P) - 1):
        a, b, c = P[i - 1], P[i], P[i + 1]
        t1, t2 = b - a, c - b
        l = (np.linalg.norm(t1) + np.linalg.norm(t2)) / 2 + 1e-9
        ang = math.atan2(t1[0] * t2[1] - t1[1] * t2[0], t1 @ t2)
        w[i] = -ang / l      # turning clockwise (convex for our profiles) is positive
    return 0.8 * clamp01((w - 8) / 22)

# ---------------------------------------------------------------- signed distance helpers (numpy)

def sd_poly(px, py, poly):
    P = np.asarray(poly, dtype=float)
    d = np.full(px.shape, 1e9)
    s = np.ones(px.shape)
    n = len(P)
    for i in range(n):
        ax, ay = P[i]
        bx, by = P[i - 1]
        ex, ey = bx - ax, by - ay
        wx, wy = px - ax, py - ay
        h = np.clip((wx * ex + wy * ey) / (ex * ex + ey * ey + 1e-12), 0, 1)
        dx, dy = wx - ex * h, wy - ey * h
        d = np.minimum(d, dx * dx + dy * dy)
        c1 = py >= ay
        c2 = py < by
        c3 = ex * wy > ey * wx
        flip = (c1 & c2 & c3) | (~c1 & ~c2 & ~c3)
        s = np.where(flip, -s, s)
    return s * np.sqrt(d)

def sd_box(px, py, x0, x1, y0, y1):
    cx, cy, hx, hy = (x0 + x1) / 2, (y0 + y1) / 2, (x1 - x0) / 2, (y1 - y0) / 2
    qx, qy = np.abs(px - cx) - hx, np.abs(py - cy) - hy
    return np.sqrt(np.maximum(qx, 0) ** 2 + np.maximum(qy, 0) ** 2) + np.minimum(np.maximum(qx, qy), 0)

def sd_circle(px, py, cx, cy, r):
    return np.sqrt((px - cx) ** 2 + (py - cy) ** 2) - r

def star(cx, cy, R, rot=0.0):
    """Waymark: four-point compass star, long points on the diagonals."""
    pts = []
    for k in range(8):
        a = math.radians(45 * k) + rot
        r = R if k % 2 == 1 else 0.62 * R          # odd k: 45, 135, ... long points
        pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
        a2 = a + math.radians(22.5)
        pts.append((cx + 0.30 * R * math.cos(a2), cy + 0.30 * R * math.sin(a2)))
    return pts

def leaf(base, direction, L=0.36, W=0.44, n=40):
    """Arrow-leaf: a pointed ogee, widest at 40% of its length."""
    bx, by = base
    dx, dy = direction
    px, py = -dy, dx
    side = []
    for i in range(n + 1):
        s = i / n
        if s <= 0.4:
            w = W / 2 * math.sqrt(max(0.0, 1 - ((0.4 - s) / 0.4) ** 2))
        else:
            q = (s - 0.4) / 0.6
            w = W / 2 * 0.5 * (1 + math.cos(math.pi * q))
        side.append((s * L, w))
    pts = [(bx + dx * a + px * w, by + dy * a + py * w) for a, w in side]
    pts += [(bx + dx * a - px * w, by + dy * a - py * w) for a, w in reversed(side[1:-1])]
    return pts

def teardrop(c0, c1, r, n=40):
    """A round end of radius r at c0, tapering to a point at c1."""
    (x0, y0), (x1, y1) = c0, c1
    L = math.hypot(x1 - x0, y1 - y0)
    dx, dy = (x1 - x0) / L, (y1 - y0) / L
    th = math.acos(r / L)                      # tangent angle
    base = math.atan2(dy, dx)
    pts = [(x1, y1)]
    for i in range(n + 1):
        a = base + th + (2 * math.pi - 2 * th) * i / n
        pts.append((x0 + r * math.cos(a), y0 + r * math.sin(a)))
    return pts

def plate(d, ztop, rb=0.035, crown=0.0, crown_w=0.15, slope=10.0):
    """Height of a cast plate from the signed distance to its footprint:
    a steep side, a rounded top edge of radius rb, then a crowned top."""
    t = -d
    run = (ztop - rb - ZLOW) / slope
    s = t - run
    side = ZLOW + t * slope
    rr = np.clip(s, 0, rb)
    top = ztop - rb + np.sqrt(np.maximum(rb * rb - (rb - rr) ** 2, 0))
    top = top + crown * np.sin(0.5 * np.pi * clamp01((s - rb) / crown_w))
    z = np.where(s < 0, side, top)
    return np.where(t < 0, ZLOW - 1, z)

def dome(px, py, cx, cy, R, h, base):
    r2 = ((px - cx) ** 2 + (py - cy) ** 2) / (R * R)
    return np.where(r2 < 1, base + h * np.sqrt(np.maximum(1 - r2, 0)), ZLOW - 1)

# ---------------------------------------------------------------- relief meshes (height fields)

class Relief:
    def __init__(self, x0, x1, y0, y1, res=HF):
        self.xs = np.arange(x0, x1 + res / 2, res)
        self.ys = np.arange(y0, y1 + res / 2, res)
        self.X, self.Y = np.meshgrid(self.xs, self.ys)
        self.Z = np.full(self.X.shape, ZLOW)
        self.CUT = np.full(self.X.shape, ZLOW)
        self.res = res

    def sl(self, bx0, bx1, by0, by1):
        r = self.res
        i0 = max(0, int((bx0 - self.xs[0]) / r) - 2)
        i1 = min(len(self.xs), int((bx1 - self.xs[0]) / r) + 3)
        j0 = max(0, int((by0 - self.ys[0]) / r) - 2)
        j1 = min(len(self.ys), int((by1 - self.ys[0]) / r) + 3)
        return (slice(j0, j1), slice(i0, i1))

    def add(self, bbox, fn, cut=None):
        s = self.sl(*bbox)
        X, Y = self.X[s], self.Y[s]
        z = fn(X, Y)
        if cut is not None:   # beyond the board this piece overhangs and stops at z = cut
            outside = (np.abs(X) > OUTER) | (np.abs(Y) > HB)
            self.CUT[s] = np.where((z > self.Z[s]) & outside, cut, self.CUT[s])
        self.Z[s] = np.maximum(self.Z[s], z)

    def apply(self, bbox, fn):
        s = self.sl(*bbox)
        self.Z[s] = fn(self.X[s], self.Y[s], self.Z[s])

    def build(self, name, mat):
        Z = self.Z
        keep_v = Z > self.CUT + 1e-4
        keep = keep_v[:-1, :-1] & keep_v[:-1, 1:] & keep_v[1:, 1:] & keep_v[1:, :-1]
        ny, nx = Z.shape
        idx = np.arange(nx * ny).reshape(ny, nx)
        faces = np.stack([idx[:-1, :-1][keep], idx[:-1, 1:][keep], idx[1:, 1:][keep], idx[1:, :-1][keep]], 1)
        used = np.unique(faces)
        remap = -np.ones(nx * ny, dtype=np.int64)
        remap[used] = np.arange(len(used))
        faces = remap[faces]
        verts = np.stack([self.X.ravel()[used], self.Y.ravel()[used], Z.ravel()[used]], 1)
        # convex curvature -> wear (bright worn edges and rivet tops)
        h = self.res
        Zp = np.pad(Z, 1, mode='edge')
        lap = (Zp[1:-1, 2:] + Zp[1:-1, :-2] + Zp[2:, 1:-1] + Zp[:-2, 1:-1] - 4 * Z) / (h * h)
        k = np.ones(3) / 3
        for axis in (0, 1):
            lap = np.apply_along_axis(lambda m: np.convolve(m, k, mode='same'), axis, lap)
        wear = clamp01((-lap - 6) / 30)
        print('relief %s: %d verts, %d faces' % (name, len(verts), len(faces)))
        return mesh_obj(name, verts, faces, [mat], {'wear': wear.ravel()[used]})

# ---------------------------------------------------------------- boards, spine, crease

for side in (1, -1):
    x0, x1 = sorted((side * SPINE, side * OUTER))
    box('Board', x0, -HB, x1, HB, 0.0, BOARD_T, LEATHER, 0.09)
# spine bulge: a leather cylinder under the gap, its ends rounded by a bevel
bpy.ops.mesh.primitive_cylinder_add(radius=0.20, depth=9.60, location=(0, 0, 0.12), rotation=(math.radians(90), 0, 0), vertices=48)
spine = bpy.context.active_object
spine.data.materials.append(LEATHER)
for p in spine.data.polygons:
    p.use_smooth = True
bev = spine.modifiers.new('Round', 'BEVEL')
bev.width, bev.segments, bev.limit_method = 0.12, 6, 'ANGLE'
box('Crease', -0.025, -Y_EDGE + 0.02, 0.025, Y_EDGE - 0.02, BOARD_T - 0.02, 0.62, CREASE, 0)

# ---------------------------------------------------------------- page blocks

rng = random.Random(11)
STEPS = [rng.uniform(0.02, 0.035) for _ in range(BUNDLES)]
TAUS = [0.0, 0.03, 0.08, 0.2, 0.38, 0.58, 0.78, 0.92]   # rows inside one bundle

def bundle_offset(tau, step):
    """Outward offset inside one bundle: a rounded lip at the top, an undercut below."""
    if tau <= 0.0:
        return 0.0
    if tau < 0.08:
        return step * math.sin(0.5 * math.pi * tau / 0.08)
    q = (tau - 0.08) / 0.92
    return step * (1 - q) ** 1.4

def wall_rows():
    rows = []
    for b in range(BUNDLES):
        for tau in TAUS:
            rows.append(((b + tau) / BUNDLES, b + tau, bundle_offset(tau, STEPS[b])))
    rows.append((1.0, float(BUNDLES), 0.0))
    return rows

def page_samples():
    us = [U_DIVE * (i / 60) ** 1.5 for i in range(60)]
    us += [U_DIVE + (U_ROLL - U_DIVE) * i / 180 for i in range(180)]
    us += [U_ROLL + R_FORE * math.sin(0.5 * math.pi * i / 20) for i in range(21)]
    ys_roll = [Y_ROLL + R_HEAD * math.sin(0.5 * math.pi * i / 16) for i in range(17)]
    ys = [-y for y in reversed(ys_roll)] + [-Y_ROLL + 2 * Y_ROLL * j / 170 for j in range(1, 170)] + ys_roll
    return us, ys

def rim_noise(u, y, k):
    return 0.012 * math.sin(u * 7.3 + y * 1.9 + k * 0.7) * math.sin(u * 2.1 - y * 5.3 + 1.3 + k * 0.3)

def page_block(side):
    us, ys = page_samples()
    nu, nv = len(us), len(ys)
    verts, uvs, faces, fmat = [], [], [], []
    grid = np.empty((nv, nu), dtype=np.int64)
    for j, y in enumerate(ys):
        for i, u in enumerate(us):
            grid[j, i] = len(verts)
            verts.append((side * u, y, float(page_top(u, y, side))))
            uvs.append((0.0, 0.0))
    for j in range(nv - 1):
        for i in range(nu - 1):
            q = [grid[j, i], grid[j, i + 1], grid[j + 1, i + 1], grid[j + 1, i]]
            faces.append(q if side > 0 else q[::-1])
            fmat.append(0)
    # the ring of top-edge vertices: tail (u up), fore-edge (y up), head (u down)
    ring = [(grid[0, i], (0.0, -1.0)) for i in range(nu - 1)]
    ring += [(grid[j, nu - 1], (1.0, -1.0) if j == 0 else (1.0, 1.0) if j == nv - 1 else (1.0, 0.0)) for j in range(nv)]
    ring += [(grid[nv - 1, i], (0.0, 1.0)) for i in range(nu - 2, -1, -1)]
    rows = wall_rows()
    along, prev = [], None
    for vi, _ in ring:
        p = Vector(verts[vi])
        along.append(0.0 if prev is None else along[-1] + (p - prev).length)
        prev = p
    wall = []
    for k, (t, bu, off) in enumerate(rows):
        row = []
        for idx, (vi, (ox, oy)) in enumerate(ring):
            if k == 0:
                row.append(vi)
                uvs[vi] = (0.0, along[idx])   # shared with the top: fine, paper ignores UVs
                continue
            tx, ty, tz = verts[vi]
            u = abs(tx)
            bx = U_FOOT if ox > 0 else u
            by = (Y_FOOT if oy > 0 else -Y_FOOT) if oy != 0 else ty
            bz = BOARD_T + 0.004
            dl = math.hypot(ox, oy)
            nx_, ny_ = ox / dl, oy / dl
            e = off + rim_noise(u, ty, int(bu)) * (1 - t * 0.5) * (1 if t < 0.999 else 0.3)
            wu = u + (bx - u) * t + nx_ * e
            wy = ty + (by - ty) * t + ny_ * e
            wz = tz + (bz - tz) * t
            row.append(len(verts))
            verts.append((side * wu, wy, wz))
            uvs.append((bu, along[idx]))
        wall.append(row)
    for k in range(len(rows) - 1):
        for i in range(len(ring) - 1):
            q = [wall[k][i], wall[k + 1][i], wall[k + 1][i + 1], wall[k][i + 1]]
            faces.append(q if side > 0 else q[::-1])
            fmat.append(1)
    me = bpy.data.meshes.new('Pages')
    me.from_pydata(verts, [], faces)
    me.polygons.foreach_set('material_index', np.asarray(fmat, dtype=np.int32))
    layer = me.uv_layers.new(name='UVMap')
    vi = np.empty(len(me.loops), dtype=np.int64)
    me.loops.foreach_get('vertex_index', vi)
    layer.data.foreach_set('uv', np.asarray(uvs, dtype=np.float32)[vi].ravel())
    me.update()
    obj = bpy.data.objects.new('Pages', me)
    return link(obj, PAPER, LEAVES)

PAGES = [page_block(1), page_block(-1)]

def tail_wall_point(u, t):
    """A point on the tail leaf wall (before the bundle steps) and its outward normal."""
    ztop = float(page_top(u, -Y_EDGE))
    y = -Y_EDGE + (-Y_FOOT + Y_EDGE) * t
    z = ztop + (BOARD_T - ztop) * t
    dy, dz = -Y_FOOT + Y_EDGE, BOARD_T - ztop
    L = math.hypot(dy, dz)
    return y, z, (dz / L, -dy / L)   # normal (ny, nz): points out (-y) and up

# ---------------------------------------------------------------- edge rails (swept profile)

RAIL_N0, RAIL_N1, RAIL_RC = -0.035, 0.24, 0.03
RAIL_GROOVE_C = (RAIL_N0 + RAIL_N1) / 2

def rail_top(n):
    return 0.40 + 0.035 * math.sin(math.pi * min(1.0, max(0.0, (n - RAIL_N0) / (RAIL_N1 - RAIL_N0))))

def rail_profile():
    """(n, z, is_top) from the bottom of the outer lip, over the top, down the inner side."""
    pts = [(RAIL_N0, 0.30, False), (RAIL_N0, 0.34, False)]
    zc = rail_top(RAIL_N0 + RAIL_RC) - RAIL_RC
    for k in range(7):                    # outer rounded corner
        a = math.pi - 0.5 * math.pi * k / 6
        pts.append((RAIL_N0 + RAIL_RC + RAIL_RC * math.cos(a), zc + RAIL_RC * math.sin(a), False))
    m = 48
    for k in range(1, m):
        n = RAIL_N0 + RAIL_RC + (RAIL_N1 - RAIL_N0 - 2 * RAIL_RC) * k / m
        pts.append((n, rail_top(n), True))
    zc = rail_top(RAIL_N1 - RAIL_RC) - RAIL_RC
    for k in range(7):                    # inner rounded corner
        a = 0.5 * math.pi - 0.5 * math.pi * k / 6
        pts.append((RAIL_N1 - RAIL_RC + RAIL_RC * math.cos(a), zc + RAIL_RC * math.sin(a), False))
    pts += [(RAIL_N1, 0.32, False)]
    return pts

def groove_depth(n):
    q = abs(n - RAIL_GROOVE_C) / 0.0175
    return 0.015 * (math.cos(0.5 * math.pi * min(q, 1.0)) ** 2 if q < 1 else 0.0)

def build_rail(name, s0, s1, to_world, stops):
    """Sweep the rail profile along s; the groove stops 0.08 before each stop (rivet/boss: (s, radius))."""
    prof = rail_profile()
    wear = wear_from_profile([(p[0], p[1]) for p in prof])
    ns = int((s1 - s0) / 0.02) + 1
    verts, attrs, faces = [], [], []
    for i in range(ns + 1):
        s = s0 + (s1 - s0) * i / ns
        gap = min([abs(s - c) - r - 0.08 for c, r in stops] + [9.0])
        g = float(smooth(0.0, 0.04, gap))
        for (n, z, top), w in zip(prof, wear):
            zz = z - (groove_depth(n) * g if top else 0.0)
            verts.append(to_world(s, n, zz))
            attrs.append(w + (0.0 if not top else 0.0))
    m = len(prof)
    for i in range(ns):
        for k in range(m - 1):
            faces.append((i * m + k, i * m + k + 1, (i + 1) * m + k + 1, (i + 1) * m + k))
    obj = mesh_obj(name, verts, faces, [METAL], {'wear': attrs})
    # make the normals point out (check one top face)
    me = obj.data
    me.update()
    top_face = me.polygons[(ns // 2) * (m - 1) + m // 2]
    if top_face.normal.z < 0:
        bm = bmesh.new()
        bm.from_mesh(me)
        bmesh.ops.reverse_faces(bm, faces=bm.faces)
        bm.to_mesh(me)
    return obj

HEAD_BOSS_X = 3.05
FORE_BOSS_Y = 2.00
HEAD_RIVETS = [1.35, 2.20, 3.90, 4.75]
FORE_RIVETS = [1.15, 2.85]
LEG_LEN = 1.65
RAIL_RIVET_R = 0.07

for side in (1, -1):
    for sy in (1, -1):
        stops = [(HEAD_BOSS_X, 0.25)] + [(x, RAIL_RIVET_R) for x in HEAD_RIVETS]
        build_rail('RailHead', 0.14, OUTER - 0.6,
                   lambda s, n, z, side=side, sy=sy: (side * s, sy * (HB - n), z), stops)
    stops = [(c * FORE_BOSS_Y, 0.25) for c in (1, -1)] + [(c * y, RAIL_RIVET_R) for y in FORE_RIVETS for c in (1, -1)] + [(0.0, 0.62)]
    build_rail('RailFore', -HB + 0.6, HB - 0.6, lambda s, n, z, side=side: (side * (OUTER - n), s, z), stops)

# ---------------------------------------------------------------- fittings (one quarter, mirrored 4x)

Q = Relief(1.0, 7.86, 0.0, 4.95)
OX, OY = OUTER, HB
RAIL_RIVET_Z = 0.428

# rail rivets
for x in HEAD_RIVETS:
    cy = OY - RAIL_GROOVE_C
    Q.add((x - 0.08, x + 0.08, cy - 0.08, cy + 0.08), lambda X, Y, x=x, cy=cy: dome(X, Y, x, cy, RAIL_RIVET_R, 0.04, RAIL_RIVET_Z))
for y in FORE_RIVETS:
    cx = OX - RAIL_GROOVE_C
    Q.add((cx - 0.08, cx + 0.08, y - 0.08, y + 0.08), lambda X, Y, y=y, cx=cx: dome(X, Y, cx, y, RAIL_RIVET_R, 0.04, RAIL_RIVET_Z))

# mid-rail waymark bosses: star plates raised 0.10 above the rail, centre rivet
def boss(cx, cy):
    pts = star(cx, cy, 0.30)
    Q.add((cx - 0.32, cx + 0.32, cy - 0.32, cy + 0.32),
          lambda X, Y: plate(sd_poly(X, Y, pts), 0.53, rb=0.02, crown=0.03, crown_w=0.07, slope=10), cut=0.22)
    Q.add((cx - 0.1, cx + 0.1, cy - 0.1, cy + 0.1), lambda X, Y: dome(X, Y, cx, cy, 0.08, 0.045, 0.55))
boss(HEAD_BOSS_X, OY - RAIL_GROOVE_C)
boss(OX, FORE_BOSS_Y)

# side catch (the half at y >= 0): two tiers with a pointed outer arch
def catch_outline():
    pts = [(OX - 0.25, -0.55)]
    for i in range(41):
        t = -0.55 + 1.10 * i / 40
        pts.append((OX + 0.30 + 0.08 * (1 - abs(t) / 0.55) ** 0.75, t))
    pts.append((OX - 0.25, 0.55))
    return pts
CATCH = catch_outline()
Q.add((OX - 0.3, OX + 0.42, 0.0, 0.6), lambda X, Y: plate(sd_poly(X, Y, CATCH), 0.62, rb=0.04, crown=0.02, crown_w=0.12, slope=10))
Q.add((OX - 0.3, OX + 0.42, 0.0, 0.6), lambda X, Y: plate(sd_poly(X, Y, CATCH) + 0.08, 0.67, rb=0.03, crown=0.015, crown_w=0.1, slope=10))
Q.add((OX - 0.1, OX + 0.15, 0.28, 0.48), lambda X, Y: dome(X, Y, OX + 0.03, 0.38, 0.07, 0.04, 0.665))

# corner pieces: two legs with a bead rim, pierced openings and arrow-leaf ends
LEG_N0, LEG_N1 = -0.06, 0.34
LEG_BODY = 1.40            # leg body length; the arrow-leaf finishes it to LEG_LEN

def corner_local(X, Y, axis):
    """(a, n): a along the edge away from the corner, n inward from the edge."""
    if axis == 'head':
        return OX - X, OY - Y
    return OY - Y, OX - X

def leg_z(X, Y, axis):
    a, n = corner_local(X, Y, axis)
    d = sd_box(a, n, -0.06, LEG_BODY, LEG_N0, LEG_N1)
    z = plate(d, 0.52, rb=0.035, crown=0.03, crown_w=0.12, slope=12)
    # bead rim along the outer edge
    bead = np.where((a > 0.25) & (a < LEG_BODY - 0.04),
                    0.52 + 0.012 + 0.03 * np.sqrt(np.maximum(0, 1 - ((n - 0.005) / 0.025) ** 2)), ZLOW - 1)
    bead = np.where(np.abs(n - 0.005) < 0.025, bead, ZLOW - 1)
    return np.maximum(z, bead)

def leaf_z(X, Y, axis):
    a, n = corner_local(X, Y, axis)
    pts = leaf((LEG_BODY - 0.10, (LEG_N0 + LEG_N1) / 2), (1.0, 0.0))
    d = sd_poly(a, n, pts)
    z = plate(d, 0.555, rb=0.03, crown=0.02, crown_w=0.08, slope=12)
    groove = (np.abs(n - (LEG_N0 + LEG_N1) / 2) < 0.015 * 1.4) & (a > LEG_BODY - 0.04) & (a < LEG_LEN - 0.08)
    gq = clamp01(1 - np.abs(n - (LEG_N0 + LEG_N1) / 2) / 0.021)
    return np.where(groove & (z > 0.4), z - 0.014 * np.sin(0.5 * np.pi * gq), z)

def holes_z(X, Y, Z, axis):
    a, n = corner_local(X, Y, axis)
    nc = 0.11
    td = teardrop((0.67, nc), (0.95, nc), 0.055)
    d = np.minimum(sd_poly(a, n, td), sd_circle(a, n, 1.13, nc, 0.065))
    cap = BOARD_T - 0.05 + (d + 0.012) * 14
    return np.minimum(Z, np.where(d < 0.05, cap, 9.0))

for axis in ('head', 'fore'):
    if axis == 'head':
        bb = (OX - LEG_LEN - 0.05, OX + 0.1, OY - 0.45, OY + 0.12)
    else:
        bb = (OX - 0.45, OX + 0.12, OY - LEG_LEN - 0.05, OY + 0.1)
    Q.add(bb, lambda X, Y, axis=axis: leg_z(X, Y, axis))
    Q.apply(bb, lambda X, Y, Z, axis=axis: holes_z(X, Y, Z, axis))
    Q.add(bb, lambda X, Y, axis=axis: leaf_z(X, Y, axis))

FIT_MESH = Q.build('Fittings', METAL)
FIT_MESH.scale = (1, 1, 1)
for sx_, sy_ in ((-1, 1), (1, -1), (-1, -1)):
    o = bpy.data.objects.new('Fittings', FIT_MESH.data)
    o.scale = (sx_, sy_, 1)
    scene.collection.objects.link(o)

# corner knobs: a revolved domed boss with a star relief, a bezel and a garnet
KNOB_C = (OX - 0.10, OY - 0.10)
KNOB_R = 0.38

def knob_dome(r):
    r = np.asarray(r, dtype=float)
    return 0.42 + 0.38 * np.maximum(0, 1 - (r / 0.33) ** 2.6) ** 0.55

def knob_profile():
    prof = [(0.380, ZLOW), (0.384, -0.02), (0.389, 0.06), (0.390, 0.15), (0.386, 0.24), (0.376, 0.31),
            (0.362, 0.355), (0.347, 0.385), (0.336, 0.405)]
    for i in range(41):
        r = 0.33 * (1 - i / 40) ** 0.8
        prof.append((r, float(knob_dome(r))))
    return prof

def revolve(name, prof, cx, cy, mat, seg=72):
    verts, faces, attrs = [], [], []
    wear = wear_from_profile([(-r, z) for r, z in prof])   # profile seen with r decreasing
    for (r, z), w in zip(prof[:-1], wear[:-1]):
        for k in range(seg):
            a = 2 * math.pi * k / seg
            verts.append((cx + r * math.cos(a), cy + r * math.sin(a), z))
            attrs.append(w)
    apex = len(verts)
    verts.append((cx, cy, prof[-1][1]))
    attrs.append(0.3)
    for i in range(len(prof) - 2):
        for k in range(seg):
            k2 = (k + 1) % seg
            faces.append((i * seg + k, i * seg + k2, (i + 1) * seg + k2, (i + 1) * seg + k))
    last = (len(prof) - 2) * seg
    for k in range(seg):
        faces.append((last + k, last + (k + 1) % seg, apex))
    return mesh_obj(name, verts, faces, [mat], {'wear': attrs})

def star_on_knob(cx, cy):
    R = Relief(cx - 0.33, cx + 0.33, cy - 0.33, cy + 0.33, res=0.006)
    pts = star(cx, cy, 0.32, rot=math.radians(45))
    def fn(X, Y):
        r = np.sqrt((X - cx) ** 2 + (Y - cy) ** 2)
        t = -sd_poly(X, Y, pts)
        rel = -0.012 + 0.047 * smooth(-0.012, 0.022, t)
        return np.where(r < 0.325, knob_dome(r) + rel, ZLOW - 1)
    R.add((cx - 0.33, cx + 0.33, cy - 0.33, cy + 0.33), fn)
    R.CUT[:] = np.where(np.sqrt((R.X - cx) ** 2 + (R.Y - cy) ** 2) < 0.325,
                        knob_dome(np.sqrt((R.X - cx) ** 2 + (R.Y - cy) ** 2)) - 0.0115, ZLOW)
    return R.build('KnobStar', METAL)

def bezel(x, y, z, r, minor=0.03, claws=0):
    bpy.ops.mesh.primitive_torus_add(major_radius=r, minor_radius=minor, location=(x, y, z), major_segments=64, minor_segments=12)
    ring = bpy.context.active_object
    ring.data.materials.append(METAL)
    for p in ring.data.polygons:
        p.use_smooth = True
    a = ring.data.attributes.new('wear', 'FLOAT', 'POINT')
    a.data.foreach_set('value', np.array([max(0.0, min(1.0, (v.normal.z - 0.4) / 0.5)) for v in ring.data.vertices], dtype=np.float32))
    for k in range(claws):
        ang = math.pi / 4 + k * math.pi / 2
        bpy.ops.mesh.primitive_uv_sphere_add(radius=0.045, location=(x + (r - 0.02) * math.cos(ang), y + (r - 0.02) * math.sin(ang), z + 0.03), segments=20, ring_count=10)
        c = bpy.context.active_object
        c.scale = (1.0 + 0.6 * abs(math.cos(ang)), 1.0 + 0.6 * abs(math.sin(ang)), 0.7)
        c.data.materials.append(METAL)
        for p in c.data.polygons:
            p.use_smooth = True

def gemstone(x, y, z, r, mat):
    bpy.ops.mesh.primitive_ico_sphere_add(radius=r, subdivisions=2, location=(x, y, z))
    obj = bpy.context.active_object
    obj.data.materials.append(mat)
    obj.scale.z = 0.55
    obj.rotation_euler = (0.25, -0.15, 0.6)
    for p in obj.data.polygons:
        p.use_smooth = False
    return obj

KNOB_PROF = knob_profile()
for side in (1, -1):
    for sy in (1, -1):
        cx, cy = side * KNOB_C[0], sy * KNOB_C[1]
        revolve('Knob', KNOB_PROF, cx, cy, METAL)
        star_on_knob(cx, cy)
        bezel(cx, cy, 0.795, 0.16, 0.03)
        gemstone(cx, cy, 0.80, 0.12, GARNET)

# catch gems (amethyst), bezel with 4 claws
for side in (1, -1):
    bezel(side * (OX + 0.04), 0.0, 0.685, 0.21, 0.03, claws=4)
    gemstone(side * (OX + 0.04), 0.0, 0.69, 0.16, AMETHYST)

# spine crest (head) and tail plate
def arch_outline():
    R = 0.6205
    c = R - 0.40
    h = math.sqrt(R * R - c * c)
    pts = [(-0.40, 4.40)]
    for i in range(25):     # left arc up to the tip
        y = 4.40 + h * i / 24
        pts.append((c - math.sqrt(max(0.0, R * R - (y - 4.40) ** 2)), y))
    for i in range(24, -1, -1):
        y = 4.40 + h * i / 24
        pts.append((-(c - math.sqrt(max(0.0, R * R - (y - 4.40) ** 2))), y))
    pts.append((0.40, 4.40))
    return pts

CREST = Relief(-0.5, 0.5, 4.30, 5.02)
ARCH = arch_outline()
CREST.add((-0.5, 0.5, 4.3, 5.02), lambda X, Y: plate(sd_poly(X, Y, ARCH), 0.58, rb=0.035, crown=0.03, crown_w=0.15, slope=10))
CSTAR = star(0.0, 4.66, 0.24)
CREST.add((-0.3, 0.3, 4.4, 4.92), lambda X, Y: plate(sd_poly(X, Y, CSTAR), 0.645, rb=0.02, crown=0.012, crown_w=0.05, slope=10))
CREST.add((-0.1, 0.1, 4.56, 4.76), lambda X, Y: dome(X, Y, 0.0, 4.66, 0.065, 0.04, 0.655))
CREST.build('HeadCrest', METAL)

TAILP = [(-0.30, -4.40), (0.30, -4.40), (0.30, -4.66), (0.0, -4.82), (-0.30, -4.66)]
TAIL = Relief(-0.4, 0.4, -4.9, -4.30)
TAIL.add((-0.4, 0.4, -4.9, -4.3), lambda X, Y: plate(sd_poly(X, Y, TAILP), 0.50, rb=0.035, crown=0.025, crown_w=0.12, slope=10))
TAIL.add((-0.1, 0.1, -4.66, -4.48), lambda X, Y: dome(X, Y, 0.0, -4.57, 0.065, 0.04, 0.515))
TAIL.build('TailPlate', METAL)

# headband in the head gutter dip
bpy.ops.mesh.primitive_cylinder_add(radius=0.07, depth=0.6, location=(0, 4.28, 0.43), rotation=(0, math.radians(90), 0), vertices=32)
hb = bpy.context.active_object
hb.data.materials.append(BAND)
for p in hb.data.polygons:
    p.use_smooth = True

# ---------------------------------------------------------------- ribbons

def catmull(points, per=12):
    pts = [points[0]] + points + [points[-1]]
    out = []
    for i in range(1, len(pts) - 2):
        p0, p1, p2, p3 = pts[i - 1], pts[i], pts[i + 1], pts[i + 2]
        for k in range(per):
            t = k / per
            out.append(0.5 * ((2 * p1) + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t * t + (-p0 + 3 * p1 - 3 * p2 + p3) * t ** 3))
    out.append(points[-1])
    return out

def page_normal(x, y):
    u, side = abs(x), (1 if x > 0 else -1)
    e = 0.01
    zx = (float(page_top(abs(x + e), y, side)) - float(page_top(abs(x - e), y, side))) / (2 * e)
    zy = (float(page_top(u, y + e, side)) - float(page_top(u, y - e, side))) / (2 * e)
    return Vector((-zx, -zy, 1)).normalized()

def rail_ribbon_path(x, x_end, y_end, sway):
    """From the board in front of the leaf wall, over the tail rail, down the front, onto the table."""
    def rt(y):
        return rail_top(HB + y if y < 0 else HB - y)
    P = [Vector((x, -4.445, 0.372)),
         Vector((x, -4.462, 0.425)),
         Vector((x, -4.50, rt(-4.50) + 0.011)),
         Vector((x, -4.60, rt(-4.60) + 0.011)),
         Vector((x, -4.70, rt(-4.70) + 0.011)),
         Vector((x, -4.745, 0.41)),
         Vector((x, -4.752, 0.33)),
         Vector((x + 0.01 * sway, -4.752, 0.20)),
         Vector((x + 0.02 * sway, -4.762, 0.07)),
         Vector((x + 0.03 * sway, -4.778, 0.018)),
         Vector((x + 0.05 * sway, -4.815, TABLE + 0.010)),
         Vector((x + (x_end - x) * 0.55, -4.815 + (y_end + 4.815) * 0.5, TABLE + 0.008)),
         Vector((x_end, y_end, TABLE + 0.008))]
    return P

def ribbon(name, ctrl, width, mat, twist_deg, phase, on_page_until=None):
    curve = catmull(ctrl, 16)
    lengths = [0.0]
    for a, b in zip(curve, curve[1:]):
        lengths.append(lengths[-1] + (b - a).length)
    total = lengths[-1]
    def at(s):
        s = min(max(s, 0.0), total)
        lo, hi = 0, len(lengths) - 1
        while hi - lo > 1:
            m = (lo + hi) // 2
            if lengths[m] < s:
                lo = m
            else:
                hi = m
        t = (s - lengths[lo]) / max(1e-9, lengths[hi] - lengths[lo])
        return curve[lo].lerp(curve[hi], t)
    M = 1600
    C = [at(total * j / M) for j in range(M + 1)]
    frames = []
    for j in range(M + 1):
        tng = (C[min(M, j + 1)] - C[max(0, j - 1)]).normalized()
        face = Vector((0, tng.z, -tng.y))
        if on_page_until is not None and C[j].y > on_page_until - 0.10:
            wpage = float(smooth(on_page_until - 0.10, on_page_until + 0.05, C[j].y))
            face = face.normalized().lerp(page_normal(C[j].x, C[j].y), wpage)
        cross = face.cross(tng).normalized()
        frames.append((cross, tng.cross(cross).normalized()))
    j_hang = next(j for j in range(M + 1) if C[j].y < -4.74 and C[j].z < 0.36)
    j_land = next(j for j in range(j_hang, M + 1) if C[j].z < 0.03)
    s_hang, s_land = total * j_hang / M, total * j_land / M
    NS, NV, notch = 160, 6, 0.12
    verts, uvs = [], []
    for i in range(NS + 1):
        for k in range(NV + 1):
            v = k / NV
            cut = notch * (1 - abs(2 * v - 1))          # V-notch: the middle ends earlier
            s = i / NS * (total - cut)
            cr, nm = frames[round(s / total * M)]
            # twist on the hanging part, back to flat where it lands on the table
            tw = math.radians(twist_deg) * float(smooth(s_hang, s_hang + 0.15, s)) * (1 - float(smooth(s_land - 0.05, s_land + 0.12, s)))
            w = width * (1 + 0.05 * math.sin(s / 0.9 * 2 * math.pi + phase))
            p = at(s) + (cr * math.cos(tw) + nm * math.sin(tw)) * ((v - 0.5) * w)
            if on_page_until is not None and p.y > -Y_FOOT:
                # lie on the surface: the page top and roll-over, then the tail leaf wall
                sd = 1 if p.x > 0 else -1
                if p.y >= -Y_EDGE:
                    zp = float(page_top(abs(p.x), p.y, sd)) + 0.014
                    if p.y > ctrl[1].y:     # the start is tucked under the top leaf
                        zp -= 0.10 * float(smooth(ctrl[1].y, ctrl[0].y, p.y))
                else:
                    t = (p.y + Y_EDGE) / (Y_EDGE - Y_FOOT)
                    zt = float(page_top(abs(p.x), -Y_EDGE, sd))
                    zp = zt + (BOARD_T - zt) * t + 0.14 * (1 - 0.6 * t)   # rest on the bundle lips
                wsurf = 1.0 - float(smooth(-Y_FOOT + 0.04, -Y_FOOT, p.y))
                p.z = p.z + (zp - p.z) * wsurf
            p.z = max(p.z, TABLE + 0.008)
            verts.append(p)
            uvs.append((s - (total - cut), v))
    faces = []
    for i in range(NS):
        for k in range(NV):
            a = i * (NV + 1) + k
            faces.append((a, a + NV + 1, a + NV + 2, a + 1))
    obj = mesh_obj(name, verts, faces, [mat], uvs=uvs)
    V = np.array([tuple(v) for v in verts])
    print('LAYOUT ribbon %s: x %.2f..%.2f, lowest y %.3f' % (name, V[:, 0].min(), V[:, 0].max(), V[:, 1].min()))
    sol = obj.modifiers.new('Thick', 'SOLIDIFY')
    sol.thickness, sol.offset = 0.012, 0.0
    sub = obj.modifiers.new('Smooth', 'SUBSURF')
    sub.levels = sub.render_levels = 1
    return obj

# purple: out from under the top leaf on the right gutter slope, over the tail roll-over and wall
xp = 0.62
ctrl = [Vector((xp, -3.05, float(page_top(xp, -3.05)) - 0.10)),
        Vector((xp, -3.32, float(page_top(xp, -3.32)) + 0.004))]
for y in (-3.60, -3.88, -4.02):
    ctrl.append(Vector((xp, y, float(page_top(xp, y)) + 0.014)))
for y in (-4.12, -4.18):
    ctrl.append(Vector((xp, y - 0.004, float(page_top(xp, y)) + 0.016)))
for t in (0.0, 0.35, 0.7):
    y, z, (ny, nz) = tail_wall_point(xp + 0.004, t)
    ctrl.append(Vector((xp + 0.004, y + ny * 0.045, z + nz * 0.045)))
ctrl += rail_ribbon_path(xp + 0.006, xp + 0.09, -5.08, 1.0)[1:]
ribbon('RibbonPurple', ctrl, 0.30, PURPLE, 24, 0.0, on_page_until=-4.12)

# crimson: out between leaf bundles 3 and 4 of the left tail wall
xr = -0.80
ctrl = []
for t, out in ((0.36, -0.06), (3 / BUNDLES, 0.012), (0.62, 0.035), (0.85, 0.04)):
    y, z, (ny, nz) = tail_wall_point(abs(xr), t)
    ctrl.append(Vector((xr, y + ny * out, z + nz * out)))
ctrl += rail_ribbon_path(xr - 0.004, xr - 0.10, -5.055, -1.0)[1:]
ribbon('RibbonCrimson', ctrl, 0.26, RED, -22, 1.7)

# ---------------------------------------------------------------- shadow catcher, light linking

bpy.ops.mesh.primitive_plane_add(size=1, location=(0, 0, TABLE))
catcher = bpy.context.active_object
catcher.scale = (30.0, 30.0, 1)
catcher.is_shadow_catcher = True

try:
    coll = bpy.data.collections.new('KickerSkip')
    for p in PAGES:
        coll.objects.link(p)
    KICK.light_linking.receiver_collection = coll
    for co in coll.collection_objects:
        co.light_linking.link_state = 'EXCLUDE'
    print('Light linking: kicker excludes the pages')
except Exception as e:
    print('Light linking unavailable, kicker reduced:', e)
    KICK.data.energy = 0.5

# ---------------------------------------------------------------- overlay and layout check

if OVERLAY:
    (_, _), (ty, by) = TEXT_UI
    bm = bmesh.new()
    for x0, x1 in TEXT_UI[0]:
        corners = [(x0, ty), (x1, ty), (x1, by), (x0, by)]
        for (ax, ay), (bx2, by2) in zip(corners, corners[1:] + corners[:1]):
            for k in range(40):
                pts = []
                for t in (k / 40, (k + 1) / 40):
                    ux, uy = ax + (bx2 - ax) * t, ay + (by2 - ay) * t
                    pts.append(world_on_page(ux / 55 - 8, 5 - uy / 55))
                d = (pts[1] - pts[0]).normalized()
                nrm = Vector((-d.y, d.x, 0)) * 0.02
                up = Vector((0, 0, 0.012))
                bm.faces.new([bm.verts.new(p) for p in (pts[0] - nrm + up, pts[1] - nrm + up, pts[1] + nrm + up, pts[0] + nrm + up)])
    mesh = bpy.data.meshes.new('Overlay')
    bm.to_mesh(mesh)
    link(bpy.data.objects.new('Overlay', mesh), MARK)

dg = bpy.context.evaluated_depsgraph_get()
xs, vs = [], []
for ob in scene.objects:
    if ob.type != 'MESH' or ob is catcher or ob.name.startswith('Overlay'):
        continue
    ev = ob.evaluated_get(dg)
    me = ev.to_mesh()
    co = np.empty(len(me.vertices) * 3, dtype=np.float64)
    me.vertices.foreach_get('co', co)
    co = co.reshape(-1, 3)
    mw = np.array(ob.matrix_world)
    p = co @ mw[:3, :3].T + mw[:3, 3]
    p = p[p[:, 2] >= TABLE - 0.001]
    if len(p):
        xs += [p[:, 0].min(), p[:, 0].max()]
        sv = p[:, 1] * COS + p[:, 2] * SIN - CAM_C
        vs += [sv.min(), sv.max()]
    ev.to_mesh_clear()
print('LAYOUT silhouette units: sx %.3f..%.3f sv %.3f..%.3f (bound +/-%.2f, +/-%.2f)' % (min(xs), max(xs), min(vs), max(vs), BOUND_SX, BOUND_SV))
print('LAYOUT silhouette UI: x %.1f..%.1f y %.1f..%.1f' % (ui(min(xs), 0)[0], ui(max(xs), 0)[0], ui(0, max(vs))[1], ui(0, min(vs))[1]))
for name, (x, y, z) in {
        'board head edge': (3.0, HB, BOARD_T),
        'board front face top': (3.0, -HB, BOARD_T),
        'board front face bottom': (3.0, -HB, 0.0),
        'tail leaf wall top (u 3)': (3.0, -Y_EDGE, float(page_top(3.0, -Y_EDGE))),
        'tail leaf wall bottom': (3.0, -Y_FOOT, BOARD_T),
        'page top over text (u 3, y 0)': (3.0, 0.0, float(page_top(3.0, 0.0))),
        'page at spine (y 0)': (0.0, 0.0, float(page_top(0.0, 0.0))),
        'fore-edge roll start': (U_ROLL, 0, float(page_top(U_ROLL, 0))),
        'head roll start (u 6.0)': (6.0, Y_ROLL, float(page_top(6.0, Y_ROLL))),
        'head roll start (u 1.2)': (1.2, Y_ROLL, float(page_top(1.2, Y_ROLL))),
        'tail roll start (u 6.0)': (6.0, -Y_ROLL, float(page_top(6.0, -Y_ROLL))),
        'gutter dive end (u 0.95)': (U_DIVE, 0, float(page_top(U_DIVE, 0))),
        'fore-edge fan top': (U_EDGE, 0, float(page_top(U_EDGE, 0))),
        'fore-edge fan bottom': (U_FOOT, 0, BOARD_T),
        'head knob outer': (OX - 0.10, OY - 0.10 + KNOB_R, 0.0),
        'tail knob outer': (OX - 0.10, -(OY - 0.10 + KNOB_R), -0.02),
        'head crest tip': (0.0, 4.98, 0.0)}.items():
    print('LAYOUT %-30s sx %.3f sv %.3f  UI x %.1f y %.1f' % ((name,) + screen(x, y, z)[0:1] + screen(x, y, z)[1:2] + ui(*screen(x, y, z))))
for x0, x1 in TEXT_UI[0]:
    a = world_on_page(x0 / 55 - 8, 5 - TEXT_UI[1][0] / 55)
    b = world_on_page(x0 / 55 - 8, 5 - TEXT_UI[1][1] / 55)
    u0, u1 = sorted((abs(x0 / 55 - 8), abs(x1 / 55 - 8)))
    print('LAYOUT text rect x %d..%d: u %.3f..%.3f y %.3f..%.3f | margins: gutter %.3f fore %.3f head %.3f tail %.3f'
          % (x0, x1, u0, u1, b.y, a.y, u0 - U_DIVE, U_ROLL - u1, Y_ROLL - a.y, b.y + Y_ROLL))
# slope over the text
uu = np.linspace(1.2, 6.0, 200)
yy = np.linspace(-3.75, 3.78, 200)
UU, YY = np.meshgrid(uu, yy)
Zt = page_top(UU, YY, -1)
gy, gx = np.gradient(Zt, yy, uu)
print('LAYOUT max slope over the text: %.2f deg' % math.degrees(math.atan(np.sqrt(gx ** 2 + gy ** 2).max())))
print('LAYOUT lifted corner at the text corner: %.4f' % float(lift(6.0, -3.73)))

# painterly pass (--paint): Kuwahara on metal, leather, gems and ribbons, mixed at 50%
if '--paint' in args and not CLAY:
    try:
        for ob in scene.objects:
            if ob.type == 'MESH' and ob.data.materials and ob.data.materials[0] in (METAL, LEATHER, GARNET, AMETHYST, PURPLE, RED, BAND):
                ob.pass_index = 1
        scene.view_layers[0].use_pass_object_index = True
        ng = bpy.data.node_groups.new('Painterly', 'CompositorNodeTree')
        ng.interface.new_socket('Image', in_out='OUTPUT', socket_type='NodeSocketColor')
        N, L = ng.nodes, ng.links
        rl = N.new('CompositorNodeRLayers')
        out = N.new('NodeGroupOutput')
        kw = N.new('CompositorNodeKuwahara')
        kw.inputs['Size'].default_value = 3
        try:
            kw.inputs['Type'].default_value = 'Anisotropic'
        except Exception as e:
            print('Kuwahara type:', e)
        L.new(rl.outputs['Image'], kw.inputs['Image'])
        idm = N.new('CompositorNodeIDMask')
        idm.inputs['Index'].default_value = 1
        idx = [o for o in rl.outputs if o.name in ('Object Index', 'IndexOB')][0]
        L.new(idx, idm.inputs['ID value'])
        half = N.new('ShaderNodeMath'); half.operation = 'MULTIPLY'; half.inputs[1].default_value = 0.5
        L.new(idm.outputs['Alpha'], half.inputs[0])
        mx = N.new('ShaderNodeMix'); mx.data_type = 'RGBA'
        L.new(half.outputs[0], mx.inputs['Factor'])
        L.new(rl.outputs['Image'], mx.inputs[6])
        L.new(kw.outputs['Image'], mx.inputs[7])
        sa = N.new('CompositorNodeSetAlpha')
        L.new(mx.outputs[2], sa.inputs['Image'])
        L.new(rl.outputs['Alpha'], sa.inputs['Alpha'])
        try:
            sa.inputs['Type'].default_value = 'Replace Alpha'
        except Exception as e:
            print('SetAlpha type:', e)
        L.new(sa.outputs['Image'], out.inputs[0])
        scene.compositing_node_group = ng
        print('Painterly pass on')
    except Exception as e:
        print('Painterly pass skipped:', e)

scene.render.filepath = OUT
if '--norender' in args:
    sys.exit(0)
bpy.ops.render.render(write_still=True)

# ---------------------------------------------------------------- shadow cleanup and checks
# The shadow catcher also picks up a faint, wide darkening. Keep the shadow
# only near the book and fade it out inside the frame bound.
img = bpy.data.images.load(OUT)
w, h = img.size
px = np.empty(w * h * 4, np.float32)
img.pixels.foreach_get(px)
px = px.reshape(h, w, 4)
alpha = px[..., 3]

def blur(a, r):
    for axis in (0, 1):
        for _ in range(3):
            c = np.cumsum(np.pad(a, [(r + 1, r) if k == axis else (0, 0) for k in (0, 1)], mode='edge'), axis=axis)
            a = (np.take(c, range(2 * r + 1, c.shape[axis]), axis=axis) - np.take(c, range(0, c.shape[axis] - 2 * r - 1), axis=axis)) / (2 * r + 1)
    return a

solid = alpha > 0.97
near = np.clip(blur(solid.astype(np.float32), max(1, int(0.20 * w / 16))) * 3.0, 0, 1)
sxp = (np.arange(w) + 0.5) / w * 16 - 8
svp = (np.arange(h) + 0.5) / h * 10 - 5               # row 0 is the bottom
inside_x = np.clip((BOUND_SX - np.abs(sxp)) / 0.10, 0, 1)
inside_v = np.clip((BOUND_SV - np.abs(svp)) / 0.08, 0, 1)
frame = np.minimum(inside_x[None, :], inside_v[:, None])
alpha = np.where(solid, alpha, alpha * near * frame)
alpha[alpha < 0.012] = 0.0
outside = (np.abs(sxp)[None, :] > BOUND_SX) | (np.abs(svp)[:, None] > BOUND_SV)
print('STATS solid pixels outside the frame bound: %d' % int((solid & outside).sum()))
alpha = np.where(outside, 0.0, alpha)
px[..., 3] = alpha
px[alpha == 0, :3] = 0.0
img.pixels.foreach_set(px.ravel())
img.filepath_raw = OUT
img.file_format = 'TARGA_RAW'
img.save()

# paper in the text rectangles (sRGB values)
(_, _), (ty, by) = TEXT_UI
for x0, x1 in TEXT_UI[0]:
    c0, c1 = int((x0 + 6) / 880 * w), int((x1 - 6) / 880 * w)
    r0, r1 = int(h - (by - 6) / 550 * h), int(h - (ty + 6) / 550 * h)
    reg = px[r0:r1, c0:c1, :3]
    lum = 0.2126 * reg[..., 0] + 0.7152 * reg[..., 1] + 0.0722 * reg[..., 2]
    sm = blur(lum, max(1, int(w / 200)))
    print('STATS text rect %d..%d: mean sRGB (%.3f %.3f %.3f) luma mean %.3f p2 %.3f p98 %.3f smooth-range %.3f'
          % (x0, x1, reg[..., 0].mean(), reg[..., 1].mean(), reg[..., 2].mean(), lum.mean(),
             np.percentile(lum, 2), np.percentile(lum, 98), sm.max() - sm.min()))
print('Saved:', OUT)
