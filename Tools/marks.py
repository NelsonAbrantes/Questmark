"""Renders small marks for the quest book (Glass Forever Tracker) with
Blender, seen from above on a transparent background:
- arrow.tga: an ornate arrow in red ink, pointing right (at the quest
  open in the book)
- tack.tga (not used any more): a brass tack's head
- corner.tga (not used any more): a stitched leather photo corner
- cover.tga: the quest book's front cover (seen as it opens and shuts)
- quill.tga (not used any more): a writing quill lying from the top left to the bottom right,
  its nib at the bottom right (it points at the quest open in the book)
- seal.tga: a red wax seal with a star pressed in it
- stamp.tga: an oval red wax stamp, for "Completed" written on it in the
  game (which turns it a little)

Run: blender -b -P marks.py -- <output folder> <pixels> <samples>
"""
import bpy, bmesh, math, sys, random

args = sys.argv[sys.argv.index('--') + 1:]
OUT, PIXELS, SAMPLES = args[0].rstrip('/\\') + '/', int(args[1]), int(args[2])
random.seed(5)


def reset():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    scene.render.engine = 'CYCLES'
    scene.cycles.device = 'CPU'
    scene.cycles.samples = SAMPLES
    scene.cycles.use_denoising = True
    scene.render.film_transparent = True
    views = [i.identifier for i in scene.view_settings.bl_rna.properties['view_transform'].enum_items]
    scene.view_settings.view_transform = 'AgX' if 'AgX' in views else 'Standard'
    scene.render.image_settings.file_format = 'TARGA_RAW'
    scene.render.image_settings.color_mode = 'RGBA'
    scene.render.resolution_x = scene.render.resolution_y = PIXELS
    scene.render.resolution_percentage = 100
    world = bpy.data.worlds.new('World')
    scene.world = world
    world.use_nodes = True
    world.node_tree.nodes['Background'].inputs['Color'].default_value = (0.7, 0.62, 0.52, 1)
    world.node_tree.nodes['Background'].inputs['Strength'].default_value = 0.5
    for name, energy, rot, color in (('Key', 3.2, (35, -25, -30), (1.0, 0.92, 0.8)),
                                     ('Fill', 0.8, (-35, 30, 10), (0.8, 0.85, 1.0))):
        data = bpy.data.lights.new(name, 'SUN')
        data.energy, data.color, data.angle = energy, color, math.radians(12)
        obj = bpy.data.objects.new(name, data)
        obj.rotation_euler = [math.radians(a) for a in rot]
        scene.collection.objects.link(obj)
    cam_data = bpy.data.cameras.new('Camera')
    cam_data.type = 'ORTHO'
    cam_data.ortho_scale = 2.0
    cam = bpy.data.objects.new('Camera', cam_data)
    cam.location = (0, 0, 10)
    scene.collection.objects.link(cam)
    scene.camera = cam
    return scene


def material(name, color, roughness, metallic=0.0, coat=0.0):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes['Principled BSDF']
    bsdf.inputs['Base Color'].default_value = color + (1,)
    bsdf.inputs['Roughness'].default_value = roughness
    bsdf.inputs['Metallic'].default_value = metallic
    if coat and 'Coat Weight' in bsdf.inputs:
        bsdf.inputs['Coat Weight'].default_value = coat
    return mat, mat.node_tree


def link(obj, mat):
    obj.data.materials.append(mat)
    bpy.context.scene.collection.objects.link(obj)
    for p in obj.data.polygons:
        p.use_smooth = True
    return obj


def render(scene, name):
    scene.render.filepath = OUT + name + '.tga'
    bpy.ops.render.render(write_still=True)


# ---------------------------------------------------------------- the quill

def quill():
    scene = reset()
    # Along the quill: t from 0 (the nib) to 1 (the feather's top), on a
    # gentle curve from the bottom right to the top left
    length = 2.55
    start = (0.86, -0.86)
    base_angle = math.radians(135)

    def spine(t):
        # the shaft bends a little as it rises
        a = base_angle + 0.18 * t * t
        x = start[0] + length * (math.cos(base_angle) * t + 0.05 * t * t * math.cos(base_angle + math.pi / 2))
        y = start[1] + length * (math.sin(base_angle) * t + 0.05 * t * t * math.sin(base_angle + math.pi / 2))
        return x, y, a

    def offset(t, side, along=0.0):
        x, y, a = spine(t)
        nx, ny = -math.sin(a), math.cos(a)
        return x + nx * side + math.cos(a) * along, y + ny * side + math.sin(a) * along

    # The feather: many fine barbs out of the shaft, slanting to the top, in
    # clumps with small gaps (as a real feather), cream with brown bands that
    # darken to the top, a little sheen
    feather = bpy.data.materials.new('Feather')
    feather.use_nodes = True
    nodes, links = feather.node_tree.nodes, feather.node_tree.links
    bsdf = nodes['Principled BSDF']
    attr = nodes.new('ShaderNodeVertexColor')
    attr.layer_name = 'Col'
    links.new(attr.outputs['Color'], bsdf.inputs['Base Color'])
    bsdf.inputs['Roughness'].default_value = 0.55
    if 'Sheen Weight' in bsdf.inputs:
        bsdf.inputs['Sheen Weight'].default_value = 0.7
    if 'Specular IOR Level' in bsdf.inputs:
        bsdf.inputs['Specular IOR Level'].default_value = 0.35

    bm = bmesh.new()
    color = bm.loops.layers.color.new('Col')

    def tone(t, outer):
        # brown bands across the feather, darker towards its top, lighter
        # at the barbs' tips
        band = 0.5 + 0.5 * math.sin(t * 34 + 0.6)
        band = band ** 3
        dark = (0.33, 0.21, 0.11)
        light = (0.90, 0.84, 0.72)
        k = min(1.0, 0.12 + 0.8 * band + 0.35 * max(0.0, t - 0.75) / 0.25)
        k *= 1.0 - 0.25 * outer
        return tuple(light[i] + (dark[i] - light[i]) * k for i in range(3)) + (1.0,)

    barbs = 150
    for side in (1, -1):
        for i in range(barbs):
            t = 0.27 + 0.71 * i / barbs
            k = (t - 0.27) / 0.71
            # the outline: rounded at the top, a narrow start, the side
            # facing down a little wider
            reach = (0.30 if side > 0 else 0.24) * math.sin(math.pi * min(1.0, k * 1.04)) ** 0.75 + 0.02
            # clumps: every few barbs a little shorter, and a few gaps
            reach *= 1.0 - 0.18 * (0.5 + 0.5 * math.sin(i * 0.9 + side))
            if (i % 37) in (17, 18) and side > 0 or (i % 43) in (25,) and side < 0:
                continue
            reach *= random.uniform(0.94, 1.04)
            steps = 6
            width = 0.011
            prev = None
            for s in range(steps + 1):
                f = s / steps
                # each barb slants towards the top and curls outward
                along = reach * 0.55 * f + 0.03 * f * f
                out = side * reach * f
                px, py = offset(t, out, along)
                z = 0.03 + 0.03 * (1 - f) + 0.01 * k
                a = spine(t)[2] + 0.6 * side
                wx, wy = width * math.cos(a) * (1 - 0.6 * f), width * math.sin(a) * (1 - 0.6 * f)
                v1 = bm.verts.new((px - wx, py - wy, z))
                v2 = bm.verts.new((px + wx, py + wy, z))
                if prev:
                    face = bm.faces.new((prev[0], prev[1], v2, v1))
                    for loop in face.loops:
                        loop[color] = tone(t, f)
                prev = (v1, v2)
    mesh = bpy.data.meshes.new('Barbs')
    bm.to_mesh(mesh)
    vane = bpy.data.objects.new('Barbs', mesh)
    vane.modifiers.new('Thick', 'SOLIDIFY').thickness = 0.004
    link(vane, feather)

    # The shaft: thick and pale at the bottom, thin at the top
    shaft_mat, _ = material('Shaft', (0.86, 0.80, 0.66), 0.3)
    curve = bpy.data.curves.new('Shaft', 'CURVE')
    curve.dimensions = '3D'
    curve.bevel_depth = 0.024
    spline = curve.splines.new('POLY')
    n = 24
    spline.points.add(n)
    for i in range(n + 1):
        t = 0.09 + 0.9 * i / n
        x, y, _ = spine(t)
        spline.points[i].co = (x, y, 0.07, 1)
        spline.points[i].radius = 1.0 - 0.75 * (i / n)
    shaft = bpy.data.objects.new('Shaft', curve)
    shaft.data.materials.append(shaft_mat)
    scene.collection.objects.link(shaft)

    # The nib: brass, cut to a point, with its slit, and a drop of ink
    nib_mat, _ = material('Nib', (0.80, 0.58, 0.28), 0.22, 1.0)
    bm = bmesh.new()
    tip = bm.verts.new(offset(0.0, 0) + (0.05,))
    l1 = bm.verts.new(offset(0.07, 0.035) + (0.07,))
    l2 = bm.verts.new(offset(0.12, 0.03) + (0.07,))
    r1 = bm.verts.new(offset(0.07, -0.035) + (0.07,))
    r2 = bm.verts.new(offset(0.12, -0.03) + (0.07,))
    bm.faces.new((tip, l1, l2, r2, r1))
    mesh = bpy.data.meshes.new('Nib')
    bm.to_mesh(mesh)
    nib = bpy.data.objects.new('Nib', mesh)
    nib.modifiers.new('Thick', 'SOLIDIFY').thickness = 0.02
    link(nib, nib_mat)
    slit_mat, _ = material('Slit', (0.05, 0.03, 0.02), 0.5)
    curve = bpy.data.curves.new('Slit', 'CURVE')
    curve.dimensions = '3D'
    curve.bevel_depth = 0.004
    spline = curve.splines.new('POLY')
    spline.points.add(1)
    spline.points[0].co = offset(0.01, 0) + (0.09, 1)
    spline.points[1].co = offset(0.07, 0) + (0.09, 1)
    slit = bpy.data.objects.new('Slit', curve)
    slit.data.materials.append(slit_mat)
    scene.collection.objects.link(slit)
    ink_mat, _ = material('Ink', (0.02, 0.02, 0.05), 0.08, 0, 1)
    bpy.ops.mesh.primitive_uv_sphere_add(radius=0.028, location=offset(0.008, 0) + (0.06,))
    drop = bpy.context.active_object
    drop.scale.z = 0.6
    drop.data.materials.append(ink_mat)
    render(scene, 'quill')


# ---------------------------------------------------------------- the seal

def seal(stamp=False):
    """stamp: a long one, for a word written on it in the game (no star)"""
    scene = reset()
    # (the stamp's picture is square: the game turns it a little)
    wax, tree = material('Wax', (0.42, 0.03, 0.025), 0.28, 0, 0.4)
    nodes, links = tree.nodes, tree.links
    bsdf = nodes['Principled BSDF']
    noise = nodes.new('ShaderNodeTexNoise')
    noise.inputs['Scale'].default_value = 6
    bump = nodes.new('ShaderNodeBump')
    bump.inputs['Strength'].default_value = 0.15
    links.new(noise.outputs['Fac'], bump.inputs['Height'])
    links.new(bump.outputs['Normal'], bsdf.inputs['Normal'])
    if 'Subsurface Weight' in bsdf.inputs:
        bsdf.inputs['Subsurface Weight'].default_value = 0.2

    # The blob: an uneven round puddle of wax, domed
    bm = bmesh.new()
    rings, points = 14, 72
    centre = bm.verts.new((0, 0, 0.16))
    rim = [random.uniform(-1, 1) for _ in range(6)]
    def radius(a):
        r = 0.82
        for k, amp in enumerate(rim):
            r += 0.035 * amp * math.sin((k + 2) * a + k)
        return r
    grid = []
    for j in range(1, rings + 1):
        f = j / rings
        row = []
        for i in range(points):
            a = 2 * math.pi * i / points
            r = radius(a) * f
            # flat top, rounded edge; the pressed ring dips a little
            z = 0.16 * math.cos(min(1, f ** 3) * math.pi / 2) ** 0.5
            if 0.62 < f < 0.72:
                z -= 0.035
            sx, sy = (0.92, 0.58) if stamp else (1, 1)
            row.append(bm.verts.new((sx * r * math.cos(a), sy * r * math.sin(a), z)))
        grid.append(row)
    for i in range(points):
        bm.faces.new((centre, grid[0][i], grid[0][(i + 1) % points]))
    for r0, r1 in zip(grid, grid[1:]):
        for i in range(points):
            bm.faces.new((r0[i], r0[(i + 1) % points], r1[(i + 1) % points], r1[i]))
    mesh = bpy.data.meshes.new('Seal')
    bm.to_mesh(mesh)
    blob = bpy.data.objects.new('Seal', mesh)
    sub = blob.modifiers.new('Smooth', 'SUBSURF')
    sub.levels = sub.render_levels = 2
    link(blob, wax)
    if stamp:
        render(scene, 'stamp')
        return

    # The star pressed in it: a raised eight-pointed star in the middle
    bm = bmesh.new()
    pts = []
    for i in range(16):
        a = math.pi * i / 8 + math.pi / 16
        r = 0.36 if i % 2 == 0 else 0.15
        pts.append(bm.verts.new((r * math.cos(a), r * math.sin(a), 0.17)))
    face = bm.faces.new(pts)
    ext = bmesh.ops.extrude_face_region(bm, geom=[face])
    for v in ext['geom']:
        if isinstance(v, bmesh.types.BMVert):
            v.co.z = 0.2
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    mesh = bpy.data.meshes.new('Star')
    bm.to_mesh(mesh)
    star = bpy.data.objects.new('Star', mesh)
    bev = star.modifiers.new('Bevel', 'BEVEL')
    bev.width, bev.segments = 0.015, 3
    link(star, wax)
    render(scene, 'seal')


# ---------------------------------------------------------------- the arrow

def arrow():
    """An ornate arrow in red ink: fletched tail, thin shaft, a head with
    curled barbs, pointing right. Flat (lit by itself), like ink."""
    scene = reset()
    scene.render.resolution_x, scene.render.resolution_y = PIXELS, PIXELS // 2
    scene.view_settings.view_transform = 'Standard'  # (the ink's own color)
    ink = bpy.data.materials.new('Ink')
    ink.use_nodes = True
    nodes, links = ink.node_tree.nodes, ink.node_tree.links
    for n in list(nodes):
        if n.type != 'OUTPUT_MATERIAL':
            nodes.remove(n)
    emit = nodes.new('ShaderNodeEmission')
    emit.inputs['Color'].default_value = (0.20, 0.012, 0.004, 1)
    emit.inputs['Strength'].default_value = 1.0
    links.new(emit.outputs['Emission'], nodes['Material Output'].inputs['Surface'])
    top = [(-0.94, 0.17), (-0.86, 0.17), (-0.76, 0.05), (-0.74, 0.17), (-0.66, 0.17),
           (-0.56, 0.028), (0.30, 0.028),
           # a little bead on the shaft
           (0.34, 0.06), (0.40, 0.06), (0.44, 0.028),
           # the head's barb, curled back
           (0.50, 0.028), (0.44, 0.16), (0.38, 0.23), (0.44, 0.25), (0.53, 0.2), (0.62, 0.13),
           (0.96, 0.0)]
    outline = top + [(x, -y) for x, y in reversed(top[:-1])]
    # (the bottom half mirrored, the tip once)
    bm = bmesh.new()
    face = bm.faces.new([bm.verts.new((x, y, 0)) for x, y in outline])
    bmesh.ops.triangulate(bm, faces=[face])
    mesh = bpy.data.meshes.new('Arrow')
    bm.to_mesh(mesh)
    obj = bpy.data.objects.new('Arrow', mesh)
    obj.data.materials.append(ink)
    scene.collection.objects.link(obj)
    render(scene, 'arrow')


# ---------------------------------------------------------------- the tack

def tack():
    """A brass tack's round head, domed, seen from above (it pins the
    book's map to the page)."""
    scene = reset()
    brass, _ = material('Brass', (0.85, 0.62, 0.30), 0.28, 1.0)
    bpy.ops.mesh.primitive_uv_sphere_add(radius=0.78, location=(0, 0, 0), segments=48, ring_count=24)
    head = bpy.context.active_object
    head.scale.z = 0.35
    head.data.materials.append(brass)
    for p in head.data.polygons:
        p.use_smooth = True
    # a rim around the dome
    bpy.ops.mesh.primitive_torus_add(major_radius=0.8, minor_radius=0.06, location=(0, 0, 0.02))
    rim = bpy.context.active_object
    rim.data.materials.append(brass)
    for p in rim.data.polygons:
        p.use_smooth = True
    render(scene, 'tack')


# ---------------------------------------------------------------- the corner

def corner():
    """A leather photo corner for the top left of the book's map: a
    triangle of dark leather over the corner, stitched along its long edge
    (the game mirrors it for the other corners)."""
    scene = reset()
    leather = bpy.data.materials.new('Leather')
    leather.use_nodes = True
    nodes, links = leather.node_tree.nodes, leather.node_tree.links
    bsdf = nodes['Principled BSDF']
    coords = nodes.new('ShaderNodeTexCoord')
    patches = nodes.new('ShaderNodeTexNoise')
    patches.inputs['Scale'].default_value = 3
    patches.inputs['Detail'].default_value = 6
    links.new(coords.outputs['Object'], patches.inputs['Vector'])
    ramp = nodes.new('ShaderNodeValToRGB')
    ramp.color_ramp.elements[0].position = 0.3
    ramp.color_ramp.elements[0].color = (0.05, 0.022, 0.012, 1)
    ramp.color_ramp.elements[1].position = 0.75
    ramp.color_ramp.elements[1].color = (0.13, 0.06, 0.03, 1)
    links.new(patches.outputs['Fac'], ramp.inputs['Fac'])
    links.new(ramp.outputs['Color'], bsdf.inputs['Base Color'])
    grain = nodes.new('ShaderNodeTexVoronoi')
    grain.inputs['Scale'].default_value = 60
    links.new(coords.outputs['Object'], grain.inputs['Vector'])
    bump = nodes.new('ShaderNodeBump')
    bump.inputs['Strength'].default_value = 0.45
    bump.inputs['Distance'].default_value = 0.02
    links.new(grain.outputs['Distance'], bump.inputs['Height'])
    links.new(bump.outputs['Normal'], bsdf.inputs['Normal'])
    bsdf.inputs['Roughness'].default_value = 0.5

    # the triangle: its right angle at the top left of the picture
    x0, y0, leg = -0.95, 0.95, 1.7
    bm = bmesh.new()
    face = bm.faces.new([bm.verts.new(v) for v in ((x0, y0, 0), (x0, y0 - leg, 0), (x0 + leg, y0, 0))])
    ext = bmesh.ops.extrude_face_region(bm, geom=[face])
    for v in ext['geom']:
        if isinstance(v, bmesh.types.BMVert):
            v.co.z = 0.08
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    mesh = bpy.data.meshes.new('Corner')
    bm.to_mesh(mesh)
    obj = bpy.data.objects.new('Corner', mesh)
    bev = obj.modifiers.new('Bevel', 'BEVEL')
    bev.width, bev.segments = 0.05, 4
    link(obj, leather)

    # stitches along the long edge, a little in from it
    thread, _ = material('Thread', (0.72, 0.60, 0.42), 0.6)
    inset = 0.16
    ax, ay = x0 + inset * 0.4, y0 - leg + inset * 1.5
    bx, by = x0 + leg - inset * 1.5, y0 - inset * 0.4
    count = 9
    for i in range(count):
        t0, t1 = (i + 0.2) / count, (i + 0.75) / count
        curve = bpy.data.curves.new('Stitch', 'CURVE')
        curve.dimensions = '3D'
        curve.bevel_depth = 0.022
        spline = curve.splines.new('POLY')
        spline.points.add(1)
        spline.points[0].co = (ax + (bx - ax) * t0, ay + (by - ay) * t0, 0.09, 1)
        spline.points[1].co = (ax + (bx - ax) * t1, ay + (by - ay) * t1, 0.09, 1)
        stitch = bpy.data.objects.new('Stitch', curve)
        stitch.data.materials.append(thread)
        scene.collection.objects.link(stitch)
    render(scene, 'corner')


# ---------------------------------------------------------------- the cover

def cover():
    """The quest book's front cover, square (seen as the book opens and
    shuts; its right edge is the spine): dark teal leather, the colour of the
    spellbook's binding and ribbon, its decoration pressed into it as a
    binder's tools do: a gilt line around and a pressed one inside it, and in
    the middle a medallion (a gilt ring, a fine one, four small lozenges, the
    leather in it pressed a little deeper) round a gilt quest mark.

    Two renders: first the decoration alone, flat, as a mask (red: gilt,
    green: pressed without gold); then the leather, the mask pressing it in
    and laying the gold in the gilt parts."""
    masks = OUT + 'cover_mask.png'

    # ---- 1: the decoration as a mask
    scene = reset()
    scene.camera.data.ortho_scale = 2.0
    scene.view_settings.view_transform = 'Standard'
    scene.render.film_transparent = False
    scene.world.node_tree.nodes['Background'].inputs['Color'].default_value = (0, 0, 0, 1)
    scene.render.image_settings.file_format = 'PNG'
    scene.render.image_settings.color_mode = 'RGB'
    scene.cycles.samples = 64
    # (twice as fine as the cover, so its edges are smooth)
    scene.render.resolution_x = scene.render.resolution_y = PIXELS * 2
    for obj in list(scene.collection.objects):
        if obj.type == 'LIGHT':
            bpy.data.objects.remove(obj)

    def flat(name, rgb):
        mat = bpy.data.materials.new(name)
        mat.use_nodes = True
        nodes, links = mat.node_tree.nodes, mat.node_tree.links
        for n in list(nodes):
            if n.type != 'OUTPUT_MATERIAL':
                nodes.remove(n)
        emit = nodes.new('ShaderNodeEmission')
        emit.inputs['Color'].default_value = rgb + (1,)
        links.new(emit.outputs['Emission'], nodes['Material Output'].inputs['Surface'])
        return mat
    gold, blind = flat('Gold', (1, 0, 0)), flat('Blind', (0, 1, 0))

    def shape(name, pts, mat, z=0.0):
        bm = bmesh.new()
        bm.faces.new([bm.verts.new((x, y, z)) for x, y in pts])
        mesh = bpy.data.meshes.new(name)
        bm.to_mesh(mesh)
        obj = bpy.data.objects.new(name, mesh)
        obj.data.materials.append(mat)
        scene.collection.objects.link(obj)

    def stroke(name, pts, width, mat, cyclic=True, z=0.0):
        # a band of the given width along the points (a line)
        n = len(pts)
        bm = bmesh.new()
        inner, outer = [], []
        for i in range(n):
            if not cyclic and (i == 0 or i == n - 1):
                j0, j1 = max(0, i - 1), min(n - 1, i + 1)
            else:
                j0, j1 = (i - 1) % n, (i + 1) % n
            dx, dy = pts[j1][0] - pts[j0][0], pts[j1][1] - pts[j0][1]
            d = math.hypot(dx, dy) or 1
            nx, ny = -dy / d * width / 2, dx / d * width / 2
            inner.append(bm.verts.new((pts[i][0] - nx, pts[i][1] - ny, z)))
            outer.append(bm.verts.new((pts[i][0] + nx, pts[i][1] + ny, z)))
        for i in range(n if cyclic else n - 1):
            k = (i + 1) % n
            bm.faces.new((inner[i], inner[k], outer[k], outer[i]))
        mesh = bpy.data.meshes.new(name)
        bm.to_mesh(mesh)
        obj = bpy.data.objects.new(name, mesh)
        obj.data.materials.append(mat)
        scene.collection.objects.link(obj)

    def rounded(r, inset):
        pts = []
        for cx, cy, a0 in ((r, r, 0), (-r, r, 90), (-r, -r, 180), (r, -r, 270)):
            for i in range(33):
                a = math.radians(a0 + 90 * i / 32)
                pts.append((cx + inset * math.cos(a), cy + inset * math.sin(a)))
        return pts

    def circle(r, n=360):
        return [(r * math.cos(2 * math.pi * i / n), r * math.sin(2 * math.pi * i / n)) for i in range(n)]

    # (the pressed parts drawn first, the gilt ones over them)
    shape('Disc', circle(0.235), blind, 0.0)
    stroke('Groove', rounded(0.76, 0.04), 0.009, blind, z=0.0)
    stroke('Trim', rounded(0.8, 0.06), 0.022, gold, z=0.01)
    stroke('Medallion', circle(0.255), 0.032, gold, z=0.01)
    stroke('Fine', circle(0.215), 0.011, gold, z=0.01)
    for i in range(4):
        a = math.pi / 2 * i
        cx, cy = 0.255 * math.cos(a), 0.255 * math.sin(a)
        ux, uy = math.cos(a), math.sin(a)
        vx, vy = -uy, ux
        shape('Lozenge', [(cx + ux * 0.06, cy + uy * 0.06), (cx + vx * 0.032, cy + vy * 0.032),
                          (cx - ux * 0.06, cy - uy * 0.06), (cx - vx * 0.032, cy - vy * 0.032)], gold, 0.01)
    shape('Bang', [(-0.045, 0.17), (0.045, 0.17), (0.022, -0.05), (-0.022, -0.05)], gold, 0.01)
    shape('Dot', circle(0.036, 96), gold, 0.01)
    for obj in scene.collection.objects:
        if obj.name.startswith('Dot'):
            obj.location.y = -0.12
    scene.render.filepath = masks
    bpy.ops.render.render(write_still=True)

    # ---- 2: the leather, pressed in by the mask
    scene = reset()
    scene.camera.data.ortho_scale = 2.0
    mat = bpy.data.materials.new('Cover')
    mat.use_nodes = True
    nodes, links = mat.node_tree.nodes, mat.node_tree.links
    bsdf = nodes['Principled BSDF']
    co = nodes.new('ShaderNodeTexCoord')
    # the mask over the board: object x and y from -1..1 to the picture's 0..1
    mapping = nodes.new('ShaderNodeMapping')
    mapping.inputs['Location'].default_value = (0.5, 0.5, 0)
    mapping.inputs['Scale'].default_value = (0.5, 0.5, 1)
    links.new(co.outputs['Object'], mapping.inputs['Vector'])
    image = nodes.new('ShaderNodeTexImage')
    image.image = bpy.data.images.load(masks)
    image.image.colorspace_settings.name = 'Non-Color'
    image.interpolation = 'Cubic'
    links.new(mapping.outputs['Vector'], image.inputs['Vector'])
    sep = nodes.new('ShaderNodeSeparateColor')
    links.new(image.outputs['Color'], sep.inputs['Color'])
    gilt_mask, blind_mask = sep.outputs['Red'], sep.outputs['Green']
    pressed = nodes.new('ShaderNodeMath')
    pressed.operation = 'MAXIMUM'
    links.new(gilt_mask, pressed.inputs[0])
    links.new(blind_mask, pressed.inputs[1])

    # the leather
    patches = nodes.new('ShaderNodeTexNoise')
    patches.inputs['Scale'].default_value = 2.2
    patches.inputs['Detail'].default_value = 8
    links.new(co.outputs['Object'], patches.inputs['Vector'])
    ramp = nodes.new('ShaderNodeValToRGB')
    ramp.color_ramp.elements[0].position = 0.3
    ramp.color_ramp.elements[0].color = (0.004, 0.014, 0.02, 1)
    ramp.color_ramp.elements[1].position = 0.75
    ramp.color_ramp.elements[1].color = (0.012, 0.035, 0.045, 1)
    links.new(patches.outputs['Fac'], ramp.inputs['Fac'])
    # (the pressed leather a little darker)
    darker = nodes.new('ShaderNodeMix')
    darker.data_type = 'RGBA'
    darker.blend_type = 'MULTIPLY'
    links.new(blind_mask, darker.inputs['Factor'])
    links.new(ramp.outputs['Color'], darker.inputs['A'])
    darker.inputs['B'].default_value = (0.55, 0.55, 0.55, 1)
    # the gold laid in, the quests' warm yellow, a little uneven
    leaf = nodes.new('ShaderNodeTexNoise')
    leaf.inputs['Scale'].default_value = 40
    links.new(co.outputs['Object'], leaf.inputs['Vector'])
    goldRamp = nodes.new('ShaderNodeValToRGB')
    goldRamp.color_ramp.elements[0].color = (0.85, 0.55, 0.04, 1)
    goldRamp.color_ramp.elements[1].color = (1.0, 0.74, 0.08, 1)
    links.new(leaf.outputs['Fac'], goldRamp.inputs['Fac'])
    color = nodes.new('ShaderNodeMix')
    color.data_type = 'RGBA'
    links.new(gilt_mask, color.inputs['Factor'])
    links.new(darker.outputs['Result'], color.inputs['A'])
    links.new(goldRamp.outputs['Color'], color.inputs['B'])
    links.new(color.outputs['Result'], bsdf.inputs['Base Color'])
    links.new(gilt_mask, bsdf.inputs['Metallic'])
    rough = nodes.new('ShaderNodeMapRange')
    rough.inputs['To Min'].default_value = 0.65
    rough.inputs['To Max'].default_value = 0.28
    links.new(gilt_mask, rough.inputs['Value'])
    links.new(rough.outputs['Result'], bsdf.inputs['Roughness'])

    # the surface: the leather's grain and wrinkles (none in the gold), and
    # the decoration pressed in
    grain = nodes.new('ShaderNodeTexVoronoi')
    grain.inputs['Scale'].default_value = 110
    links.new(co.outputs['Object'], grain.inputs['Vector'])
    wrinkles = nodes.new('ShaderNodeTexNoise')
    wrinkles.inputs['Scale'].default_value = 7
    wrinkles.inputs['Detail'].default_value = 10
    links.new(co.outputs['Object'], wrinkles.inputs['Vector'])
    flatGold = nodes.new('ShaderNodeMath')
    flatGold.operation = 'SUBTRACT'
    flatGold.inputs[0].default_value = 1.0
    links.new(gilt_mask, flatGold.inputs[1])
    grainOff = nodes.new('ShaderNodeMath')
    grainOff.operation = 'MULTIPLY'
    links.new(grain.outputs['Distance'], grainOff.inputs[0])
    links.new(flatGold.outputs[0], grainOff.inputs[1])
    b1 = nodes.new('ShaderNodeBump')
    b1.inputs['Strength'].default_value = 0.3
    b1.inputs['Distance'].default_value = 0.008
    links.new(grainOff.outputs[0], b1.inputs['Height'])
    b2 = nodes.new('ShaderNodeBump')
    b2.inputs['Strength'].default_value = 0.2
    links.new(wrinkles.outputs['Fac'], b2.inputs['Height'])
    links.new(b1.outputs['Normal'], b2.inputs['Normal'])
    b3 = nodes.new('ShaderNodeBump')
    b3.invert = False
    b3.inputs['Strength'].default_value = 0.9
    b3.inputs['Distance'].default_value = 0.02
    links.new(pressed.outputs[0], b3.inputs['Height'])
    links.new(b2.outputs['Normal'], b3.inputs['Normal'])
    links.new(b3.outputs['Normal'], bsdf.inputs['Normal'])

    # the board, its edges rounded and a little worn
    bm = bmesh.new()
    face = bm.faces.new([bm.verts.new((x, y, -0.1)) for x, y in ((-1, -1), (1, -1), (1, 1), (-1, 1))])
    ext = bmesh.ops.extrude_face_region(bm, geom=[face])
    for v in ext['geom']:
        if isinstance(v, bmesh.types.BMVert):
            v.co.z = 0.0
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    mesh = bpy.data.meshes.new('Board')
    bm.to_mesh(mesh)
    board = bpy.data.objects.new('Board', mesh)
    bev = board.modifiers.new('Bevel', 'BEVEL')
    bev.width, bev.segments = 0.05, 4
    link(board, mat)
    render(scene, 'cover')


arrow()
tack()
corner()
cover()
# (quill() makes a quill, not used any more)
# (the wax seal and stamp below aren't used any more; seal(), seal(stamp=True))
