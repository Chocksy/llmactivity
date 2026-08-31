#!/usr/bin/env python3
"""Generate assets/icon-1024.png: dark rounded square with a 3-ring stack."""
from PIL import Image, ImageDraw

S = 1024
img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
d = ImageDraw.Draw(img)
d.rounded_rectangle((0, 0, S - 1, S - 1), radius=230, fill=(28, 28, 30, 255))

BG = (28, 28, 30)
rings = [((232, 132, 92), 0.07), ((238, 160, 128), 0.07), ((244, 190, 166), 0.48)]  # (color, fraction)

def track(col):  # opaque 22% blend over the squircle; ImageDraw replaces pixels, it does not composite
    return tuple(int(b + (c - b) * 0.22) for c, b in zip(col, BG)) + (255,)

lw, gap, r = 88, 26, S / 2 - 120
for i, (col, frac) in enumerate(rings):
    rr = r - i * (lw + gap)
    box = (S / 2 - rr, S / 2 - rr, S / 2 + rr, S / 2 + rr)
    d.ellipse(box, outline=track(col), width=lw)
    if frac > 0:
        d.arc(box, start=-90, end=-90 + 360 * frac, fill=col + (255,), width=lw)
        # round caps
        import math
        for ang in (-90, -90 + 360 * frac):
            a = math.radians(ang)
            cx, cy = S / 2 + (rr - lw / 2) * math.cos(a), S / 2 + (rr - lw / 2) * math.sin(a)
            d.ellipse((cx - lw / 2, cy - lw / 2, cx + lw / 2, cy + lw / 2), fill=col + (255,))
img.save("assets/icon-1024.png")
print("wrote assets/icon-1024.png")
