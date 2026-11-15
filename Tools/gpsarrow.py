"""Draws the arrows of the quest GPS (Questmark), pointing up, white (the
game colors them) with a soft dark edge, on a transparent background.
Plain Python, no libraries.

- gpsArrow.tga: an arrow head with a notch at its tail
- gpsChevron.tga: an open V
- gpsDouble.tga: two open Vs, one over the other
- gpsTriangle.tga: a plain triangle
- gpsNeedle.tga: a thin compass needle, its tail darker
- gpsDart.tga: a long thin arrow with a shaft

And the marks of the navigation marker, over the place itself:
- navPin.tga: a map pin, with a hole
- navDiamond.tga: a cut gem, its facets lighter and darker
- navRing.tga: a ring with a dot in the middle
- navFlag.tga: a flag on its pole
- navStar.tga: a four pointed sparkle

Run: python gpsarrow.py <output folder>
"""
import math, struct, sys

SIZE = 64
SAMPLES = 4  # per side, for smooth edges

# Each arrow: parts in a 0..1 square (y down), each a polygon and how light
# it is (1: white)
SHAPES = {
    'gpsArrow': [((0.5, 0.06), (0.86, 0.9), (0.5, 0.7), (0.14, 0.9)), 1.0],
    'gpsChevron': [((0.5, 0.12), (0.9, 0.62), (0.9, 0.84), (0.5, 0.44), (0.1, 0.84), (0.1, 0.62)), 1.0],
    'gpsDouble': [((0.5, 0.06), (0.88, 0.42), (0.88, 0.6), (0.5, 0.3), (0.12, 0.6), (0.12, 0.42)), 1.0,
                  ((0.5, 0.42), (0.88, 0.78), (0.88, 0.96), (0.5, 0.66), (0.12, 0.96), (0.12, 0.78)), 0.8],
    'gpsTriangle': [((0.5, 0.1), (0.88, 0.86), (0.12, 0.86)), 1.0],
    'gpsNeedle': [((0.5, 0.04), (0.64, 0.5), (0.36, 0.5)), 1.0,
                  ((0.36, 0.5), (0.64, 0.5), (0.5, 0.96)), 0.45],
    'gpsDart': [((0.5, 0.04), (0.78, 0.38), (0.57, 0.33), (0.57, 0.96), (0.43, 0.96), (0.43, 0.33), (0.22, 0.38)), 1.0],
}


def circle(cx, cy, r, n=48):
    return tuple((cx + r * math.cos(2 * math.pi * i / n), cy + r * math.sin(2 * math.pi * i / n)) for i in range(n))


# (a part whose lightness is None is a hole: cut out of what's after it)
SHAPES.update({
    'navPin': [circle(0.5, 0.36, 0.11), None,
               circle(0.5, 0.36, 0.3), 1.0,
               ((0.24, 0.5), (0.76, 0.5), (0.5, 0.97)), 1.0],
    'navDiamond': [((0.5, 0.06), (0.86, 0.42), (0.5, 0.42)), 1.0,
                   ((0.5, 0.06), (0.5, 0.42), (0.14, 0.42)), 0.8,
                   ((0.14, 0.42), (0.5, 0.42), (0.5, 0.96)), 0.62,
                   ((0.5, 0.42), (0.86, 0.42), (0.5, 0.96)), 0.82],
    'navRing': [circle(0.5, 0.5, 0.11), 1.0,
                circle(0.5, 0.5, 0.29), None,
                circle(0.5, 0.5, 0.42), 1.0],
    'navFlag': [((0.3, 0.1), (0.86, 0.26), (0.3, 0.46)), 1.0,
                ((0.21, 0.06), (0.29, 0.06), (0.29, 0.95), (0.21, 0.95)), 0.7],
    'navStar': [((0.5, 0.02), (0.6, 0.4), (0.98, 0.5), (0.6, 0.6), (0.5, 0.98), (0.4, 0.6), (0.02, 0.5), (0.4, 0.4)), 1.0],
})


def inside(px, py, poly):
    hit = False
    j = len(poly) - 1
    for i in range(len(poly)):
        xi, yi = poly[i]
        xj, yj = poly[j]
        if (yi > py) != (yj > py) and px < (xj - xi) * (py - yi) / (yj - yi) + xi:
            hit = not hit
        j = i
    return hit


def edge_distance(px, py, poly):
    best = 1e9
    for i in range(len(poly)):
        ax, ay = poly[i]
        bx, by = poly[(i + 1) % len(poly)]
        dx, dy = bx - ax, by - ay
        t = max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)))
        best = min(best, math.hypot(px - (ax + t * dx), py - (ay + t * dy)))
    return best


def draw(parts):
    polys = [(parts[i], parts[i + 1]) for i in range(0, len(parts), 2)]
    pixels = []
    for y in range(SIZE):
        for x in range(SIZE):
            cover, light = 0, 0
            for sy in range(SAMPLES):
                for sx in range(SAMPLES):
                    px = (x + (sx + 0.5) / SAMPLES) / SIZE
                    py = (y + (sy + 0.5) / SAMPLES) / SIZE
                    for poly, shade in polys:
                        if inside(px, py, poly):
                            if shade is not None:
                                cover += 1
                                light += shade
                            break
            n = SAMPLES * SAMPLES
            light = light / cover if cover else 0
            cover /= n
            cx, cy = (x + 0.5) / SIZE, (y + 0.5) / SIZE
            # (a soft dark edge around it, so it reads on any ground)
            near = min(edge_distance(cx, cy, poly) for poly, _ in polys)
            outside = True
            for poly, shade in polys:
                if inside(cx, cy, poly):
                    outside = shade is None
                    break
            glow = max(0, 1 - near / 0.06) * 0.75 if (cover < 1 and outside) else 0
            alpha = cover + glow * (1 - cover)
            mix = cover / alpha if alpha > 0 else 0
            shade = int(255 * mix * light * (0.85 + 0.15 * (1 - cy)))
            pixels.append((shade, shade, shade, int(255 * min(1, alpha))))
    return pixels


def main(out):
    for name, parts in SHAPES.items():
        pixels = draw(parts)
        with open(out.rstrip('/\\') + '/' + name + '.tga', 'wb') as f:
            # uncompressed true color, 32 bits, rows from the top
            f.write(struct.pack('<BBBHHBHHHHBB', 0, 0, 2, 0, 0, 0, 0, 0, SIZE, SIZE, 32, 8 | 32))
            for r, g, b, a in pixels:
                f.write(struct.pack('BBBB', b, g, r, a))


if __name__ == '__main__':
    main(sys.argv[1])
