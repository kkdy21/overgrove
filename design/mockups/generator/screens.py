"""Overgrove high-fidelity mockups. Run: venv/bin/python screens.py <outdir>"""
import sys, re
from lib import *

W, H = 1280, 800
TB = 52            # toolbar height
SBW = 240          # sidebar width
DETW = 340         # detail width
CX0, CX1 = SBW, W - DETW   # center pane x range
STY = H - 24       # status bar top
ROW = 24

AUTHORS = {
    'MP': ('Mina Park', 'mina@example.com'),
    'AK': ('Alex Kim', 'alex@example.com'),
    'JL': ('Jordan Lee', 'jordan@example.com'),
    'SR': ('Sam Rivera', 'sam@example.com'),
}
AI_COAUTHOR = ('Coding Agent', 'agent@example.com')
CHECKED_OUT = {'main', 'agent/refactor-logging', 'feat/42-rate-limit', 'fix/57-token-refresh'}

# sha, subject, author, date, lane, parents, refs, ai, worktree-pill
C = [
    ('a91f3c2', 'feat(ratelimit): add sliding window limiter', 'AK', '2h', 1, [1], [('local', 'feat/42-rate-limit'), ('remote', 'origin/feat/42-rate-limit')], True, None),
    ('7d20e18', 'test(ratelimit): cover burst and refill cases', 'AK', '3h', 1, [4], [], True, None),
    ('e4b9a07', 'fix(auth): refresh token before expiry', 'MP', '5h', 2, [4], [('local', 'fix/57-token-refresh')], False, None),
    ('0f6a9d3', 'refactor(log): structured logger with request id', 'AK', '6h', 3, [7], [('local', 'agent/refactor-logging')], True, None),
    ('3c5d6f1', "Merge pull request #51 from acme/feat/48-metrics", 'JL', '1d', 0, [6, 5], [('local', 'main'), ('remote', 'origin/main')], False, None),
    ('b2e8a44', 'feat(metrics): export request latency histogram', 'SR', '1d', 1, [8], [('remote', 'origin/feat/48-metrics')], True, 'review-51'),
    ('9a1c7e2', 'docs: describe rate limit response headers', 'MP', '1d', 0, [7], [], False, None),
    ('58de0b4', 'chore(deps): bump Go toolchain to 1.23', 'JL', '2d', 0, [8], [('tag', 'v0.4.0')], False, None),
    ('6b7f2c1', 'feat(api): paginate /v1/orders', 'SR', '2d', 0, [9], [], False, None),
    ('2d4e8a9', 'fix(tenant): return 404 for unknown tenant', 'MP', '3d', 0, [10], [], False, None),
    ('c81d5f0', 'Merge pull request #44 from acme/fix/40-timeouts', 'JL', '3d', 0, [12, 11], [], False, None),
    ('47b2e9a', 'fix(http): set server read and write timeouts', 'MP', '4d', 1, [13], [], False, None),
    ('e19c3b7', 'test(api): table tests for order filters', 'SR', '4d', 0, [13], [], True, None),
    ('a0f4d62', 'feat(auth): verify JWT audience claim', 'AK', '5d', 0, [14], [], False, None),
    ('5c7e8b1', 'refactor(store): split order repository', 'SR', '5d', 0, [15], [], True, None),
    ('8d3a2f9', 'ci: cache Go modules between jobs', 'JL', '6d', 0, [16], [], False, None),
    ('f2b6c04', 'docs: add architecture overview', 'MP', '1w', 0, [17], [], False, None),
    ('3e9d1a5', 'feat(api): add /v1/health endpoint', 'AK', '1w', 0, [18], [('tag', 'v0.3.0')], False, None),
    ('b74c0e2', 'fix(store): close rows on early return', 'SR', '1w', 0, [19], [], False, None),
    ('6a2f8d7', 'chore: add golangci-lint config', 'JL', '2w', 0, [20], [], False, None),
    ('d5e1b93', 'feat(orders): create order endpoint', 'MP', '2w', 0, [21], [], False, None),
    ('0c9b7f4', 'feat(store): Postgres connection pool', 'AK', '2w', 0, [22], [], False, None),
    ('9f3e6a1', 'build: add Makefile targets', 'JL', '3w', 0, [23], [], False, None),
    ('7b1d4c8', 'docs: README quick start', 'MP', '3w', 0, [24], [], False, None),
    ('2e6f9a3', 'feat: request id middleware', 'AK', '4w', 0, [25], [], False, None),
    ('c4a8e17', 'chore: project layout', 'JL', '4w', 0, [26], [], False, None),
    ('1f5b2d6', 'Initial commit', 'JL', '1mo', 0, [], [], False, None),
]


def av_idx(code):
    return fnv1a(AUTHORS[code][1]) % 8


# ------------------------------------------------------------------ primitives

def knock(T):
    return T('surface.content')


def avatar(S, T, cx, cy, code, d=16, on_sel=False):
    if on_sel:
        S.circle(cx, cy, d / 2 + 1, fill=T('text.on-selection'))
    S.circle(cx, cy, d / 2, fill=T.avatar(av_idx(code)))
    fs = d * 0.46
    S.text(cx, cy + fs * 0.36, code, size=fs, fill=T('avatar.initials'), weight=700, anchor='middle')


def ai_avatar(S, T, cx, cy, d=16):
    S.circle(cx, cy, d / 2 - .5, fill=None, stroke=T('text.secondary'), sw=1)
    g_sparkles(S, cx, cy, d * .62, T('text.secondary'))


def ai_badge(S, T, x, cy, on_sel=False):
    """'AI' badge for commits carrying a Co-Authored-By AI trailer. Returns width."""
    c = T('text.on-selection') if on_sel else T('text.secondary')
    w = 34
    S.rect(x, cy - 8, w, 16, r=4, stroke=c, sw=1, op=.7)
    g_sparkles(S, x + 10, cy, 10, c)
    S.text(x + 18, cy + 3.5, 'AI', size=10, fill=c, weight=700)
    return w


def pill_w(kind, name, maxw=150, tree=False, remote_too=False):
    gl = 14 if (kind in ('tag', 'wt') or tree) else 0
    gr = 14 if remote_too else 0
    name = fit(name, 11, maxw - 12 - gl - gr, 500)
    return tw(name, 11, 500) + 12 + gl + gr, name, gl, gr


def pill(S, T, x, cy, kind, name, lane=0, on_sel=False, maxw=150, tree=False, remote_too=False):
    """Ref pill. local = lane fill, remote = lane outline, local+remote at the same commit = fill + outline + globe.
    tree = branch is checked out in another worktree; wt = detached worktree HEAD; tag = neutral."""
    fs = 11
    txt = T('text.on-selection') if on_sel else T('text.primary')
    sec = T('text.on-selection') if on_sel else T('text.secondary')
    w, name, gl, gr = pill_w(kind, name, maxw, tree, remote_too)
    lc = T.lane(lane)
    fill_op = float(tok('semantic.color.graph.ref-pill-local-fill-opacity'))
    border_op = float(tok('semantic.color.graph.ref-pill-remote-border-opacity'))
    if kind == 'local':
        S.rect(x, cy - 8, w, 16, fill=lc if not on_sel else txt, r=4, op=fill_op if not on_sel else .25)
        if remote_too:
            S.rect(x + .5, cy - 7.5, w - 1, 15, r=4, stroke=lc if not on_sel else txt, sw=1, op=border_op if not on_sel else .8)
    elif kind == 'remote':
        S.rect(x + .5, cy - 7.5, w - 1, 15, r=4, stroke=lc if not on_sel else txt, sw=1, op=border_op if not on_sel else .8)
    else:
        S.rect(x + .5, cy - 7.5, w - 1, 15, r=4, stroke=sec, sw=1, op=.6)
    if kind == 'tag':
        g_tag(S, x + 6 + 4, cy, 9, sec)
    elif kind == 'wt' or tree:
        g_tree(S, x + 6 + 4, cy, 10, txt if kind == 'local' else sec)
    S.text(x + 6 + gl, cy + 4, name, size=fs, fill=txt, weight=500)
    if remote_too:
        g_globe(S, x + w - 6 - 5, cy, 10, txt)
    return w


def button(S, T, x, y, w, label, h=28, glyph=None, primary=False, fs=13):
    if primary:
        S.rect(x, y, w, h, fill=T('accent'), r=6)
        c = T('text.on-selection')
    else:
        S.rect(x, y, w, h, fill=T('surface.control'), r=6, stroke=T('border.separator'), sw=1)
        c = T('text.primary')
    tx = x + w / 2
    if glyph:
        gw = 18
        lw = tw(label, fs)
        x0 = x + (w - gw - lw) / 2
        glyph(S, x0 + 7, y + h / 2, 14, c)
        S.text(x0 + gw, y + h / 2 + fs * .36, label, size=fs, fill=c)
    else:
        S.text(tx, y + h / 2 + fs * .36, label, size=fs, fill=c, anchor='middle', weight=500 if primary else 400)


def segmented(S, T, x, y, items, active, h=24, fs=12):
    ws = [tw(i, fs, 500) + 24 for i in items]
    tot = sum(ws) + 4
    S.rect(x, y, tot, h, fill=T('surface.window'), r=6, stroke=T('border.separator'), sw=1)
    cx = x + 2
    for i, (it, w) in enumerate(zip(items, ws)):
        if i == active:
            S.rect(cx, y + 2, w, h - 4, fill=T('surface.control'), r=5, stroke=T('border.separator'), sw=.5)
            S.text(cx + w / 2, y + h / 2 + fs * .36, it, size=fs, fill=T('text.primary'), weight=500, anchor='middle')
        else:
            S.text(cx + w / 2, y + h / 2 + fs * .36, it, size=fs, fill=T('text.secondary'), anchor='middle')
        cx += w
    return tot


def toggle(S, T, x, cy, on=True):
    w, h = 26, 15
    S.rect(x, cy - h / 2, w, h, r=h / 2, fill=T('accent') if on else T('border.separator'))
    S.circle(x + (w - h / 2) if on else x + h / 2, cy, h / 2 - 1.5, fill=T('surface.control') if not on else T('text.on-selection'))


def path_text(S, T, x, y, path, maxw, fs=13, on_sel=False, mono=False):
    """Directory in secondary, file name in primary. Middle-truncate the directory."""
    if '/' in path:
        d, n = path.rsplit('/', 1)
        d += '/'
    else:
        d, n = '', path
    pc = T('text.on-selection') if on_sel else T('text.primary')
    sc = T('text.on-selection') if on_sel else T('text.secondary')
    nw = tw(n, fs, 400, mono)
    room = maxw - nw
    if room < tw(d, fs, 400, mono):
        d = fit(d, fs, max(room, 20), mono=mono, middle=True) if room > 30 else ''
    w = 0
    if d:
        w += S.text(x, y, d, size=fs, fill=sc, op=.85 if on_sel else 1, mono=mono)
    S.text(x + w, y, n, size=fs, fill=pc, mono=mono)
    return w + nw


def stat(S, T, xr, y, add, rem, fs=11, on_sel=False):
    """Right-aligned '+a −r' using glyph + color (never color alone)."""
    ca = T('text.on-selection') if on_sel else T('diff.gutter-added')
    cr_ = T('text.on-selection') if on_sel else T('diff.gutter-removed')
    s2 = f'−{rem}'
    w2 = tw(s2, fs, 500, True)
    S.text(xr, y, s2, size=fs, fill=cr_, mono=True, anchor='end', weight=500)
    s1 = f'+{add}'
    S.text(xr - w2 - 6, y, s1, size=fs, fill=ca, mono=True, anchor='end', weight=500)


def status_glyph(S, T, kind, cx, cy, s=12, on_sel=False):
    col = {'staged': 'status.staged', 'unstaged': 'status.unstaged', 'untracked': 'status.untracked', 'conflicted': 'status.conflicted'}[kind]
    c = T('text.on-selection') if on_sel else T(col)
    kn = T('surface.selection') if on_sel else knock(T)
    if kind == 'staged':
        g_check_circle_fill(S, cx, cy, s, c, kn)
    elif kind == 'unstaged':
        g_pencil(S, cx, cy, s, c)
    elif kind == 'untracked':
        g_question_circle(S, cx, cy, s, c)
    else:
        g_triangle_fill(S, cx, cy, s, c, kn)


# ------------------------------------------------------------------ window chrome

def window(T, title):
    S = Svg(W, H, title)
    S.clip('win', 0, 0, W, H, 10)
    S.open_group(clip='win')
    S.rect(0, 0, W, H, fill=T('surface.window'))
    return S


def finish(S, T):
    S.close_group()
    S.rect(.5, .5, W - 1, H - 1, r=10, stroke=T('border.separator'), sw=1)
    return S.render()


def traffic(S, T):
    for i, k in enumerate(('window-close', 'window-minimize', 'window-zoom')):
        S.circle(20 + i * 20, 26, 6, fill=T('primitive.color.system-fallback.' + k))


def toolbar(S, T, focus_branch, fetching=False):
    x = SBW + 16
    S.text(x, 24, 'api', size=13, fill=T('text.primary'), weight=700)
    g_updown(S, x + tw('api', 13, 700) + 9, 19, 10, T('text.secondary'))
    S.text(x, 39, 'acme/api', size=10, fill=T('text.secondary'))
    button(S, T, x + 72, 12, 84, 'Fetch', glyph=g_arrow_down_circle)
    # focus worktree branch (center of center+detail)
    mid = (CX0 + W - 260) / 2 + 40
    lw = tw(focus_branch, 13)
    g_branch(S, mid - lw / 2 - 12, 26, 12, T('text.secondary'))
    S.text(mid - lw / 2, 30.5, focus_branch, size=13, fill=T('text.primary'))
    # search
    sx = W - 16 - 224
    S.rect(sx, 12, 224, 28, fill=T('surface.control'), r=6, stroke=T('border.separator'), sw=1)
    g_magnifier(S, sx + 15, 26, 12, T('text.secondary'))
    S.text(sx + 28, 30.5, 'Search commits, authors, refs', size=12, fill=T('text.tertiary'))
    S.text(sx + 212, 30.5, '⌘F', size=11, fill=T('text.tertiary'), anchor='end')
    S.line(SBW, TB - .5, W, TB - .5, T('border.separator'))


def statusbar(S, T, ab=(2, 0)):
    S.rect(0, STY, W, H - STY, fill=T('surface.window'))
    S.line(0, STY + .5, W, STY + .5, T('border.separator'))
    y = STY + 15.5
    x = 16
    g_refresh(S, x + 5, y - 3.5, 11, T('text.secondary'))
    x += 15
    x += S.text(x, y, 'Fetched 2 min ago', size=10, fill=T('text.secondary'))
    x += S.text(x, y, '  ·  ', size=10, fill=T('text.secondary'))
    if ab is None:
        x += S.text(x, y, 'No upstream', size=10, fill=T('text.secondary'))
    else:
        g_arrow(S, x + 4, y - 3.5, 9, T('status.ahead'), up=True)
        x += 10
        x += S.text(x, y, str(ab[0]), size=10, fill=T('status.ahead'), weight=500) + 6
        g_arrow(S, x + 4, y - 3.5, 9, T('status.behind'), up=False)
        x += 10
        x += S.text(x, y, str(ab[1]), size=10, fill=T('status.behind'), weight=500)
    x += S.text(x, y, '  ·  6 worktrees  ·  ', size=10, fill=T('text.secondary'))
    g_question_folder(S, x + 6, y - 3.5, 11, T('status.prunable'))
    x += 15
    S.text(x, y, '1 prunable', size=10, fill=T('status.prunable'), weight=500)
    # right
    t = 'gh: @mina-dev'
    S.text(W - 16, y, t, size=10, fill=T('text.secondary'), anchor='end')
    g_person_badge(S, W - 16 - tw(t, 10) - 10, y - 3.5, 12, T('text.secondary'), ok=True, badge_c=T('status.ok'), knock=T('surface.window'))


# ------------------------------------------------------------------ sidebar

WORKTREES = [
    dict(key='main', name='main', tag='main worktree', badges=[]),
    dict(key='refactor', name='agent/refactor-logging', badges=[('conflict', 1), ('pencil', 6)]),
    dict(key='feat42', name='feat/42-rate-limit', badges=[('pencil', 7), ('ahead', 2)]),
    dict(key='fix57', name='fix/57-token-refresh', badges=[('pencil', 3), ('ahead', 1)]),
    dict(key='review', name='detached @ b2e8a44', sub='review-51', badges=[('lock', 0)]),
    dict(key='spike', name='spike/grpc', sub='path missing', badges=[('prunable', 0)], dim=True),
]


def sb_header(S, T, y, label):
    S.text(16, y, label, size=11, fill=T('text.secondary'), weight=700, ls='.3')


def sb_badges(S, T, xr, cy, badges, sel):
    """Draw badges right-to-left in priority order. Returns left x."""
    x = xr
    for kind, n in badges:
        c_sec = T('text.on-selection') if sel else T('text.secondary')
        if kind == 'conflict':
            c = T('text.on-selection') if sel else T('status.conflicted')
            s = str(n)
            x -= tw(s, 11, 500)
            S.text(x, cy + 4, s, size=11, fill=c, weight=500)
            x -= 15
            g_triangle_fill(S, x + 6, cy, 12, c, T('surface.selection') if sel else T('surface.sidebar'))
        elif kind == 'pencil':
            s = str(n)
            x -= tw(s, 11)
            S.text(x, cy + 4, s, size=11, fill=c_sec)
            x -= 14
            g_pencil(S, x + 6, cy, 11, c_sec)
        elif kind in ('ahead', 'behind'):
            c = T('text.on-selection') if sel else T('status.ahead')
            s = str(n)
            x -= tw(s, 11, 500)
            S.text(x, cy + 4, s, size=11, fill=c, weight=500)
            x -= 11
            g_arrow(S, x + 5, cy, 10, c, up=(kind == 'ahead'))
        elif kind == 'lock':
            x -= 12
            g_lock(S, x + 6, cy, 12, T('text.on-selection') if sel else T('status.locked'))
        elif kind == 'prunable':
            x -= 14
            g_question_folder(S, x + 7, cy, 13, T('text.on-selection') if sel else T('status.prunable'))
        elif kind == 'tree':
            x -= 12
            g_tree(S, x + 6, cy, 11, c_sec)
        elif kind == 'delta':
            s = str(n)
            x -= tw(s, 11)
            S.text(x, cy + 4, s, size=11, fill=c_sec)
            x -= 15
            g_plusminus(S, x + 6, cy, 11, c_sec)
        elif kind == 'count':
            s = str(n)
            x -= tw(s, 11)
            S.text(x, cy + 4, s, size=11, fill=c_sec)
        x -= 8
    return x


def sidebar(S, T, focus='feat42', selected='wt:feat42', delta=None):
    S.rect(0, 0, SBW, STY, fill=T('surface.sidebar'))
    S.line(SBW - .5, 0, SBW - .5, STY, T('border.separator'))
    traffic(S, T)
    g_sidebar(S, SBW - 28, 26, 15, T('text.secondary'))

    def row(y, sel):
        if sel:
            S.rect(8, y, SBW - 16, ROW, fill=T('surface.selection'), r=6)

    y = TB + 22
    sb_header(S, T, y, f'WORKTREES ({len(WORKTREES)})')
    y += 8
    for wt in WORKTREES:
        sel = selected == f'wt:{wt["key"]}'
        row(y, sel)
        cy = y + ROW / 2
        pc = T('text.on-selection') if sel else T('text.primary')
        sc = T('text.on-selection') if sel else T('text.secondary')
        if wt['key'] == focus:
            S.circle(19, cy, 3, fill=T('text.on-selection') if sel else T('accent'))
        g_tree(S, 33, cy, 12, sc, filled=(wt['key'] == 'main'))
        badges = list(wt['badges'])
        if delta and wt['key'] == focus:
            badges = badges + [('delta', delta)]
        left = sb_badges(S, T, SBW - 20, cy, badges, sel)
        op = .6 if wt.get('dim') else 1
        nx = 46
        extra = wt.get('tag') or wt.get('sub')
        room = left - nx - 4
        if extra and tw(wt['name'], 13) + tw(extra, 10) + 6 > room:
            extra = None
        if extra:
            ew = tw(extra, 10)
            name = fit(wt['name'], 13, room - ew - 8)
            w = S.text(nx, cy + 4.5, name, size=13, fill=pc, op=op)
            S.text(nx + w + 6, cy + 4, extra, size=10, fill=sc, op=op)
        else:
            S.text(nx, cy + 4.5, fit(wt['name'], 13, room), size=13, fill=pc, op=op)
        y += ROW

    y += 22
    sb_header(S, T, y, 'LOCAL (5)')
    y += 8
    local = [('branch', 'main', [('tree', 0)], 0), ('folder', 'agent/', [('count', 1)], 0), ('open', 'feat/', [], 0),
             ('branch', '42-rate-limit', [('tree', 0), ('ahead', 2)], 1), ('folder', 'fix/', [('count', 1)], 0)]
    for kind, name, badges, ind in local:
        sel = False
        cy = y + ROW / 2
        x = 22 + ind * 14
        sc, pc = T('text.secondary'), T('text.primary')
        if kind == 'branch':
            g_branch(S, x + 11, cy, 12, sc)
        else:
            g_chevron(S, x + 4, cy, 9, sc, 'down' if kind == 'open' else 'right')
            g_folder(S, x + 18, cy, 12, sc)
            x += 6
        sb_badges(S, T, SBW - 20, cy, badges, sel)
        S.text(x + 24, cy + 4.5, name, size=13, fill=pc)
        y += ROW

    y += 22
    sb_header(S, T, y, 'REMOTE')
    y += 8
    cy = y + ROW / 2
    g_chevron(S, 26, cy, 9, T('text.secondary'), 'down')
    g_globe(S, 40, cy, 12, T('text.secondary'))
    S.text(52, cy + 4.5, 'origin', size=13, fill=T('text.primary'))
    S.text(SBW - 20, cy + 4, '4', size=11, fill=T('text.secondary'), anchor='end')
    y += ROW
    remote = [('feat/42-rate-limit', 'AK', '2h'), ('feat/48-metrics', 'SR', '1d'), ('fix/57-token-refresh', 'MP', '5h'), ('main', 'JL', '1d')]
    for name, code, when in remote:
        cy = y + ROW / 2
        g_branch(S, 47, cy, 12, T('text.secondary'))
        tx = SBW - 20
        tx -= S.text(tx, cy + 4, when, size=11, fill=T('text.secondary'), anchor='end') if False else 0
        S.text(tx, cy + 4, when, size=11, fill=T('text.secondary'), anchor='end')
        ww = max(tw('2h', 11), tw(when, 11))
        avatar(S, T, tx - 22 - 4, cy, code, d=16)
        S.text(59, cy + 4.5, fit(name, 13, tx - 22 - 16 - 59), size=13, fill=T('text.primary'))
        y += ROW

    y += 22
    sb_header(S, T, y, 'STASHES (2)')
    y += 8
    for ref, msg in (('stash@{0}', 'WIP on feat/42-rate-limit'), ('stash@{1}', 'spike notes')):
        cy = y + ROW / 2
        g_tray(S, 33, cy, 12, T('text.secondary'))
        w = S.text(46, cy + 4.5, ref, size=13, fill=T('text.primary'))
        S.text(46 + w + 6, cy + 4.5, fit(msg, 12, SBW - 20 - 52 - w), size=12, fill=T('text.secondary'))
        y += ROW

    y += 22
    sb_header(S, T, y, 'ISSUES (3)')
    y += 8
    for num, title, linked in (('#42', 'Rate limit per tenant', True), ('#57', 'Token refresh race', True), ('#61', 'Paginate audit log', False)):
        cy = y + ROW / 2
        g_number_circle(S, 33, cy, 12, T('text.secondary'))
        left = sb_badges(S, T, SBW - 20, cy, [('tree', 0)] if linked else [], False)
        w = S.text(46, cy + 4.5, num, size=13, fill=T('text.secondary'))
        S.text(46 + w + 6, cy + 4.5, fit(title, 13, left - 52 - w), size=13, fill=T('text.primary'))
        y += ROW


# ------------------------------------------------------------------ graph

def lane_x(l):
    return CX0 + 16 + l * 14


def author_chips(S, T, active='all'):
    y0 = TB
    S.rect(CX0, y0, CX1 - CX0, 40, fill=T('surface.content'))
    S.line(CX0, y0 + 39.5, CX1, y0 + 39.5, T('border.separator'))
    cy = y0 + 20
    x = CX0 + 16
    g_person2(S, x + 6, cy, 13, T('text.secondary'))
    x += 20
    chips = [('all', 'All', None, None), ('JL', 'Jordan Lee', 'JL', 9), ('AK', 'Alex Kim', 'AK', 8),
             ('MP', 'Mina Park', 'MP', 8), ('SR', 'Sam Rivera', 'SR', 6)]
    for key, label, code, n in chips:
        on = key == active
        lw = tw(label, 12, 500 if on else 400)
        w = lw + 20 + (20 if code else 0) + (tw(str(n), 11) + 6 if n else 0)
        if on:
            S.rect(x, cy - 12, w, 24, fill=T('accent'), r=12)
        else:
            S.rect(x + .5, cy - 11.5, w - 1, 23, fill=T('surface.control'), r=12, stroke=T('border.separator'))
        tc = T('text.on-selection') if on else T('text.primary')
        tx = x + 10
        if code:
            avatar(S, T, tx + 7, cy, code, d=16)
            tx += 20
        tx += S.text(tx, cy + 4, label, size=12, fill=tc, weight=500 if on else 400)
        if n:
            S.text(tx + 6, cy + 4, str(n), size=11, fill=T('text.on-selection') if on else T('text.secondary'))
        x += w + 6
    # AI-assisted filter chip, separated
    x += 4
    S.line(x, cy - 10, x, cy + 10, T('border.separator'))
    x += 12
    on = active == 'ai'
    label = 'AI-assisted'
    w = tw(label, 12, 500 if on else 400) + 20 + 18 + tw('7', 11) + 6
    if on:
        S.rect(x, cy - 12, w, 24, fill=T('accent'), r=12)
    else:
        S.rect(x + .5, cy - 11.5, w - 1, 23, fill=T('surface.control'), r=12, stroke=T('border.separator'))
    tc = T('text.on-selection') if on else T('text.primary')
    g_sparkles(S, x + 17, cy, 12, tc)
    tx = x + 28 + S.text(x + 28, cy + 4, label, size=12, fill=tc, weight=500 if on else 400)
    S.text(tx + 6, cy + 4, '7', size=11, fill=T('text.on-selection') if on else T('text.secondary'))


def graph(S, T, focus_lane=1, focus_idx=0, wip=None, selected=None, dim_non_ai=False, y0=TB + 40, focus_branch='feat/42-rate-limit'):
    """wip: summary list of (kind, n) or None. selected: 'wip' or commit index."""
    S.rect(CX0, y0, CX1 - CX0, STY - y0, fill=T('surface.content'))
    S.clip('graphclip', CX0, y0, CX1 - CX0, STY - y0)
    off = 1 if wip else 0
    rowy = lambda r: y0 + r * ROW + ROW / 2
    # rows backgrounds
    if wip:
        S.rect(CX0, y0, CX1 - CX0, ROW, fill=T('surface.wip-row'))
    if selected is not None:
        r = 0 if selected == 'wip' else selected + off
        S.rect(CX0, y0 + r * ROW, CX1 - CX0, ROW, fill=T('surface.selection'))
    S.open_group(clip='graphclip')
    # edges
    n = len(C)
    for i, c in enumerate(C):
        li, ri = c[4], i + off
        for p in c[5]:
            lp = C[p][4] if p < n else 0
            rp = p + off
            col = T.lane(max(li, lp))
            x1, y1, x2, y2 = lane_x(li), rowy(ri), lane_x(lp), rowy(rp)
            if li == lp:
                d = f'M{x1} {y1} L{x2} {y2}'
            elif li > lp:
                ym = rowy(rp - 1)
                d = f'M{x1} {y1} L{x1} {ym} C{x1} {(ym + y2) / 2} {x2} {(ym + y2) / 2} {x2} {y2}'
            else:
                ym = rowy(ri + 1)
                d = f'M{x1} {y1} C{x1} {(y1 + ym) / 2} {x2} {(y1 + ym) / 2} {x2} {ym} L{x2} {y2}'
            S.path(d, stroke=col, sw=2)
    # root continues? last commit is root, no line.
    if wip:
        S.line(lane_x(focus_lane), rowy(0), lane_x(focus_lane), rowy(focus_idx + off), T('graph.wip-node'), sw=1.5, dash='2 3')
    S.close_group()
    # nodes + text
    for i, c in enumerate(C):
        r = i + off
        cy = rowy(r)
        if cy > STY:
            break
        sha, subj, au, date, lane, parents, refs, ai, wtp = c
        x = lane_x(lane)
        ring = T('graph.node-ring')
        sel = selected == i
        if sel:
            ring = T('surface.selection')
        if len(parents) > 1:
            S.circle(x, cy, 3 + 2, fill=ring)
            S.circle(x, cy, 3.25, fill=ring, stroke=T.lane(lane), sw=1.5)
        else:
            S.circle(x, cy, 4 + 2, fill=ring)
            S.circle(x, cy, 4, fill=T.lane(lane))
        if i == focus_idx:
            S.circle(x, cy, 7.5, stroke=T('graph.head-ring'), sw=2)
        op = .4 if (dim_non_ai and not ai and not sel) else 1
        pc = T('text.on-selection') if sel else T('text.primary')
        sc = T('text.on-selection') if sel else T('text.secondary')
        S.open_group(op=op)
        S.text(CX0 + 80, cy + 4, sha, size=11, fill=sc, mono=True)
        # right side: author + date
        S.text(CX1 - 16, cy + 4, date, size=12, fill=sc, anchor='end')
        avatar(S, T, CX1 - 140, cy, au, d=16, on_sel=sel)
        S.text(CX1 - 128, cy + 4, AUTHORS[au][0], size=12, fill=sc)
        # subject + badges + pills
        sx = CX0 + 144
        right = CX1 - 156
        items = []
        if ai:
            items.append(('ai', None, False, False))
        if wtp:
            items.append(('wt', wtp, False, False))
        names = [nm for k, nm in refs]
        for k, nm in refs:
            if k == 'remote' and nm.split('/', 1)[1] in names:
                continue
            remote_too = k == 'local' and ('origin/' + nm) in names
            tree = k == 'local' and nm in CHECKED_OUT and nm != focus_branch
            items.append((k, nm, tree, remote_too))
        widths = [34 if it[0] == 'ai' else pill_w(it[0], it[1], 170, it[2], it[3])[0] for it in items]
        need = sum(widths) + 6 * len(widths)
        subj_room = max(right - sx - need - (8 if items else 0), 150)
        t = fit(subj, 13, subj_room, 500 if i == focus_idx else 400)
        w = S.text(sx, cy + 4.5, t, size=13, fill=pc, weight=500 if i == focus_idx else 400)
        px = sx + w + 8
        for (k, nm, tree, rt), pw in zip(items, widths):
            if px + 30 > right:
                break
            if k == 'ai':
                ai_badge(S, T, px, cy, on_sel=sel)
                px += 34 + 6
            else:
                px += pill(S, T, px, cy, k, nm, lane=lane, on_sel=sel, maxw=min(170, right - px), tree=tree, remote_too=rt) + 6
        S.close_group()
    if wip:
        cy = rowy(0)
        x = lane_x(focus_lane)
        sel = selected == 'wip'
        S.circle(x, cy, 6, fill=T('surface.selection') if sel else T('surface.content'))
        S.circle(x, cy, 4.5, stroke=T('text.on-selection') if sel else T('graph.wip-node'), sw=1.5, dash='2 2')
        pc = T('text.on-selection') if sel else T('text.primary')
        sc = T('text.on-selection') if sel else T('text.secondary')
        tx = CX0 + 80
        tx += S.text(tx, cy + 4.5, 'WIP', size=13, fill=pc, weight=700) + 12
        first = True
        for kind, num in wip:
            if not first:
                tx += S.text(tx, cy + 4, ' · ', size=12, fill=sc)
            first = False
            if kind == 'conflicted':
                c = T('text.on-selection') if sel else T('status.conflicted')
                g_triangle_fill(S, tx + 6, cy, 12, c, T('surface.selection') if sel else knock(T))
                tx += 16
                tx += S.text(tx, cy + 4, f'{num} conflicted', size=12, fill=c, weight=500)
            else:
                tx += S.text(tx, cy + 4, f'{num} {kind}', size=12, fill=sc)
    # pane border to detail
    S.line(CX1 + .5, TB, CX1 + .5, STY, T('border.separator'))


# ------------------------------------------------------------------ detail pane

DX = CX1 + 16
DXR = W - 16


def detail_bg(S, T):
    S.rect(CX1 + 1, TB, DETW - 1, STY - TB, fill=T('surface.content'))


def d_title(S, T, y, text, mono_prefix=None):
    x = DX
    if mono_prefix:
        x += S.text(x, y, mono_prefix, size=13, fill=T('text.secondary'), mono=True) + 8
    S.text(x, y, fit(text, 15, DXR - x, 600), size=15, fill=T('text.primary'), weight=600)


def d_section(S, T, y, glyph_kind, label, add=None, rem=None):
    x = DX
    if glyph_kind:
        status_glyph(S, T, glyph_kind, x + 6, y - 4, 12)
        x += 18
    S.text(x, y, label, size=11, fill=T('text.secondary'), weight=700, ls='.3')
    if add is not None:
        stat(S, T, DXR, y, add, rem)


def d_file(S, T, y, kind, letter, path, add=None, rem=None, sel=False, note=None):
    """File row 22px tall, y = row top."""
    if sel:
        S.rect(CX1 + 8, y, DETW - 16, 22, fill=T('surface.selection'), r=6)
    cy = y + 11
    x = DX
    if kind:
        status_glyph(S, T, kind, x + 6, cy, 12, on_sel=sel)
        x += 18
    S.text(x, cy + 4, letter, size=11, fill=T('text.on-selection') if sel else T('text.secondary'), mono=True)
    x += 16
    right = DXR
    if add is not None:
        right -= tw(f'+{add} −{rem}', 11, 500, True) + 12
    if note:
        nw = tw(note, 10) + 12
        S.rect(right - nw, cy - 7.5, nw, 15, r=4, stroke=T('text.on-selection') if sel else T('text.secondary'), sw=1, op=.6)
        S.text(right - nw / 2, cy + 3.5, note, size=10, fill=T('text.on-selection') if sel else T('text.secondary'), anchor='middle')
        right -= nw + 8
    path_text(S, T, x, cy + 4.5, path, right - x, fs=13, on_sel=sel)
    if add is not None:
        stat(S, T, DXR, cy + 4, add, rem, on_sel=sel)


def d_kv(S, T, y, key, val, kx=None, mono=False, col=None):
    S.text(DX, y, key, size=12, fill=T('text.secondary'))
    S.text(DX + 84 if kx is None else kx, y, val, size=12 if not mono else 11, fill=col or T('text.primary'), mono=mono)


# ------------------------------------------------------------------ screens

def s01(mode):
    T = Theme(mode)
    S = window(T, f'Overgrove S-01 main window mockup ({mode})')
    sidebar(S, T, focus='feat42', selected='wt:feat42')
    toolbar(S, T, 'feat/42-rate-limit')
    author_chips(S, T, 'all')
    graph(S, T, focus_lane=1, focus_idx=0, wip=[('staged', 2), ('unstaged', 3), ('untracked', 2)], selected='wip')
    detail_bg(S, T)
    wip_detail(S, T, 'feat/42-rate-limit', '~/dev/api-wt/42-rate-limit', [
        ('staged', 'STAGED', 64, 31, [('A', 'internal/ratelimit/window.go', None), ('R', 'internal/http/{noop.go → passthrough.go}', None)]),
        ('unstaged', 'UNSTAGED', 5, 42, [('M', 'internal/http/middleware.go', None), ('M', 'cmd/api/main.go', None), ('D', 'internal/http/noop_limiter.go', None)]),
        ('untracked', 'UNTRACKED', None, None, [('?', 'docs/rate-limit.md', None), ('?', 'internal/ratelimit/bench_test.go', None)]),
    ])
    statusbar(S, T)
    return finish(S, T)


def wip_detail(S, T, branch, path, groups, sel_file=None):
    y = TB + 32
    d_title(S, T, y, f'WIP — {branch}')
    y += 16
    segmented(S, T, DX, y, ['Changes', 'Worktree'], 0)
    y += 24 + 20
    S.text(DX, y, path, size=11, fill=T('text.secondary'), mono=True)
    y += 16
    for kind, label, a, r, files in groups:
        y += 24
        d_section(S, T, y, kind, f'{label} ({len(files)})', a, r)
        y += 8
        for letter, p, note in files:
            d_file(S, T, y, kind, letter, p, sel=(sel_file == (label, p)), note=note)
            y += 22
    return y


def s02(mode):
    T = Theme(mode)
    S = window(T, f'Overgrove S-02 WIP detail mockup ({mode})')
    sidebar(S, T, focus='refactor', selected='wt:refactor')
    toolbar(S, T, 'agent/refactor-logging')
    author_chips(S, T, 'all')
    graph(S, T, focus_branch='agent/refactor-logging', focus_lane=3, focus_idx=3, wip=[('conflicted', 1), ('staged', 3), ('unstaged', 2), ('untracked', 1)], selected='wip')
    detail_bg(S, T)
    wip_detail(S, T, 'agent/refactor-logging', '~/dev/api-wt/refactor-logging', [
        ('conflicted', 'CONFLICTED', None, None, [('U', 'internal/http/middleware.go', None)]),
        ('staged', 'STAGED', 64, 21, [('M', 'internal/log/logger.go', None), ('A', 'internal/log/requestid.go', None), ('R', 'internal/log/{format.go → encoder.go}', None)]),
        ('unstaged', 'UNSTAGED', 11, 3, [('M', 'internal/log/logger.go', None), ('M', 'cmd/api/main.go', None)]),
        ('untracked', 'UNTRACKED', None, None, [('?', 'notes/agent-plan.md', None)]),
    ])
    statusbar(S, T, ab=None)
    return finish(S, T)


def commit_detail(S, T, idx, sel_file=None):
    sha, subj, au, date, lane, parents, refs, ai, wtp = C[idx]
    y = TB + 32
    sw_ = S.text(DX, y, sha, size=13, fill=T('text.secondary'), mono=True) + 8
    words, line, lines = subj.split(), '', []
    for wd in words:
        t = (line + ' ' + wd).strip()
        if tw(t, 15, 600) > DXR - DX - sw_ and line:
            lines.append(line)
            line = wd
        else:
            line = t
    lines.append(line)
    for i, ln in enumerate(lines[:2]):
        S.text(DX + sw_, y + i * 20, ln, size=15, fill=T('text.primary'), weight=600)
    y += 20 * (min(len(lines), 2) - 1) + 28
    # Author
    S.text(DX, y, 'Author', size=12, fill=T('text.secondary'))
    avatar(S, T, DX + 92, y - 4, au, d=16)
    nm, em = AUTHORS[au]
    w = S.text(DX + 106, y, nm, size=12, fill=T('text.primary'))
    S.text(DX + 106 + w + 6, y, f'<{em}>', size=12, fill=T('text.secondary'))
    y += 24
    if ai:
        S.text(DX, y, 'Co-author', size=12, fill=T('text.secondary'))
        ai_avatar(S, T, DX + 92, y - 4)
        w = S.text(DX + 106, y, AI_COAUTHOR[0], size=12, fill=T('text.primary'))
        ai_badge(S, T, DX + 106 + w + 8, y - 4)
        y += 24
    d_kv(S, T, y, 'Date', '2026-11-06 09:41 (+09:00)')
    y += 24
    S.text(DX, y, 'Parents', size=12, fill=T('text.secondary'))
    S.text(DX + 84, y, ', '.join(C[p][0] for p in parents), size=11, fill=T('text.link'), mono=True)
    y += 24
    S.text(DX, y, 'Refs', size=12, fill=T('text.secondary'))
    px = DX + 84
    names = [nm for k, nm in refs]
    for k, nmr in refs:
        if k == 'remote' and nmr.split('/', 1)[1] in names:
            continue
        rt = k == 'local' and ('origin/' + nmr) in names
        px += pill(S, T, px, y - 4, k, nmr, lane=lane, maxw=DXR - px, remote_too=rt) + 6
    y += 24
    S.text(DX, y, 'Issues', size=12, fill=T('text.secondary'))
    w = S.text(DX + 84, y, '#42', size=12, fill=T('text.link'))
    S.text(DX + 84 + w + 6, y, 'Rate limit per tenant', size=12, fill=T('text.primary'))
    y += 16
    S.line(CX1 + 16, y, W - 16, y, T('border.separator'))
    y += 24
    body = ['Use a sliding window counter per tenant key. Reject', 'with 429 and Retry-After once the window is full.', '',
            'Refs: #42']
    for ln in body:
        if ln:
            S.text(DX, y, ln, size=13, fill=T('text.primary'))
        y += 18
    if ai:
        S.text(DX, y, f'Co-Authored-By: {AI_COAUTHOR[0]} <{AI_COAUTHOR[1]}>', size=12, fill=T('text.secondary'))
        y += 18
    y += 2
    S.line(CX1 + 16, y, W - 16, y, T('border.separator'))
    y += 28
    files = [('A', 'internal/ratelimit/limiter.go', 112, 0), ('M', 'internal/http/middleware.go', 38, 4), ('A', 'internal/ratelimit/limiter_test.go', 27, 0),
             ('M', 'cmd/api/main.go', 6, 2), ('M', 'go.mod', 3, 6)]
    d_section(S, T, y, None, f'FILES ({len(files)})', sum(f[2] for f in files), sum(f[3] for f in files))
    y += 8
    for letter, p, a, r in files:
        d_file(S, T, y, None, letter, p, a, r, sel=(sel_file == p))
        y += 22
    return y


def s03(mode):
    T = Theme(mode)
    S = window(T, f'Overgrove S-03 commit detail mockup ({mode})')
    sidebar(S, T, focus='feat42', selected=None)
    toolbar(S, T, 'feat/42-rate-limit')
    author_chips(S, T, 'ai')
    graph(S, T, focus_lane=1, focus_idx=0, wip=[('staged', 2), ('unstaged', 3), ('untracked', 2)], selected=0, dim_non_ai=True)
    detail_bg(S, T)
    commit_detail(S, T, 0)
    statusbar(S, T)
    return finish(S, T)


def s05(mode):
    T = Theme(mode)
    S = window(T, f'Overgrove S-05 worktree detail mockup ({mode})')
    sidebar(S, T, focus='fix57', selected='wt:fix57')
    toolbar(S, T, 'fix/57-token-refresh')
    author_chips(S, T, 'all')
    graph(S, T, focus_branch='fix/57-token-refresh', focus_lane=2, focus_idx=2, wip=[('staged', 1), ('unstaged', 2)], selected=None)
    detail_bg(S, T)
    y = TB + 32
    d_title(S, T, y, 'Worktree — fix/57-token-refresh')
    y += 16
    segmented(S, T, DX, y, ['Changes', 'Worktree'], 1)
    y += 24 + 28
    kx = DX + 84
    S.text(DX, y, 'Path', size=12, fill=T('text.secondary'))
    S.text(kx, y, '~/dev/api-wt/57-token-refresh', size=11, fill=T('text.primary'), mono=True)
    g_copy(S, DXR - 6, y - 4, 12, T('text.secondary'))
    y += 24
    S.text(DX, y, 'HEAD', size=12, fill=T('text.secondary'))
    w = S.text(kx, y, 'e4b9a07', size=11, fill=T('text.link'), mono=True)
    S.text(kx + w + 8, y, fit('fix(auth): refresh token before expiry', 12, DXR - kx - w - 8), size=12, fill=T('text.primary'))
    y += 24
    d_kv(S, T, y, 'Branch', 'fix/57-token-refresh')
    y += 24
    S.text(DX, y, 'Upstream', size=12, fill=T('text.secondary'))
    w = S.text(kx, y, 'origin/fix/57-token-refresh', size=12, fill=T('text.primary'))
    x = kx + w + 10
    g_arrow(S, x + 4, y - 4, 10, T('status.ahead'), up=True)
    x += 10 + S.text(x + 10, y, '1', size=12, fill=T('status.ahead'), weight=500) + 6
    g_arrow(S, x + 4 + 6, y - 4, 10, T('status.behind'), up=False)
    S.text(x + 16, y, '0', size=12, fill=T('status.behind'), weight=500)
    y += 24
    d_kv(S, T, y, 'State', '3 changed · no untracked · no conflicts')
    y += 24
    d_kv(S, T, y, 'Lock', 'Not locked')
    y += 24
    d_kv(S, T, y, 'Last fetch', '2 min ago (repository)')
    y += 24
    S.text(DX, y, 'Base', size=12, fill=T('text.secondary'))
    w = S.text(kx, y, 'main', size=12, fill=T('text.primary'))
    S.text(kx + w + 8, y, '1 commit ahead · 4 files', size=12, fill=T('text.secondary'))
    y += 16
    button(S, T, kx, y, 176, 'Compare with Base…', h=24, glyph=g_plusminus, fs=12)
    S.text(kx + 186, y + 16, '⌘⇧B', size=11, fill=T('text.secondary'))
    y += 24 + 20
    S.line(CX1 + 16, y, W - 16, y, T('border.separator'))
    y += 28
    S.text(DX, y, 'SECURITY', size=11, fill=T('text.secondary'), weight=700, ls='.3')
    y += 10
    items = [(True, 'Hooks disabled'), (True, 'fsmonitor disabled'), (True, 'External diff and textconv disabled'),
             (True, 'Remote URL credentials masked')]
    for ok, label in items:
        cy = y + 12
        g_shield(S, DX + 7, cy, 14, T('status.ok'), ok=True)
        S.text(DX + 22, cy + 4.5, label, size=13, fill=T('text.primary'))
        y += 24
    # warning, expanded
    cy = y + 12
    S.rect(CX1 + 8, y, DETW - 16, 24 + 44 + 48, fill=T('status.warning'), r=6, op=.10)
    g_shield(S, DX + 7, cy, 14, T('status.warning'), ok=False)
    S.text(DX + 22, cy + 4.5, 'Repository config overrides neutralized (2)', size=13, fill=T('text.primary'))
    g_chevron(S, DXR - 6, cy, 10, T('text.secondary'), 'down')
    y += 24
    for key in ('filter.lfs.process', 'core.sshCommand'):
        S.text(DX + 22, y + 15, key, size=11, fill=T('text.primary'), mono=True)
        y += 22
    y += 8
    S.text(DX + 22, y + 12, 'Values are never shown. These keys are overridden', size=11, fill=T('text.secondary'))
    S.text(DX + 22, y + 26, 'for every git command Overgrove runs here.', size=11, fill=T('text.secondary'))
    statusbar(S, T, ab=(1, 0))
    return finish(S, T)


GO_DIFF = [
    ('h', '@@ -8,11 +8,24 @@ import ('),
    (' ', 8, 8, '    "net/http"'),
    (' ', 9, 9, '    "strconv"'),
    (' ', 10, 10, '    "time"'),
    ('-', 11, None, ''),
    ('+', None, 11, '    "github.com/acme/api/internal/ratelimit"'),
    (' ', 12, 12, ')'),
    (' ', 13, 13, ''),
    ('-', 14, None, '// RateLimit is a placeholder that allows every request.'),
    ('-', 15, None, 'func RateLimit(next http.Handler) http.Handler {'),
    ('-', 16, None, '    return next'),
    ('+', None, 14, "// RateLimit rejects requests over the tenant's window with 429."),
    ('+', None, 15, 'func RateLimit(l *ratelimit.Limiter, next http.Handler) http.Handler {'),
    ('+', None, 16, '    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {'),
    ('+', None, 17, '        key := TenantFrom(r.Context())'),
    ('+', None, 18, '        ok, retry := l.Allow(key, time.Now())'),
    ('+', None, 19, '        if !ok {'),
    ('+', None, 20, '            w.Header().Set("Retry-After", strconv.Itoa(int(retry.Seconds())))'),
    ('+', None, 21, '            http.Error(w, "rate limit exceeded", http.StatusTooManyRequests)'),
    ('+', None, 22, '            return'),
    ('+', None, 23, '        }'),
    ('+', None, 24, '        next.ServeHTTP(w, r)'),
    ('+', None, 25, '    })'),
    (' ', 17, 26, '}'),
    ('h', '@@ -40,6 +49,9 @@ func Chain(h http.Handler, m ...Middleware) http.Handler {'),
    (' ', 40, 49, '    for i := len(m) - 1; i >= 0; i-- {'),
    (' ', 41, 50, '        h = m[i](h)'),
    (' ', 42, 51, '    }'),
    ('+', None, 52, '    // Rate limiting runs after auth so the tenant is known.'),
    ('+', None, 53, '    h = RateLimit(defaultLimiter, h)'),
    ('+', None, 54, ''),
    (' ', 43, 55, '    return h'),
    (' ', 44, 56, '}'),
]


def diff_body(S, T, y0, lines, x0=CX0, x1=CX1, lh=20):
    S.rect(x0, y0, x1 - x0, STY - y0, fill=T('surface.content'))
    S.clip('diffclip', x0, y0, x1 - x0, STY - y0)
    S.open_group(clip='diffclip')
    y = y0
    gut = x0 + 92
    for ln in lines:
        if y > STY:
            break
        if ln[0] == 'h':
            S.rect(x0, y, x1 - x0, lh, fill=T('diff.hunk-header-bg'))
            S.text(x0 + 16, y + 14, ln[1], size=11, fill=T('text.secondary'), mono=True)
        else:
            k, o, n, code = ln
            if k == '+':
                S.rect(x0, y, x1 - x0, lh, fill=T('diff.added-bg'))
            elif k == '-':
                S.rect(x0, y, x1 - x0, lh, fill=T('diff.removed-bg'))
            if o is not None:
                S.text(x0 + 36, y + 14, str(o), size=11, fill=T('text.secondary'), mono=True, anchor='end')
            if n is not None:
                S.text(x0 + 72, y + 14, str(n), size=11, fill=T('text.secondary'), mono=True, anchor='end')
            if k == '+':
                S.text(x0 + 82, y + 14, '+', size=12, fill=T('diff.gutter-added'), mono=True, weight=700, anchor='middle')
            elif k == '-':
                S.text(x0 + 82, y + 14, '−', size=12, fill=T('diff.gutter-removed'), mono=True, weight=700, anchor='middle')
            S.text(gut + 8, y + 14, code, size=12, fill=T('text.primary'), mono=True)
        y += lh
    S.close_group()
    S.line(gut - .5, y0, gut - .5, min(y, STY), T('border.separator'))


def back_button(S, T, x, cy):
    w = 72
    S.rect(x, cy - 12, w, 24, fill=T('surface.control'), r=6, stroke=T('border.separator'))
    g_chevron(S, x + 13, cy, 10, T('text.primary'), 'left')
    S.text(x + 24, cy + 4.5, 'Graph', size=12, fill=T('text.primary'))
    return w


def s10(mode):
    T = Theme(mode)
    S = window(T, f'Overgrove S-10 diff viewer mockup ({mode})')
    sidebar(S, T, focus='feat42', selected=None)
    toolbar(S, T, 'feat/42-rate-limit')
    # header
    S.rect(CX0, TB, CX1 - CX0, 40, fill=T('surface.content'))
    S.line(CX0, TB + 39.5, CX1, TB + 39.5, T('border.separator'))
    cy = TB + 20
    x = CX0 + 16
    x += back_button(S, T, x, cy) + 12
    w = path_text(S, T, x, cy + 4.5, 'internal/http/middleware.go', 260, fs=12, mono=True)
    x += w + 12
    S.text(x, cy + 4, 'a91f3c2 · Modified · +38 −4', size=11, fill=T('text.secondary'))
    segw = tw('Unified', 12, 500) + tw('Split', 12, 500) + 48 + 4
    segmented(S, T, CX1 - 16 - segw, cy - 12, ['Unified', 'Split'], 0)
    diff_body(S, T, TB + 40, GO_DIFF)
    S.line(CX1 + .5, TB, CX1 + .5, STY, T('border.separator'))
    detail_bg(S, T)
    commit_detail(S, T, 0, sel_file='internal/http/middleware.go')
    statusbar(S, T)
    return finish(S, T)


def s11(mode):
    T = Theme(mode)
    S = window(T, f'Overgrove S-11 changes vs base branch mockup ({mode})')
    sidebar(S, T, focus='feat42', selected='wt:feat42', delta=8)
    toolbar(S, T, 'feat/42-rate-limit')
    # header row 1: back, title, base selector, toggle
    S.rect(CX0, TB, CX1 - CX0, 72, fill=T('surface.content'))
    cy = TB + 20
    x = CX0 + 16
    x += back_button(S, T, x, cy) + 16
    x += S.text(x, cy + 5, 'Changes vs', size=15, fill=T('text.primary'), weight=600) + 8
    # base popup
    bw = tw('main', 13) + 40
    S.rect(x, cy - 12, bw, 24, fill=T('surface.control'), r=6, stroke=T('border.separator'))
    g_branch(S, x + 12, cy, 11, T('text.secondary'))
    S.text(x + 22, cy + 4.5, 'main', size=13, fill=T('text.primary'), weight=500)
    g_updown(S, x + bw - 10, cy, 10, T('text.secondary'))
    x += bw + 16
    # toggle right aligned
    tl = 'Include uncommitted'
    tx = CX1 - 16 - 26
    toggle(S, T, tx, cy, on=True)
    S.text(tx - 8, cy + 4.5, tl, size=12, fill=T('text.primary'), anchor='end')
    # row 2 summary
    cy2 = TB + 52
    x = CX0 + 16
    parts = [('2 commits ahead', T('text.primary'), 500), (' · ', T('text.secondary'), 400), ('0 behind', T('text.secondary'), 400),
             (' · ', T('text.secondary'), 400), ('uncommitted: 5 files', T('text.secondary'), 400), (' · ', T('text.secondary'), 400),
             ('8 files', T('text.primary'), 500), (' · ', T('text.secondary'), 400)]
    for s, c, wgt in parts:
        x += S.text(x, cy2 + 4, s, size=12, fill=c, weight=wgt)
    x += S.text(x, cy2 + 4, '+272', size=12, fill=T('diff.gutter-added'), weight=500, mono=True) + 6
    x += S.text(x, cy2 + 4, '−85', size=12, fill=T('diff.gutter-removed'), weight=500, mono=True)
    S.text(CX1 - 16, cy2 + 4, 'merge base 3c5d6f1', size=11, fill=T('text.secondary'), mono=True, anchor='end')
    S.line(CX0, TB + 71.5, CX1, TB + 71.5, T('border.separator'))
    # file header
    fy = TB + 72
    S.rect(CX0, fy, CX1 - CX0, 32, fill=T('surface.window'))
    S.line(CX0, fy + 31.5, CX1, fy + 31.5, T('border.separator'))
    w = path_text(S, T, CX0 + 16, fy + 20.5, 'internal/http/middleware.go', 300, fs=12, mono=True)
    S.text(CX0 + 16 + w + 12, fy + 20, 'Modified · 1 commit + uncommitted · +40 −4', size=11, fill=T('text.secondary'))
    diff_body(S, T, fy + 32, GO_DIFF)
    S.line(CX1 + .5, TB, CX1 + .5, STY, T('border.separator'))
    # detail pane: commits ahead, files, untracked
    detail_bg(S, T)
    y = TB + 32
    d_title(S, T, y, 'feat/42-rate-limit')
    y += 18
    S.text(DX, y, 'compared with main, including uncommitted changes', size=11, fill=T('text.secondary'))
    y += 32
    S.text(DX, y, 'COMMITS AHEAD (2)', size=11, fill=T('text.secondary'), weight=700, ls='.3')
    y += 8
    commits = [(None, 'Uncommitted changes', None, False), ('a91f3c2', 'feat(ratelimit): add sliding window limiter', 'AK', True),
               ('7d20e18', 'test(ratelimit): cover burst and refill cases', 'AK', True)]
    for sha, subj, au, ai in commits:
        cy = y + 11
        if sha is None:
            S.circle(DX + 8, cy, 5, stroke=T('graph.wip-node'), sw=1.5, dash='2 2')
            S.text(DX + 22, cy + 4.5, subj, size=13, fill=T('text.primary'), weight=500)
            S.text(DXR, cy + 4, '5 files', size=11, fill=T('text.secondary'), anchor='end')
        else:
            avatar(S, T, DX + 8, cy, au, d=16)
            w = S.text(DX + 22, cy + 4, sha, size=11, fill=T('text.secondary'), mono=True)
            right = DXR - (40 if ai else 0)
            S.text(DX + 22 + w + 8, cy + 4.5, fit(subj, 12, right - (DX + 30 + w)), size=12, fill=T('text.primary'))
            if ai:
                ai_badge(S, T, DXR - 34, cy)
        y += 22
    y += 26
    files = [('M', 'internal/http/middleware.go', 40, 4, 'unstaged', True), ('A', 'internal/ratelimit/limiter.go', 112, 0, None, False),
             ('A', 'internal/ratelimit/window.go', 58, 0, 'staged', False), ('A', 'internal/ratelimit/limiter_test.go', 44, 0, None, False),
             ('R', 'internal/http/{noop.go → passthrough.go}', 6, 31, 'staged', False), ('M', 'cmd/api/main.go', 9, 3, 'unstaged', False),
             ('D', 'internal/http/noop_limiter.go', 0, 41, 'unstaged', False), ('M', 'go.mod', 3, 6, None, False)]
    d_section(S, T, y, None, f'FILES CHANGED ({len(files)})', sum(f[2] for f in files), sum(f[3] for f in files))
    y += 8
    for letter, p, a, r, wc, sel in files:
        d_file(S, T, y, None, letter, p, a, r, sel=sel, note='WIP' if wc else None)
        y += 22
    y += 26
    d_section(S, T, y, 'untracked', 'UNTRACKED (2)')
    y += 8
    for p in ('docs/rate-limit.md', 'internal/ratelimit/bench_test.go'):
        d_file(S, T, y, 'untracked', '?', p)
        y += 22
    statusbar(S, T)
    return finish(S, T)


MARK = open(f'{REPO}/design/icon/mark.svg').read()


def mark_svg(x, y, size):
    inner = MARK.split('>', 1)[1].rsplit('</svg>', 1)[0]
    inner = re.sub(r'<title>.*?</title>', '', inner)
    h = size * 600 / 640
    return f'<svg x="{x}" y="{y}" width="{size}" height="{h:.1f}" viewBox="190 262 640 600">{inner}</svg>'


def s07(mode):
    T = Theme(mode)
    S = window(T, f'Overgrove S-07 onboarding mockup ({mode})')
    traffic(S, T)
    S.text(W / 2, 30.5, 'Overgrove Setup', size=13, fill=T('text.secondary'), weight=700, anchor='middle')
    S.line(0, TB - .5, W, TB - .5, T('border.separator'))
    S.add(mark_svg(W / 2 - 36, 100, 72))
    S.text(W / 2, 212, 'Welcome to Overgrove', size=26, fill=T('text.primary'), weight=700, anchor='middle')
    S.text(W / 2, 238, 'See every worktree of a repository at a glance. Read-only — the only network action is git fetch.',
           size=13, fill=T('text.secondary'), anchor='middle')
    cx0, cx1 = 280, 1000
    lx = cx0 + 64       # content column inside cards

    def card(y, h, num, title, state):
        S.rect(cx0, y, cx1 - cx0, h, fill=T('surface.content'), r=10, stroke=T('border.separator'))
        c = {'ok': T('status.ok'), 'warn': T('status.warning'), 'todo': T('text.secondary')}[state]
        if state == 'ok':
            S.circle(cx0 + 32, y + 28, 12, fill=c)
            g_check(S, cx0 + 32, y + 28, 12, T('surface.content'))
        else:
            S.circle(cx0 + 32, y + 28, 11.25, stroke=c, sw=1.5)
            S.text(cx0 + 32, y + 32.5, str(num), size=13, fill=c, weight=700, anchor='middle')
        S.text(lx, y + 33, title, size=13, fill=T('text.primary'), weight=700)

    y = 272
    card(y, 96, 1, 'Add a repository', 'ok')
    button(S, T, cx1 - 24 - 140, y + 16, 140, 'Choose Folder…', h=24, fs=12)
    g_check_circle(S, lx + 6, y + 56, 13, T('status.ok'))
    S.text(lx + 20, y + 60.5, '~/dev/api', size=12, fill=T('text.primary'), mono=True)
    S.text(lx + 20 + tw('~/dev/api', 12, mono=True) + 10, y + 60.5, 'Git repository · 6 worktrees', size=12, fill=T('text.secondary'))
    S.text(lx, y + 80, 'Only folders you choose here are ever read.', size=12, fill=T('text.secondary'))

    y += 96 + 16
    card(y, 72, 2, 'git', 'ok')
    g_check_circle(S, lx + 6, y + 52, 13, T('status.ok'))
    w = S.text(lx + 20, y + 56.5, 'git 2.50.1 (Apple Git-155)', size=12, fill=T('text.primary'))
    S.text(lx + 20 + w + 8, y + 56.5, 'at /usr/bin/git', size=12, fill=T('text.secondary'))

    y += 72 + 16
    card(y, 200, 3, 'GitHub', 'warn')
    S.text(lx + tw('GitHub', 13, 700) + 8, y + 33, '(optional — used only to show issues)', size=12, fill=T('text.secondary'))
    S.text(cx1 - 24, y + 33, 'Skip', size=12, fill=T('text.link'), anchor='end')
    g_person_badge(S, lx + 7, y + 56, 14, T('status.warning'), ok=False, badge_c=T('status.warning'), knock=T('surface.content'))
    S.text(lx + 22, y + 60.5, 'Not logged in to GitHub CLI', size=12, fill=T('status.warning'), weight=500)
    S.text(lx, y + 88, 'Run this in Terminal, then check again:', size=12, fill=T('text.primary'))
    S.rect(lx, y + 100, 240, 32, fill=T('surface.window'), r=6, stroke=T('border.separator'))
    S.text(lx + 12, y + 121, 'gh auth login', size=12, fill=T('text.primary'), mono=True)
    button(S, T, lx + 248, y + 104, 80, 'Copy', h=24, glyph=g_copy, fs=12)
    button(S, T, lx, y + 148, 112, 'Check Again', h=24, fs=12)
    g_lock(S, lx + 128, y + 160, 11, T('text.secondary'))
    S.text(lx + 140, y + 164, 'Overgrove never asks for or stores tokens. Authentication stays with gh.', size=12, fill=T('text.secondary'))

    y += 200 + 24
    S.text(cx0, y + 18, 'Reopen anytime from Help › Setup Assistant.', size=12, fill=T('text.secondary'))
    button(S, T, cx1 - 152, y + 2, 152, 'Open Repository', h=28, primary=True)
    return finish(S, T)


SCREENS = {
    'main-window': s01,
    's02-wip-detail': s02,
    's03-commit-detail': s03,
    's05-worktree-detail': s05,
    's10-diff-viewer': s10,
    's11-changes-vs-base': s11,
    's07-onboarding': s07,
}

if __name__ == '__main__':
    out = sys.argv[1]
    only = sys.argv[2:] or list(SCREENS)
    for name in only:
        for mode in ('light', 'dark'):
            open(f'{out}/{name}-{mode}.svg', 'w').write(SCREENS[name](mode))
            print('wrote', name, mode)
