"""Makes xpBook.tga for the quest book's rewards (Questmark): the tracker's
xp icon (Assets/xp.tga) in the experience bar's purple over its outline
(Assets/xpOutline.tga) in a dark ink, in one picture, so it can sit in a
line of text. Made at 64 and averaged down to 32 (the size it shows at in
the book: the game shrinks a bigger picture without smoothing it).
Run: python xpbook.py <Assets folder>
"""
import struct, sys

ASSETS = sys.argv[1].rstrip('/\\') + '/'
ICON = (0.62, 0.38, 1.0)      # the experience purple
OUTLINE = (0.10, 0.05, 0.16)  # a dark ink, a touch of purple


def load(name):
    data = open(ASSETS + name, 'rb').read()
    width, height = struct.unpack('<HH', data[12:16])
    return width, height, data[18 + data[0]:]


w, h, icon = load('xp.tga')
_, _, outline = load('xpOutline.tga')
# each pixel premultiplied (colour times alpha), so the averaging below
# doesn't darken the edges
full = []
for i in range(0, w * h * 4, 4):
    # (both white shapes: their alpha is the shape)
    ia, oa = icon[i + 3] / 255, outline[i + 3] / 255
    a = ia + oa * (1 - ia)
    full.append([ICON[c] * ia + OUTLINE[c] * oa * (1 - ia) for c in range(3)] + [a])
half_w, half_h = w // 2, h // 2
out = bytearray()
for y in range(half_h):
    for x in range(half_w):
        px = [full[(2 * y + dy) * w + 2 * x + dx] for dy in (0, 1) for dx in (0, 1)]
        r, g, b, a = (sum(p[k] for p in px) / 4 for k in range(4))
        if a > 0:
            r, g, b = r / a, g / a, b / a
        out += bytes((int(b * 255 + 0.5), int(g * 255 + 0.5), int(r * 255 + 0.5), int(a * 255 + 0.5)))
w, h = half_w, half_h
header = struct.pack('<BBBHHBHHHHBB', 0, 0, 2, 0, 0, 0, 0, 0, w, h, 32, 8)
open(ASSETS + 'xpBook.tga', 'wb').write(header + bytes(out))
print('done')
