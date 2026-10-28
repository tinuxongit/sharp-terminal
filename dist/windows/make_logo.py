"""Draw Sharp's icon: a dark rounded tile with a prompt chevron and a small
blue sharp sign, in the spirit of the Windows Terminal and PowerShell icons.

usage: python make_logo.py <out.ico> <preview.png>   (needs Pillow)
"""
import sys
from PIL import Image, ImageDraw

S = 1024  # every size is drawn at 4x (or 1024) and downsampled


def lerp(a, b, t):
    return tuple(round(x + (y - x) * t) for x, y in zip(a, b))


def render(size):
    big = max(size * 4, S) if size >= 256 else size * 4
    k = big / S
    img = Image.new("RGBA", (big, big), (0, 0, 0, 0))

    # Tile: a vertical gradient inside a rounded square.
    grad = Image.new("RGBA", (big, big))
    gd = ImageDraw.Draw(grad)
    top, bottom = (52, 56, 74), (24, 25, 34)
    for y in range(big):
        gd.line([(0, y), (big, y)], fill=lerp(top, bottom, y / big) + (255,))
    mask = Image.new("L", (big, big), 0)
    ImageDraw.Draw(mask).rounded_rectangle([40 * k, 40 * k, big - 40 * k, big - 40 * k], radius=170 * k, fill=255)
    img.paste(grad, (0, 0), mask)
    d = ImageDraw.Draw(img)

    def stroke(points, width, color):
        w = round(width * k)
        d.line([(x * k, y * k) for x, y in points], fill=color, width=w, joint="curve")
        r = w / 2
        for x, y in (points[0], points[-1]):
            d.ellipse([x * k - r, y * k - r, x * k + r, y * k + r], fill=color)

    white = (240, 242, 248, 255)
    blue = (58, 156, 255, 255)
    # Tiny sizes need heavier strokes to stay legible.
    heavy = 1.15 if size <= 24 else 1.0

    # The prompt chevron, left of center.
    stroke([(195, 352), (397, 512), (195, 672)], 124 * heavy, white)
    # The sharp sign, about as tall as the chevron, with clear space after it.
    sw = 70 * heavy
    stroke([(667, 340), (640, 684)], sw, blue)
    stroke([(802, 340), (775, 684)], sw, blue)
    stroke([(560, 450), (874, 440)], sw, blue)
    stroke([(548, 580), (862, 570)], sw, blue)

    return img.resize((size, size), Image.LANCZOS)


sizes = [16, 20, 24, 32, 40, 48, 64, 96, 128, 256]
images = [render(s) for s in sizes]
images[-1].save(sys.argv[1], format="ICO", sizes=[(s, s) for s in sizes], append_images=images[:-1])

preview = Image.new("RGBA", (16 + 256 + 16 + 48 + 16 + 32 + 16 + 16 + 16, 256 + 32), (32, 32, 32, 255))
x = 16
for img in (images[-1], images[5], images[3], images[0]):
    preview.alpha_composite(img, (x, 16 + (256 - img.height) // 2))
    x += img.width + 16
preview.save(sys.argv[2])
print("ok")
