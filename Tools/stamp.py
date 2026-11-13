"""Makes stampFrame.tga for the quest book (Questmark): the frame of a rubber
stamp's ink mark, for "Completed" stamped over a quest done (the word is
written by the game in the middle). A rounded box, a thick line and a thin
one inside it, the ink worn in places as a stamp leaves it. White, tinted
in the game.
Run: python stamp.py <Assets folder>
"""
import struct, sys
import numpy as np

ASSETS = sys.argv[1].rstrip('/\\') + '/'
W, H = 512, 224
SS = 2  # drawn twice as big, then made smaller: smooth edges
rng = np.random.default_rng(7)


def rounded_box(w, h, inset, radius):
    # signed distance (pixels) to a rounded box inset from the edges
    y, x = np.mgrid[0:h, 0:w] + 0.5
    qx = np.abs(x - w / 2) - (w / 2 - inset - radius)
    qy = np.abs(y - h / 2) - (h / 2 - inset - radius)
    outside = np.hypot(np.maximum(qx, 0), np.maximum(qy, 0))
    inside = np.minimum(np.maximum(qx, qy), 0)
    return outside + inside - radius


def noise(w, h, cells):
    # smooth random noise: random values on a coarse grid, smoothly blended
    grid = rng.random((cells + 2, int(cells * w / h) + 2))
    ys = np.linspace(0, cells, h)
    xs = np.linspace(0, grid.shape[1] - 2, w)
    y0 = np.floor(ys).astype(int); x0 = np.floor(xs).astype(int)
    fy = ys - y0; fx = xs - x0
    fy = (fy * fy * (3 - 2 * fy))[:, None]; fx = (fx * fx * (3 - 2 * fx))[None, :]
    a = grid[y0][:, x0]; b = grid[y0][:, x0 + 1]; c = grid[y0 + 1][:, x0]; d = grid[y0 + 1][:, x0 + 1]
    return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy


w, h = W * SS, H * SS
# the two lines: thick outside, thin inside
outer = rounded_box(w, h, 10 * SS, 34 * SS)
inner = rounded_box(w, h, 34 * SS, 18 * SS)
thick, thin = 13 * SS, 4 * SS
ink = np.clip(thick / 2 - np.abs(outer + thick / 2) + 0.5, 0, 1)
ink = np.maximum(ink, np.clip(thin / 2 - np.abs(inner) + 0.5, 0, 1))
# a little wobble in the ink's strength, and worn places where it didn't take
grain = 0.55 * noise(w, h, 40) + 0.3 * noise(w, h, 12) + 0.15 * rng.random((h, w))
worn = np.clip((grain - 0.2) * 6, 0, 1)
strength = 0.75 + 0.25 * noise(w, h, 6)
alpha = ink * worn * strength
# down to its size
alpha = alpha.reshape(H, SS, W, SS).mean(axis=(1, 3))

data = np.zeros((H, W, 4), np.uint8)
data[:, :, :3] = 255
data[:, :, 3] = (np.clip(alpha, 0, 1) * 255 + 0.5).astype(np.uint8)
# BGRA, rows from the top (descriptor 0x28)
header = struct.pack('<BBBHHBHHHHBB', 0, 0, 2, 0, 0, 0, 0, 0, W, H, 32, 0x28)
open(ASSETS + 'stampFrame.tga', 'wb').write(header + data[:, :, [2, 1, 0, 3]].tobytes())
print('done')
