"""Mockup toolkit: token resolver, text measurement, SVG primitives, SF-Symbol-like glyphs."""
import json, math, re
from xml.sax.saxutils import escape
from fontTools.ttLib import TTCollection

import os
REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..', '..'))
TOK = json.load(open(f'{REPO}/design/tokens/tokens.json'))
EXT = 'io.github.kkdy21.overgrove'


def _node(path):
    n = TOK
    for k in path.split('.'):
        n = n[k]
    return n


def _resolve(v, mode):
    if isinstance(v, str) and v.startswith('{'):
        return tok(v[1:-1], mode)
    return v


def tok(path, mode='light'):
    n = _node(path)
    v = n['$value']
    if mode == 'dark':
        d = n.get('$extensions', {}).get(EXT, {}).get('modes', {}).get('dark')
        if d is not None:
            v = d
    return _resolve(v, mode)


class Theme:
    def __init__(self, mode):
        self.mode = mode

    def __call__(self, name):
        """Semantic color by short name, e.g. 'text.primary'. Primitive with 'primitive.' prefix."""
        if name.startswith('primitive.'):
            return tok(name, self.mode)
        return tok('semantic.color.' + name, self.mode)

    def lane(self, i):
        return self(f'graph.lane.{i % 8}')

    def avatar(self, i):
        return self(f'avatar.{i % 8}')


def fnv1a(s):
    h = 0x811c9dc5
    for b in s.strip().lower().encode():
        h ^= b
        h = (h * 0x01000193) & 0xffffffff
    return h


# ---------------------------------------------------------------- text metrics
_HN = TTCollection('/System/Library/Fonts/HelveticaNeue.ttc')
_FACES = {400: _HN.fonts[0], 500: _HN.fonts[10], 700: _HN.fonts[1]}
_CACHE = {}


def _face(weight):
    if weight >= 600:
        return _FACES[700]
    if weight >= 500:
        return _FACES[500]
    return _FACES[400]


def tw(s, size, weight=400, mono=False):
    if mono:
        return len(s) * size * 0.6021
    f = _face(weight)
    key = (id(f), s)
    if key not in _CACHE:
        cmap = f.getBestCmap()
        hm = f['hmtx']
        upm = f['head'].unitsPerEm
        w = 0
        for ch in s:
            g = cmap.get(ord(ch))
            if g is None:
                g = cmap.get(ord('M'))
            w += hm[g][0]
        _CACHE[key] = w / upm
    return _CACHE[key] * size


def fit(s, size, maxw, weight=400, mono=False, middle=False):
    if tw(s, size, weight, mono) <= maxw:
        return s
    if middle:
        a, b = s[: len(s) // 2], s[len(s) // 2:]
        while a and b and tw(a + '…' + b, size, weight, mono) > maxw:
            if len(a) >= len(b):
                a = a[:-1]
            else:
                b = b[1:]
        return a + '…' + b
    while s and tw(s + '…', size, weight, mono) > maxw:
        s = s[:-1]
    return s.rstrip() + '…'


SANS = "-apple-system, 'SF Pro Text', 'Helvetica Neue', sans-serif"
MONO = "'SF Mono', Menlo, monospace"


def _color(c):
    """Return (fill, opacity) splitting #rrggbbaa for renderer compatibility."""
    if c and c.startswith('#') and len(c) == 9:
        return c[:7], int(c[7:9], 16) / 255
    return c, 1.0


class Svg:
    def __init__(self, w, h, title):
        self.w, self.h, self.title = w, h, title
        self.els = []
        self.defs = []

    def add(self, s):
        self.els.append(s)

    def rect(self, x, y, w, h, fill=None, r=0, stroke=None, sw=1, op=1.0, dash=None):
        f, fo = _color(fill) if fill else ('none', 1)
        a = f'<rect x="{x:g}" y="{y:g}" width="{w:g}" height="{h:g}"'
        if r:
            a += f' rx="{r:g}"'
        a += f' fill="{f}"'
        if fo * op < 1 and fill:
            a += f' fill-opacity="{fo * op:.3g}"'
        if stroke:
            sc, so = _color(stroke)
            a += f' stroke="{sc}" stroke-width="{sw:g}"'
            if so * op < 1:
                a += f' stroke-opacity="{so * op:.3g}"'
            if dash:
                a += f' stroke-dasharray="{dash}"'
        self.add(a + '/>')

    def line(self, x1, y1, x2, y2, stroke, sw=1, op=1.0, dash=None, cap=None):
        sc, so = _color(stroke)
        a = f'<line x1="{x1:g}" y1="{y1:g}" x2="{x2:g}" y2="{y2:g}" stroke="{sc}" stroke-width="{sw:g}"'
        if so * op < 1:
            a += f' stroke-opacity="{so * op:.3g}"'
        if dash:
            a += f' stroke-dasharray="{dash}"'
        if cap:
            a += f' stroke-linecap="{cap}"'
        self.add(a + '/>')

    def circle(self, cx, cy, r, fill=None, stroke=None, sw=1, op=1.0, dash=None):
        f, fo = _color(fill) if fill else ('none', 1)
        a = f'<circle cx="{cx:g}" cy="{cy:g}" r="{r:g}" fill="{f}"'
        if fill and fo * op < 1:
            a += f' fill-opacity="{fo * op:.3g}"'
        if stroke:
            sc, so = _color(stroke)
            a += f' stroke="{sc}" stroke-width="{sw:g}"'
            if so * op < 1:
                a += f' stroke-opacity="{so * op:.3g}"'
            if dash:
                a += f' stroke-dasharray="{dash}"'
        self.add(a + '/>')

    def path(self, d, fill=None, stroke=None, sw=1, op=1.0, cap='round', join='round'):
        f, fo = _color(fill) if fill else ('none', 1)
        a = f'<path d="{d}" fill="{f}"'
        if fill and fo * op < 1:
            a += f' fill-opacity="{fo * op:.3g}"'
        if stroke:
            sc, so = _color(stroke)
            a += f' stroke="{sc}" stroke-width="{sw:g}" stroke-linecap="{cap}" stroke-linejoin="{join}"'
            if so * op < 1:
                a += f' stroke-opacity="{so * op:.3g}"'
        self.add(a + '/>')

    def text(self, x, y, s, size=13, fill='#000', weight=400, anchor='start', mono=False, op=1.0, ls=None):
        fc, fo = _color(fill)
        fam = MONO if mono else SANS
        a = (f'<text x="{x:g}" y="{y:g}" font-family="{fam}" font-size="{size:g}" '
             f'font-weight="{weight}" fill="{fc}"')
        if anchor != 'start':
            a += f' text-anchor="{anchor}"'
        if fo * op < 1:
            a += f' fill-opacity="{fo * op:.3g}"'
        if ls:
            a += f' letter-spacing="{ls}"'
        self.add(a + f'>{escape(s)}</text>')
        return tw(s, size, weight, mono)

    def group(self, inner, op=1.0, transform=None):
        a = '<g'
        if op < 1:
            a += f' opacity="{op:.3g}"'
        if transform:
            a += f' transform="{transform}"'
        self.add(a + '>')
        self.add(inner)
        self.add('</g>')

    def open_group(self, op=1.0, clip=None):
        a = '<g'
        if op < 1:
            a += f' opacity="{op:.3g}"'
        if clip:
            a += f' clip-path="url(#{clip})"'
        self.add(a + '>')

    def close_group(self):
        self.add('</g>')

    def clip(self, cid, x, y, w, h, r=0):
        self.defs.append(f'<clipPath id="{cid}"><rect x="{x:g}" y="{y:g}" width="{w:g}" height="{h:g}" rx="{r:g}"/></clipPath>')

    def render(self):
        out = [f'<svg xmlns="http://www.w3.org/2000/svg" xml:space="preserve" width="{self.w}" height="{self.h}" viewBox="0 0 {self.w} {self.h}">',
               f'<title>{escape(self.title)}</title>']
        if self.defs:
            out.append('<defs>' + ''.join(self.defs) + '</defs>')
        out += self.els
        out.append('</svg>')
        return '\n'.join(out) + '\n'


# ---------------------------------------------------------------- glyphs
# Simplified, hand-drawn stand-ins for SF Symbols (names in comments). Each takes
# a center (cx, cy), a nominal size s (12 or 14) and a color.

def g_check_circle_fill(S, cx, cy, s, c, knock):  # checkmark.circle.fill
    r = s / 2
    S.circle(cx, cy, r, fill=c)
    S.path(f'M{cx - r * .45:.1f} {cy + r * .02:.1f} L{cx - r * .1:.1f} {cy + r * .38:.1f} L{cx + r * .48:.1f} {cy - r * .36:.1f}',
           stroke=knock, sw=s * .14)


def g_check_circle(S, cx, cy, s, c):  # checkmark.circle
    r = s / 2 - .6
    S.circle(cx, cy, r, stroke=c, sw=1.3)
    S.path(f'M{cx - r * .45:.1f} {cy + r * .02:.1f} L{cx - r * .1:.1f} {cy + r * .38:.1f} L{cx + r * .48:.1f} {cy - r * .36:.1f}',
           stroke=c, sw=1.4)


def g_check(S, cx, cy, s, c):  # checkmark
    r = s / 2
    S.path(f'M{cx - r * .7:.1f} {cy:.1f} L{cx - r * .2:.1f} {cy + r * .55:.1f} L{cx + r * .75:.1f} {cy - r * .6:.1f}', stroke=c, sw=1.6)


def g_pencil(S, cx, cy, s, c):  # pencil
    r = s / 2
    # body along 45deg
    x0, y0 = cx - r * .75, cy + r * .75
    S.path(f'M{x0:.1f} {y0:.1f} L{x0 + r * .2:.1f} {y0 - r * .55:.1f} L{cx + r * .55:.1f} {cy - r * .95:.1f} '
           f'L{cx + r * .95:.1f} {cy - r * .55:.1f} L{x0 + r * .55:.1f} {y0 - r * .2:.1f} Z', fill=c)
    S.line(x0 + r * .2, y0 - r * .55, x0 + r * .55, y0 - r * .2, c, sw=.8)


def g_question_circle(S, cx, cy, s, c):  # questionmark.circle
    r = s / 2 - .6
    S.circle(cx, cy, r, stroke=c, sw=1.3)
    S.path(f'M{cx - r * .38:.1f} {cy - r * .25:.1f} C{cx - r * .38:.1f} {cy - r * .75:.1f} {cx + r * .42:.1f} {cy - r * .75:.1f} '
           f'{cx + r * .42:.1f} {cy - r * .22:.1f} C{cx + r * .42:.1f} {cy + r * .08:.1f} {cx:.1f} {cy + r * .05:.1f} {cx:.1f} {cy + r * .3:.1f}',
           stroke=c, sw=1.3)
    S.circle(cx, cy + r * .6, .9, fill=c)


def g_triangle_fill(S, cx, cy, s, c, knock):  # exclamationmark.triangle.fill
    r = s / 2
    S.path(f'M{cx:.1f} {cy - r * .95:.1f} L{cx + r:.1f} {cy + r * .8:.1f} L{cx - r:.1f} {cy + r * .8:.1f} Z', fill=c, stroke=c, sw=1.2)
    S.line(cx, cy - r * .35, cx, cy + r * .25, knock, sw=1.5, cap='round')
    S.circle(cx, cy + r * .55, .95, fill=knock)


def g_triangle(S, cx, cy, s, c):  # exclamationmark.triangle
    r = s / 2
    S.path(f'M{cx:.1f} {cy - r * .9:.1f} L{cx + r * .95:.1f} {cy + r * .78:.1f} L{cx - r * .95:.1f} {cy + r * .78:.1f} Z', stroke=c, sw=1.3)
    S.line(cx, cy - r * .3, cx, cy + r * .22, c, sw=1.4, cap='round')
    S.circle(cx, cy + r * .5, .85, fill=c)


def g_arrow(S, cx, cy, s, c, up=True):  # arrow.up / arrow.down
    r = s / 2
    d = -1 if up else 1
    S.line(cx, cy - d * r * .8, cx, cy + d * r * .8, c, sw=1.5, cap='round')
    S.path(f'M{cx - r * .55:.1f} {cy + d * r * .25:.1f} L{cx:.1f} {cy + d * r * .85:.1f} L{cx + r * .55:.1f} {cy + d * r * .25:.1f}',
           stroke=c, sw=1.5)


def g_lock(S, cx, cy, s, c):  # lock.fill
    r = s / 2
    S.rect(cx - r * .72, cy - r * .1, r * 1.44, r * 1.0, fill=c, r=1.5)
    S.path(f'M{cx - r * .45:.1f} {cy - r * .1:.1f} L{cx - r * .45:.1f} {cy - r * .45:.1f} A{r * .45:.1f} {r * .45:.1f} 0 0 1 '
           f'{cx + r * .45:.1f} {cy - r * .45:.1f} L{cx + r * .45:.1f} {cy - r * .1:.1f}', stroke=c, sw=1.4)


def g_question_folder(S, cx, cy, s, c):  # questionmark.folder
    r = s / 2
    S.path(f'M{cx - r:.1f} {cy - r * .55:.1f} L{cx - r * .35:.1f} {cy - r * .55:.1f} L{cx - r * .15:.1f} {cy - r * .3:.1f} '
           f'L{cx + r:.1f} {cy - r * .3:.1f} L{cx + r:.1f} {cy + r * .7:.1f} L{cx - r:.1f} {cy + r * .7:.1f} Z', stroke=c, sw=1.2)
    S.text(cx, cy + r * .58, '?', size=s * .7, fill=c, weight=700, anchor='middle')


def g_tree(S, cx, cy, s, c, filled=False):  # tree / tree.fill
    r = s / 2
    d = (f'M{cx:.1f} {cy - r:.1f} L{cx + r * .55:.1f} {cy - r * .15:.1f} L{cx + r * .3:.1f} {cy - r * .15:.1f} '
         f'L{cx + r * .8:.1f} {cy + r * .5:.1f} L{cx - r * .8:.1f} {cy + r * .5:.1f} L{cx - r * .3:.1f} {cy - r * .15:.1f} '
         f'L{cx - r * .55:.1f} {cy - r * .15:.1f} Z')
    if filled:
        S.path(d, fill=c, stroke=c, sw=.8)
    else:
        S.path(d, stroke=c, sw=1.1)
    S.line(cx, cy + r * .5, cx, cy + r, c, sw=1.4, cap='round')


def g_branch(S, cx, cy, s, c):  # arrow.triangle.branch (simplified: trunk + fork with nodes)
    r = s / 2
    x0, x1 = cx - r * .45, cx + r * .5
    S.line(x0, cy - r * .55, x0, cy + r * .55, c, sw=1.2)
    S.path(f'M{x0:.1f} {cy + r * .25:.1f} C{x0:.1f} {cy - r * .15:.1f} {x1:.1f} {cy:.1f} {x1:.1f} {cy - r * .45:.1f}', stroke=c, sw=1.2)
    S.circle(x0, cy + r * .72, r * .22, stroke=c, sw=1.1)
    S.circle(x0, cy - r * .72, r * .22, stroke=c, sw=1.1)
    S.circle(x1, cy - r * .72, r * .22, stroke=c, sw=1.1)


def g_globe(S, cx, cy, s, c):  # network
    r = s / 2 - .5
    S.circle(cx, cy, r, stroke=c, sw=1.1)
    S.path(f'M{cx:.1f} {cy - r:.1f} C{cx - r * .7:.1f} {cy - r * .4:.1f} {cx - r * .7:.1f} {cy + r * .4:.1f} {cx:.1f} {cy + r:.1f} '
           f'C{cx + r * .7:.1f} {cy + r * .4:.1f} {cx + r * .7:.1f} {cy - r * .4:.1f} {cx:.1f} {cy - r:.1f}', stroke=c, sw=1)
    S.line(cx - r, cy, cx + r, cy, c, sw=1)


def g_tag(S, cx, cy, s, c):  # tag
    r = s / 2
    S.path(f'M{cx - r * .9:.1f} {cy - r * .9:.1f} L{cx + r * .05:.1f} {cy - r * .9:.1f} L{cx + r * .95:.1f} {cy:.1f} '
           f'L{cx + r * .05:.1f} {cy + r * .9:.1f} L{cx - r * .9:.1f} {cy + r * .9:.1f} Z', stroke=c, sw=1.1)
    S.circle(cx - r * .45, cy - r * .45, .9, fill=c)


def g_tray(S, cx, cy, s, c):  # tray.full
    r = s / 2
    S.path(f'M{cx - r:.1f} {cy:.1f} L{cx - r * .7:.1f} {cy - r * .7:.1f} L{cx + r * .7:.1f} {cy - r * .7:.1f} L{cx + r:.1f} {cy:.1f} '
           f'L{cx + r:.1f} {cy + r * .75:.1f} L{cx - r:.1f} {cy + r * .75:.1f} Z', stroke=c, sw=1.1)
    S.path(f'M{cx - r:.1f} {cy:.1f} L{cx - r * .35:.1f} {cy:.1f} L{cx - r * .25:.1f} {cy + r * .3:.1f} L{cx + r * .25:.1f} {cy + r * .3:.1f} '
           f'L{cx + r * .35:.1f} {cy:.1f} L{cx + r:.1f} {cy:.1f}', stroke=c, sw=1.1)


def g_number_circle(S, cx, cy, s, c):  # number.circle
    r = s / 2 - .5
    S.circle(cx, cy, r, stroke=c, sw=1.1)
    S.text(cx, cy + s * .22, '#', size=s * .62, fill=c, weight=700, anchor='middle')


def g_magnifier(S, cx, cy, s, c):  # magnifyingglass
    r = s / 2
    S.circle(cx - r * .15, cy - r * .15, r * .55, stroke=c, sw=1.4)
    S.line(cx + r * .25, cy + r * .25, cx + r * .8, cy + r * .8, c, sw=1.6, cap='round')


def g_arrow_down_circle(S, cx, cy, s, c):  # arrow.down.circle
    r = s / 2 - .5
    S.circle(cx, cy, r, stroke=c, sw=1.3)
    g_arrow(S, cx, cy, s * .62, c, up=False)


def g_shield(S, cx, cy, s, c, ok=True):  # checkmark.shield / exclamationmark.shield
    r = s / 2
    S.path(f'M{cx:.1f} {cy - r:.1f} L{cx + r * .8:.1f} {cy - r * .65:.1f} L{cx + r * .8:.1f} {cy - r * .05:.1f} '
           f'C{cx + r * .8:.1f} {cy + r * .5:.1f} {cx + r * .35:.1f} {cy + r * .8:.1f} {cx:.1f} {cy + r:.1f} '
           f'C{cx - r * .35:.1f} {cy + r * .8:.1f} {cx - r * .8:.1f} {cy + r * .5:.1f} {cx - r * .8:.1f} {cy - r * .05:.1f} '
           f'L{cx - r * .8:.1f} {cy - r * .65:.1f} Z', stroke=c, sw=1.2)
    if ok:
        S.path(f'M{cx - r * .38:.1f} {cy:.1f} L{cx - r * .08:.1f} {cy + r * .3:.1f} L{cx + r * .4:.1f} {cy - r * .3:.1f}', stroke=c, sw=1.3)
    else:
        S.line(cx, cy - r * .45, cx, cy + r * .12, c, sw=1.4, cap='round')
        S.circle(cx, cy + r * .42, .85, fill=c)


def g_copy(S, cx, cy, s, c):  # doc.on.doc
    r = s / 2
    S.rect(cx - r * .8, cy - r * .5, r * 1.1, r * 1.35, r=1.5, stroke=c, sw=1.1)
    S.path(f'M{cx - r * .4:.1f} {cy - r * .75:.1f} L{cx - r * .4:.1f} {cy - r * .9:.1f} L{cx + r * .8:.1f} {cy - r * .9:.1f} '
           f'L{cx + r * .8:.1f} {cy + r * .45:.1f} L{cx + r * .5:.1f} {cy + r * .45:.1f}', stroke=c, sw=1.1)


def g_chevron(S, cx, cy, s, c, d='down'):  # chevron.*
    r = s / 2
    if d == 'down':
        p = f'M{cx - r * .55:.1f} {cy - r * .25:.1f} L{cx:.1f} {cy + r * .3:.1f} L{cx + r * .55:.1f} {cy - r * .25:.1f}'
    elif d == 'up':
        p = f'M{cx - r * .55:.1f} {cy + r * .25:.1f} L{cx:.1f} {cy - r * .3:.1f} L{cx + r * .55:.1f} {cy + r * .25:.1f}'
    elif d == 'right':
        p = f'M{cx - r * .25:.1f} {cy - r * .55:.1f} L{cx + r * .3:.1f} {cy:.1f} L{cx - r * .25:.1f} {cy + r * .55:.1f}'
    else:
        p = f'M{cx + r * .25:.1f} {cy - r * .55:.1f} L{cx - r * .3:.1f} {cy:.1f} L{cx + r * .25:.1f} {cy + r * .55:.1f}'
    S.path(p, stroke=c, sw=1.5)


def g_updown(S, cx, cy, s, c):  # chevron.up.chevron.down (pop-up button)
    g_chevron(S, cx, cy - s * .2, s * .55, c, 'up')
    g_chevron(S, cx, cy + s * .2, s * .55, c, 'down')


def g_sparkles(S, cx, cy, s, c):  # sparkles
    def star(x, y, r):
        k = r * .28
        S.path(f'M{x:.2f} {y - r:.2f} Q{x + k:.2f} {y - k:.2f} {x + r:.2f} {y:.2f} Q{x + k:.2f} {y + k:.2f} {x:.2f} {y + r:.2f} '
               f'Q{x - k:.2f} {y + k:.2f} {x - r:.2f} {y:.2f} Q{x - k:.2f} {y - k:.2f} {x:.2f} {y - r:.2f} Z', fill=c)
    r = s / 2
    star(cx - r * .15, cy + r * .1, r * .8)
    star(cx + r * .6, cy - r * .55, r * .38)


def g_refresh(S, cx, cy, s, c):  # arrow.clockwise
    r = s / 2 - 1
    S.path(f'M{cx + r:.1f} {cy:.1f} A{r:.1f} {r:.1f} 0 1 1 {cx + r * .5:.1f} {cy - r * .87:.1f}', stroke=c, sw=1.3)
    S.path(f'M{cx + r * .05:.1f} {cy - r * 1.15:.1f} L{cx + r * .6:.1f} {cy - r * .9:.1f} L{cx + r * .35:.1f} {cy - r * .35:.1f}', stroke=c, sw=1.3)


def g_person_badge(S, cx, cy, s, c, ok=True, badge_c=None, knock='#fff'):  # person.crop.circle.badge.*
    r = s / 2 - .5
    S.circle(cx, cy, r, stroke=c, sw=1.1)
    S.circle(cx, cy - r * .2, r * .32, fill=c)
    S.path(f'M{cx - r * .6:.1f} {cy + r * .65:.1f} C{cx - r * .5:.1f} {cy + r * .15:.1f} {cx + r * .5:.1f} {cy + r * .15:.1f} {cx + r * .6:.1f} {cy + r * .65:.1f}', fill=c)
    bc = badge_c or c
    S.circle(cx + r * .75, cy + r * .6, r * .5, fill=bc, stroke=knock, sw=1)
    if ok:
        S.path(f'M{cx + r * .52:.1f} {cy + r * .62:.1f} L{cx + r * .7:.1f} {cy + r * .8:.1f} L{cx + r:.1f} {cy + r * .42:.1f}', stroke=knock, sw=1)
    else:
        S.line(cx + r * .55, cy + r * .4, cx + r * .95, cy + r * .8, knock, sw=1)
        S.line(cx + r * .95, cy + r * .4, cx + r * .55, cy + r * .8, knock, sw=1)


def g_xmark_circle(S, cx, cy, s, c):  # xmark.circle
    r = s / 2 - .6
    S.circle(cx, cy, r, stroke=c, sw=1.3)
    k = r * .38
    S.line(cx - k, cy - k, cx + k, cy + k, c, sw=1.4, cap='round')
    S.line(cx + k, cy - k, cx - k, cy + k, c, sw=1.4, cap='round')


def g_sidebar(S, cx, cy, s, c):  # sidebar.left
    r = s / 2
    S.rect(cx - r, cy - r * .75, s, r * 1.5, r=2, stroke=c, sw=1.2)
    S.line(cx - r * .35, cy - r * .75, cx - r * .35, cy + r * .75, c, sw=1.2)


def g_folder(S, cx, cy, s, c):  # folder
    r = s / 2
    S.path(f'M{cx - r:.1f} {cy - r * .55:.1f} L{cx - r * .35:.1f} {cy - r * .55:.1f} L{cx - r * .15:.1f} {cy - r * .3:.1f} '
           f'L{cx + r:.1f} {cy - r * .3:.1f} L{cx + r:.1f} {cy + r * .7:.1f} L{cx - r:.1f} {cy + r * .7:.1f} Z', stroke=c, sw=1.2)


def g_terminal(S, cx, cy, s, c):  # terminal
    r = s / 2
    S.rect(cx - r, cy - r * .75, s, r * 1.5, r=2, stroke=c, sw=1.1)
    S.path(f'M{cx - r * .55:.1f} {cy - r * .3:.1f} L{cx - r * .2:.1f} {cy:.1f} L{cx - r * .55:.1f} {cy + r * .3:.1f}', stroke=c, sw=1.1)
    S.line(cx, cy + r * .3, cx + r * .5, cy + r * .3, c, sw=1.1)


def g_plusminus(S, cx, cy, s, c):  # plus.forwardslash.minus
    r = s / 2
    S.line(cx - r * .85, cy - r * .45, cx - r * .15, cy - r * .45, c, sw=1.2)
    S.line(cx - r * .5, cy - r * .8, cx - r * .5, cy - r * .1, c, sw=1.2)
    S.line(cx + r * .15, cy + r * .45, cx + r * .85, cy + r * .45, c, sw=1.2)
    S.line(cx + r * .45, cy - r * .7, cx - r * .45, cy + r * .7, c, sw=1)


def g_filter(S, cx, cy, s, c):  # line.3.horizontal.decrease
    r = s / 2
    for i, k in enumerate((.85, .55, .25)):
        y = cy - r * .55 + i * r * .55
        S.line(cx - r * k, y, cx + r * k, y, c, sw=1.3, cap='round')


def g_person2(S, cx, cy, s, c):  # person.2
    r = s / 2
    S.circle(cx - r * .3, cy - r * .35, r * .3, stroke=c, sw=1.1)
    S.path(f'M{cx - r * .9:.1f} {cy + r * .7:.1f} C{cx - r * .85:.1f} {cy:.1f} {cx + r * .25:.1f} {cy:.1f} {cx + r * .3:.1f} {cy + r * .7:.1f}', stroke=c, sw=1.1)
    S.circle(cx + r * .45, cy - r * .45, r * .25, stroke=c, sw=1.1)
    S.path(f'M{cx + r * .45:.1f} {cy - r * .02:.1f} C{cx + r * .8:.1f} {cy:.1f} {cx + r * .95:.1f} {cy + r * .3:.1f} {cx + r * .95:.1f} {cy + r * .55:.1f}', stroke=c, sw=1.1)
