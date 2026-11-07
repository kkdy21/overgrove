"""Validates the color tokens in design/tokens/tokens.json and prints the tables used in
docs/design/design-tokens.md §5. Standard library only. Run: python3 colorcheck.py

Checks
  - text tiers on every panel surface (WCAG 2.x contrast; text needs 4.5:1)
  - lane, status, and accent colors against the surfaces they are drawn on (graphics need 3:1)
  - text on solid lane fills (graph.on-lane)
  - text on the toolbar focus chip: text.primary and text.secondary on every lane at
    graph.focus-chip-fill-opacity over surface.window (#300)
  - neighbouring lanes (i, i+1 mod 8): OKLab distance with normal vision and simulated
    protanopia / deuteranopia / tritanopia (Machado et al. 2009, severity 1.0)
  - Increase Contrast modes (high-contrast, dark-high-contrast): every text tier including tertiary,
    status and lane colors need 4.5:1 on every panel surface including surface.selection
"""
import json, math, os

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..', '..'))
TOK = json.load(open(f'{REPO}/design/tokens/tokens.json'))
EXT = 'io.github.kkdy21.overgrove'


def node(path):
    n = TOK
    for k in path.split('.'):
        n = n[k]
    return n


# Mode lookup order; $value (light) is the last fallback. Aliases resolve in the same mode.
FALLBACK = {
    'light': [],
    'dark': ['dark'],
    'high-contrast': ['high-contrast'],
    'dark-high-contrast': ['dark-high-contrast', 'dark'],
}
MODES = list(FALLBACK)


def tok(path, mode):
    n = node(path)
    modes = n.get('$extensions', {}).get(EXT, {}).get('modes', {})
    v = next((modes[m] for m in FALLBACK[mode] if m in modes), n['$value'])
    if isinstance(v, str) and v.startswith('{'):
        return tok(v[1:-1], mode)
    return v


def sem(name, mode):
    return tok('semantic.color.' + name, mode)


def rgb(h):
    h = h.lstrip('#')
    return [int(h[i:i + 2], 16) / 255 for i in (0, 2, 4)]


def lin(c):
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def unlin(c):
    return 12.92 * c if c <= 0.0031308 else 1.055 * c ** (1 / 2.4) - 0.055


def blend(fg, bg):
    """#rrggbbaa over an opaque background."""
    if len(fg) == 9:
        a = int(fg[7:9], 16) / 255
        f, b = rgb(fg[:7]), rgb(bg)
        return '#%02x%02x%02x' % tuple(round((f[i] * a + b[i] * (1 - a)) * 255) for i in range(3))
    return fg


def lum(h):
    r, g, b = [lin(c) for c in rgb(h)]
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast(a, b):
    la, lb = lum(a), lum(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)


def oklab(h):
    r, g, b = [lin(c) for c in rgb(h)]
    l = (0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b) ** (1 / 3)
    m = (0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b) ** (1 / 3)
    s = (0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b) ** (1 / 3)
    return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)


def de(a, b):
    return 100 * math.dist(oklab(a), oklab(b))


CVD = {
    'protan': [[0.152286, 1.052583, -0.204868], [0.114503, 0.786281, 0.099216], [-0.003882, -0.048116, 1.051998]],
    'deutan': [[0.367322, 0.860646, -0.227968], [0.280085, 0.672501, 0.047413], [-0.011820, 0.042940, 0.968881]],
    'tritan': [[1.255528, -0.076749, -0.178779], [-0.078411, 0.930809, 0.147602], [0.004733, 0.691367, 0.303900]],
}


def simulate(h, kind):
    v = [lin(c) for c in rgb(h)]
    m = CVD[kind]
    out = [min(max(sum(m[i][j] * v[j] for j in range(3)), 0), 1) for i in range(3)]
    return '#%02x%02x%02x' % tuple(round(unlin(c) * 255) for c in out)


def main():
    fails = []
    surfaces = ['surface.canvas', 'surface.panel', 'surface.panel-header', 'surface.raised', 'surface.selection']
    for mode in MODES:
        hc = mode.endswith('high-contrast')
        print(f'\n## {mode}')
        surf = {s: sem(s, mode) for s in surfaces}
        print('surfaces:', ', '.join(f'{k.split(".")[1]} {v}' for k, v in surf.items()), '| window', sem('surface.window', mode))
        print('\ntext tier   ' + ' '.join(f'{k.split(".")[1]:>13}' for k in surfaces))
        for t in ('primary', 'secondary', 'tertiary', 'quaternary'):
            c = sem('text.' + t, mode)
            vals = [contrast(c, surf[s]) for s in surfaces]
            print(f'{t:10} {c} ' + ' '.join(f'{v:13.2f}' for v in vals))
            for s, v in zip(surfaces, vals):
                if t in ('primary', 'secondary') and v < 4.5:
                    fails.append(f'{mode} text.{t} on {s}: {v:.2f}')
                if t == 'tertiary' and (hc or s != 'surface.selection') and v < 4.5:
                    fails.append(f'{mode} text.tertiary on {s}: {v:.2f}')
        canvas = surf['surface.canvas']
        lanes = [sem(f'graph.lane.{i}', mode) for i in range(8)]
        print('\nlane  color    vs canvas  on-lane text' + ('  min surface' if hc else ''))
        for i, c in enumerate(lanes):
            ol = sem(f'graph.on-lane.{i}', mode)
            v, t = contrast(c, canvas), contrast(ol, c)
            low = min(contrast(c, x) for x in surf.values())
            print(f'{i}     {c}  {v:6.2f}     {ol} {t:5.2f}' + (f'  {low:5.2f}' if hc else ''))
            if v < 3:
                fails.append(f'{mode} lane {i} vs canvas {v:.2f}')
            if hc and low < 4.5:
                fails.append(f'{mode} lane {i} below 4.5:1 on a panel surface ({low:.2f})')
            if t < 4.5:
                fails.append(f'{mode} on-lane {i} {t:.2f}')
        # Toolbar focus chip (#300): the branch name (text.primary) and the ahead count and ⌘J hint (text.secondary)
        # on the lane tint over the toolbar background.
        alpha = tok('semantic.color.graph.focus-chip-fill-opacity', mode)
        window = sem('surface.window', mode)
        chips = [blend(lane + '%02x' % round(alpha * 255), window) for lane in lanes]
        chip_low = {t: min(contrast(sem('text.' + t, mode), c) for c in chips) for t in ('primary', 'secondary')}
        print(f'\nfocus chip (lane {alpha:.0%} over window) min text.primary {chip_low["primary"]:.2f}'
              f'  text.secondary {chip_low["secondary"]:.2f}')
        for t, v in chip_low.items():
            if v < 4.5:
                fails.append(f'{mode} text.{t} on the focus chip {v:.2f}')
        print('\nneighbour lanes ΔE(OKLab×100)  normal  protan  deutan  tritan')
        for i in range(8):
            a, b = lanes[i], lanes[(i + 1) % 8]
            row = [de(a, b)] + [de(simulate(a, k), simulate(b, k)) for k in ('protan', 'deutan', 'tritan')]
            print(f'{i}-{(i + 1) % 8}                          ' + '  '.join(f'{v:6.1f}' for v in row))
        print('\nstatus/accent  vs canvas  panel  raised' + ('  min surface' if hc else ''))
        for name in ('status.staged', 'status.unstaged', 'status.untracked', 'status.conflicted', 'status.ahead', 'accent'):
            c = sem(name, mode)
            vals = [contrast(c, surf[s]) for s in ('surface.canvas', 'surface.panel', 'surface.raised')]
            low = min(contrast(c, x) for x in surf.values())
            print(f'{name:18} {c} ' + '  '.join(f'{v:5.2f}' for v in vals) + (f'  {low:5.2f}' if hc else ''))
            if min(vals) < 3:
                fails.append(f'{mode} {name} below 3:1')
            if hc and name.startswith('status.') and low < 4.5:
                fails.append(f'{mode} {name} below 4.5:1 on a panel surface ({low:.2f})')
        for k in ('staged', 'unstaged', 'untracked', 'conflicted', 'ahead'):
            v = contrast(sem('on-status.' + k, mode), sem('status.' + k, mode))
            if v < 4.5:
                fails.append(f'{mode} on-status.{k} {v:.2f}')
        acc, on = sem('accent', mode), sem('text.on-accent', mode)
        print(f'text.on-accent on accent: {contrast(on, acc):.2f}')
        if contrast(on, acc) < 4.5:
            fails.append(f'{mode} on-accent {contrast(on, acc):.2f}')
        for a in range(8):
            c = tok(f'semantic.color.avatar.{a}', mode)
            if contrast('#ffffff', c) < 4.5:
                fails.append(f'avatar {a} initials {contrast("#ffffff", c):.2f}')
        diff_text = sem('text.primary', mode)
        for k in ('added-bg', 'removed-bg', 'added-word-bg', 'removed-word-bg', 'hunk-header-bg'):
            v = contrast(diff_text, sem('diff.' + k, mode))
            if v < 4.5:
                fails.append(f'{mode} text on diff.{k} {v:.2f}')
    print('\nRESULT:', 'all checks pass' if not fails else 'FAIL\n  ' + '\n  '.join(fails))
    return 1 if fails else 0


if __name__ == '__main__':
    raise SystemExit(main())
