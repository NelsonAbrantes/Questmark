"""Draws smudgeBackground.tga (Questmark): a background for the tracker like a
dark smudge of charcoal: cloudy, its wavy edges breaking up into scattered
specks that thin out going out. Gray: the game tints it (Options:
Background color). Its edges stay in the outer 128 pixels, so the tracker
stretches only its middle.

Run: python smudge.py <output folder>
"""
import struct, sys
import numpy as np

SIZE = 512
INSET = 48           # where the edge sits, from the image's side
rng = np.random.default_rng(11)


def noise(shape, cell):
    """Smooth random values, `cell` pixels between the random points"""
    h, w = shape
    grid = rng.random((h // cell + 2, w // cell + 2))
    y, x = np.arange(h) / cell, np.arange(w) / cell
    y0, x0 = y.astype(int), x.astype(int)
    fy, fx = y - y0, x - x0
    fy, fx = fy * fy * (3 - 2 * fy), fx * fx * (3 - 2 * fx)
    a, b = grid[y0][:, x0], grid[y0][:, x0 + 1]
    c, d = grid[y0 + 1][:, x0], grid[y0 + 1][:, x0 + 1]
    top = a + (b - a) * fx[None, :]
    bottom = c + (d - c) * fx[None, :]
    return top + (bottom - top) * fy[:, None]


def fractal(shape, cells, fall=0.55):
    total, weight = np.zeros(shape), 0
    for i, cell in enumerate(cells):
        w = fall ** i
        total += noise(shape, cell) * w
        weight += w
    return total / weight


def main(out):
    shape = (SIZE, SIZE)
    yy, xx = np.mgrid[0:SIZE, 0:SIZE].astype(float)
    side = np.minimum(np.minimum(xx, SIZE - 1 - xx), np.minimum(yy, SIZE - 1 - yy))
    # The edge: wandering in big soft waves, and no hard line: the paint
    # breaks up into specks, fewer and fewer going out, over a soft haze
    bays = (fractal(shape, [90, 45, 22, 11]) - 0.5) * 58
    depth = side - INSET + bays
    t = np.clip((depth + 26) / 60, 0, 1)          # 0 far out, 1 well inside (the specks start early)
    haze = t ** 2.2
    specks = fractal(shape, [4, 2, 1], 0.75)
    dots = np.clip((specks - (1 - t) * 0.95 - 0.05) * 9, 0, 1)
    # (the haze reaches full paint where the specks do: no line between)
    alpha = np.maximum(haze, dots * 0.9 + 0.1 * t)

    # The charcoal: cloudy, darker and lighter patches, a fine grain
    clouds = fractal(shape, [90, 45, 20, 9])
    grain = fractal(shape, [3, 2], 0.8)
    shade = 0.2 + (clouds - 0.5) * 0.16 + (grain - 0.5) * 0.05

    shade = np.clip(shade, 0, 1)

    pixels = np.zeros((SIZE, SIZE, 4), dtype=np.uint8)
    value = (shade * 255).astype(np.uint8)
    for i in range(3):
        pixels[..., i] = value
    pixels[..., 3] = (np.clip(alpha, 0, 1) * 255).astype(np.uint8)
    with open(out.rstrip('/\\') + '/smudgeBackground.tga', 'wb') as f:
        # uncompressed true color, 32 bits, rows from the top
        f.write(struct.pack('<BBBHHBHHHHBB', 0, 0, 2, 0, 0, 0, 0, 0, SIZE, SIZE, 32, 8 | 32))
        f.write(pixels[..., [2, 1, 0, 3]].tobytes())


if __name__ == '__main__':
    main(sys.argv[1])
