"""Makes the Questmark logo from the quest book's cover (Assets/cover.tga):
its middle (the leather and the gold "!" medallion) in a rounded square,
with a thin gold line inside the edge, like the cover's own frame.
Writes Assets/logo.tga (64x64, the AddOns list icon) and PNGs (512 and 400)
in the folder given.
Run: python logo.py <Assets folder> <PNG folder>
"""
import struct, sys, zlib
import numpy as np

ASSETS = sys.argv[1].rstrip('/\\') + '/'
OUT = sys.argv[2].rstrip('/\\') + '/'

CROP = (270, 754)  # the medallion and some leather around it (cover pixels)
GOLD = np.array([0.93, 0.74, 0.20])
GOLD_DARK = np.array([0.62, 0.45, 0.08])


def load_tga(path):
    d = open(path, 'rb').read()
    w, h = struct.unpack('<HH', d[12:16])
    px = np.frombuffer(d[18 + d[0]:18 + d[0] + w * h * 4], np.uint8).reshape(h, w, 4).astype(np.float64) / 255
    if not d[17] & 0x20:
        px = px[::-1]  # bottom-up rows
    return px[:, :, [2, 1, 0, 3]]  # BGRA -> RGBA


def resample(img, size):
    # area average down / bilinear: the crop is close to the size, bilinear is enough
    h, w = img.shape[:2]
    ys = (np.arange(size) + 0.5) * h / size - 0.5
    xs = (np.arange(size) + 0.5) * w / size - 0.5
    y0 = np.clip(np.floor(ys).astype(int), 0, h - 1); y1 = np.clip(y0 + 1, 0, h - 1)
    x0 = np.clip(np.floor(xs).astype(int), 0, w - 1); x1 = np.clip(x0 + 1, 0, w - 1)
    fy = (ys - np.floor(ys))[:, None, None]; fx = (xs - np.floor(xs))[None, :, None]
    a = img[y0][:, x0]; b = img[y0][:, x1]; c = img[y1][:, x0]; e = img[y1][:, x1]
    return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + e * fx) * fy


def rounded_box_distance(size, inset, radius):
    # signed distance (pixels) to a rounded square inset from the edges
    p = np.arange(size) + 0.5
    x, y = np.meshgrid(p, p)
    half = size / 2 - inset
    qx = np.abs(x - size / 2) - (half - radius)
    qy = np.abs(y - size / 2) - (half - radius)
    outside = np.hypot(np.maximum(qx, 0), np.maximum(qy, 0))
    inside = np.minimum(np.maximum(qx, qy), 0)
    return outside + inside - radius


def make(size):
    cover = load_tga(ASSETS + 'cover.tga')
    a, b = CROP
    img = resample(cover[a:b, a:b, :3], size)
    # a soft darkening towards the edges, so the medallion stands out
    p = (np.arange(size) + 0.5) / size - 0.5
    x, y = np.meshgrid(p, p)
    img *= (1 - 0.35 * np.clip(np.hypot(x, y) / 0.7, 0, 1) ** 2)[:, :, None]
    # the gold line inside the edge (light at the top, darker at the bottom)
    line_w = max(1.0, size * 0.018)
    d = rounded_box_distance(size, size * 0.075, size * 0.11)
    line = np.clip(line_w / 2 - np.abs(d) + 0.5, 0, 1)[:, :, None]
    shade = (0.5 - y)[:, :, None]  # 1 at the top .. 0 at the bottom
    gold = GOLD_DARK + (GOLD - GOLD_DARK) * np.clip(shade * 1.2 + 0.2, 0, 1)
    img = img * (1 - line) + gold * line
    # the rounded square itself
    edge = rounded_box_distance(size, 0, size * 0.16)
    alpha = np.clip(0.5 - edge, 0, 1)
    return np.dstack([np.clip(img, 0, 1), alpha])


def write_png(path, rgba):
    h, w = rgba.shape[:2]
    data = (rgba * 255 + 0.5).astype(np.uint8)
    raw = b''.join(b'\x00' + data[y].tobytes() for y in range(h))
    def chunk(t, body):
        return struct.pack('>I', len(body)) + t + body + struct.pack('>I', zlib.crc32(t + body) & 0xffffffff)
    open(path, 'wb').write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0))
                           + chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b''))


def write_tga(path, rgba):
    h, w = rgba.shape[:2]
    data = (rgba[:, :, [2, 1, 0, 3]] * 255 + 0.5).astype(np.uint8)
    # top-left origin (descriptor 0x28: 8 alpha bits, rows from the top)
    open(path, 'wb').write(struct.pack('<BBBHHBHHHHBB', 0, 0, 2, 0, 0, 0, 0, 0, w, h, 32, 0x28) + data.tobytes())


big = make(1024)  # (drawn big, then made smaller: smooth edges)
small = big
for size in (512, 256, 128, 64):  # halving steps keep the small ones clean
    small = small.reshape(size, 2, size, 2, 4).mean(axis=(1, 3))
    if size == 512:
        write_png(OUT + 'questmark-logo-512.png', small)
        write_png(OUT + 'questmark-logo-400.png', resample(small, 400))
write_tga(ASSETS + 'logo.tga', small)
print('done')
