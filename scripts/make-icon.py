#!/usr/bin/env python3
"""Generate assets/icon-1024.png: dark rounded square with a 3-ring stack."""
from PIL import Image, ImageDraw

S = 1024
img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
d = ImageDraw.Draw(img)
d.rounded_rectangle((0, 0, S - 1, S - 1), radius=230, fill=(28, 28, 30, 255))

rings = [((232, 132, 92), 0.07), ((242, 176, 148), 0.07), ((250, 214, 196), 0.48)]  # (color, fraction)
lw, gap, r = 88, 26, S / 2 - 120
for i, (col, frac) in enumerate(rings):
    rr = r - i * (lw + gap)
    box = (S / 2 - rr, S / 2 - rr, S / 2 + rr, S / 2 + rr)
    d.ellipse(box, outline=col + (56,), width=lw)
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
