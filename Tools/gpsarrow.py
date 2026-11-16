"""Draws the arrows of the quest GPS and the marks of the navigation marker
(Questmark): white and grays (the game colors them), with a raised look (a
bevel lit from the top left), a thin dark outline and a soft shadow under
them, on a transparent background. 128 pixels, drawn 4 times bigger and
brought down, for smooth edges.

GPS arrows (pointing up):
- gpsArrow.tga: an arrow head with a notch at its tail, folded along its middle
- gpsChevron.tga: an open V, folded
- gpsDouble.tga: two open Vs, the back one dimmer
- gpsTriangle.tga: a rounded triangle
- gpsNeedle.tga: a compass needle, its tail dark, a pin in the middle
- gpsDart.tga: a long arrow with a shaft and feathers
- gpsSword.tga: a sword, a groove down its blade, a curved guard, a wrapped grip

Navigation marks (over the place itself):
- navPin.tga: a map pin, with a hole
- navDiamond.tga: a cut gem, its facets lighter and darker
- navRing.tga: a ring with a dot in the middle
- navFlag.tga: a waving flag on its pole
- navStar.tga: a sparkle, four long points and four short
- navQuest.tga: the quest giver's "!"

Run: python gpsarrow.py <output folder> [preview.png]
"""
import math, struct, sys, zlib
import numpy as np

SIZE = 128
SS = 4                      # drawn this many times bigger, then brought down
N = SIZE * SS
BEVEL = 0.055               # how wide the raised edge is (of the image)
OUTLINE = 0.02              # the dark outline
SHADOW_AT = (0.012, 0.022)  # the shadow, right and down
SHADOW_SOFT = 0.05
LIGHT = np.array([-0.5, -0.65, 0.58])
LIGHT = LIGHT / np.linalg.norm(LIGHT)

v, u = (np.mgrid[0:N, 0:N] + 0.5) / N   # u: right, v: down (0..1)


# ---- Shapes as distances (negative inside)

def polygon(points):
    points = [np.array(p, float) for p in points]
    d = np.full(u.shape, 1e9)
    s = np.ones(u.shape)
    j = len(points) - 1
    for i in range(len(points)):
        a, b = points[j], points[i]
        ex, ey = a[0] - b[0], a[1] - b[1]
        if ex * ex + ey * ey < 1e-12:   # (a point twice: no edge)
            j = i
            continue
        wx, wy = u - b[0], v - b[1]
        t = np.clip((wx * ex + wy * ey) / (ex * ex + ey * ey), 0, 1)
        dx, dy = wx - ex * t, wy - ey * t
        d = np.minimum(d, dx * dx + dy * dy)
        c1 = v >= b[1]
        c2 = v < a[1]
        c3 = ex * wy > ey * wx
        flip = (c1 & c2 & c3) | (~c1 & ~c2 & ~c3)
        s = np.where(flip, -s, s)
        j = i
    return s * np.sqrt(d)


def circle(cx, cy, r):
    return np.hypot(u - cx, v - cy) - r


def rounded(d, r):
    return d - r


def cut(a, b):
    return np.maximum(a, -b)


def smooth_union(a, b, k):
    h = np.clip(0.5 + 0.5 * (b - a) / k, 0, 1)
    return b * (1 - h) + a * h - k * h * (1 - h)


def curve(f, n=160):
    return [f(i / (n - 1)) for i in range(n)]


# ---- Drawing

def render(parts, bevel=BEVEL, gloss=0.1):
    """parts: (distance, shade) pairs; shade a number or an array. Each
    pixel takes the shade of the part it's deepest in."""
    dists = np.array([p[0] for p in parts])
    shape = dists.min(axis=0)
    which = dists.argmin(axis=0)
    shade = np.zeros(u.shape)
    for i, (_, s) in enumerate(parts):
        shade = np.where(which == i, s, shade)

    # Raised: a height that climbs over the bevel's width, lit from the top left
    h = np.clip(-shape / bevel, 0, 1)
    h = np.sin(h * math.pi / 2)
    gy, gx = np.gradient(h * bevel * 1.6, 1 / N)
    normal = np.stack([-gx, -gy, np.ones(u.shape)])
    normal /= np.linalg.norm(normal, axis=0)
    lit = np.tensordot(LIGHT, normal, axes=1)
    flat = LIGHT[2]
    light = 0.86 + 0.7 * (lit - flat)
    # (a glint where the edge faces the light, a gloss toward the top)
    shine = np.clip(lit - 0.93, 0, 1) * 4
    light = light + shine + gloss * (0.5 - v)
    color = np.clip(shade * light, 0, 1)

    fill = (shape < 0).astype(float)
    outline = (shape < OUTLINE).astype(float)
    # (the shadow: the shape moved down a little, its edge soft)
    sx, sy = int(SHADOW_AT[0] * N), int(SHADOW_AT[1] * N)
    moved = np.full(u.shape, 1.0)
    moved[sy:, sx:] = shape[:N - sy, :N - sx]
    shadow = 0.5 * np.clip(1 - np.maximum(moved - OUTLINE, 0) / SHADOW_SOFT, 0, 1) ** 2

    alpha = outline + shadow * (1 - outline)
    premul = fill * color + (outline - fill) * 0.05

    def down(a):
        return a.reshape(SIZE, SS, SIZE, SS).mean(axis=(1, 3))

    alpha, premul = down(alpha), down(premul)
    gray = np.where(alpha > 0, premul / np.maximum(alpha, 1e-6), 0)
    return np.clip(gray, 0, 1), np.clip(alpha, 0, 1)


def fold(left, right):
    """A shape folded along its middle: one side lighter"""
    return np.where(u < 0.5, left, right)


# ---- The shapes

def gps_arrow():
    head = rounded(polygon([(0.5, 0.08), (0.85, 0.88), (0.5, 0.7), (0.15, 0.88)]), 0.018)
    return [(head, fold(1.0, 0.78))]


def chevron(top, depth, thick=0.17, wide=0.38):
    return rounded(polygon([(0.5, top), (0.5 + wide, top + depth), (0.5 + wide, top + depth + thick),
                            (0.5, top + thick), (0.5 - wide, top + depth + thick),
                            (0.5 - wide, top + depth)]), 0.02)


def gps_chevron():
    return [(chevron(0.16, 0.42, 0.22), fold(1.0, 0.78))]


def gps_double():
    return [(chevron(0.07, 0.32, 0.16), fold(1.0, 0.8)),
            (chevron(0.42, 0.32, 0.16), fold(0.72, 0.56))]


def gps_triangle():
    return [(rounded(polygon([(0.5, 0.14), (0.84, 0.82), (0.16, 0.82)]), 0.04), 1.0)]


def gps_needle():
    top = polygon([(0.5, 0.05), (0.65, 0.5), (0.35, 0.5)])
    tail = polygon([(0.35, 0.5), (0.65, 0.5), (0.5, 0.95)])
    pin = circle(0.5, 0.5, 0.075)
    return [(pin, 0.95), (top, fold(1.0, 0.76)), (tail, fold(0.42, 0.3))]


def gps_dart():
    head = rounded(polygon([(0.5, 0.05), (0.76, 0.4), (0.5, 0.32), (0.24, 0.4)]), 0.014)
    shaft = rounded(polygon([(0.465, 0.3), (0.535, 0.3), (0.535, 0.84), (0.465, 0.84)]), 0.01)
    right = rounded(polygon([(0.535, 0.7), (0.66, 0.8), (0.66, 0.95), (0.535, 0.86)]), 0.012)
    left = rounded(polygon([(0.465, 0.7), (0.34, 0.8), (0.34, 0.95), (0.465, 0.86)]), 0.012)
    return [(head, fold(1.0, 0.78)), (shaft, 0.82), (right, 0.62), (left, 0.74)]


def nav_pin():
    head = circle(0.5, 0.37, 0.28)
    tip = polygon([(0.27, 0.5), (0.73, 0.5), (0.5, 0.95)])
    body = smooth_union(head, tip, 0.06)
    body = cut(body, circle(0.5, 0.37, 0.105))
    return [(body, 1.0)]


def nav_diamond():
    whole = polygon([(0.3, 0.1), (0.7, 0.1), (0.9, 0.36), (0.5, 0.94), (0.1, 0.36)])
    table = polygon([(0.36, 0.1), (0.64, 0.1), (0.7, 0.36), (0.3, 0.36)])
    crown_l = polygon([(0.3, 0.1), (0.36, 0.1), (0.3, 0.36), (0.1, 0.36)])
    crown_r = polygon([(0.64, 0.1), (0.7, 0.1), (0.9, 0.36), (0.7, 0.36)])
    pav_l = polygon([(0.1, 0.36), (0.3, 0.36), (0.5, 0.94)])
    pav_m = polygon([(0.3, 0.36), (0.7, 0.36), (0.5, 0.94)])
    pav_r = polygon([(0.7, 0.36), (0.9, 0.36), (0.5, 0.94)])
    # (the facets inside the gem, each lighter or darker; the gem's edge
    # makes its outline and bevel)
    facets = [(crown_l, 0.82), (table, 1.0), (crown_r, 0.7), (pav_l, 0.66), (pav_m, 0.84), (pav_r, 0.52)]
    return [(np.maximum(f, whole), s) for f, s in facets]


def nav_ring():
    ring = cut(circle(0.5, 0.5, 0.4), circle(0.5, 0.5, 0.27))
    dot = circle(0.5, 0.5, 0.12)
    return [(ring, 1.0), (dot, 1.0)]


def nav_flag():
    pole = rounded(polygon([(0.215, 0.14), (0.265, 0.14), (0.265, 0.95), (0.215, 0.95)]), 0.008)
    ball = circle(0.24, 0.1, 0.055)

    def wave(x):
        return 0.035 * math.sin((x - 0.27) / 0.6 * 2 * math.pi)

    top = curve(lambda t: (0.27 + 0.62 * t, 0.15 + 0.04 * t + wave(0.27 + 0.62 * t)))
    bottom = curve(lambda t: (0.89 - 0.62 * t, 0.5 + 0.03 * (1 - t) + wave(0.89 - 0.62 * t)))
    notch = [(0.76, 0.35)]
    cloth = rounded(polygon(top + notch + bottom), 0.01)
    folds = 0.82 + 0.18 * np.sin((u - 0.27) / 0.6 * 2 * math.pi + 0.9)
    return [(pole, 0.72), (ball, 1.0), (cloth, folds)]


def nav_star():
    def astroid(scale, turn):
        def point(t):
            a = 2 * math.pi * t
            x, y = math.cos(a) ** 3, math.sin(a) ** 3
            c, s = math.cos(turn), math.sin(turn)
            return (0.5 + scale * (x * c - y * s), 0.5 + scale * (x * s + y * c))
        return polygon(curve(point, 240))

    big = rounded(astroid(0.46, 0), 0.012)
    small = rounded(astroid(0.34, math.pi / 4), 0.012)
    return [(big, 1.0), (small, 0.74)]


def gps_sword():
    # a straight blade with a groove down its middle, folded; a guard curving
    # up at its ends, a wrapped grip and a round pommel with a gem
    blade = rounded(polygon([(0.5, 0.03), (0.59, 0.16), (0.59, 0.6), (0.41, 0.6), (0.41, 0.16)]), 0.008)
    groove = polygon([(0.5, 0.15), (0.525, 0.2), (0.525, 0.56), (0.475, 0.56), (0.475, 0.2)])
    guard = curve(lambda t: (0.22 + 0.56 * t, 0.62 + 0.05 * (2 * t - 1) ** 2), 60)
    guard = [(x, y - 0.055 * (2 * abs(x - 0.5) / 0.56) ** 3) for x, y in guard]
    guard = guard + [(x, y + 0.065) for x, y in reversed(guard)]
    guard = rounded(polygon(guard), 0.014)
    grip = rounded(polygon([(0.46, 0.68), (0.54, 0.68), (0.54, 0.86), (0.46, 0.86)]), 0.008)
    wraps = [rounded(polygon([(0.45, y), (0.55, y), (0.55, y + 0.024), (0.45, y + 0.024)]), 0.008)
             for y in (0.705, 0.755, 0.805)]
    pommel = circle(0.5, 0.905, 0.062)
    gem = circle(0.5, 0.905, 0.028)
    parts = [(gem, 1.0), (np.maximum(groove, blade), fold(0.62, 0.5)), (blade, fold(1.0, 0.74)),
             (guard, fold(0.88, 0.66)), (pommel, fold(0.86, 0.66))]
    parts += [(w, 0.8) for w in wraps]
    return parts + [(grip, 0.5)]


def nav_quest():
    # the quest giver's "!": a tall mark, wider at the top, and its dot
    bar = rounded(polygon([(0.37, 0.06), (0.63, 0.06), (0.56, 0.64), (0.44, 0.64)]), 0.03)
    dot = circle(0.5, 0.83, 0.105)
    return [(bar, fold(1.0, 0.82)), (dot, fold(1.0, 0.82))]


SHAPES = {
    'gpsArrow': gps_arrow, 'gpsChevron': gps_chevron, 'gpsDouble': gps_double,
    'gpsTriangle': gps_triangle, 'gpsNeedle': gps_needle, 'gpsDart': gps_dart,
    'navPin': nav_pin, 'navDiamond': nav_diamond, 'navRing': nav_ring,
    'navFlag': nav_flag, 'navStar': nav_star,
    'gpsSword': gps_sword, 'navQuest': nav_quest,
}
BEVELS = {'navDiamond': 0.03, 'gpsDart': 0.035, 'navFlag': 0.035, 'gpsSword': 0.03}


def write_tga(path, gray, alpha):
    with open(path, 'wb') as f:
        # uncompressed true color, 32 bits, rows from the top
        f.write(struct.pack('<BBBHHBHHHHBB', 0, 0, 2, 0, 0, 0, 0, 0, SIZE, SIZE, 32, 8 | 32))
        g = (gray * 255 + 0.5).astype(np.uint8)
        a = (alpha * 255 + 0.5).astype(np.uint8)
        f.write(np.stack([g, g, g, a], axis=-1).tobytes())


def write_preview(path, images):
    """Every image tinted gold, over a dark and a light ground"""
    tint = np.array([1.0, 0.82, 0.3])
    cell = SIZE + 16
    rows = []
    for ground in (0.12, 0.62):
        row = np.full((cell, cell * len(images), 3), ground)
        for i, (gray, alpha) in enumerate(images):
            rgb = gray[..., None] * tint
            x = i * cell + 8
            region = row[8:8 + SIZE, x:x + SIZE]
            row[8:8 + SIZE, x:x + SIZE] = rgb * alpha[..., None] + region * (1 - alpha[..., None])
        rows.append(row)
    pixels = (np.clip(np.concatenate(rows), 0, 1) * 255).astype(np.uint8)
    h, w, _ = pixels.shape
    raw = b''.join(b'\x00' + pixels[y].tobytes() for y in range(h))

    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)

    with open(path, 'wb') as f:
        f.write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
                + chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b''))


def main(out, preview=None):
    images = []
    for name, make in SHAPES.items():
        gray, alpha = render(make(), BEVELS.get(name, BEVEL))
        write_tga(out.rstrip('/\\') + '/' + name + '.tga', gray, alpha)
        images.append((gray, alpha))
    if preview:
        write_preview(preview, images)


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else None)
