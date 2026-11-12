"""Makes the Questmark logo: the Glass Forever logo's frame and teal
background (its "G" taken out, the background filled in again), and in the
middle the quest book cover's gold medallion (the ring, its four points and
the "!"), cut out with the cover's decoration mask.
Writes Assets/logo.tga (64x64, the AddOns list icon) and PNGs (1024, 512
and 400) in the folder given.
Run: python logo.py <Assets folder> <Glass logo 1024 PNG> <cover_mask.png
     (made by marks.py with the cover)> <PNG folder>
"""
import struct, sys, zlib
import numpy as np

ASSETS = sys.argv[1].rstrip('/\\') + '/'
GLASS_LOGO, COVER_MASK = sys.argv[2], sys.argv[3]
OUT = sys.argv[4].rstrip('/\\') + '/'

SIZE = 1024
MEDALLION = 600   # the medallion's size in the logo (pixels of 1024)
MASK_RADIUS = 0.34  # the medallion's reach on the cover (cover from -1 to 1)


def read_png(path):
    d = open(path, 'rb').read()
    pos, idat = 8, b''
    while pos < len(d):
        n, t = struct.unpack('>I4s', d[pos:pos + 8])
        body = d[pos + 8:pos + 8 + n]
        if t == b'IHDR':
            w, h, depth, ctype = struct.unpack('>IIBB', body[:10])
        elif t == b'IDAT':
            idat += body
        pos += 12 + n
    ch = {2: 3, 6: 4, 0: 1, 4: 2}[ctype]
    bpp = ch * depth // 8
    raw = zlib.decompress(idat)
    stride = w * bpp
    out = np.zeros((h, stride), np.uint8)
    prev = np.zeros(stride, np.int32)
    i = 0
    for y in range(h):
        f = raw[i]
        line = np.frombuffer(raw[i + 1:i + 1 + stride], np.uint8).astype(np.int32)
        i += 1 + stride
        if f == 0:
            cur = line
        elif f == 2:
            cur = (line + prev) & 255
        else:
            cur = np.zeros(stride, np.int32)
            for x in range(stride):
                a = cur[x - bpp] if x >= bpp else 0
                b = prev[x]
                c = prev[x - bpp] if x >= bpp else 0
                if f == 1:
                    p = a
                elif f == 3:
                    p = (a + b) >> 1
                else:
                    pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                    p = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                cur[x] = (line[x] + p) & 255
        out[y] = cur
        prev = cur
    if depth == 16:
        px = out.reshape(h, w * ch, 2)
        img = (px[:, :, 0].astype(np.float64) * 256 + px[:, :, 1]) / 65535
    else:
        img = out.astype(np.float64) / 255
    return img.reshape(h, w, ch)


def load_tga(path):
    d = open(path, 'rb').read()
    w, h = struct.unpack('<HH', d[12:16])
    px = np.frombuffer(d[18 + d[0]:18 + d[0] + w * h * 4], np.uint8).reshape(h, w, 4).astype(np.float64) / 255
    if not d[17] & 0x20:
        px = px[::-1]  # bottom-up rows
    return px[:, :, [2, 1, 0, 3]]


def resample(img, size):
    h, w = img.shape[:2]
    ys = (np.arange(size) + 0.5) * h / size - 0.5
    xs = (np.arange(size) + 0.5) * w / size - 0.5
    y0 = np.clip(np.floor(ys).astype(int), 0, h - 1); y1 = np.clip(y0 + 1, 0, h - 1)
    x0 = np.clip(np.floor(xs).astype(int), 0, w - 1); x1 = np.clip(x0 + 1, 0, w - 1)
    fy = np.clip(ys - np.floor(ys), 0, 1)[:, None, None]
    fx = np.clip(xs - np.floor(xs), 0, 1)[None, :, None]
    a = img[y0][:, x0]; b = img[y0][:, x1]; c = img[y1][:, x0]; e = img[y1][:, x1]
    return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + e * fx) * fy


def blur(img, r):
    # a box blur, three times (close to a soft gaussian)
    for _ in range(3):
        for axis in (0, 1):
            pad = [(0, 0)] * img.ndim
            pad[axis] = (r + 1, r)
            c = np.cumsum(np.pad(img, pad, mode='edge'), axis=axis)
            n = img.shape[axis]
            img = (np.take(c, range(2 * r + 1, 2 * r + 1 + n), axis=axis)
                   - np.take(c, range(0, n), axis=axis)) / (2 * r + 1)
    return img


# ---- the Glass logo without its "G"
logo = read_png(GLASS_LOGO)
rgb, alpha = logo[:, :, :3].copy(), logo[:, :, 3]
p = np.arange(SIZE) + 0.5
x, y = np.meshgrid(p, p)
edge = np.minimum(np.minimum(x, SIZE - x), np.minimum(y, SIZE - y))
radius = np.hypot(x - SIZE / 2, y - SIZE / 2)
inner = (edge > 75) & (radius < 360)  # round the letter, away from the frame
bins = np.minimum((radius / 2).astype(int), SIZE)


def background(teal):
    # the background by its distance from the middle, from the teal pixels
    counts = np.bincount(bins[teal], minlength=SIZE + 1)
    have = counts > 0
    out = np.zeros((SIZE, SIZE, 3))
    for c in range(3):
        sums = np.bincount(bins[teal], weights=rgb[:, :, c][teal], minlength=SIZE + 1)
        profile = np.interp(np.arange(SIZE + 1), np.nonzero(have)[0], sums[have] / counts[have])
        out[:, :, c] = profile[bins]
    return out


# first a rough background (the letter is light), then everything that isn't
# close to it is the letter, with its soft edge
letter = inner & (rgb[:, :, 0] >= 60 / 255)
for _ in range(2):
    letter = blur(letter.astype(np.float64), 3) > 0.01
    back = background(inner & ~letter)
    letter = inner & (np.abs(rgb - back).max(axis=2) > 6 / 255)
letter = blur(letter.astype(np.float64), 3) > 0.01
back = background(inner & ~letter)
rgb[letter] = back[letter]

# ---- the medallion, cut out of the cover with its mask
mask = read_png(COVER_MASK)[:, :, 0]
m = mask.shape[0]
cover = resample(load_tga(ASSETS + 'cover.tga')[:, :, :3], m)
half = int(MASK_RADIUS * m / 2)
lo, hi = m // 2 - half, m // 2 + half
gilt = mask[lo:hi, lo:hi]
gold = cover[lo:hi, lo:hi]
# (the edges' colour from the solid gold next to them, not the leather)
solid = (gilt > 0.95).astype(np.float64)
spread = blur(gold * solid[:, :, None], 3) / np.maximum(blur(solid, 3), 1e-6)[:, :, None]
gold = np.where((gilt > 0.95)[:, :, None], gold, spread)
gold = resample(gold, MEDALLION)
gilt = resample(gilt[:, :, None], MEDALLION)[:, :, 0]

place = slice((SIZE - MEDALLION) // 2, (SIZE - MEDALLION) // 2 + MEDALLION)
full = np.zeros((SIZE, SIZE))
full[place, place] = gilt
art = np.zeros((SIZE, SIZE, 3))
art[place, place] = gold
# a soft dark shadow under it, so it lifts off the teal
shadow = np.roll(blur(full, 6), 10, axis=0) * 0.55
rgb = rgb * (1 - shadow[:, :, None])
rgb = rgb * (1 - full[:, :, None]) + art * full[:, :, None]
result = np.dstack([np.clip(rgb, 0, 1), alpha])


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


write_png(OUT + 'questmark-logo-1024.png', result)
small = result
for size in (512, 256, 128, 64):  # halving steps keep the small ones clean
    small = small.reshape(size, 2, size, 2, 4).mean(axis=(1, 3))
    if size == 512:
        write_png(OUT + 'questmark-logo-512.png', small)
        write_png(OUT + 'questmark-logo-400.png', resample(small, 400))
write_tga(ASSETS + 'logo.tga', small)
print('done')
