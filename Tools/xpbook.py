"""Makes xpBook.tga for the quest book's rewards (Questmark): the tracker's
xp icon (Assets/xp.tga) in the experience bar's purple over its outline
(Assets/xpOutline.tga) in a dark ink, in one picture, so it can sit in a
line of text.
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
out = bytearray()
for i in range(0, w * h * 4, 4):
    # (both white shapes: their alpha is the shape)
    ia, oa = icon[i + 3] / 255, outline[i + 3] / 255
    a = ia + oa * (1 - ia)
    if a > 0:
        rgb = [(ICON[c] * ia + OUTLINE[c] * oa * (1 - ia)) / a for c in range(3)]
    else:
        rgb = [0, 0, 0]
    out += bytes((int(rgb[2] * 255), int(rgb[1] * 255), int(rgb[0] * 255), int(a * 255)))
header = struct.pack('<BBBHHBHHHHBB', 0, 0, 2, 0, 0, 0, 0, 0, w, h, 32, 8)
open(ASSETS + 'xpBook.tga', 'wb').write(header + bytes(out))
print('done')
