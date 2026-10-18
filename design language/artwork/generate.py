#!/usr/bin/env python3
"""Generates the Kakureneko artwork SVGs (app icon variants, menu bar glyphs, mascot poses) from one cat drawing.
The cat follows the embroidery reference: a lanky startled cat on four stiff legs, big ears, a puffed spiky tail,
ring eyes, hand-cut edges. Pure string templating: no third-party modules.
Usage: python3 generate.py "design language/artwork"  (writes the SVGs next to itself)"""
import math, os, random, re, sys

OUT = sys.argv[1]
os.makedirs(f"{OUT}/menubar", exist_ok=True)
os.makedirs(f"{OUT}/mascot", exist_ok=True)

INK = "#121212"
INK_SOFT = "#34332F"   # inner ears
BONE = "#F4F2EC"
AMBER = "#FFB300"
WHITE = "#FFFFFF"

# ---------------------------------------------------------------------------------------------------------
# Geometry: shapes are chains of cubic segments, sampled to polygons, then roughened (hand-cut edges).

def cubic(p0, p1, p2, p3, t):
    u = 1 - t
    return (u*u*u*p0[0] + 3*u*u*t*p1[0] + 3*u*t*t*p2[0] + t*t*t*p3[0],
            u*u*u*p0[1] + 3*u*u*t*p1[1] + 3*u*t*t*p2[1] + t*t*t*p3[1])

def cubic_tangent(p0, p1, p2, p3, t):
    u = 1 - t
    return (3*u*u*(p1[0]-p0[0]) + 6*u*t*(p2[0]-p1[0]) + 3*t*t*(p3[0]-p2[0]),
            3*u*u*(p1[1]-p0[1]) + 6*u*t*(p2[1]-p1[1]) + 3*t*t*(p3[1]-p2[1]))

def dist(a, b):
    return math.hypot(b[0]-a[0], b[1]-a[1])

def sample_chain(chain, step=4.0):
    """chain = [start, seg, seg, …]; a seg is (c1, c2, end) for a cubic or a point for a line. Closed polygon."""
    pts = [chain[0]]
    cur = chain[0]
    for seg in chain[1:]:
        if isinstance(seg[0], tuple):
            c1, c2, p = seg
            n = max(2, int((dist(cur, c1) + dist(c1, c2) + dist(c2, p)) / step))
            pts.extend(cubic(cur, c1, c2, p, i / n) for i in range(1, n + 1))
        else:
            p = seg
            n = max(1, int(dist(cur, p) / step))
            pts.extend((cur[0] + (p[0]-cur[0]) * i / n, cur[1] + (p[1]-cur[1]) * i / n) for i in range(1, n + 1))
        cur = p
    if dist(pts[-1], pts[0]) < 1e-6:
        pts.pop()
    return pts

def roughen(pts, seed, low=4.0, high=1.8, chips=0.010):
    """Hand-cut edges: a slow wobble, a fine jitter, and a few small bites, all along the edge normal."""
    rng = random.Random(seed)
    n = len(pts)
    cx = sum(p[0] for p in pts) / n
    cy = sum(p[1] for p in pts) / n
    waves = [(rng.uniform(0, 2*math.pi), k) for k in (7, 13, 23)]
    normals = []
    for i in range(n):
        x0, y0 = pts[i-1]; x1, y1 = pts[(i+1) % n]
        tx, ty = x1-x0, y1-y0
        l = math.hypot(tx, ty) or 1
        nx, ny = -ty / l, tx / l
        # orient outward
        if (pts[i][0]-cx) * nx + (pts[i][1]-cy) * ny < 0:
            nx, ny = -nx, -ny
        normals.append((nx, ny))
    disp = []
    for i in range(n):
        s = 2 * math.pi * i / n
        d = low * sum(math.sin(s * k + ph) for ph, k in waves) / 3 + rng.uniform(-high, high)
        disp.append(d)
    for _ in range(int(n * chips)):
        j = rng.randrange(n); depth = rng.uniform(5, 11); span = rng.randint(2, 5)
        for k in range(-span, span + 1):
            disp[(j + k) % n] -= depth * (1 - abs(k) / (span + 1))
    return [(pts[i][0] + normals[i][0]*disp[i], pts[i][1] + normals[i][1]*disp[i]) for i in range(n)]

def poly(pts):
    return "M" + " L".join(f"{x:.1f} {y:.1f}" for x, y in pts) + " Z"

def shape(chain, seed, step=4.0, **kw):
    return poly(roughen(sample_chain(chain, step), seed, **kw))

def bushy_tail(p0, p1, p2, p3, w_base, w_mid, w_tip, tuft, seed, n=40):
    """A puffed tail: a cubic swept with a width profile, with irregular fur tufts along both edges and a tuft
    at the tip. Tufts are random in size and spacing and grow toward the tip, like the embroidery reference."""
    rng = random.Random(seed)
    def tuft_profile():
        amp = [0.0] * (n + 1)
        i = rng.randint(2, 4)
        while i < n:
            size = rng.uniform(0.55, 1.0) * tuft * (0.45 + 0.9 * i / n)
            span = rng.randint(2, 3)
            for k in range(-span, span + 1):
                j = i + k
                if 0 <= j <= n:
                    amp[j] = max(amp[j], size * (1 - (abs(k) / (span + 1)) ** 1.6))
            i += span + rng.randint(3, 5)
        return amp
    al, ar = tuft_profile(), tuft_profile()
    left, right = [], []
    for i in range(n + 1):
        t = i / n
        x, y = cubic(p0, p1, p2, p3, t)
        tx, ty = cubic_tangent(p0, p1, p2, p3, t)
        l = math.hypot(tx, ty) or 1
        nx, ny = -ty / l, tx / l
        w = ((1-t)**2 * w_base + 2*(1-t)*t * w_mid + t*t * w_tip) / 2
        left.append((x + nx*(w + al[i] + rng.uniform(-0.6, 0.6)), y + ny*(w + al[i] + rng.uniform(-0.6, 0.6))))
        right.append((x - nx*(w + ar[i] + rng.uniform(-0.6, 0.6)), y - ny*(w + ar[i] + rng.uniform(-0.6, 0.6))))
    x, y = cubic(p0, p1, p2, p3, 1); tx, ty = cubic_tangent(p0, p1, p2, p3, 1)
    l = math.hypot(tx, ty) or 1; fx, fy = tx / l, ty / l; nx, ny = -fy, fx
    tip = [(x + fx*tuft*0.9 + nx*tuft*0.5, y + fy*tuft*0.9 + ny*tuft*0.5),
           (x + fx*tuft*1.5, y + fy*tuft*1.5),
           (x + fx*tuft*0.8 - nx*tuft*0.55, y + fy*tuft*0.8 - ny*tuft*0.55)]
    return poly(left + tip + right[::-1])

def ellipse_sub(cx, cy, rx, ry):
    return f"M{cx-rx:.2f} {cy:.2f} a{rx:.2f} {ry:.2f} 0 1 0 {2*rx:.2f} 0 a{rx:.2f} {ry:.2f} 0 1 0 {-2*rx:.2f} 0 Z"

def toes(cx, cy, r, spread, color=INK):
    """Three toe bumps along the bottom of a paw centred on (cx, cy)."""
    return "".join(f'<circle cx="{cx+dx:.1f}" cy="{cy+dy:.1f}" r="{r:.1f}" fill="{color}"/>'
                   for dx, dy in ((-spread, -r*0.25), (0, 0), (spread, -r*0.25)))

def grain(clip_id, x0, y0, x1, y1, seed, density=1 / 2600, scale=1.0, angle=-34):
    """Linocut grain: sparse short bone strokes in one direction, clipped to the silhouette."""
    rng = random.Random(seed)
    count = int((x1 - x0) * (y1 - y0) * density / (scale * scale))
    out = [f'<g clip-path="url(#{clip_id})" stroke="{BONE}" stroke-linecap="round" fill="none">']
    for _ in range(count):
        cx, cy = rng.uniform(x0, x1), rng.uniform(y0, y1)
        a = math.radians(angle + rng.gauss(0, 9))
        half = rng.uniform(3, 8) * scale
        w = rng.uniform(1.8, 2.8) * scale
        op = rng.uniform(0.05, 0.12)
        out.append(f'<path d="M{cx - math.cos(a)*half:.1f} {cy - math.sin(a)*half:.1f} L{cx + math.cos(a)*half:.1f} {cy + math.sin(a)*half:.1f}" '
                   f'stroke-width="{w:.1f}" stroke-opacity="{op:.2f}"/>')
    out.append('</g>')
    return "".join(out)

# ---------------------------------------------------------------------------------------------------------
# The cat on a 1024 grid, centred on x = 512: a symmetric head (tall ears set wide apart, wide cheeks) on a small
# sitting body, front paws at the base, a puffed tail to the right. Built from the right half and its mirror.

def mirror_chain(half):
    """`half` runs from the top centre down the right side to the bottom centre; returns the closed chain."""
    def m(p): return (1024 - p[0], p[1])
    chain = list(half)
    # walk the right half backwards, mirrored, to come back up the left side
    pts = [half[0]] + [seg[2] if isinstance(seg[0], tuple) else seg for seg in half[1:]]
    for i in range(len(half) - 1, 0, -1):
        seg = half[i]
        if isinstance(seg[0], tuple):
            c1, c2, _ = seg
            chain.append((m(c2), m(c1), m(pts[i-1])))
        else:
            chain.append(m(pts[i-1]))
    return chain

RIGHT_HALF = [
    (512, 262),
    ((540, 256), (568, 258), (586, 266)),      # top of the head to the ear's inner base
    ((610, 246), (636, 214), (654, 182)),      # ear, inner edge up
    ((660, 174), (672, 176), (674, 186)),      # tip
    ((680, 234), (684, 290), (672, 332)),      # outer edge down
    ((686, 372), (680, 412), (656, 436)),      # cheek to the jaw
    ((672, 452), (700, 500), (704, 560)),      # shoulder out to the hip
    ((708, 610), (704, 650), (690, 672)),      # flank down
    ((684, 690), (670, 700), (650, 700)),      # base corner
    (512, 700),                                # base to the centre
]
BODY = mirror_chain(RIGHT_HALF)
def inner_ear(inner_base, tip, outer_base, k=0.6):
    """The ear's triangle shrunk toward its centroid: a mark that stays inside the ear whatever its shape."""
    cx = (inner_base[0] + tip[0] + outer_base[0]) / 3
    cy = (inner_base[1] + tip[1] + outer_base[1]) / 3
    a, b, c = [(cx + k*(x-cx), cy + k*(y-cy)) for x, y in (inner_base, tip, outer_base)]
    return (f'<path d="M{a[0]:.1f} {a[1]:.1f} L{b[0]:.1f} {b[1]:.1f} L{c[0]:.1f} {c[1]:.1f} Z" fill="{INK_SOFT}" '
            f'stroke="{INK_SOFT}" stroke-width="10" stroke-linejoin="round"/>')
INNER_EARS = inner_ear((586, 268), (664, 182), (670, 334)) + inner_ear((438, 268), (360, 182), (354, 334))
PAWS = toes(440, 704, 9, 15) + toes(584, 704, 9, 15)
def simple_tail(p0, p1, p2, p3, w0, w1, n=36):
    """One closed path: a cubic swept with a width that tapers from w0 to w1, round at the tip."""
    left, right = [], []
    for i in range(n + 1):
        t = i / n
        x, y = cubic(p0, p1, p2, p3, t)
        tx, ty = cubic_tangent(p0, p1, p2, p3, t)
        l = math.hypot(tx, ty) or 1
        nx, ny = -ty / l, tx / l
        w = (w0 + (w1 - w0) * (t ** 0.9)) / 2
        left.append((x + nx*w, y + ny*w)); right.append((x - nx*w, y - ny*w))
    x, y = cubic(p0, p1, p2, p3, 1); tx, ty = cubic_tangent(p0, p1, p2, p3, 1)
    l = math.hypot(tx, ty) or 1; fx, fy = tx / l, ty / l; nx, ny = -fy, fx; r = w1 / 2
    tip = [(x + r*(nx*math.cos(a) + fx*math.sin(a)), y + r*(ny*math.cos(a) + fy*math.sin(a)))
           for a in [math.pi * k / 8 for k in range(1, 8)]]
    return left + tip + right[::-1]

TAIL = poly(roughen(simple_tail((686, 612), (796, 650), (850, 560), (818, 446), 60, 30), seed=5, low=1.6, high=0.5, chips=0))

def eyes_1024(eye_fill=AMBER, pupil_fill=INK, glint=True):
    s = (f'<ellipse cx="466" cy="366" rx="38" ry="50" fill="{eye_fill}"/>'
         f'<ellipse cx="558" cy="366" rx="38" ry="50" fill="{eye_fill}"/>'
         f'<circle cx="467" cy="370" r="21" fill="{pupil_fill}"/>'
         f'<circle cx="559" cy="370" r="21" fill="{pupil_fill}"/>')
    if glint:
        s += f'<circle cx="474" cy="348" r="7" fill="{WHITE}"/><circle cx="566" cy="348" r="7" fill="{WHITE}"/>'
    return s

def closed_eyes_1024():
    out = []
    for cx in (466, 558):
        cy = 366
        out.append(f"M{cx-40} {cy-6} Q{cx} {cy+32} {cx+40} {cy-6} Q{cx} {cy+10} {cx-40} {cy-6} Z")
    return " ".join(out)

def cat_1024(uid, eye_fill=AMBER, pupil_fill=INK, glint=True, tail=True, paws=True, before="", after="", eyes="open"):
    body = shape(BODY, seed=11, low=2.2, high=0.7, chips=0.004)
    if eyes == "closed":
        body = body + " " + closed_eyes_1024()
    parts, clip = [before], [f'<path d="{body}"/>']
    if tail:
        parts.append(f'<path d="{TAIL}" fill="{INK}"/>'); clip.append(f'<path d="{TAIL}"/>')
    parts.append(f'<path d="{body}" fill="{INK}" fill-rule="evenodd"/>')
    if paws:
        parts.append(PAWS); clip.append(PAWS.replace(f' fill="{INK}"', ''))
    parts.append(INNER_EARS)
    parts.append(after)
    clip_markup = "".join(clip).replace("<path d=", '<path fill-rule="evenodd" d=', 1)
    parts.append(f'<clipPath id="{uid}">{clip_markup}</clipPath>')
    parts.append(grain(uid, 300, 170, 880, 720, seed=hash(uid) % 1000 + 7))
    if eyes == "open":
        parts.append(eyes_1024(eye_fill=eye_fill, pupil_fill=pupil_fill, glint=glint))
    return "\n  ".join(p for p in parts if p)

def laptop_1024(dy=0):
    return (f'<path d="M184 {682+dy} H840 a24 24 0 0 1 24 24 V{730+dy} H160 V{706+dy} a24 24 0 0 1 24 -24 Z" fill="#DCD9D1"/>\n  '
            f'<path d="M160 {730+dy} H864 V{740+dy} a18 18 0 0 1 -18 18 H178 a18 18 0 0 1 -18 -18 Z" fill="#B6B2A8"/>\n  '
            f'<rect x="478" y="{727+dy}" width="68" height="10" rx="5" fill="#8A867C"/>')

def scene(uid, eye_fill=AMBER, pupil_fill=INK, glint=True, shadow=True, laptop=True):
    """The cat sitting on a closed MacBook."""
    parts = []
    if shadow:
        parts.append(f'<ellipse cx="512" cy="{778 if laptop else 740}" rx="296" ry="12" fill="{INK}"/>')
    if laptop:
        parts.append(laptop_1024())
    parts.append(cat_1024(uid, eye_fill=eye_fill, pupil_fill=pupil_fill, glint=glint))
    return "\n  ".join(parts)

def svg(body, size=1024, vb="0 0 1024 1024"):
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{vb}" width="{size}" height="{size}">\n  {body}\n</svg>\n'

def write(path, text):
    with open(f"{OUT}/{path}", "w") as f:
        f.write(text)

# macOS icon: rounded tile (824 pt body, 100 pt margins, radius 185), transparent outside. The scene is a little
# tall for the tile, so it is scaled 0.92 around the tile centre.
ICON_T = ''
write("icon-mac.svg", svg(f'<rect x="100" y="100" width="824" height="824" rx="185" fill="{BONE}"/>\n  <g {ICON_T}>\n  {scene("c-icon")}\n  </g>'))
write("icon-mac-amber.svg", svg(f'<rect x="100" y="100" width="824" height="824" rx="185" fill="{AMBER}"/>\n  <g {ICON_T}>\n  '
                                + scene("c-amber", eye_fill=WHITE, glint=False) + '\n  </g>'))
write("icon-mac-ink.svg", svg(f'<rect x="100" y="100" width="824" height="824" rx="185" fill="{INK}"/>\n  <g {ICON_T}>\n  '
                              + scene("c-ink", shadow=False).replace(f'fill="{INK}"', 'fill="#1F1E1B"').replace(f'stroke="{INK}"', 'stroke="#1F1E1B"') + '\n  </g>'))
write("icon-ios.svg", svg(f'<rect width="1024" height="1024" fill="{BONE}"/>\n  '
                          f'<g transform="translate(512 512) scale(1.18) translate(-512 -512)">\n  {scene("c-ios")}\n  </g>'))

# ---------------------------------------------------------------------------------------------------------
# Menu bar glyphs: template images (black + alpha) on an 18 pt grid, authored at 2x (36 units). The head alone,
# wide with big ears, the eyes as ring holes (even-odd). Clean edges: roughness would only blur at 18 pt.

HEAD_HALF = RIGHT_HALF[:6] + [((622, 466), (562, 484), (512, 484))]        # head to the jaw, then a chin
HEAD_FLAT_HALF = [RIGHT_HALF[0], RIGHT_HALF[1],
                  ((620, 258), (660, 250), (702, 250)),                             # ear flattened sideways
                  ((706, 256), (704, 264), (698, 270)),
                  ((690, 288), (682, 310), (672, 332)),
                  RIGHT_HALF[5], ((622, 466), (562, 484), (512, 484))]

def chain_to_path(chain, scale, dx, dy):
    """A closed chain of cubics as compact SVG path data, scaled and offset."""
    f = lambda p: f"{p[0]*scale + dx:.2f} {p[1]*scale + dy:.2f}"
    d = [f"M{f(chain[0])}"]
    for seg in chain[1:]:
        if isinstance(seg[0], tuple):
            d.append(f"C {f(seg[0])}, {f(seg[1])}, {f(seg[2])}")
        else:
            d.append(f"L{f(seg)}")
    return " ".join(d) + " Z"

# the head spans x 350..674 and y 174..484 on the 1024 grid; fit it into the 36 grid with a 2-unit margin
G_SCALE = 32 / 324
G_DX, G_DY = 2 - 350 * G_SCALE, 2.5 - 174 * G_SCALE
HEAD36 = chain_to_path(mirror_chain(HEAD_HALF), G_SCALE, G_DX, G_DY)
HEAD36_FLAT = chain_to_path(mirror_chain(HEAD_FLAT_HALF), G_SCALE, G_DX, G_DY)
G_INNER = ""   # inner ears are too small to read at 18 pt; the template stays a silhouette

def head(eyes, pupils=(), extra="", head_path=HEAD36, transform=None, stroke_only=False):
    if stroke_only:
        shape_ = f'<path d="{head_path}" fill="none" stroke="#000" stroke-width="2.4" stroke-linejoin="round"/>'
        shape_ += "".join(f'<path d="{e}" fill="#000"/>' for e in eyes)
    else:
        shape_ = f'<path d="{head_path} {" ".join(eyes)}" fill="#000" fill-rule="evenodd"/>'
        shape_ += "".join(f'<circle cx="{x}" cy="{y}" r="{r}" fill="#000"/>' for (x, y, r) in pupils)
    g = f'<g transform="{transform}">{shape_}</g>' if transform else shape_
    return svg(g + extra, size=36, vb="0 0 36 36")

EYE_L, EYE_R, EYE_Y = 466 * G_SCALE + G_DX, 558 * G_SCALE + G_DX, 366 * G_SCALE + G_DY
def eyes(rx, ry, y=EYE_Y):
    return [ellipse_sub(EYE_L, y, rx, ry), ellipse_sub(EYE_R, y, rx, ry)]

def lidded():
    return [f"M{cx-3.2} {EYE_Y+0.6} a3.2 3.4 0 0 0 6.4 0 Z" for cx in (EYE_L, EYE_R)]

def closed():
    return [f"M{cx-3.6} {EYE_Y-0.6} Q{cx} {EYE_Y+3.6} {cx+3.6} {EYE_Y-0.6} Q{cx} {EYE_Y+1.2} {cx-3.6} {EYE_Y-0.6} Z"
            for cx in (EYE_L, EYE_R)]

def x_eyes():
    out = []
    for cx in (EYE_L, EYE_R):
        w, h, t = 3.0, 3.2, 1.0
        out.append(f"M{cx-w} {EYE_Y-h+t} L{cx-w+t} {EYE_Y-h} L{cx} {EYE_Y-t} L{cx+w-t} {EYE_Y-h} L{cx+w} {EYE_Y-h+t} "
                   f"L{cx+t} {EYE_Y} L{cx+w} {EYE_Y+h-t} L{cx+w-t} {EYE_Y+h} L{cx} {EYE_Y+t} L{cx-w+t} {EYE_Y+h} "
                   f"L{cx-w} {EYE_Y+h-t} L{cx-t} {EYE_Y} Z")
    return out

SMALL = "translate(-1.2 10) scale(0.72)"   # head bottom-left (x ≤ 24, ear tip at y ≈ 12); badges start at x ≥ 26.5

BANG = ('<rect x="29.2" y="1.5" width="4.2" height="11.5" rx="2.1" fill="#000"/>'
        '<circle cx="31.3" cy="17.6" r="2.4" fill="#000"/>')
QUEST = ('<path d="M27.2 5.4 C 27.2 1.6, 34.8 1.6, 34.8 5.6 C 34.8 8.6, 31.2 8.4, 31.2 11.8" fill="none" stroke="#000" stroke-width="2.9" stroke-linecap="round"/>'
         '<circle cx="31.2" cy="16.6" r="2.2" fill="#000"/>')
ZZ = ('<path d="M27.2 11 H33.4 L27.2 17.2 H33.4" fill="none" stroke="#000" stroke-width="2.7" stroke-linejoin="round" stroke-linecap="round"/>'
      '<path d="M31 2 H35.4 L31 6.4 H35.4" fill="none" stroke="#000" stroke-width="2.1" stroke-linejoin="round" stroke-linecap="round"/>')
Z1 = '<path d="M27.6 6 H34.2 L27.6 12.6 H34.2" fill="none" stroke="#000" stroke-width="2.7" stroke-linejoin="round" stroke-linecap="round"/>'
MUG = ('<path d="M26.6 10.5 H32.6 V17.4 A3 3 0 0 1 29.6 20.4 A3 3 0 0 1 26.6 17.4 Z" fill="#000"/>'
       '<path d="M32.6 12.2 H33.8 A2.1 2.1 0 0 1 33.8 16.4 H32.6 Z" fill="#000"/>'
       '<path d="M28.3 8 C 28.3 6.7, 29.7 6.5, 29.7 5.2 M31.1 8 C 31.1 6.7, 32.5 6.5, 32.5 5.2" fill="none" stroke="#000" stroke-width="1.5" stroke-linecap="round"/>')
POWER = ('<path d="M27.6 7.6 A4.2 4.2 0 1 0 34 7.6" fill="none" stroke="#000" stroke-width="2.3" stroke-linecap="round"/>'
         '<path d="M30.8 3.6 V9.2" stroke="#000" stroke-width="2.3" stroke-linecap="round"/>')

RING = eyes(3.75, 4.9)       # the cat's eyes at glyph scale: a tall hole with a centred pupil
PUPIL = 2.1
glyphs = {
    "idle":      head(closed(), transform=SMALL),
    "working":   head(eyes(3.9, 5.1), pupils=[(EYE_L, EYE_Y + 0.2, PUPIL), (EYE_R, EYE_Y + 0.2, PUPIL)], transform=SMALL),
    "keepawake": head(eyes(3.9, 5.1), pupils=[(EYE_L, EYE_Y + 0.2, PUPIL), (EYE_R, EYE_Y + 0.2, PUPIL)], transform=SMALL, extra=MUG),
    "waiting":   head(RING, pupils=[(EYE_L + 1.1, EYE_Y - 1.1, PUPIL), (EYE_R + 1.1, EYE_Y - 1.1, PUPIL)], transform=SMALL, extra=QUEST),
    "attention": head(RING, pupils=[(EYE_L, EYE_Y, 1.5), (EYE_R, EYE_Y, 1.5)], head_path=HEAD36_FLAT, transform=SMALL, extra=BANG),
    "countdown": head(lidded(), transform=SMALL, extra=Z1),
    "asleep":    head(closed(), transform=SMALL, extra=ZZ),
    "shutdown":  head(x_eyes(), transform=SMALL, extra=POWER),
    "off":       head(eyes(2.1, 2.9), stroke_only=True, transform=SMALL),
}
for name, text in glyphs.items():
    write(f"menubar/{name}.svg", text)

# ---------------------------------------------------------------------------------------------------------
# Mascot poses.

def sticker_underlay(body):
    u = re.sub(r'<clipPath id="[^"]+">.*?</clipPath>\s*', '', body, flags=re.S)
    u = re.sub(r'<g clip-path="[^"]+".*?</g>', '', u, flags=re.S)
    def widen(m):
        return f'stroke="{BONE}" stroke-width="{float(m.group(1)) + 28:g}"'
    u = re.sub(r'stroke="#121212" stroke-width="([0-9.]+)"', widen, u)
    u = re.sub(r'stroke="#F4F2EC" stroke-width="([0-9.]+)"', widen, u)
    return (f'<g stroke="{BONE}" stroke-width="28" stroke-linejoin="round" stroke-linecap="round" fill="{BONE}">\n  {u}\n  </g>')

def wsvg(name, vb, body):
    x, y, vw, vh = (float(v) for v in vb.split())
    with open(f"{OUT}/mascot/{name}.svg", "w") as f:
        f.write(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{vb}" width="{vw:g}" height="{vh:g}">\n  {body}\n</svg>\n')
    pad = 16
    svb = f"{x-pad:g} {y-pad:g} {vw+2*pad:g} {vh+2*pad:g}"
    with open(f"{OUT}/mascot/{name}-sticker.svg", "w") as f:
        f.write(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{svb}" width="{vw+2*pad:g}" height="{vh+2*pad:g}">\n  {sticker_underlay(body)}\n  {body}\n</svg>\n')

def placed(inner, x, y, s, base=(512, 790)):
    """`inner` (1024 grid) placed so `base` lands on (x, y) at scale s."""
    return f'<g transform="translate({x - base[0]*s:.1f} {y - base[1]*s:.1f}) scale({s})">{inner}</g>'

def z_path(x, y, size, width):
    return (f'<path d="M{x} {y} H{x+size} L{x} {y+size} H{x+size}" fill="none" stroke="{INK}" '
            f'stroke-width="{width}" stroke-linejoin="round" stroke-linecap="round"/>')

# 1. sit: the icon's cat alone, with its shadow
wsvg("sit", "280 150 600 590", f'<ellipse cx="512" cy="724" rx="236" ry="11" fill="{INK}"/>\n  ' + cat_1024("c-sit"))

# 2. peek: a closed MacBook, lid barely lifted, ring eyes in the gap and the puffed tail out the side
peek_tail = poly(roughen(simple_tail((540, 286), (598, 292), (628, 238), (610, 176), 26, 12), seed=8, low=0.8, high=0.3, chips=0))
peek = f'''<ellipse cx="320" cy="356" rx="236" ry="9" fill="{INK}"/>
  <path d="M94 250 H546 L552 300 H88 Z" fill="{INK}"/>
  <path d="M90 298 H550 L580 322 H60 Z" fill="#DCD9D1"/>
  <path d="M60 322 H580 V330 a12 12 0 0 1 -12 12 H72 a12 12 0 0 1 -12 -12 Z" fill="#B6B2A8"/>
  <clipPath id="gap"><rect x="94" y="258" width="452" height="40"/></clipPath>
  <g clip-path="url(#gap)"><ellipse cx="262" cy="284" rx="24" ry="32" fill="{AMBER}"/><ellipse cx="382" cy="284" rx="24" ry="32" fill="{AMBER}"/><circle cx="262" cy="287" r="13" fill="{INK}"/><circle cx="382" cy="287" r="13" fill="{INK}"/><circle cx="268" cy="272" r="4" fill="{WHITE}"/><circle cx="388" cy="272" r="4" fill="{WHITE}"/></g>
  <path d="{peek_tail}" fill="{INK}"/>
  <path d="M112 196 H528 a8 8 0 0 1 8 8 L548 250 a10 10 0 0 1 -10 10 H102 a10 10 0 0 1 -10 -10 L104 204 a8 8 0 0 1 8 -8 Z" fill="#E4E1DA"/>
  <path d="M92 246 H548 L548 250 a10 10 0 0 1 -10 10 H102 a10 10 0 0 1 -10 -10 Z" fill="#C9C5BC"/>'''
wsvg("peek", "0 0 640 400", peek)

# 3. hide: behind a flat panel, head over the top edge, toes hooked over it
hide_cat = placed(cat_1024("c-hide", tail=False, paws=False), 210, 392, 0.56, base=(512, 700))
hide = f'''<ellipse cx="210" cy="372" rx="170" ry="9" fill="{INK}"/>
  {hide_cat}
  <path d="M62 214 H358 a8 8 0 0 1 8 8 V352 a8 8 0 0 1 -8 8 H62 a8 8 0 0 1 -8 -8 V222 a8 8 0 0 1 8 -8 Z" fill="{BONE}" stroke="{INK}" stroke-width="11" stroke-linejoin="round"/>
  <rect x="146" y="200" width="44" height="22" rx="10" fill="{INK}"/>{toes(168, 224, 7, 13)}
  <rect x="228" y="200" width="44" height="22" rx="10" fill="{INK}"/>{toes(250, 224, 7, 13)}'''
wsvg("hide", "0 0 400 400", hide)

# 4. coffee: both paws on a mug with a bolt on it
coffee_cat = placed(cat_1024("c-coffee", tail=False, paws=False), 200, 352, 0.5, base=(512, 700))
coffee = f'''<ellipse cx="200" cy="372" rx="150" ry="9" fill="{INK}"/>
  {coffee_cat}
  <path d="M150 262 H260 a10 10 0 0 1 10 10 V322 a30 30 0 0 1 -30 30 H170 a30 30 0 0 1 -30 -30 V272 a10 10 0 0 1 10 -10 Z" fill="{WHITE}" stroke="{INK}" stroke-width="11" stroke-linejoin="round"/>
  <path d="M270 282 H284 a22 22 0 0 1 0 44 H270" fill="none" stroke="{INK}" stroke-width="11" stroke-linecap="round"/>
  <path d="M214 278 L192 314 H208 L196 342 L222 304 H206 Z" fill="{AMBER}"/>
  <rect x="134" y="272" width="42" height="26" rx="12" fill="{INK}"/>{toes(155, 300, 7, 13)}
  <rect x="226" y="272" width="42" height="26" rx="12" fill="{INK}"/>{toes(247, 300, 7, 13)}'''
wsvg("coffee", "0 0 400 400", coffee)

# 5. sleep: the same sitting cat, eyes closed, zZ
sleep = (f'<ellipse cx="512" cy="724" rx="236" ry="11" fill="{INK}"/>\n  ' + cat_1024("c-sleep", eyes="closed") + "\n  "
         + z_path(690, 236, 34, 14) + z_path(742, 168, 50, 16))
wsvg("sleep", "280 150 600 590", sleep)

# 6. wave: one paw raised with the toes up, a question bubble
WAVE_ARM = (f'<path d="M640 560 C 720 540, 770 480, 788 392" fill="none" stroke="{INK}" stroke-width="44" stroke-linecap="round"/>'
            f'<rect x="754" y="344" width="68" height="38" rx="17" fill="{INK}"/>' + toes(788, 348, 10, 21))
wave_cat = placed(cat_1024("c-wave", tail=False, after=WAVE_ARM), 236, 388, 0.5, base=(512, 700))
wave = f'''<ellipse cx="236" cy="392" rx="150" ry="9" fill="{INK}"/>
  {wave_cat}
  <path d="M400 150 L414 136 M410 174 L428 170" stroke="{INK}" stroke-width="8" stroke-linecap="round"/>
  <path d="M30 70 C 30 38, 60 22, 88 22 C 118 22, 144 38, 144 70 C 144 98, 120 114, 94 116 L 82 136 L 78 114 C 52 110, 30 96, 30 70 Z" fill="{WHITE}" stroke="{INK}" stroke-width="10" stroke-linejoin="round"/>
  <path d="M70 56 C 70 38, 106 38, 106 58 C 106 72, 88 70, 88 84" fill="none" stroke="{INK}" stroke-width="10" stroke-linecap="round"/>
  <circle cx="88" cy="100" r="6.5" fill="{INK}"/>'''
wsvg("wave", "0 0 500 420", wave)

print("wrote", ", ".join(sorted(os.listdir(OUT))), "| mascot:", ", ".join(sorted(os.listdir(f"{OUT}/mascot"))))
