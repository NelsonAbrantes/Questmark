"""Makes the quest book's map edges (Glass Forever Tracker): a torn, burnt
piece of an old map.
- mapMask.tga: white, its alpha the torn shape (a mask for the map's picture)
- mapBurn.tga: the scorched rim along the torn edge, to lay over the map

The map is 3 x 2 (the images are square and stretched to it, so the noise
and the distances are worked out in that shape).
Run: python mapedge.py <output folder>
"""
import math, random, struct, sys

OUT = sys.argv[1].rstrip('/\\') + '/'
SIZE = 512
ASPECT = 1.5
random.seed(11)


def noise1d(n, seed):
    rnd = random.Random(seed)
    points = [rnd.random() for _ in range(n + 1)]
    points[-1] = points[0]

    def f(t):
        t = (t % 1.0) * n
        i = int(t)
        k = t - i
        k = k * k * (3 - 2 * k)
        return points[i] + (points[i + 1] - points[i]) * k
    return f


coarse, fine, tiny = noise1d(30, 1), noise1d(110, 2), noise1d(400, 3)


def edge_noise(t):
    return 0.55 * coarse(t) + 0.3 * fine(t) + 0.15 * tiny(t)


def write(name, pixels):
    header = struct.pack('<BBBHHBHHHHBB', 0, 0, 2, 0, 0, 0, 0, 0, SIZE, SIZE, 32, 8)
    with open(OUT + name, 'wb') as f:
        f.write(header + bytes(pixels))


mask, burn = bytearray(), bytearray()
for row in range(SIZE - 1, -1, -1):  # (TGA rows go bottom up)
    v = (row + 0.5) / SIZE
    for col in range(SIZE):
        u = (col + 0.5) / SIZE
        x, y = u * ASPECT, v
        # distance in from the nearest edge, and where along the rim that is
        d = min(x, ASPECT - x, y, 1 - y)
        if d == x:
            t = 0.0 + y * 0.25
        elif d == ASPECT - x:
            t = 0.5 + y * 0.25
        elif d == y:
            t = 0.25 + x / ASPECT * 0.25
        else:
            t = 0.75 + x / ASPECT * 0.25
        torn = 0.01 + 0.075 * edge_noise(t) ** 1.5
        inside = d - torn
        # the torn edge: a soft step of a pixel or two
        a = max(0.0, min(1.0, inside / 0.006 + 0.5))
        mask += bytes((255, 255, 255, int(a * 255)))
        # the scorch: dark brown right at the edge, fading in, uneven
        scorch = 0.04 + 0.03 * fine((t * 3.1) % 1)
        k = max(0.0, 1 - inside / scorch) if inside > 0 else 1.0
        k = k ** 1.6 * a
        burn += bytes((10, 26, 52, int(min(1.0, k * 0.92) * 255)))  # (B, G, R: a dark brown)

write('mapMask.tga', mask)
write('mapBurn.tga', burn)
print('done')
