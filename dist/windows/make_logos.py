"""Turn the SVG logos in dist/windows/logos/ into the polygons Sharp fills,
written to src/apprt/win32/logos.zon. Sharp has no SVG renderer, so curves
and arcs are flattened here once.

    python dist/windows/make_logos.py

Each logo is one SVG with a 0 0 24 24 viewBox and evenodd paths. A fill
of currentColor (or none) draws in the theme's text color; a fixed color
is kept.
"""
import math
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SOURCE = os.path.join(HERE, "logos")
TARGET = os.path.join(HERE, "..", "..", "src", "apprt", "win32", "logos.zon")
# Flatten curves to within this distance, in viewBox units (24 = whole icon).
TOLERANCE = 0.02

NUMBER = re.compile(r"[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?")


class Tokens:
    def __init__(self, d):
        self.d, self.i = d, 0

    def skip(self):
        while self.i < len(self.d) and self.d[self.i] in " ,\t\r\n":
            self.i += 1

    def command(self):
        self.skip()
        if self.i < len(self.d) and self.d[self.i].isalpha():
            self.i += 1
            return self.d[self.i - 1]
        return None

    def more(self):
        self.skip()
        return self.i < len(self.d) and not self.d[self.i].isalpha()

    def number(self):
        self.skip()
        m = NUMBER.match(self.d, self.i)
        if not m:
            raise ValueError(f"number expected at {self.d[self.i:self.i + 20]!r}")
        self.i = m.end()
        return float(m.group())

    def flag(self):
        # Arc flags are one digit and may touch the next number: "013.04".
        self.skip()
        c = self.d[self.i]
        if c not in "01":
            raise ValueError(f"arc flag expected at {self.d[self.i:self.i + 20]!r}")
        self.i += 1
        return c == "1"


def cubic(p0, p1, p2, p3):
    length = sum(math.dist(a, b) for a, b in ((p0, p1), (p1, p2), (p2, p3)))
    steps = max(2, int(math.ceil(math.sqrt(length / TOLERANCE))))
    out = []
    for k in range(1, steps + 1):
        t = k / steps
        u = 1 - t
        out.append((u**3 * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t**3 * p3[0],
                    u**3 * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t**3 * p3[1]))
    return out


def quadratic(p0, p1, p2):
    return cubic(p0, (p0[0] + 2 / 3 * (p1[0] - p0[0]), p0[1] + 2 / 3 * (p1[1] - p0[1])),
                 (p2[0] + 2 / 3 * (p1[0] - p2[0]), p2[1] + 2 / 3 * (p1[1] - p2[1])), p2)


def arc(p0, rx, ry, angle, large, sweep, p1):
    """Points along an SVG arc, by the spec's endpoint-to-center conversion."""
    if p0 == p1:
        return []
    if rx == 0 or ry == 0:
        return [p1]
    rx, ry = abs(rx), abs(ry)
    phi = math.radians(angle)
    cos, sin = math.cos(phi), math.sin(phi)
    dx, dy = (p0[0] - p1[0]) / 2, (p0[1] - p1[1]) / 2
    x1, y1 = cos * dx + sin * dy, -sin * dx + cos * dy
    scale = x1 * x1 / (rx * rx) + y1 * y1 / (ry * ry)
    if scale > 1:
        rx, ry = rx * math.sqrt(scale), ry * math.sqrt(scale)
    num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
    den = rx * rx * y1 * y1 + ry * ry * x1 * x1
    co = math.sqrt(max(0, num / den)) * (-1 if large == sweep else 1)
    cx1, cy1 = co * rx * y1 / ry, -co * ry * x1 / rx
    cx = cos * cx1 - sin * cy1 + (p0[0] + p1[0]) / 2
    cy = sin * cx1 + cos * cy1 + (p0[1] + p1[1]) / 2

    def ang(ux, uy, vx, vy):
        a = math.atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        return a

    t1 = ang(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
    dt = ang((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
    if not sweep and dt > 0:
        dt -= 2 * math.pi
    elif sweep and dt < 0:
        dt += 2 * math.pi
    steps = max(2, int(math.ceil(abs(dt) * math.sqrt(max(rx, ry) / TOLERANCE) / 2)))
    out = []
    for k in range(1, steps + 1):
        t = t1 + dt * k / steps
        ex, ey = rx * math.cos(t), ry * math.sin(t)
        out.append((cos * ex - sin * ey + cx, sin * ex + cos * ey + cy))
    out[-1] = p1
    return out


def polygons(d):
    """The closed outlines of path data `d`, as lists of points."""
    tokens = Tokens(d)
    shapes, current = [], []
    pos = start = (0.0, 0.0)
    last_control = None
    command = None
    while True:
        c = tokens.command()
        if c is None:
            if not tokens.more():
                break
            # Numbers after M repeat as L, otherwise the command repeats.
            c = {"M": "L", "m": "l"}.get(command, command)
        command = c
        rel = c.islower()
        C = c.upper()
        base = pos if rel else (0.0, 0.0)

        def point():
            x, y = tokens.number(), tokens.number()
            return (base[0] + x, base[1] + y)

        control = None
        if C == "M":
            if len(current) > 2:
                shapes.append(current)
            pos = start = point()
            current = [pos]
        elif C == "L":
            pos = point()
            current.append(pos)
        elif C == "H":
            pos = ((pos[0] if rel else 0) + tokens.number(), pos[1])
            current.append(pos)
        elif C == "V":
            pos = (pos[0], (pos[1] if rel else 0) + tokens.number())
            current.append(pos)
        elif C == "C":
            p1, p2, p3 = point(), point(), point()
            current += cubic(pos, p1, p2, p3)
            control, pos = p2, p3
        elif C == "S":
            p1 = (2 * pos[0] - last_control[0], 2 * pos[1] - last_control[1]) if last_control else pos
            p2, p3 = point(), point()
            current += cubic(pos, p1, p2, p3)
            control, pos = p2, p3
        elif C == "Q":
            p1, p2 = point(), point()
            current += quadratic(pos, p1, p2)
            control, pos = p1, p2
        elif C == "T":
            p1 = (2 * pos[0] - last_control[0], 2 * pos[1] - last_control[1]) if last_control else pos
            p2 = point()
            current += quadratic(pos, p1, p2)
            control, pos = p1, p2
        elif C == "A":
            rx, ry, angle = tokens.number(), tokens.number(), tokens.number()
            large, sweep = tokens.flag(), tokens.flag()
            end = point()
            current += arc(pos, rx, ry, angle, large, sweep, end)
            pos = end
        elif C == "Z":
            if len(current) > 2:
                shapes.append(current)
            pos = start
            current = [pos]
        else:
            raise ValueError(f"unsupported path command {c}")
        last_control = control if C in "CSQT" else None
    if len(current) > 2:
        shapes.append(current)
    return shapes


def logo(path):
    svg = open(path, encoding="utf-8").read()
    if 'viewBox="0 0 24 24"' not in svg:
        raise ValueError(f"{path}: needs viewBox 0 0 24 24")
    if 'fill-rule="evenodd"' not in svg:
        raise ValueError(f"{path}: needs fill-rule evenodd, the only rule Sharp fills by")
    color = None
    for fill in re.findall(r'fill="#([0-9A-Fa-f]{6})"', svg):
        color = fill.upper()
    shapes = []
    for d in re.findall(r'\bd="([^"]+)"', svg):
        shapes += polygons(d)
    return color, shapes


def main():
    lines = [
        "// Generated by dist/windows/make_logos.py from dist/windows/logos/*.svg",
        "// (thesvg.org, MIT; the marks belong to their owners and only name each",
        "// tool). Edit the SVGs and run the script, not this file.",
        "//",
        "// Each logo: .color null draws in the theme's text color; .shapes are",
        "// closed outlines in a 24-unit square, filled even-odd.",
        ".{",
    ]
    for name in sorted(os.listdir(SOURCE)):
        if not name.endswith(".svg"):
            continue
        color, shapes = logo(os.path.join(SOURCE, name))
        lines.append("    .{")
        lines.append(f'        .name = "{name[:-4]}",')
        lines.append(f"        .color = {'0x' + color if color else 'null'},")
        lines.append("        .shapes = .{")
        for shape in shapes:
            points = ", ".join(f"{x:.2f}, {y:.2f}" for x, y in shape)
            lines.append(f"            .{{ {points} }},")
        lines.append("        },")
        lines.append("    },")
        print(f"{name}: {len(shapes)} shapes, {sum(len(s) for s in shapes)} points")
    lines.append("}")
    open(TARGET, "w", encoding="utf-8", newline="\n").write("\n".join(lines) + "\n")


if __name__ == "__main__":
    sys.exit(main())
