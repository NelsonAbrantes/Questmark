"""Makes a piece of old linen tape for the quest book's map (Glass Forever
Tracker): tape.tga, square, the tape across it from the bottom left to the
top right (it goes over the map's top left corner; the game mirrors it for
the top right one). Yellowed, a little see-through, a fine weave, its ends
torn.
Run: python tape.py <output folder>
"""
import math, random, struct, sys

OUT = sys.argv[1].rstrip('/\\') + '/'
SIZE = 128
HALF_W, HALF_L = 11.0, 56.0  # the tape's half width and half length (pixels)
random.seed(4)


def noise1d(n, seed):
    rnd = random.Random(seed)
    points = [rnd.random() for _ in range(n + 1)]

    def f(t):
        t = max(0.0, min(0.999, t)) * n
        i = int(t)
        k = t - i
        k = k * k * (3 - 2 * k)
        return points[i] + (points[i + 1] - points[i]) * k
    return f


tear_a, tear_b, side_a, side_b = noise1d(12, 1), noise1d(12, 2), noise1d(20, 3), noise1d(20, 4)
stain = noise1d(8, 5)
pixels = bytearray()
c = SIZE / 2
for row in range(SIZE - 1, -1, -1):  # (TGA rows go bottom up; y grows down here)
    y = row + 0.5
    for col in range(SIZE):
        x = col + 0.5
        dx, dy = x - c, y - c
        along = (dx - dy) / math.sqrt(2)   # from the bottom left to the top right
        across = (dx + dy) / math.sqrt(2)
        k = (across / HALF_W + 1) / 2      # 0..1 across the tape
        j = (along / HALF_L + 1) / 2       # 0..1 along it
        # torn ends and slightly uneven sides
        end_a = HALF_L - 6 * tear_a(k) - 2 * math.sin(k * 23)
        end_b = HALF_L - 6 * tear_b(k) - 2 * math.sin(k * 19 + 1)
        width = HALF_W * (0.94 + 0.06 * (side_a(j) if across > 0 else side_b(j)))
        inside = min(width - abs(across), (end_a - along) if along > 0 else (end_b + along))
        a = max(0.0, min(1.0, inside / 1.2))
        # yellowed linen: a fine weave, some stain, darker at its edges
        weave = 0.5 + 0.25 * math.sin(along * 1.9) * math.sin(across * 1.9)
        tone = 0.92 + 0.06 * weave - 0.08 * stain(j) - 0.12 * max(0.0, min(1.0, 1 - inside / 3))
        r, g, b = 0.86 * tone, 0.77 * tone, 0.58 * tone
        alpha = a * (0.80 + 0.08 * weave)
        pixels += bytes((int(b * 255), int(g * 255), int(r * 255), int(alpha * 255)))

header = struct.pack('<BBBHHBHHHHBB', 0, 0, 2, 0, 0, 0, 0, 0, SIZE, SIZE, 32, 8)
with open(OUT + 'tape.tga', 'wb') as f:
    f.write(header + bytes(pixels))
print('done')
