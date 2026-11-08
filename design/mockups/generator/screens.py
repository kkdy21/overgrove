"""Overgrove high-fidelity mockups — panel theme (#166). Run ./render.sh (needs mkfonts.py fonts)."""
import sys
from lib import *

W, H = 1440, 900
TB = 52              # toolbar
SBH = 30             # status bar
G = 8                # gutter between and around panels (splitter hit area)
LW, RW = 256, 344    # sidebar and detail panel widths
PT, PB = TB, H - SBH
LX0, LX1 = G, G + LW
RX0, RX1 = W - G - RW, W - G
CX0, CX1 = LX1 + G, RX0 - G
PH = 40              # panel header
CH = 28              # graph column header
ROW = 30             # graph row
PR = 10              # panel radius
LANE = 20            # lane spacing

AUTHORS = {
    'MP': ('Mina Park', 'mina@example.com'),
    'AK': ('Alex Kim', 'alex@example.com'),
    'JL': ('Jordan Lee', 'jordan@example.com'),
    'SR': ('Sam Rivera', 'sam@example.com'),
}
AI_COAUTHOR = ('Coding Agent', 'agent@example.com')
# branch -> worktree folder for branches checked out in a worktree
CHECKED_OUT = {'main': 'api', 'agent/refactor-logging': 'agent-logging', 'feat/42-rate-limit': '42-rate-limit',
               'fix/57-token-refresh': '57-token-refresh'}

# sha, subject, author, date, lane, parents (row indices), refs, ai, detached-worktree folder
C = [
    ('a91f3c2', 'feat(ratelimit): add sliding window limiter', 'AK', '2h', 1, [1], [('local', 'feat/42-rate-limit'), ('remote', 'origin/feat/42-rate-limit')], True, None),
    ('7d20e18', 'test(ratelimit): cover burst and refill cases', 'AK', '3h', 1, [4], [], True, None),
    ('e4b9a07', 'fix(auth): refresh token before expiry', 'MP', '5h', 2, [4], [('local', 'fix/57-token-refresh')], False, None),
    ('0f6a9d3', 'refactor(log): structured logger with request id', 'AK', '6h', 3, [7], [('local', 'agent/refactor-logging')], True, None),
    ('3c5d6f1', 'Merge pull request #51 from acme/feat/48-metrics', 'JL', '1d', 0, [6, 5], [('local', 'main'), ('remote', 'origin/main')], False, None),
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

# worktrees: key, branch (or None), folder, path, lane, badges, flags
WORKTREES = [
    ('main', 'main', 'api', '~/dev/api', 0, {}, {'main': True}),
    ('agent', 'agent/refactor-logging', 'agent-logging', '~/dev/api-wt/agent-logging', 3, {'conflicts': 1, 'changes': 6}, {}),
    ('feat42', 'feat/42-rate-limit', '42-rate-limit', '~/dev/api-wt/42-rate-limit', 1, {'changes': 7, 'ahead': 2}, {}),
    ('fix57', 'fix/57-token-refresh', '57-token-refresh', '~/dev/api-wt/57-token-refresh', 2, {'changes': 3, 'ahead': 1}, {}),
    ('review', None, 'review-51', '~/dev/api-wt/review-51', 1, {'locked': True}, {'detached': 'b2e8a44'}),
    ('spike', 'spike/grpc', 'grpc-spike', '~/dev/api-wt/grpc-spike', 5, {'prunable': True}, {'prunable': True}),
]


# ---------------------------------------------------------------- small helpers

def av_idx(code):
    return fnv1a(AUTHORS[code][1]) % 8


def avatar(S, T, cx, cy, code, d=16, ring=None, ring_w=0):
    r = d / 2
    S.circle(cx, cy, r, fill=T.avatar(av_idx(code)))
    S.text(cx, cy + d * .17, code, size=d * .46, fill=T('avatar.initials'), weight=700, anchor='middle')
    if ring:
        S.circle(cx, cy, r + ring_w / 2, stroke=ring, sw=ring_w)


def chip_count(S, T, xr, cy, n, sel=False):
    s = str(n)
    w = max(18, tw(s, 10.5, 600) + 10)
    S.rect(xr - w, cy - 8, w, 16, fill=T('surface.hover') if not sel else '#ffffff26', r=8)
    S.rect(xr - w, cy - 8, w, 16, fill=('#ffffff0d' if T.mode == 'dark' else '#1a1f2a0d'), r=8)
    S.text(xr - w / 2, cy + 3.6, s, size=10.5, fill=T('text.secondary'), weight=600, anchor='middle')
    return w


def kbd(S, T, xr, cy, label):
    w = tw(label, 10.5, 500) + 10
    S.rect(xr - w + .5, cy - 8.5, w - 1, 17, r=4, stroke=T('border.strong'), fill=T('surface.control') if T.mode == 'light' else None)
    S.text(xr - w / 2, cy + 3.7, label, size=10.5, fill=T('text.secondary'), weight=500, anchor='middle')
    return w


def stat(S, T, xr, cy, add, rem, fs=11):
    """Right-aligned '+a −r'. Returns width."""
    x = xr
    w = 0
    if add == 0 and rem:
        add = None
    if rem == 0 and add:
        rem = None
    if rem is not None:
        s = f'−{rem}'
        ww = tw(s, fs, 500)
        S.text(x - ww, cy + fs * .36, s, size=fs, fill=T('status.conflicted'), weight=500)
        x -= ww + 6
        w += ww + 6
    if add is not None:
        s = f'+{add}'
        ww = tw(s, fs, 500)
        S.text(x - ww, cy + fs * .36, s, size=fs, fill=T('status.staged'), weight=500)
        w += ww
    return w


KIND = {'A': 'status.staged', 'M': 'status.unstaged', 'D': 'status.conflicted', 'R': 'status.ahead', '?': 'status.untracked', 'U': 'status.conflicted'}


ON_STATUS = {'status.staged': 'staged', 'status.unstaged': 'unstaged', 'status.untracked': 'untracked', 'status.conflicted': 'conflicted', 'status.ahead': 'ahead'}


def kind_badge(S, T, x, cy, k):
    c = T(KIND[k])
    S.rect(x, cy - 8, 16, 16, fill=c, r=4)
    S.text(x + 8, cy + 3.6, k, size=10, fill=T('on-status.' + ON_STATUS[KIND[k]]), weight=700, anchor='middle', mono=True)


def path_text(S, T, x, cy, path, maxw, fs=12.5, sel=False):
    """Directory in tertiary, file name in primary. Handles {old → new} renames."""
    if '/' in path and not path.endswith('}'):
        d, f = path.rsplit('/', 1)
        d += '/'
    elif '{' in path:
        d, f = path.split('{', 1)
        f = '{' + f
    else:
        d, f = '', path
    fw = tw(f, fs, 500)
    if fw > maxw:
        S.text(x, cy + fs * .36, fit(f, fs, maxw, 500), size=fs, fill=T('text.primary'), weight=500)
        return
    dw = maxw - fw
    if d:
        dd = d
        if tw(d, fs) > dw:
            parts = d.rstrip('/').split('/')
            dd = ''
            for i in range(len(parts)):
                cand = '…/' + '/'.join(parts[i + 1:]) + ('/' if parts[i + 1:] else '')
                if tw(cand, fs) <= dw:
                    dd = cand
                    break
            if not dd:
                dd = '…/'
        x += S.text(x, cy + fs * .36, dd, size=fs, fill=T('text.secondary' if sel else 'text.tertiary'))
    S.text(x, cy + fs * .36, f, size=fs, fill=T('text.primary'), weight=500)


def status_glyph(S, T, kind, cx, cy, s=13):
    if kind == 'staged':
        g_check_circle_fill(S, cx, cy, s, T('status.staged'), T('surface.raised'))
    elif kind == 'unstaged':
        g_pencil(S, cx, cy, s * .92, T('status.unstaged'))
    elif kind == 'untracked':
        g_question_circle(S, cx, cy, s, T('status.untracked'))
    elif kind == 'conflicted':
        g_triangle_fill(S, cx, cy, s, T('status.conflicted'), T('surface.raised'))


# ---------------------------------------------------------------- window chrome

def window(T, title):
    S = Svg(W, H, title)
    S.clip('win', 0, 0, W, H, 12)
    S.open_group(clip='win')
    S.rect(0, 0, W, H, fill=T('surface.window'))
    return S


def finish(S, T):
    S.close_group()
    S.rect(.5, .5, W - 1, H - 1, r=12, stroke='#ffffff1f' if T.mode == 'dark' else '#00000033')
    return S.render()


def traffic(S, T):
    for i, k in enumerate(('close', 'minimize', 'zoom')):
        S.circle(20 + i * 20, TB / 2, 6, fill=T(f'primitive.color.system-fallback.window-{k}'))
        S.circle(20 + i * 20, TB / 2, 6, stroke='#00000026', sw=.5)


def tb_button(S, T, cx, label, glyph, active=False, badge=None):
    w = 58
    if active:
        S.rect(cx - w / 2, 7, w, 40, r=8, fill=T('surface.hover'))
    c = T('text.primary')
    glyph(S, cx, 21, 17, c)
    S.text(cx, 41, label, size=10.5, fill=T('text.secondary'), weight=500, anchor='middle')
    if badge:
        S.circle(cx + 11, 13, 4, fill=T('accent'))


def toolbar(S, T, focus='feat42', fetching=False):
    traffic(S, T)
    g_sidebar(S, 98, TB / 2, 16, T('text.secondary'))
    # repository switcher
    x = 120
    S.rect(x, 11, 108, 30, r=7, fill=T('surface.control'), stroke=T('border.separator') if T.mode == 'light' else None)
    g_folder(S, x + 16, TB / 2, 14, T('text.secondary'))
    S.text(x + 30, TB / 2 + 4.6, 'api', size=13, fill=T('text.primary'), weight=600)
    S.text(x + 30 + tw('api', 13, 600) + 6, TB / 2 + 4.2, 'acme', size=11.5, fill=T('text.tertiary'))
    g_updown(S, x + 96, TB / 2, 12, T('text.tertiary'))
    g_chevron(S, x + 122, TB / 2, 11, T('text.quaternary'), 'right')
    # focused worktree → branch (click = jump to HEAD)
    wt = next(w for w in WORKTREES if w[0] == focus)
    lane = wt[4]
    name = wt[1] or f"detached @ {wt[6]['detached']}"
    x = 254
    bw = tw(name, 13, 500) + 64 + (24 if wt[5].get('ahead') else 0)
    S.rect(x, 11, bw, 30, r=7, fill=T.lane(lane), op=.14)
    S.rect(x + .5, 11.5, bw - 1, 29, r=7, stroke=T.lane(lane), op=.45)
    tile(S, T, x + 17, TB / 2, lane, 18)
    S.text(x + 32, TB / 2 + 4.6, name, size=13, fill=T('text.primary'), weight=500)
    xx = x + 32 + tw(name, 13, 500) + 8
    if wt[5].get('ahead'):
        g_arrow(S, xx + 4, TB / 2, 10, T('status.ahead'), up=True)
        S.text(xx + 11, TB / 2 + 4.2, str(wt[5]['ahead']), size=11.5, fill=T('text.primary'), weight=600)
        xx += 24
    S.text(x + bw - 24, TB / 2 + 4, '⌘J', size=10.5, fill=T('text.tertiary'), weight=500)
    # actions (centered over the graph panel)
    cx = (CX0 + CX1) / 2
    items = [('Fetch', g_arrow_down_circle), ('Refresh', g_refresh), None, ('Compare', g_plusminus), None,
             ('Terminal', g_terminal), ('Finder', g_finder)]
    n = len([i for i in items if i])
    total = n * 58 + 2 * 17
    x = cx - total / 2
    for it in items:
        if it is None:
            S.line(x + 8.5, 15, x + 8.5, 39, T('border.separator'))
            x += 17
            continue
        tb_button(S, T, x + 29, it[0], it[1], active=(fetching and it[0] == 'Fetch'))
        x += 58
    # search
    sx, sw_ = RX0 + 24, RX1 - RX0 - 24
    S.rect(sx, 11, sw_, 30, r=8, fill=T('surface.control'), stroke=T('border.separator') if T.mode == 'light' else None)
    g_magnifier(S, sx + 16, TB / 2, 13, T('text.tertiary'))
    S.text(sx + 30, TB / 2 + 4.3, 'Search commits, authors, refs, #issues', size=12.5, fill=T('text.quaternary'))
    kbd(S, T, sx + sw_ - 8, TB / 2, '⌘F')
    g_sidebar_right(S, W - 0 - 0 + 100, TB / 2, 16, T('text.secondary'))  # off-canvas placeholder (detail toggle lives in View menu)


def statusbar(S, T, ab=(2, 0), wts=6, prunable=1, fetched='Fetched 2 min ago', gh='@mina-dev', left_extra=None):
    y = H - SBH / 2
    x = 16
    g_shield(S, x + 6, y, 13, T('status.ok'))
    x += 16 + S.text(x + 16, y + 4, 'Read-only', size=11.5, fill=T('text.secondary'), weight=500)
    sep = lambda xx: S.circle(xx + 10, y, 1.5, fill=T('text.quaternary'))
    sep(x)
    x += 20
    g_refresh(S, x + 6, y, 12, T('text.tertiary'))
    x += 16 + S.text(x + 16, y + 4, fetched, size=11.5, fill=T('text.secondary'))
    sep(x)
    x += 20
    if ab is None:
        x += S.text(x, y + 4, 'No upstream', size=11.5, fill=T('text.secondary'))
    else:
        g_arrow(S, x + 4, y, 10, T('status.ahead'), up=True)
        x += 11 + S.text(x + 11, y + 4, str(ab[0]), size=11.5, fill=T('status.ahead'), weight=600)
        g_arrow(S, x + 8, y, 10, T('status.behind'), up=False)
        x += 15 + S.text(x + 15, y + 4, str(ab[1]), size=11.5, fill=T('status.behind'), weight=600)
    sep(x)
    x += 20
    x += S.text(x, y + 4, f'{wts} worktrees', size=11.5, fill=T('text.secondary'))
    if prunable:
        sep(x)
        x += 20
        g_question_folder(S, x + 7, y, 13, T('status.prunable'))
        x += 18 + S.text(x + 18, y + 4, f'{prunable} prunable', size=11.5, fill=T('text.secondary'), weight=500)
    if left_extra:
        sep(x)
        x += 20
        S.text(x, y + 4, left_extra, size=11.5, fill=T('text.secondary'))
    # right: gh status
    label = f'gh: {gh}'
    lw = tw(label, 11.5)
    S.text(W - 34 - lw, y + 4, label, size=11.5, fill=T('text.secondary'))
    g_check_circle_fill(S, W - 22, y, 12, T('status.ok'), T('surface.window'))


# ---------------------------------------------------------------- panels

def panel(S, T, x0, y0, x1, y1, cid):
    """Rounded panel box with outline. Returns nothing; content goes inside open_group(clip=cid)."""
    if T.mode == 'light':
        S.rect(x0, y0 + 1, x1 - x0, y1 - y0, r=PR, fill='#1a1f2a', op=.05)
    S.rect(x0, y0, x1 - x0, y1 - y0, r=PR, fill=T('surface.panel'))
    S.clip(cid, x0, y0, x1 - x0, y1 - y0, PR)


def panel_outline(S, T, x0, y0, x1, y1):
    S.rect(x0 + .5, y0 + .5, x1 - x0 - 1, y1 - y0 - 1, r=PR - .5, stroke=T('border.panel'))
    if T.mode == 'dark':
        S.line(x0 + PR, y0 + 1.5, x1 - PR, y0 + 1.5, '#ffffff', op=.035)


def panel_header(S, T, x0, y0, x1, h=PH):
    S.rect(x0, y0, x1 - x0, h, fill=T('surface.panel-header'))
    S.line(x0, y0 + h - .5, x1, y0 + h - .5, T('border.separator'))


def grip(S, T, x, active=False):
    cy = (PT + PB) / 2
    if active:
        S.rect(x - G / 2, PT, G, PB - PT, fill=T('accent'), op=.10)
    S.rect(x - 2, cy - 14, 4, 28, r=2, fill=T('surface.splitter-grip-active') if active else T('surface.splitter-grip'))


def scrollbar(S, T, x, y0, y1, start, length):
    h = (y1 - y0) * length
    y = y0 + (y1 - y0) * start
    S.rect(x, y, 5, h, r=2.5, fill=T('surface.scrollbar-thumb'))


def tile(S, T, cx, cy, lane, s=20, glyph='tree', neutral=False):
    c = T('text.secondary') if neutral else T.lane(lane)
    S.rect(cx - s / 2, cy - s / 2, s, s, r=s * .27, fill=c, op=.18 if not neutral else .14)
    if glyph == 'tree':
        g_tree(S, cx, cy, s * .62, c, filled=True)
    elif glyph == 'detached':
        g_tree(S, cx, cy, s * .62, c, filled=False)


def section_header(S, T, x0, x1, y, label, count=None, open_=True):
    cy = y + 15
    g_chevron(S, x0 + 14, cy, 10, T('text.tertiary'), 'down' if open_ else 'right')
    S.text(x0 + 24, cy + 3.8, label, size=10.5, fill=T('text.tertiary'), weight=700, ls='0.7')
    if count is not None:
        chip_count(S, T, x1 - 12, cy, count)
    return y + 30


def badges(S, T, xr, cy, b, sel=False):
    """Right-to-left badges following the IA priority order. Returns the left edge."""
    x = xr
    def text_badge(glyph, s, color, weight=600):
        nonlocal x
        w = tw(s, 11.5, weight)
        S.text(x - w, cy + 4.1, s, size=11.5, fill=color, weight=weight)
        x -= w + 2
        glyph(x - 5)
        x -= 14
    if b.get('locked'):
        g_lock(S, x - 6, cy, 12, T('status.locked'))
        x -= 18
    if b.get('ahead') or b.get('behind'):
        if b.get('behind'):
            text_badge(lambda gx: g_arrow(S, gx, cy, 10, T('status.behind'), up=False), str(b['behind']), T('status.behind'))
        if b.get('ahead'):
            text_badge(lambda gx: g_arrow(S, gx, cy, 10, T('status.ahead'), up=True), str(b['ahead']), T('status.ahead'))
    if b.get('changes'):
        text_badge(lambda gx: g_pencil(S, gx, cy, 11, T('text.secondary')), str(b['changes']), T('text.secondary'), 500)
    if b.get('prunable'):
        g_question_folder(S, x - 7, cy, 13, T('status.prunable'))
        x -= 20
    if b.get('conflicts'):
        text_badge(lambda gx: g_triangle_fill(S, gx, cy, 11, T('status.conflicted'), T('surface.panel')), str(b['conflicts']), T('status.conflicted'))
    if b.get('delta'):
        text_badge(lambda gx: g_plusminus(S, gx, cy, 11, T('text.secondary')), str(b['delta']), T('text.secondary'), 500)
    return x


def issue_filter_chip(S, T, xr, cy):
    label = 'Open'
    w = tw(label, 11, 500) + 22
    S.rect(xr - w, cy - 9, w, 18, r=5, fill=T('surface.control'), stroke=T('border.separator') if T.mode == 'light' else None)
    S.text(xr - w + 7, cy + 3.8, label, size=11, fill=T('text.secondary'), weight=500)
    g_chevron(S, xr - 8, cy, 8, T('text.tertiary'), 'down')


def sidebar(S, T, focus='feat42', selected='wt:feat42', delta=None, scroll=(0.0, 0.78), scroll_px=0, issue_filter=False, tags=False):
    x0, x1, y0, y1 = LX0, LX1, PT, PB
    panel(S, T, x0, y0, x1, y1, 'sbclip')
    S.open_group(clip='sbclip')
    panel_header(S, T, x0, y0, x1)
    # filter field
    S.rect(x0 + 10, y0 + 8, x1 - x0 - 20, 24, r=6, fill=T('surface.control'), stroke=T('border.separator') if T.mode == 'light' else None)
    g_magnifier(S, x0 + 24, y0 + 20, 12, T('text.tertiary'))
    S.text(x0 + 36, y0 + 24.2, 'Filter', size=12.5, fill=T('text.quaternary'))
    kbd(S, T, x1 - 16, y0 + 20, '⌥⌘F')
    S.clip('sbbody', x0, y0 + PH, x1 - x0, y1 - y0 - PH)
    S.open_group(clip='sbbody')
    S.open_group(transform=f'translate(0 {-scroll_px})' if scroll_px else None)
    sections = []  # (label, count, top, bottom) for the sticky header
    y = y0 + PH + 4
    sec_top = y
    # WORKTREES
    sections.append(['WORKTREES', len(WORKTREES), y])
    y = section_header(S, T, x0, x1, y, 'WORKTREES', len(WORKTREES))
    for key, branch, folder, path, lane, b, fl in WORKTREES:
        h = 46
        is_focus = key == focus
        sel = selected == f'wt:{key}'
        if sel:
            S.rect(x0 + 6, y + 1, x1 - x0 - 12, h - 2, r=8, fill=T('surface.selection'))
            S.rect(x0 + 6, y + 1, x1 - x0 - 12, h - 2, r=8, stroke=T.lane(lane), op=.55)
        dim = fl.get('prunable')
        op = .55 if dim else 1
        tile(S, T, x0 + 26, y + h / 2, lane, 22, glyph='detached' if fl.get('detached') else 'tree', neutral=bool(fl.get('detached') or dim))
        name = branch if branch else f"detached @ {fl['detached']}"
        if delta and is_focus:
            b = dict(b, delta=delta)
        bx = badges(S, T, x1 - 14, y + 16, b, sel)
        nx = x0 + 44
        maxw = bx - nx - 6
        S.open_group(op=op)
        S.text(nx, y + 20, fit(name, 13, maxw, 600 if is_focus else 500), size=13, fill=T('text.primary'), weight=600 if is_focus else 500)
        sub = 'main worktree' if fl.get('main') else ('path missing' if dim else folder)
        sub_c = T('text.secondary' if sel else 'text.tertiary')
        sx = nx
        if fl.get('main'):
            w = tw(sub, 10.5, 600) + 10
            S.rect(sx, y + 27, w, 15, r=4, fill=T('text.tertiary'), op=.16)
            S.text(sx + 5, y + 38, sub, size=10.5, fill=T('text.secondary'), weight=600)
            sx += w + 6
            S.text(sx, y + 38.5, path, size=11.5, fill=sub_c)
        else:
            S.text(sx, y + 38.5, fit(path if not dim else 'path missing', 11.5, x1 - sx - 14), size=11.5, fill=T('status.prunable') if dim else sub_c)
        S.close_group()
        if is_focus:
            S.circle(x0 + 26 + 9, y + h / 2 - 9, 4.2, fill=T('accent'), stroke=T('surface.selection') if sel else T('surface.panel'), sw=2)
        y += h
    y += 6
    # LOCAL
    sections.append(['LOCAL', 5, y])
    y = section_header(S, T, x0, x1, y, 'LOCAL', 5)
    local = [(0, 'main', 'branch', {}, 'main'), (0, 'agent/', 'folder', {'n': 1}, None), (0, 'feat/', 'folder-open', {}, None),
             (1, '42-rate-limit', 'branch', {'ahead': 2}, 'feat/42-rate-limit'), (0, 'fix/', 'folder', {'n': 1}, None)]
    for depth, name, kind, b, full in local:
        cy = y + 14
        sel = selected == f'br:{full}'
        if sel:
            S.rect(x0 + 6, y + 1, x1 - x0 - 12, 26, r=6, fill=T('surface.selection'))
        xx = x0 + 16 + depth * 16
        if kind.startswith('folder'):
            g_chevron(S, xx, cy, 9, T('text.tertiary'), 'down' if kind == 'folder-open' else 'right')
            g_folder(S, xx + 15, cy, 13, T('text.secondary'))
            S.text(xx + 27, cy + 4.3, name, size=12.5, fill=T('text.primary'))
            if b.get('n'):
                S.text(x1 - 16, cy + 4, str(b['n']), size=11, fill=T('text.tertiary'), anchor='end')
        else:
            g_branch(S, xx + 15, cy, 13, T('text.secondary'))
            S.text(xx + 27, cy + 4.3, name, size=12.5, fill=T('text.primary'))
            bx = badges(S, T, x1 - 34 if full in CHECKED_OUT else x1 - 14, cy, b)
            if full in CHECKED_OUT:
                lane = next(w[4] for w in WORKTREES if w[1] == full)
                g_tree(S, x1 - 22, cy, 12, T.lane(lane), filled=True)
        y += 28
    y += 6
    # REMOTE
    sections.append(['REMOTE', 4, y])
    y = section_header(S, T, x0, x1, y, 'REMOTE', 4)
    cy = y + 14
    g_chevron(S, x0 + 16, cy, 9, T('text.tertiary'), 'down')
    g_globe(S, x0 + 31, cy, 13, T('text.secondary'))
    S.text(x0 + 43, cy + 4.3, 'origin', size=12.5, fill=T('text.primary'))
    y += 28
    for name, code, when in (('feat/42-rate-limit', 'AK', '2h'), ('feat/48-metrics', 'SR', '1d'), ('fix/57-token-refresh', 'MP', '5h'), ('main', 'JL', '1d')):
        cy = y + 14
        g_branch(S, x0 + 47, cy, 13, T('text.secondary'))
        tw_ = tw(when, 11)
        S.text(x1 - 14, cy + 4, when, size=11, fill=T('text.tertiary'), anchor='end')
        avatar(S, T, x1 - 14 - tw_ - 14, cy, code, d=16)
        S.text(x0 + 59, cy + 4.3, fit(name, 12.5, x1 - 14 - tw_ - 26 - (x0 + 59)), size=12.5, fill=T('text.primary'))
        y += 28
    y += 6
    # TAGS (#377): under REMOTE, newest first; the relative date on the right, the tree mark for a detached worktree.
    # Drawn only for the TAGS mockup; the other screens predate the section and keep their layout.
    if tags:
        sections.append(['TAGS', 38, y])
        y = section_header(S, T, x0, x1, y, 'TAGS', 38)
        for name, when, detached in (('v1.4.0', '3d', False), ('v1.4.0-rc.2', '12d', False), ('v1.3.2', '1mo', True),
                                     ('v1.3.1', '2mo', False)):
            cy = y + 14
            if selected == f'tg:{name}':
                S.rect(x0 + 6, y + 1, x1 - x0 - 12, 26, r=6, fill=T('surface.selection'))
            g_tag(S, x0 + 23, cy, 13, T('text.secondary'))
            S.text(x1 - 14, cy + 4, when, size=11, fill=T('text.tertiary'), anchor='end')
            if detached:
                g_tree(S, x1 - 14 - tw(when, 11) - 14, cy, 12, T('text.secondary'))
            S.text(x0 + 35, cy + 4.3, name, size=12.5, fill=T('text.primary'))
            y += 28
        S.text(x0 + 16, y + 18, '34 more tags — filter to find one', size=11, fill=T('text.tertiary'))
        y += 28
        y += 6
    # STASHES
    sections.append(['STASHES', 2, y])
    y = section_header(S, T, x0, x1, y, 'STASHES', 2)
    for si, (ref, msg) in enumerate((('stash@{0}', 'WIP on feat/42-rate-limit'), ('stash@{1}', 'spike notes'))):
        cy = y + 14
        if selected == f'st:{si}':
            S.rect(x0 + 6, y + 1, x1 - x0 - 12, 26, r=6, fill=T('surface.selection'))
        g_tray(S, x0 + 23, cy, 13, T('text.secondary'))
        w = S.text(x0 + 35, cy + 4.3, ref, size=12, fill=T('text.primary'), mono=True)
        S.text(x0 + 35 + w + 8, cy + 4.3, fit(msg, 12.5, x1 - (x0 + 43 + w) - 14), size=12.5, fill=T('text.tertiary'))
        y += 28
    y += 6
    sections.append(['ISSUES', 3, y])
    y = section_header(S, T, x0, x1, y, 'ISSUES', 3)
    if issue_filter:
        issue_filter_chip(S, T, x1 - 40, y - 15)
    for num, title, linked in (('#42', 'Rate limit per tenant', 1), ('#57', 'Token refresh race', 2), ('#61', 'Paginate audit log', None)):
        cy = y + 14
        if selected == f'is:{num[1:]}':
            S.rect(x0 + 6, y + 1, x1 - x0 - 12, 26, r=6, fill=T('surface.selection'))
        g_number_circle(S, x0 + 23, cy, 13, T('text.secondary'))
        w = S.text(x0 + 35, cy + 4.3, num, size=12.5, fill=T('text.secondary'), weight=500)
        S.text(x0 + 35 + w + 6, cy + 4.3, fit(title, 12.5, x1 - (x0 + 41 + w) - 34), size=12.5, fill=T('text.primary'))
        if linked is not None:
            g_tree(S, x1 - 22, cy, 12, T.lane(linked), filled=True)
        y += 28
    S.close_group()
    if scroll_px:
        # sticky header of the section that the top edge is inside
        top = y0 + PH + scroll_px
        cur = [sec for sec in sections if sec[2] <= top][-1]
        S.rect(x0, y0 + PH, x1 - x0, 30, fill=T('surface.panel'))
        section_header(S, T, x0, x1, y0 + PH, cur[0], cur[1])
        S.line(x0, y0 + PH + 30.5, x1, y0 + PH + 30.5, T('border.separator'))
    S.close_group()
    scrollbar(S, T, x1 - 8, y0 + PH + 4, y1 - 4, scroll[0], scroll[1])
    S.close_group()
    panel_outline(S, T, x0, y0, x1, y1)


# ---------------------------------------------------------------- graph panel

COLS = None


def columns(lanes=4):
    gw = (lanes - 1) * LANE + 34
    x = CX0
    cols = {}
    for name, w in (('refs', 172), ('graph', gw)):
        cols[name] = (x, x + w)
        x += w
    right = [('sha', 72), ('date', 52), ('author', 108)]
    xr = CX1
    for name, w in right:
        cols[name] = (xr - w, xr)
        xr -= w
    cols['message'] = (x, xr)
    return cols


def lane_x(cols, l):
    return cols['graph'][0] + 17 + l * LANE


def author_chips(S, T, y0, active='all'):
    cy = y0 + PH / 2
    x = CX0 + 14
    g_person2(S, x + 6, cy, 14, T('text.tertiary'))
    x += 22
    chips = [('all', 'All', None, None), ('JL', 'Jordan Lee', 'JL', 9), ('AK', 'Alex Kim', 'AK', 8),
             ('MP', 'Mina Park', 'MP', 8), ('SR', 'Sam Rivera', 'SR', 6)]
    for key, label, code, n in chips:
        on = key == active
        lw = tw(label, 12, 500)
        w = lw + 18 + (20 if code else 0) + (tw(str(n), 11, 500) + 6 if n else 0)
        if on:
            S.rect(x, cy - 12, w, 24, fill=T('accent'), r=12)
        else:
            S.rect(x + .5, cy - 11.5, w - 1, 23, fill=T('surface.control'), r=12, stroke=T('border.separator'))
        tc = T('text.on-accent') if on else T('text.primary')
        tx = x + 9
        if code:
            avatar(S, T, tx + 8, cy, code, d=17)
            tx += 21
        tx += S.text(tx, cy + 4.2, label, size=12, fill=tc, weight=500)
        if n:
            S.text(tx + 6, cy + 4.2, str(n), size=11, fill=T('text.on-accent') if on else T('text.secondary'), weight=500)
        x += w + 6
    x += 4
    S.line(x, cy - 9, x, cy + 9, T('border.separator'))
    x += 10
    on = active == 'ai'
    label = 'AI-assisted'
    w = tw(label, 12, 500) + 18 + 18 + tw('7', 11, 500) + 6
    if on:
        S.rect(x, cy - 12, w, 24, fill=T('accent'), r=12)
    else:
        S.rect(x + .5, cy - 11.5, w - 1, 23, fill=T('surface.control'), r=12, stroke=T('border.separator'))
    tc = T('text.on-accent') if on else T('text.primary')
    g_sparkles(S, x + 16, cy, 12, tc)
    tx = x + 27 + S.text(x + 27, cy + 4.2, label, size=12, fill=tc, weight=500)
    S.text(tx + 6, cy + 4.2, '7', size=11, fill=T('text.on-accent') if on else T('text.secondary'), weight=500)
    # right: column/density menu
    g_ellipsis(S, CX1 - 22, cy, 15, T('text.secondary'))


def column_header(S, T, cols, y):
    S.rect(CX0, y, CX1 - CX0, CH, fill=T('surface.panel-header'))
    S.line(CX0, y + CH - .5, CX1, y + CH - .5, T('border.separator'))
    labels = [('refs', 'Refs'), ('graph', 'Graph'), ('message', 'Message'), ('author', 'Author'), ('date', 'Date'), ('sha', 'SHA')]
    for k, lab in labels:
        a, b = cols[k]
        S.text(a + 12, y + 18, lab, size=11, fill=T('text.tertiary'), weight=500)
        if k != 'sha':
            S.line(b - .5, y + 8, b - .5, y + CH - 8, T('border.strong'))


def pill_parts(refs, focus_branch):
    """Merge local + same-name remote into one pill; order focus → local → remote → tag."""
    out = []
    names = {n for k, n in refs if k == 'local'}
    for k, n in refs:
        if k == 'remote' and n.split('/', 1)[1] in names:
            continue
        both = k == 'local' and f'origin/{n}' in {m for kk, m in refs if kk == 'remote'}
        out.append((k, n, both))
    rank = lambda p: (0 if p[1] == focus_branch else 1 if p[0] == 'local' else 2 if p[0] == 'remote' else 3)
    return sorted(out, key=rank)


def ref_pill(S, T, x, cy, kind, name, lane, both=False, focus=False, maxw=136, worktree=False):
    h = 18
    glyph_w = 14 if (worktree or kind in ('remote', 'tag', 'detached')) else 0
    tail_w = 14 if both else 0
    tw_max = maxw - 12 - glyph_w - tail_w
    label = fit(name, 11, tw_max, 500)
    w = 12 + glyph_w + tw(label, 11, 500) + tail_w
    c = T.lane(lane)
    if kind == 'local' and focus:
        S.rect(x, cy - h / 2, w, h, r=5, fill=c)
        tc = T.on_lane(lane)
    elif kind == 'local':
        S.rect(x, cy - h / 2, w, h, r=5, fill=c, op=T_val('graph.ref-pill-local-fill-opacity'))
        S.rect(x + .5, cy - h / 2 + .5, w - 1, h - 1, r=4.5, stroke=c, op=T_val('graph.ref-pill-border-opacity'))
        tc = T('text.primary')
    elif kind == 'remote':
        S.rect(x + .5, cy - h / 2 + .5, w - 1, h - 1, r=4.5, stroke=c, op=T_val('graph.ref-pill-border-opacity'))
        tc = T('text.secondary')
    elif kind == 'tag':
        S.rect(x, cy - h / 2, w, h, r=5, fill=T('text.tertiary'), op=.16)
        tc = T('text.secondary')
    else:  # detached worktree
        S.rect(x + .5, cy - h / 2 + .5, w - 1, h - 1, r=4.5, stroke=T('text.tertiary'), op=.7)
        tc = T('text.secondary')
    gx = x + 6
    if worktree or kind == 'detached':
        g_tree(S, gx + 5, cy, 10.5, tc, filled=True)
        gx += 14
    elif kind == 'remote':
        g_globe(S, gx + 5, cy, 10.5, tc)
        gx += 14
    elif kind == 'tag':
        g_tag(S, gx + 5, cy, 10, tc)
        gx += 14
    S.text(gx, cy + 3.9, label, size=11, fill=tc, weight=500)
    if both:
        g_globe(S, x + w - 11, cy, 10, tc)
    return w


def T_val(path):
    return tok('semantic.color.' + path)


def graph_panel(S, T, wip=None, selected='wip', focus_lane=1, focus_idx=0, dim_non_ai=False, active_chip='all',
                focus_branch='feat/42-rate-limit', hover=None, scroll=(0.0, 0.22), highlight=None):
    """wip: list of (kind, n) for the WIP summary or None. selected: 'wip' or a commit index."""
    x0, x1, y0, y1 = CX0, CX1, PT, PB
    panel(S, T, x0, y0, x1, y1, 'gpclip')
    S.open_group(clip='gpclip')
    S.rect(x0, y0, x1 - x0, y1 - y0, fill=T('surface.canvas'))
    panel_header(S, T, x0, y0, x1)
    author_chips(S, T, y0, active_chip)
    cols = columns(4)
    column_header(S, T, cols, y0 + PH)
    by0 = y0 + PH + CH
    S.clip('gbody', x0, by0, x1 - x0, y1 - by0)
    S.open_group(clip='gbody')
    off = 1 if wip else 0
    rowy = lambda r: by0 + (r + off) * ROW + ROW / 2
    # row backgrounds
    if wip:
        S.rect(x0, by0, x1 - x0, ROW, fill=T('surface.wip-row'))
    if selected == 'wip' and wip:
        S.rect(x0, by0, 3, ROW, fill=T('accent'))
    if isinstance(selected, int):
        ln = C[selected][4]
        S.rect(x0, rowy(selected) - ROW / 2, x1 - x0, ROW, fill=T.lane(ln), op=T_val('graph.selection-opacity'))
        S.rect(x0, rowy(selected) - ROW / 2, 3, ROW, fill=T.lane(ln))
    if hover is not None:
        S.rect(x0, rowy(hover) - ROW / 2, x1 - x0, ROW, fill=T('surface.hover'))
    if highlight is not None:
        ln = C[highlight][4]
        S.rect(x0, rowy(highlight) - ROW / 2, x1 - x0, ROW, fill=T.lane(ln), op=.08)
        S.rect(x0 + 1.5, rowy(highlight) - ROW / 2 + .75, x1 - x0 - 3, ROW - 1.5, r=4, stroke=T.lane(ln), op=.6, dash='4 3')
    # edges
    n = len(C)
    edge_w = 3
    for i, (sha, subj, au, dt, ln, parents, refs, ai, wt) in enumerate(C):
        xa, ya = lane_x(cols, ln), rowy(i)
        for pi, p in enumerate(parents):
            pln = C[p][4]
            xb, yb = lane_x(cols, pln), rowy(p)
            op = .35 if dim_non_ai and not (ai or C[p][7]) else 1
            if pln == ln:
                S.line(xa, ya, xb, yb, T.lane(ln), sw=edge_w, op=op)
            elif pi == 0:
                # branch-off: stay in own lane until the row above the parent, then curve in
                yc = yb - ROW
                if yc > ya:
                    S.line(xa, ya, xa, yc, T.lane(ln), sw=edge_w, op=op)
                S.path(f'M{xa} {yc} C{xa} {yc + ROW * .55} {xb} {yb - ROW * .55} {xb} {yb}', stroke=T.lane(ln), sw=edge_w, op=op)
            else:
                # merge: curve out of the merge node into the parent's lane, then straight down
                yc = ya + ROW
                S.path(f'M{xa} {ya} C{xa} {ya + ROW * .55} {xb} {yc - ROW * .55} {xb} {yc}', stroke=T.lane(pln), sw=edge_w, op=op)
                if yb > yc:
                    S.line(xb, yc, xb, yb, T.lane(pln), sw=edge_w, op=op)
    # lanes continuing below the last visible commit
    # WIP connector
    if wip:
        xw, yw = lane_x(cols, focus_lane), by0 + ROW / 2
        S.line(xw, yw + 9, xw, rowy(focus_idx) - 12, T('graph.wip-node'), sw=1.75, dash='3 3')
        S.circle(xw, yw, 11, fill=T('surface.canvas'))
        S.circle(xw, yw, 9, stroke=T('graph.wip-node'), sw=1.75, dash='3.2 2.6')
        g_pencil(S, xw, yw, 8.5, T('text.secondary'))
    # nodes
    for i, (sha, subj, au, dt, ln, parents, refs, ai, wt) in enumerate(C):
        x, y = lane_x(cols, ln), rowy(i)
        op = .4 if dim_non_ai and not ai else 1
        S.open_group(op=op)
        c = T.lane(ln)
        if len(parents) > 1:
            S.circle(x, y, 7.5, fill=T('graph.node-ring'))
            S.circle(x, y, 5, fill=c)
        else:
            S.circle(x, y, 12.5, fill=T('graph.node-ring'))
            S.circle(x, y, 8.75, fill=T.avatar(av_idx(au)))
            S.text(x, y + 3, au, size=8.5, fill=T('avatar.initials'), weight=700, anchor='middle')
            S.circle(x, y, 10, stroke=c, sw=2.5)
        if i == focus_idx:
            S.circle(x, y, 14.2, stroke=T('graph.head-ring'), sw=1.75)
        S.close_group()
    # refs, message, author, date, sha
    for i, (sha, subj, au, dt, ln, parents, refs, ai, wt) in enumerate(C):
        y = rowy(i)
        is_sel = selected == i
        op = .4 if dim_non_ai and not ai else 1
        S.open_group(op=op)
        parts = pill_parts(refs, focus_branch)
        if wt:
            parts = [('detached', wt, False)] + parts
        if parts:
            ra, rb = cols['refs']
            px = ra + 10
            k, nm, both = parts[0]
            more = len(parts) - 1
            maxw = rb - ra - 20 - (26 if more else 0)
            pw = ref_pill(S, T, px, y, k, nm, ln, both=both, focus=(nm == focus_branch), maxw=maxw,
                          worktree=(k == 'local' and nm in CHECKED_OUT))
            ex = px + pw
            if more:
                mw = tw(f'+{more}', 10.5, 600) + 10
                S.rect(ex + 4, y - 8, mw, 16, r=8, fill=T('text.tertiary'), op=.18)
                S.text(ex + 4 + mw / 2, y + 3.6, f'+{more}', size=10.5, fill=T('text.secondary'), weight=600, anchor='middle')
                ex += mw + 4
            nx = lane_x(cols, ln) - (13 if len(parents) <= 1 else 8)
            S.line(ex + 2, y, nx, y, T.lane(ln), sw=1.5, op=T_val('graph.ref-connector-opacity'))
        ma, mb = cols['message']
        maxw = mb - ma - 24 - (36 if ai else 0)
        s = fit(subj, 13, maxw)
        w = S.text(ma + 12, y + 4.6, s, size=13, fill=T('text.primary'), weight=500 if is_sel else 400)
        if ai:
            ai_badge(S, T, ma + 12 + w + 8, y)
        aa, ab = cols['author']
        S.text(aa + 12, y + 4.3, fit(AUTHORS[au][0], 12, ab - aa - 18), size=12, fill=T('text.secondary'))
        da, db = cols['date']
        S.text(da + 12, y + 4.3, dt, size=12, fill=T('text.secondary' if is_sel else 'text.tertiary'))
        sa, sb = cols['sha']
        S.text(sa + 12, y + 4.2, sha, size=11.5, fill=T('text.secondary' if is_sel else 'text.tertiary'), mono=True)
        S.close_group()
    # WIP row text
    if wip:
        y = by0 + ROW / 2
        ma, mb = cols['message']
        x = ma + 12
        conf = [n for k, n in wip if k == 'conflicted']
        if conf:
            g_triangle_fill(S, x + 6, y, 12, T('status.conflicted'), T('surface.canvas'))
            x += 16 + S.text(x + 16, y + 4.4, f'{conf[0]} conflicted', size=12.5, fill=T('status.conflicted'), weight=600)
            x += 10
        x += S.text(x, y + 4.6, 'WIP', size=13, fill=T('text.primary'), weight=700) + 10
        summary = ' · '.join(f'{n} {k}' for k, n in wip if k != 'conflicted')
        S.text(x, y + 4.4, summary, size=12.5, fill=T('text.secondary'))
        ra, rb = cols['refs']
        wt = next(w for w in WORKTREES if w[1] == focus_branch or (w[1] is None and focus_branch is None))
        lab = wt[2]
        pw = tw(lab, 11, 500) + 26
        S.rect(ra + 10.5, y - 8.5, pw - 1, 17, r=4.5, stroke=T('graph.wip-node'), dash='2.5 2', op=.9)
        g_tree(S, ra + 21, y, 10.5, T('text.secondary'), filled=False)
        S.text(ra + 30, y + 3.9, lab, size=11, fill=T('text.secondary'), weight=500)
        S.line(ra + 10 + pw + 2, y, lane_x(cols, focus_lane) - 12, y, T('graph.wip-node'), sw=1.25, dash='2 2.5')
    S.close_group()
    scrollbar(S, T, x1 - 8, by0 + 4, y1 - 4, scroll[0], scroll[1])
    S.close_group()
    panel_outline(S, T, x0, y0, x1, y1)
    return cols


def ai_badge(S, T, x, cy):
    w = 32
    S.rect(x + .5, cy - 8, w - 1, 16, r=8, stroke=T('text.tertiary'), op=.7)
    g_sparkles(S, x + 10, cy, 9, T('text.secondary'))
    S.text(x + 17, cy + 3.7, 'AI', size=10, fill=T('text.secondary'), weight=700)
    return w


# ---------------------------------------------------------------- detail panel

def detail_frame(S, T, cid='dpclip'):
    x0, x1, y0, y1 = RX0, RX1, PT, PB
    panel(S, T, x0, y0, x1, y1, cid)
    S.open_group(clip=cid)
    return x0, x1, y0, y1


def detail_end(S, T):
    S.close_group()
    panel_outline(S, T, RX0, PT, RX1, PB)


def segmented(S, T, xr, cy, items, active, fs=11.5):
    ws = [tw(i, fs, 500) + 20 for i in items]
    total = sum(ws) + 4
    x = xr - total
    S.rect(x, cy - 12, total, 24, r=7, fill=T('surface.control'), stroke=T('border.separator'))
    xx = x + 2
    for it, w in zip(items, ws):
        if it == active:
            S.rect(xx, cy - 10, w, 20, r=5.5, fill=T('surface.raised') if T.mode == 'dark' else '#ffffff', stroke=T('border.strong') if T.mode == 'light' else None)
            if T.mode == 'dark':
                S.rect(xx, cy - 10, w, 20, r=5.5, fill='#ffffff', op=.08)
        S.text(xx + w / 2, cy + 4, it, size=fs, fill=T('text.primary') if it == active else T('text.secondary'), weight=500, anchor='middle')
        xx += w
    return x


def card(S, T, x0, x1, y, h):
    S.rect(x0, y, x1 - x0, h, r=8, fill=T('surface.raised'))
    S.rect(x0 + .5, y + .5, x1 - x0 - 1, h - 1, r=7.5, stroke=T('border.separator'))


def file_group(S, T, x0, x1, y, kind, label, files, add=None, rem=None, sel_file=None):
    h = 32 + len(files) * 26 + 6
    card(S, T, x0, x1, y, h)
    cy = y + 16
    status_glyph(S, T, kind, x0 + 16, cy, 13)
    lw = S.text(x0 + 30, cy + 4.3, label, size=12, fill=T('text.primary'), weight=600)
    cw = chip_count(S, T, x0 + 30 + lw + 8 + 18, cy, len(files))
    if add is not None or rem is not None:
        stat(S, T, x1 - 12, cy, add, rem)
    S.line(x0 + 1, y + 31.5, x1 - 1, y + 31.5, T('border.separator'))
    fy = y + 32 + 3
    for k, path, a, r_ in files:
        fcy = fy + 13
        if sel_file == path:
            S.rect(x0 + 4, fy, x1 - x0 - 8, 26, r=6, fill=T('surface.selection'))
        kind_badge(S, T, x0 + 10, fcy, k)
        sw_ = 0
        if a is not None or r_ is not None:
            sw_ = stat(S, T, x1 - 12, fcy, a, r_, fs=11)
        path_text(S, T, x0 + 34, fcy, path, x1 - x0 - 34 - 18 - sw_, fs=12.5, sel=sel_file == path)
        fy += 26
    return y + h


def wip_detail(S, T, wt_key, groups, compare=None, sel_file=None):
    wt = next(w for w in WORKTREES if w[0] == wt_key)
    key, branch, folder, path, lane, b, fl = wt
    x0, x1, y0, y1 = detail_frame(S, T)
    panel_header(S, T, x0, y0, x1)
    tile(S, T, x0 + 22, y0 + PH / 2, lane, 20)
    sx = segmented(S, T, x1 - 12, y0 + PH / 2, ['Changes', 'Worktree'], 'Changes')
    S.text(x0 + 40, y0 + PH / 2 + 4.6, fit(branch, 13, sx - x0 - 48, 600), size=13, fill=T('text.primary'), weight=600)
    y = y0 + PH + 12
    g_folder(S, x0 + 20, y + 8, 13, T('text.tertiary'))
    pw = S.text(x0 + 32, y + 12, path, size=12, fill=T('text.secondary'))
    g_copy(S, x0 + 32 + pw + 12, y + 8, 12, T('text.tertiary'))
    y += 24
    total = sum(len(g[2]) for g in groups)
    adds = sum(g[3] or 0 for g in groups)
    rems = sum(g[4] or 0 for g in groups)
    S.text(x0 + 14, y + 13, f'{total} changed files', size=12, fill=T('text.tertiary'))
    bx0, bx1 = x0 + 120, x1 - 90
    S.rect(bx0, y + 7, bx1 - bx0, 6, r=3, fill=T('text.tertiary'), op=.2)
    if adds + rems:
        aw = (bx1 - bx0) * adds / (adds + rems)
        S.rect(bx0, y + 7, aw, 6, r=3, fill=T('status.staged'))
        S.rect(bx0 + aw + 1.5, y + 7, (bx1 - bx0) - aw - 1.5, 6, r=3, fill=T('status.conflicted'))
    stat(S, T, x1 - 14, y + 10, adds, rems, fs=11.5)
    y += 30
    for kind, label, files, add, rem in groups:
        y = file_group(S, T, x0 + 10, x1 - 10, y, kind, label, files, add, rem, sel_file) + 10
    if compare is not None:
        footer(S, T, x0, x1, y1, 112)
        compare_card(S, T, x0 + 10, x1 - 10, y1 - 10 - 92, **compare)
    detail_end(S, T)


def footer(S, T, x0, x1, y1, h):
    S.rect(x0, y1 - h, x1 - x0, h, fill=T('surface.panel-header'))
    S.line(x0, y1 - h + .5, x1, y1 - h + .5, T('border.separator'))


def compare_card(S, T, x0, x1, y, base='main', summary='2 commits ahead · 0 behind · 8 files', add=272, rem=85, merge_base='3c5d6f1'):
    h = 92
    S.rect(x0, y, x1 - x0, h, r=8, fill=T('accent'), op=.07)
    S.rect(x0 + .5, y + .5, x1 - x0 - 1, h - 1, r=7.5, stroke=T('accent'), op=.35)
    g_plusminus(S, x0 + 17, y + 19, 13, T('accent'))
    w = S.text(x0 + 31, y + 23.5, 'Changes vs', size=12, fill=T('text.primary'), weight=600)
    bx = x0 + 31 + w + 6
    bw = tw(base, 12, 600) + 28
    S.rect(bx, y + 9, bw, 21, r=5, fill=T('surface.control'), stroke=T('border.strong'))
    S.text(bx + 8, y + 23.5, base, size=12, fill=T('text.primary'), weight=600)
    g_updown(S, bx + bw - 10, y + 19.5, 10, T('text.tertiary'))
    S.text(x1 - 12, y + 23.5, f'base {merge_base}', size=11, fill=T('text.tertiary'), anchor='end', mono=True)
    S.text(x0 + 14, y + 49, summary, size=12, fill=T('text.secondary'))
    stat(S, T, x1 - 12, y + 45, add, rem, fs=11.5)
    label = 'Compare with Base…'
    bw = tw(label, 12, 600) + 24
    S.rect(x0 + 12, y + 60, bw, 24, r=6, fill=T('accent'))
    S.text(x0 + 24, y + 76, label, size=12, fill=T('text.on-accent'), weight=600)
    S.text(x0 + 12 + bw + 10, y + 76, '⌘⇧B', size=11, fill=T('text.tertiary'), weight=500)
    return y + h + 10


def kv_row(S, T, x0, x1, y, key, value=None, kx=84, mono=False, color=None, draw=None, h=26):
    cy = y + h / 2
    S.text(x0, cy + 4.2, key, size=12, fill=T('text.tertiary'))
    if draw:
        draw(x0 + kx, cy)
    elif value is not None:
        S.text(x0 + kx, cy + 4.2, fit(value, 12 if not mono else 12, x1 - x0 - kx, mono=mono), size=12 if not mono else 12,
               fill=color or T('text.primary'), mono=mono)
    return y + h


def ai_avatar(S, T, cx, cy, d=16):
    S.circle(cx, cy, d / 2 - .5, stroke=T('text.tertiary'), sw=1)
    g_sparkles(S, cx, cy, d * .58, T('text.secondary'))


def wrap(text, size, maxw, weight=400):
    words, line, lines = text.split(), '', []
    for wd in words:
        t = (line + ' ' + wd).strip()
        if tw(t, size, weight) > maxw and line:
            lines.append(line)
            line = wd
        else:
            line = t
    lines.append(line)
    return lines


COMMIT_FILES = [('A', 'internal/ratelimit/limiter.go', 112, 0), ('M', 'internal/http/middleware.go', 38, 4),
                ('A', 'internal/ratelimit/limiter_test.go', 27, 0), ('M', 'cmd/api/main.go', 6, 2), ('M', 'go.mod', 3, 6)]


def commit_detail(S, T, idx, sel_file=None):
    sha, subj, au, date, lane, parents, refs, ai, wtp = C[idx]
    x0, x1, y0, y1 = detail_frame(S, T)
    panel_header(S, T, x0, y0, x1)
    S.circle(x0 + 22, y0 + PH / 2, 9, fill=T.avatar(av_idx(au)))
    S.circle(x0 + 22, y0 + PH / 2, 9.8, stroke=T.lane(lane), sw=2)
    S.text(x0 + 22, y0 + PH / 2 + 3, au, size=8, fill=T('avatar.initials'), weight=700, anchor='middle')
    w = S.text(x0 + 40, y0 + PH / 2 + 4.4, 'Commit', size=13, fill=T('text.primary'), weight=600)
    sw_ = S.text(x0 + 40 + w + 8, y0 + PH / 2 + 4.2, sha, size=12, fill=T('text.secondary'), mono=True)
    g_copy(S, x0 + 40 + w + 8 + sw_ + 12, y0 + PH / 2, 12, T('text.tertiary'))
    g_ellipsis(S, x1 - 20, y0 + PH / 2, 15, T('text.secondary'))
    y = y0 + PH + 18
    for i, ln in enumerate(wrap(subj, 15, x1 - x0 - 28, 600)[:2]):
        S.text(x0 + 14, y + 12 + i * 21, ln, size=15, fill=T('text.primary'), weight=600)
    y += 21 * min(2, len(wrap(subj, 15, x1 - x0 - 28, 600))) + 8
    body = ['Use a sliding window counter per tenant key. Reject with 429 and Retry-After once the window is full.', '', 'Refs: #42']
    for para in body:
        if not para:
            y += 8
            continue
        for ln in wrap(para, 12.5, x1 - x0 - 28):
            S.text(x0 + 14, y + 12, ln, size=12.5, fill=T('text.secondary'))
            y += 18
    if ai:
        trailer = f'Co-Authored-By: {AI_COAUTHOR[0]} <{AI_COAUTHOR[1]}>'
        if tw(trailer, 11.5, mono=True) > x1 - x0 - 28:
            S.text(x0 + 14, y + 12, f'Co-Authored-By: {AI_COAUTHOR[0]}', size=11.5, fill=T('text.tertiary'), mono=True)
            y += 17
            S.text(x0 + 14, y + 12, f'    <{AI_COAUTHOR[1]}>', size=11.5, fill=T('text.tertiary'), mono=True)
        else:
            S.text(x0 + 14, y + 12, trailer, size=11.5, fill=T('text.tertiary'), mono=True)
        y += 18
    y += 10
    # metadata card
    rows = 6 if ai else 5
    ch = rows * 26 + 12
    card(S, T, x0 + 10, x1 - 10, y, ch)
    cx0, cx1 = x0 + 24, x1 - 22
    yy = y + 6
    nm, em = AUTHORS[au]
    def author_draw(x, cy):
        avatar(S, T, x + 8, cy, au, d=17)
        w = S.text(x + 22, cy + 4.3, nm, size=12.5, fill=T('text.primary'), weight=500)
        S.text(x + 22 + w + 6, cy + 4.2, fit(em, 11.5, cx1 - (x + 28 + w)), size=11.5, fill=T('text.tertiary'))
    yy = kv_row(S, T, cx0, cx1, yy, 'Author', draw=author_draw)
    if ai:
        def co_draw(x, cy):
            ai_avatar(S, T, x + 8, cy, 17)
            w = S.text(x + 22, cy + 4.3, AI_COAUTHOR[0], size=12.5, fill=T('text.primary'), weight=500)
            ai_badge(S, T, x + 22 + w + 8, cy)
        yy = kv_row(S, T, cx0, cx1, yy, 'Co-author', draw=co_draw)
    yy = kv_row(S, T, cx0, cx1, yy, 'Date', '2026-11-06 09:41 (+09:00)')
    yy = kv_row(S, T, cx0, cx1, yy, 'Parents', ', '.join(C[p][0] for p in parents), mono=True, color=T('text.link'))
    def refs_draw(x, cy):
        px = x
        for k, nmr, both in pill_parts(refs, 'feat/42-rate-limit'):
            px += ref_pill(S, T, px, cy, k, nmr, lane, both=both, focus=(nmr == 'feat/42-rate-limit'), maxw=cx1 - px,
                           worktree=(k == 'local' and nmr in CHECKED_OUT)) + 6
    yy = kv_row(S, T, cx0, cx1, yy, 'Refs', draw=refs_draw)
    def issue_draw(x, cy):
        w = S.text(x, cy + 4.3, '#42', size=12.5, fill=T('text.link'), weight=500)
        S.text(x + w + 6, cy + 4.3, 'Rate limit per tenant', size=12.5, fill=T('text.primary'))
    yy = kv_row(S, T, cx0, cx1, yy, 'Issue', draw=issue_draw)
    y += ch + 10
    files = COMMIT_FILES
    file_group(S, T, x0 + 10, x1 - 10, y, None, 'Files', files, sum(f[2] for f in files), sum(f[3] for f in files), sel_file)
    detail_end(S, T)


def toggle(S, T, x, cy, on=True):
    S.rect(x, cy - 9, 32, 18, r=9, fill=T('accent') if on else T('border.strong'))
    S.circle(x + (23 if on else 9), cy, 7, fill='#ffffff')


def button(S, T, x, cy, label, glyph=None, primary=False, h=26, fs=12.5):
    w = tw(label, fs, 500) + 24 + (18 if glyph else 0)
    if primary:
        S.rect(x, cy - h / 2, w, h, r=7, fill=T('accent'))
        tc = T('text.on-accent')
    else:
        S.rect(x + .5, cy - h / 2 + .5, w - 1, h - 1, r=6.5, fill=T('surface.control'), stroke=T('border.strong'))
        tc = T('text.primary')
    tx = x + 12
    if glyph:
        glyph(S, tx + 6, cy, 13, tc)
        tx += 18
    S.text(tx, cy + fs * .36, label, size=fs, fill=tc, weight=500 if not primary else 600)
    return w


def worktree_detail(S, T, wt_key):
    wt = next(w for w in WORKTREES if w[0] == wt_key)
    key, branch, folder, path, lane, b, fl = wt
    x0, x1, y0, y1 = detail_frame(S, T)
    panel_header(S, T, x0, y0, x1)
    tile(S, T, x0 + 22, y0 + PH / 2, lane, 20)
    sx = segmented(S, T, x1 - 12, y0 + PH / 2, ['Changes', 'Worktree'], 'Worktree')
    S.text(x0 + 40, y0 + PH / 2 + 4.6, fit(branch, 13, sx - x0 - 48, 600), size=13, fill=T('text.primary'), weight=600)
    y = y0 + PH + 10
    ch = 7 * 26 + 12
    card(S, T, x0 + 10, x1 - 10, y, ch)
    cx0, cx1 = x0 + 24, x1 - 22
    yy = y + 6
    def path_draw(x, cy):
        S.text(x, cy + 4.2, fit(path, 12, cx1 - x - 20, mono=True, middle=True), size=12, fill=T('text.primary'), mono=True)
        g_copy(S, cx1 - 4, cy, 12, T('text.tertiary'))
    yy = kv_row(S, T, cx0, cx1, yy, 'Path', draw=path_draw)
    def head_draw(x, cy):
        w = S.text(x, cy + 4.2, 'e4b9a07', size=12, fill=T('text.link'), mono=True)
        S.text(x + w + 8, cy + 4.3, fit('fix(auth): refresh token before expiry', 12.5, cx1 - x - w - 8), size=12.5, fill=T('text.primary'))
    yy = kv_row(S, T, cx0, cx1, yy, 'HEAD', draw=head_draw)
    yy = kv_row(S, T, cx0, cx1, yy, 'Branch', branch)
    def up_draw(x, cy):
        w = S.text(x, cy + 4.3, fit('origin/fix/57-token-refresh', 12.5, cx1 - x - 52), size=12.5, fill=T('text.primary'))
        xx = x + w + 10
        g_arrow(S, xx + 4, cy, 10, T('status.ahead'), up=True)
        xx += 10 + S.text(xx + 10, cy + 4.3, '1', size=12, fill=T('status.ahead'), weight=600) + 8
        g_arrow(S, xx + 4, cy, 10, T('status.behind'), up=False)
        S.text(xx + 10, cy + 4.3, '0', size=12, fill=T('status.behind'), weight=600)
    yy = kv_row(S, T, cx0, cx1, yy, 'Upstream', draw=up_draw)
    yy = kv_row(S, T, cx0, cx1, yy, 'State', '3 changed · 0 untracked · 0 conflicts')
    yy = kv_row(S, T, cx0, cx1, yy, 'Lock', 'Not locked')
    yy = kv_row(S, T, cx0, cx1, yy, 'Last fetch', '2 min ago (repository)')
    y += ch + 10
    # security
    sh = 34 + 4 * 26 + 8 + 112
    card(S, T, x0 + 10, x1 - 10, y, sh)
    S.text(x0 + 24, y + 21, 'Security', size=12, fill=T('text.primary'), weight=600)
    S.text(x1 - 22, y + 21, 'always on', size=11, fill=T('text.tertiary'), anchor='end')
    S.line(x0 + 11, y + 33.5, x1 - 11, y + 33.5, T('border.separator'))
    yy = y + 38
    for label in ('Hooks disabled', 'fsmonitor disabled', 'External diff and textconv disabled', 'Remote URL credentials masked'):
        cy = yy + 13
        g_shield(S, x0 + 31, cy, 14, T('status.ok'), ok=True)
        S.text(x0 + 46, cy + 4.3, label, size=12.5, fill=T('text.primary'))
        yy += 26
    yy += 6
    wy = yy
    S.rect(x0 + 18, wy, x1 - x0 - 36, 104, r=7, fill=T('status.warning'), op=.10)
    S.rect(x0 + 18.5, wy + .5, x1 - x0 - 37, 103, r=6.5, stroke=T('status.warning'), op=.35)
    cy = wy + 15
    g_shield(S, x0 + 33, cy, 14, T('status.warning'), ok=False)
    S.text(x0 + 48, cy + 4.3, 'Config overrides neutralized', size=12.5, fill=T('text.primary'), weight=500)
    chip_count(S, T, x1 - 46, cy, 2)
    g_chevron(S, x1 - 32, cy, 10, T('text.secondary'), 'down')
    ky = cy + 22
    for k in ('filter.lfs.process', 'core.sshCommand'):
        S.text(x0 + 48, ky + 4, k, size=11.5, fill=T('text.primary'), mono=True)
        ky += 18
    S.text(x0 + 48, ky + 6, 'Values are never shown. Overridden for every git', size=11, fill=T('text.secondary'))
    S.text(x0 + 48, ky + 20, 'command Overgrove runs in this worktree.', size=11, fill=T('text.secondary'))
    footer(S, T, x0, x1, y1, 112)
    compare_card(S, T, x0 + 10, x1 - 10, y1 - 10 - 92, summary='1 commit ahead · 0 behind · 4 files', add=46, rem=12, merge_base='3c5d6f1')
    detail_end(S, T)


# ---------------------------------------------------------------- center: diff viewer and comparison

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


def diff_body(S, T, y0, y1, lines, x0=None, x1=None, lh=21):
    x0 = CX0 if x0 is None else x0
    x1 = CX1 if x1 is None else x1
    gut = x0 + 96
    S.rect(x0, y0, gut - x0, y1 - y0, fill=T('surface.panel-header'))
    y = y0 + 4
    for ln in lines:
        if y > y1:
            break
        if ln[0] == 'h':
            S.rect(x0, y, x1 - x0, lh + 2, fill=T('diff.hunk-header-bg'))
            S.text(gut + 12, y + 15, ln[1], size=11.5, fill=T('text.secondary'), mono=True)
            y += lh + 2
            continue
        k, o, n, code = ln
        if k == '+':
            S.rect(x0, y, x1 - x0, lh, fill=T('diff.added-bg'))
            S.rect(x0, y, gut - x0, lh, fill=T('diff.added-word-bg'), op=.55)
        elif k == '-':
            S.rect(x0, y, x1 - x0, lh, fill=T('diff.removed-bg'))
            S.rect(x0, y, gut - x0, lh, fill=T('diff.removed-word-bg'), op=.55)
        if o is not None:
            S.text(x0 + 38, y + 14.5, str(o), size=11, fill=T('text.tertiary'), mono=True, anchor='end')
        if n is not None:
            S.text(x0 + 74, y + 14.5, str(n), size=11, fill=T('text.tertiary'), mono=True, anchor='end')
        if k == '+':
            S.text(x0 + 86, y + 15, '+', size=12, fill=T('diff.gutter-added'), mono=True, weight=600, anchor='middle')
        elif k == '-':
            S.text(x0 + 86, y + 15, '−', size=12, fill=T('diff.gutter-removed'), mono=True, weight=600, anchor='middle')
        S.text(gut + 12, y + 15, code, size=12, fill=T('text.primary'), mono=True)
        y += lh
    S.line(gut - .5, y0, gut - .5, y1, T('border.separator'))


def back_button(S, T, x, cy):
    w = 74
    S.rect(x + .5, cy - 12, w - 1, 24, fill=T('surface.control'), r=6, stroke=T('border.strong'))
    g_chevron(S, x + 13, cy, 10, T('text.primary'), 'left')
    S.text(x + 24, cy + 4.3, 'Graph', size=12, fill=T('text.primary'), weight=500)
    return w + 12


def mono_path(S, T, x, cy, path, fs=12.5):
    d, f = path.rsplit('/', 1)
    w = S.text(x, cy + 4.4, d + '/', size=fs, fill=T('text.tertiary'), mono=True)
    w += S.text(x + w, cy + 4.4, f, size=fs, fill=T('text.primary'), mono=True, weight=600)
    return w


def diff_panel(S, T):
    x0, x1, y0, y1 = CX0, CX1, PT, PB
    panel(S, T, x0, y0, x1, y1, 'dvclip')
    S.open_group(clip='dvclip')
    S.rect(x0, y0, x1 - x0, y1 - y0, fill=T('surface.canvas'))
    panel_header(S, T, x0, y0, x1, h=44)
    cy = y0 + 22
    x = x0 + 12
    x += back_button(S, T, x, cy)
    kind_badge(S, T, x, cy, 'M')
    x += 24
    w = mono_path(S, T, x, cy, 'internal/http/middleware.go')
    x += w + 14
    S.text(x, cy + 4.2, 'a91f3c2', size=11.5, fill=T('text.link'), mono=True)
    x += tw('a91f3c2', 11.5, mono=True) + 8
    S.text(x, cy + 4.2, 'Modified', size=12, fill=T('text.secondary'))
    stat(S, T, x1 - 160, cy, 38, 4, fs=12)
    segmented(S, T, x1 - 12, cy, ['Unified', 'Split'], 'Unified')
    diff_body(S, T, y0 + 44, y1, GO_DIFF)
    scrollbar(S, T, x1 - 8, y0 + 48, y1 - 4, 0.0, 0.62)
    S.close_group()
    panel_outline(S, T, x0, y0, x1, y1)


def compare_panel(S, T):
    x0, x1, y0, y1 = CX0, CX1, PT, PB
    panel(S, T, x0, y0, x1, y1, 'cvclip')
    S.open_group(clip='cvclip')
    S.rect(x0, y0, x1 - x0, y1 - y0, fill=T('surface.canvas'))
    hh = 78
    panel_header(S, T, x0, y0, x1, h=hh)
    cy = y0 + 22
    x = x0 + 12
    x += back_button(S, T, x, cy)
    g_plusminus(S, x + 7, cy, 14, T('accent'))
    x += 20
    x += S.text(x, cy + 5, 'Changes vs', size=15, fill=T('text.primary'), weight=600) + 8
    bw = tw('main', 13, 600) + 44
    S.rect(x + .5, cy - 11.5, bw - 1, 23, fill=T('surface.control'), r=6, stroke=T('border.strong'))
    g_branch(S, x + 13, cy, 12, T.lane(0))
    S.text(x + 24, cy + 4.5, 'main', size=13, fill=T('text.primary'), weight=600)
    g_updown(S, x + bw - 11, cy, 10, T('text.tertiary'))
    tx = x1 - 14 - 32
    toggle(S, T, tx, cy, on=True)
    S.text(tx - 8, cy + 4.3, 'Include uncommitted', size=12, fill=T('text.primary'), anchor='end')
    cy2 = y0 + 56
    x = x0 + 14
    parts = [('2 commits ahead', 'text.primary', 600), ('  ·  ', 'text.tertiary', 400), ('0 behind', 'text.secondary', 400),
             ('  ·  ', 'text.tertiary', 400), ('uncommitted: 5 files', 'text.secondary', 400), ('  ·  ', 'text.tertiary', 400),
             ('8 files', 'text.primary', 600), ('  ', 'text.tertiary', 400)]
    for t_, c, wgt in parts:
        x += S.text(x, cy2 + 4.2, t_, size=12, fill=T(c), weight=wgt)
    stat_w = tw('+272', 12, 500) + tw('−85', 12, 500) + 6
    stat(S, T, x + stat_w, cy2, 272, 85, fs=12)
    S.text(x1 - 14, cy2 + 4, 'merge base 3c5d6f1', size=11.5, fill=T('text.tertiary'), mono=True, anchor='end')
    fy = y0 + hh
    S.rect(x0, fy, x1 - x0, 34, fill=T('surface.raised'))
    S.line(x0, fy + 33.5, x1, fy + 33.5, T('border.separator'))
    kind_badge(S, T, x0 + 14, fy + 17, 'M')
    w = mono_path(S, T, x0 + 38, fy + 17, 'internal/http/middleware.go')
    xx = x0 + 38 + w + 12
    S.rect(xx, fy + 9, 34, 16, r=4, fill=T('status.unstaged'), op=.2)
    S.text(xx + 17, fy + 20.6, 'WIP', size=10, fill=T('text.secondary'), weight=700, anchor='middle')
    S.text(xx + 44, fy + 21.2, '1 commit + uncommitted', size=12, fill=T('text.secondary'))
    stat(S, T, x1 - 14, fy + 17, 40, 4, fs=12)
    diff_body(S, T, fy + 34, y1, GO_DIFF)
    scrollbar(S, T, x1 - 8, fy + 38, y1 - 4, 0.0, 0.5)
    S.close_group()
    panel_outline(S, T, x0, y0, x1, y1)


def compare_detail(S, T):
    x0, x1, y0, y1 = detail_frame(S, T)
    panel_header(S, T, x0, y0, x1)
    tile(S, T, x0 + 22, y0 + PH / 2, 1, 20)
    S.text(x0 + 40, y0 + PH / 2 + 4.6, 'feat/42-rate-limit', size=13, fill=T('text.primary'), weight=600)
    w = tw('vs main', 11.5, 600) + 14
    S.rect(x1 - 12 - w, y0 + PH / 2 - 10, w, 20, r=10, fill=T('accent'), op=.14)
    S.text(x1 - 12 - w / 2, y0 + PH / 2 + 4, 'vs main', size=11.5, fill=T('accent'), weight=600, anchor='middle')
    y = y0 + PH + 10
    # commits ahead
    rows = [(None, 'Uncommitted changes', None, False), ('a91f3c2', 'feat(ratelimit): add sliding window limiter', 'AK', True),
            ('7d20e18', 'test(ratelimit): cover burst and refill cases', 'AK', True)]
    h = 32 + len(rows) * 28 + 6
    card(S, T, x0 + 10, x1 - 10, y, h)
    S.text(x0 + 24, y + 20.5, 'Commits ahead', size=12, fill=T('text.primary'), weight=600)
    chip_count(S, T, x0 + 24 + tw('Commits ahead', 12, 600) + 8 + 18, y + 16, 2)
    S.line(x0 + 11, y + 31.5, x1 - 11, y + 31.5, T('border.separator'))
    yy = y + 35
    for sha, subj, au, ai in rows:
        cy = yy + 14
        if sha is None:
            S.circle(x0 + 30, cy, 7, stroke=T('graph.wip-node'), sw=1.5, dash='2.4 2')
            S.text(x0 + 44, cy + 4.3, subj, size=12.5, fill=T('text.primary'), weight=500)
            S.text(x1 - 22, cy + 4, '5 files', size=11.5, fill=T('text.tertiary'), anchor='end')
        else:
            S.circle(x0 + 30, cy, 8, fill=T.avatar(av_idx(au)))
            S.circle(x0 + 30, cy, 8.8, stroke=T.lane(1), sw=1.8)
            S.text(x0 + 30, cy + 2.7, au, size=7.5, fill=T('avatar.initials'), weight=700, anchor='middle')
            w = S.text(x0 + 44, cy + 4, sha, size=11.5, fill=T('text.tertiary'), mono=True)
            right = x1 - 22 - (40 if ai else 0)
            S.text(x0 + 44 + w + 8, cy + 4.3, fit(subj, 12.5, right - (x0 + 52 + w)), size=12.5, fill=T('text.primary'))
            if ai:
                ai_badge(S, T, x1 - 22 - 32, cy)
        yy += 28
    y += h + 10
    files = [('M', 'internal/http/middleware.go', 40, 4, True), ('A', 'internal/ratelimit/limiter.go', 112, 0, False),
             ('A', 'internal/ratelimit/window.go', 58, 0, True), ('A', 'internal/ratelimit/limiter_test.go', 44, 0, False),
             ('R', 'internal/http/{noop.go → passthrough.go}', 6, 31, True), ('M', 'cmd/api/main.go', 9, 3, True),
             ('D', 'internal/http/noop_limiter.go', 0, 41, True), ('M', 'go.mod', 3, 6, False)]
    h = 32 + len(files) * 26 + 6
    card(S, T, x0 + 10, x1 - 10, y, h)
    S.text(x0 + 24, y + 20.5, 'Files changed', size=12, fill=T('text.primary'), weight=600)
    chip_count(S, T, x0 + 24 + tw('Files changed', 12, 600) + 8 + 18, y + 16, len(files))
    stat(S, T, x1 - 22, y + 16, 272, 85)
    S.line(x0 + 11, y + 31.5, x1 - 11, y + 31.5, T('border.separator'))
    fy = y + 35
    for k, pth, a, r_, wip in files:
        fcy = fy + 13
        if pth == 'internal/http/middleware.go':
            S.rect(x0 + 14, fy, x1 - x0 - 28, 26, r=6, fill=T('surface.selection'))
        kind_badge(S, T, x0 + 20, fcy, k)
        sw_ = stat(S, T, x1 - 22, fcy, a, r_)
        extra = 0
        if wip:
            extra = 34
            S.rect(x1 - 22 - sw_ - 8 - 28, fcy - 7.5, 28, 15, r=4, fill=T('status.unstaged'), op=.2)
            S.text(x1 - 22 - sw_ - 8 - 14, fcy + 3.4, 'WIP', size=9.5, fill=T('text.secondary'), weight=700, anchor='middle')
        path_text(S, T, x0 + 44, fcy, pth, x1 - x0 - 44 - 30 - sw_ - extra, fs=12.5, sel=pth == 'internal/http/middleware.go')
        fy += 26
    y += h + 10
    file_group(S, T, x0 + 10, x1 - 10, y, 'untracked', 'Untracked', [('?', 'docs/rate-limit.md', None, None), ('?', 'internal/ratelimit/bench_test.go', None, None)])
    detail_end(S, T)


# ---------------------------------------------------------------- onboarding

MARK = open(f'{REPO}/design/icon/mark.svg').read()


def mark_svg(x, y, size):
    import re
    inner = MARK.split('>', 1)[1].rsplit('</svg>', 1)[0]
    inner = re.sub(r'<title>.*?</title>', '', inner)
    h = size * 600 / 640
    return f'<svg x="{x}" y="{y}" width="{size}" height="{h:.1f}" viewBox="190 262 640 600">{inner}</svg>'


def s07(mode):
    T = Theme(mode)
    S = window(T, 'Overgrove — S-07 onboarding')
    traffic(S, T)
    S.text(W / 2, TB / 2 + 4.5, 'Overgrove Setup', size=13, fill=T('text.secondary'), weight=600, anchor='middle')
    px0, px1 = W / 2 - 400, W / 2 + 400
    py0, py1 = PT, PB
    panel(S, T, px0, py0, px1, py1, 'obclip')
    S.open_group(clip='obclip')
    py0 += 44
    S.add(mark_svg(W / 2 - 34, py0 + 40, 68))
    S.text(W / 2, py0 + 140, 'Welcome to Overgrove', size=26, fill=T('text.primary'), weight=700, anchor='middle')
    S.text(W / 2, py0 + 166, 'See every worktree of a repository at a glance.', size=13.5, fill=T('text.secondary'), anchor='middle')
    w1 = tw('Read-only', 12, 600) + 34
    S.rect(W / 2 - w1 / 2, py0 + 182, w1, 24, r=12, fill=T('status.ok'), op=.12)
    g_shield(S, W / 2 - w1 / 2 + 15, py0 + 194, 12, T('status.ok'))
    S.text(W / 2 - w1 / 2 + 25, py0 + 198.2, 'Read-only', size=12, fill=T('status.ok'), weight=600)
    S.text(W / 2, py0 + 228, 'The only network action is git fetch. Nothing in your repositories is ever changed.', size=12.5, fill=T('text.tertiary'), anchor='middle')
    cx0, cx1 = px0 + 56, px1 - 56
    lx = cx0 + 60

    def step(y, h, num, title, state):
        S.rect(cx0, y, cx1 - cx0, h, r=10, fill=T('surface.raised'))
        S.rect(cx0 + .5, y + .5, cx1 - cx0 - 1, h - 1, r=9.5, stroke=T('border.separator'))
        c = {'ok': T('status.ok'), 'warn': T('status.warning'), 'todo': T('text.tertiary')}[state]
        if state == 'ok':
            S.circle(cx0 + 30, y + 28, 12, fill=c)
            g_check(S, cx0 + 30, y + 28, 12, T('surface.raised'))
        else:
            S.circle(cx0 + 30, y + 28, 11.25, stroke=c, sw=1.6)
            S.text(cx0 + 30, y + 32.5, str(num), size=13, fill=c, weight=700, anchor='middle')
        S.text(lx, y + 32.5, title, size=13.5, fill=T('text.primary'), weight=700)

    y = py0 + 256
    step(y, 92, 1, 'Add a repository', 'ok')
    button(S, T, cx1 - 20 - (tw('Choose Folder…', 12.5, 500) + 24), y + 28, 'Choose Folder…')
    g_check_circle(S, lx + 6, y + 56, 13, T('status.ok'))
    w = S.text(lx + 20, y + 60.5, '~/dev/api', size=12, fill=T('text.primary'), mono=True)
    S.text(lx + 20 + w + 10, y + 60.5, 'Git repository · 6 worktrees', size=12.5, fill=T('text.secondary'))
    S.text(lx, y + 80, 'Only folders you choose here are ever read.', size=12, fill=T('text.tertiary'))
    y += 92 + 12
    step(y, 70, 2, 'git', 'ok')
    g_check_circle(S, lx + 6, y + 51, 13, T('status.ok'))
    w = S.text(lx + 20, y + 55.5, 'git 2.50.1 (Apple Git-155)', size=12.5, fill=T('text.primary'))
    S.text(lx + 20 + w + 8, y + 55.5, 'at /usr/bin/git', size=12.5, fill=T('text.tertiary'))
    y += 70 + 12
    step(y, 196, 3, 'GitHub', 'warn')
    S.text(lx + tw('GitHub', 13.5, 700) + 8, y + 32.5, 'optional — used only to show issues', size=12.5, fill=T('text.tertiary'))
    S.text(cx1 - 20, y + 32.5, 'Skip', size=12.5, fill=T('text.link'), weight=500, anchor='end')
    g_person_badge(S, lx + 7, y + 56, 14, T('status.warning'), ok=False, badge_c=T('status.warning'), knock=T('surface.raised'))
    S.text(lx + 22, y + 60.5, 'Not logged in to GitHub CLI', size=12.5, fill=T('status.warning'), weight=600)
    S.text(lx, y + 88, 'Run this in Terminal, then check again:', size=12.5, fill=T('text.primary'))
    S.rect(lx, y + 98, 250, 32, fill=T('surface.canvas'), r=7, stroke=T('border.strong'))
    S.text(lx + 12, y + 118.5, '$ gh auth login', size=12.5, fill=T('text.primary'), mono=True)
    button(S, T, lx + 258, y + 114, 'Copy', glyph=g_copy)
    button(S, T, lx, y + 160, 'Check Again', glyph=g_refresh)
    g_lock(S, lx + 134, y + 160, 11, T('text.tertiary'))
    S.text(lx + 146, y + 164.2, 'Overgrove never asks for or stores tokens.', size=12, fill=T('text.tertiary'))
    y += 196 + 20
    S.text(cx0, y + 18, 'Reopen anytime from Help › Setup Assistant.', size=12, fill=T('text.tertiary'))
    bw = tw('Open Repository', 12.5, 600) + 24
    button(S, T, cx1 - bw, y + 14, 'Open Repository', primary=True, h=30)
    S.close_group()
    panel_outline(S, T, px0, PT, px1, py1)
    return finish(S, T)


# ---------------------------------------------------------------- stash, issue, history

def neutral_tile(S, T, cx, cy, s, glyph):
    S.rect(cx - s / 2, cy - s / 2, s, s, r=s * .27, fill=T('text.secondary'), op=.14)
    glyph(S, cx, cy, s * .62, T('text.secondary'))


def chip(S, T, x, cy, label, glyph=None, mono=False):
    w = tw(label, 11, 500, mono=mono) + 14 + (14 if glyph else 0)
    S.rect(x, cy - 9, w, 18, r=5, fill=T('text.tertiary'), op=.16)
    tx = x + 7
    if glyph:
        glyph(S, tx + 5, cy, 10, T('text.secondary'))
        tx += 14
    S.text(tx, cy + 3.8, label, size=11, fill=T('text.secondary'), weight=500, mono=mono)
    return w


def footer_buttons(S, T, x0, x1, y1, buttons):
    h = 48
    footer(S, T, x0, x1, y1, h)
    x = x0 + 12
    for label, glyph in buttons:
        x += button(S, T, x, y1 - h / 2, label, glyph=glyph) + 8


STASH_FILES = [('M', 'internal/ratelimit/window.go', 12, 3, False), ('M', 'internal/http/middleware.go', 5, 1, False),
               ('A', 'docs/rate-limit-notes.md', 14, 0, True), ('M', 'go.sum', 2, 2, False)]


def stash_detail(S, T):
    x0, x1, y0, y1 = detail_frame(S, T)
    panel_header(S, T, x0, y0, x1)
    neutral_tile(S, T, x0 + 22, y0 + PH / 2, 20, g_tray)
    S.text(x0 + 40, y0 + PH / 2 + 4.4, 'stash@{0}', size=13, fill=T('text.primary'), weight=600, mono=True)
    S.text(x1 - 14, y0 + PH / 2 + 4.2, '1 hour ago', size=12, fill=T('text.tertiary'), anchor='end')
    y = y0 + PH + 14
    for ln in wrap('WIP on feat/42-rate-limit: a91f3c2 feat(ratelimit): add sliding window limiter', 13, x1 - x0 - 28, 500):
        S.text(x0 + 14, y + 12, ln, size=13, fill=T('text.primary'), weight=500)
        y += 19
    y += 10
    ch = 3 * 26 + 12
    card(S, T, x0 + 10, x1 - 10, y, ch)
    cx0, cx1 = x0 + 24, x1 - 22
    yy = y + 6
    def base_draw(x, cy):
        w = S.text(x, cy + 4.2, 'a91f3c2', size=12, fill=T('text.link'), mono=True)
        S.text(x + w + 8, cy + 4.3, fit('feat(ratelimit): add sliding window limiter', 12, cx1 - x - w - 8), size=12, fill=T('text.primary'))
    yy = kv_row(S, T, cx0, cx1, yy, 'Base commit', draw=base_draw, kx=92)
    def branch_draw(x, cy):
        w = S.text(x, cy + 4.3, 'feat/42-rate-limit', size=12, fill=T('text.primary'))
        S.text(x + w + 6, cy + 4.2, '(from message)', size=11.5, fill=T('text.tertiary'))
    yy = kv_row(S, T, cx0, cx1, yy, 'Branch', draw=branch_draw, kx=92)
    yy = kv_row(S, T, cx0, cx1, yy, 'Includes', 'index · working tree · untracked', kx=92)
    y += ch + 10
    h = 32 + len(STASH_FILES) * 26 + 6
    card(S, T, x0 + 10, x1 - 10, y, h)
    S.text(x0 + 24, y + 20.5, 'Files', size=12, fill=T('text.primary'), weight=600)
    chip_count(S, T, x0 + 24 + tw('Files', 12, 600) + 8 + 18, y + 16, len(STASH_FILES))
    stat(S, T, x1 - 22, y + 16, sum(f[2] for f in STASH_FILES), sum(f[3] for f in STASH_FILES))
    S.line(x0 + 11, y + 31.5, x1 - 11, y + 31.5, T('border.separator'))
    fy = y + 35
    for k, pth, a, r_, from_untracked in STASH_FILES:
        fcy = fy + 13
        kind_badge(S, T, x0 + 20, fcy, k)
        sw_ = stat(S, T, x1 - 22, fcy, a, r_)
        extra = 0
        if from_untracked:
            g_question_circle(S, x1 - 22 - sw_ - 14, fcy, 13, T('status.untracked'))
            extra = 22
        path_text(S, T, x0 + 44, fcy, pth, x1 - x0 - 44 - 30 - sw_ - extra, fs=12.5)
        fy += 26
    y += h + 8
    g_question_circle(S, x0 + 22, y + 10, 12, T('status.untracked'))
    S.text(x0 + 34, y + 14, 'From the stash’s untracked-files commit', size=11.5, fill=T('text.tertiary'))
    footer_buttons(S, T, x0, x1, y1, [('Copy Ref', g_copy)])
    detail_end(S, T)


def issue_detail(S, T):
    x0, x1, y0, y1 = detail_frame(S, T)
    panel_header(S, T, x0, y0, x1)
    g_number_circle(S, x0 + 22, y0 + PH / 2, 15, T('text.secondary'))
    w = S.text(x0 + 36, y0 + PH / 2 + 4.6, '#42', size=13, fill=T('text.secondary'), weight=600)
    S.text(x0 + 36 + w + 7, y0 + PH / 2 + 4.6, fit('Rate limit per tenant', 13, x1 - (x0 + 43 + w) - 36, 600), size=13, fill=T('text.primary'), weight=600)
    g_ellipsis(S, x1 - 20, y0 + PH / 2, 15, T('text.secondary'))
    y = y0 + PH + 12
    # state line
    sw = tw('Open', 11.5, 600) + 30
    S.rect(x0 + 14, y + 2, sw, 20, r=10, fill=T('text.tertiary'), op=.16)
    g_number_circle(S, x0 + 27, y + 12, 11, T('text.secondary'))
    S.text(x0 + 36, y + 16.2, 'Open', size=11.5, fill=T('text.primary'), weight=600)
    S.text(x0 + 14 + sw + 10, y + 16.2, 'updated 3h ago · opened by Jordan Lee', size=12, fill=T('text.tertiary'))
    y += 34
    ch = 3 * 26 + 12
    card(S, T, x0 + 10, x1 - 10, y, ch)
    cx0, cx1 = x0 + 24, x1 - 22
    yy = y + 6
    def labels_draw(x, cy):
        xx = x
        for lab in ('type:feature', 'area:api', 'p1'):
            xx += chip(S, T, xx, cy, lab) + 5
    yy = kv_row(S, T, cx0, cx1, yy, 'Labels', draw=labels_draw)
    def assignee_draw(x, cy):
        avatar(S, T, x + 8, cy, 'AK', d=17)
        S.text(x + 22, cy + 4.3, '@alexkim', size=12.5, fill=T('text.primary'))
    yy = kv_row(S, T, cx0, cx1, yy, 'Assignees', draw=assignee_draw)
    yy = kv_row(S, T, cx0, cx1, yy, 'Milestone', 'v0.5.0')
    y += ch + 10
    rows = [('wt', 'feat/42-rate-limit', 'worktree · 42-rate-limit'), ('remote', 'origin/feat/42-rate-limit', 'remote branch'),
            ('commit', 'a91f3c2', 'feat(ratelimit): add sliding window limiter'), ('commit', '7d20e18', 'test(ratelimit): cover burst and refill cases')]
    h = 32 + len(rows) * 28 + 6
    card(S, T, x0 + 10, x1 - 10, y, h)
    S.text(x0 + 24, y + 20.5, 'Linked', size=12, fill=T('text.primary'), weight=600)
    chip_count(S, T, x0 + 24 + tw('Linked', 12, 600) + 8 + 18, y + 16, len(rows))
    S.line(x0 + 11, y + 31.5, x1 - 11, y + 31.5, T('border.separator'))
    ry = y + 35
    for kind, name, sub in rows:
        cy = ry + 14
        if kind == 'wt':
            tile(S, T, x0 + 30, cy, 1, 18)
            w = S.text(x0 + 46, cy + 4.3, name, size=12.5, fill=T('text.primary'), weight=500)
            S.text(x0 + 46 + w + 8, cy + 4.2, fit(sub, 11.5, x1 - (x0 + 54 + w) - 22), size=11.5, fill=T('text.tertiary'))
        elif kind == 'remote':
            g_globe(S, x0 + 30, cy, 13, T('text.secondary'))
            w = S.text(x0 + 46, cy + 4.3, name, size=12.5, fill=T('text.primary'))
            S.text(x0 + 46 + w + 8, cy + 4.2, fit(sub, 11.5, x1 - (x0 + 54 + w) - 22), size=11.5, fill=T('text.tertiary'))
        else:
            S.circle(x0 + 30, cy, 8, fill=T.avatar(av_idx('AK')))
            S.circle(x0 + 30, cy, 8.8, stroke=T.lane(1), sw=1.8)
            S.text(x0 + 30, cy + 2.7, 'AK', size=7.5, fill=T('avatar.initials'), weight=700, anchor='middle')
            w = S.text(x0 + 46, cy + 4, name, size=11.5, fill=T('text.link'), mono=True)
            S.text(x0 + 46 + w + 8, cy + 4.3, fit(sub, 12.5, x1 - (x0 + 54 + w) - 22), size=12.5, fill=T('text.primary'))
        ry += 28
    y += h + 12
    g_globe(S, x0 + 22, y + 10, 12, T('text.tertiary'))
    for i, ln in enumerate(wrap('The issue body is not shown in Overgrove. Open it in your browser to read or reply.', 11.5, x1 - x0 - 50)):
        S.text(x0 + 34, y + 14 + i * 16, ln, size=11.5, fill=T('text.tertiary'))
    footer_buttons(S, T, x0, x1, y1, [('Open in Browser', None), ('Copy URL', g_copy)])
    detail_end(S, T)


HISTORY = [
    ('a91f3c2', 'feat(ratelimit): add sliding window limiter', 'AK', '2h', 1, 38, 4, True, None),
    ('47b2e9a', 'fix(http): set server read and write timeouts', 'MP', '4d', 1, 12, 3, False, None),
    ('a0f4d62', 'feat(auth): verify JWT audience claim', 'AK', '5d', 0, 9, 2, False, None),
    ('2e6f9a3', 'feat: request id middleware', 'AK', '4w', 0, 18, 2, False, 'internal/mw/middleware.go'),
    ('c4a8e17', 'chore: project layout', 'JL', '4w', 0, 24, 0, False, None),
]


def history_panel(S, T, selected=0):
    x0, x1, y0, y1 = CX0, CX1, PT, PB
    panel(S, T, x0, y0, x1, y1, 'hpclip')
    S.open_group(clip='hpclip')
    S.rect(x0, y0, x1 - x0, y1 - y0, fill=T('surface.canvas'))
    panel_header(S, T, x0, y0, x1, h=44)
    cy = y0 + 22
    x = x0 + 12
    x += back_button(S, T, x, cy)
    x += S.text(x, cy + 4.6, 'History of', size=13, fill=T('text.secondary'), weight=500) + 8
    mono_path(S, T, x, cy, 'internal/http/middleware.go')
    tx = x1 - 14 - 32
    toggle(S, T, tx, cy, on=True)
    S.text(tx - 8, cy + 4.3, 'Follow renames', size=12, fill=T('text.primary'), anchor='end')
    hy = y0 + 44
    S.rect(x0, hy, x1 - x0, CH, fill=T('surface.panel-header'))
    S.line(x0, hy + CH - .5, x1, hy + CH - .5, T('border.separator'))
    cols = {'node': (x0, x0 + 44), 'sha': (x0 + 44, x0 + 120), 'message': (x0 + 120, x1 - 250), 'author': (x1 - 250, x1 - 148),
            'date': (x1 - 148, x1 - 96), 'changes': (x1 - 96, x1)}
    for k, lab in (('sha', 'Commit'), ('message', 'Message'), ('author', 'Author'), ('date', 'Date'), ('changes', 'This file')):
        a, b = cols[k]
        S.text(a + 12, hy + 18, lab, size=11, fill=T('text.tertiary'), weight=500)
        if k != 'changes':
            S.line(b - .5, hy + 8, b - .5, hy + CH - 8, T('border.strong'))
    by0 = hy + CH
    nx = x0 + 24
    rowy = lambda r: by0 + r * ROW + ROW / 2
    # selection
    sel_lane = HISTORY[selected][4]
    S.rect(x0, rowy(selected) - ROW / 2, x1 - x0, ROW, fill=T.lane(sel_lane), op=T_val('graph.selection-opacity'))
    S.rect(x0, rowy(selected) - ROW / 2, 3, ROW, fill=T.lane(sel_lane))
    # timeline
    S.line(nx, rowy(0), nx, rowy(len(HISTORY) - 1), T('border.strong'), sw=2)
    for i, (sha, subj, au, dt, ln, a, r_, ai, renamed) in enumerate(HISTORY):
        y = rowy(i)
        is_sel = i == selected
        S.circle(nx, y, 12, fill=T('surface.canvas') if not is_sel else T('surface.canvas'))
        S.circle(nx, y, 8.75, fill=T.avatar(av_idx(au)))
        S.text(nx, y + 3, au, size=8.5, fill=T('avatar.initials'), weight=700, anchor='middle')
        S.circle(nx, y, 10, stroke=T.lane(ln), sw=2.5)
        S.text(cols['sha'][0] + 12, y + 4.2, sha, size=11.5, fill=T('text.link' if is_sel else 'text.secondary'), mono=True)
        ma, mb = cols['message']
        maxw = mb - ma - 24 - (36 if ai else 0)
        if renamed:
            subj_w = tw(subj, 13)
            room = maxw - subj_w - 8 - 14
            note = 'renamed from ' + fit(renamed, 11, room - tw('renamed from ', 11, 500), 500, middle=True)
            nw = tw(note, 11, 500) + 14
            w = S.text(ma + 12, y + 4.6, subj, size=13, fill=T('text.primary'))
            S.rect(ma + 12 + w + 8, y - 9, nw, 18, r=5, fill=T('status.ahead'), op=.14)
            S.text(ma + 12 + w + 15, y + 3.8, note, size=11, fill=T('text.secondary'), weight=500)
        else:
            w = S.text(ma + 12, y + 4.6, fit(subj, 13, maxw), size=13, fill=T('text.primary'), weight=500 if is_sel else 400)
            if ai:
                ai_badge(S, T, ma + 12 + w + 8, y)
        S.text(cols['author'][0] + 12, y + 4.3, AUTHORS[au][0], size=12, fill=T('text.secondary'))
        S.text(cols['date'][0] + 12, y + 4.3, dt, size=12, fill=T('text.secondary' if is_sel else 'text.tertiary'))
        stat(S, T, x1 - 18, y, a, r_, fs=12)
    # beginning of history
    ey = rowy(len(HISTORY) - 1) + ROW / 2 + 22
    S.line(x0 + 44, ey, x1 - 18, ey, T('border.separator'))
    lab = 'Beginning of history · created in c4a8e17 as internal/mw/middleware.go'
    lw = tw(lab, 11.5) + 20
    S.rect((x0 + x1) / 2 - lw / 2, ey - 10, lw, 20, fill=T('surface.canvas'))
    S.text((x0 + x1) / 2, ey + 4, lab, size=11.5, fill=T('text.tertiary'), anchor='middle')
    S.close_group()
    panel_outline(S, T, x0, y0, x1, y1)


# ---------------------------------------------------------------- settings (native window)

# The Settings window uses native controls, so it keeps macOS system colors at runtime (ADR-0014).
# These are approximations for the mockup only; they are not design tokens.
NATIVE = {
    'light': dict(backdrop='#d4d8df', window='#ececec', toolbar='#e4e4e4', group='#ffffff', group_border='#dedede', sep='#e6e6e6',
                  label='#1d1d1f', secondary='#6e6e73', tab_sel='#d6d6d6', control='#ffffff', control_border='#cfcfcf',
                  toggle_off='#dedede', title='#4a4a4f'),
    'dark': dict(backdrop='#07080b', window='#232325', toolbar='#2c2c2e', group='#2c2c2e', group_border='#3a3a3c', sep='#3a3a3c',
                 label='#e8e8e6', secondary='#a1a1a6', tab_sel='#3c3c3f', control='#3a3a3c', control_border='#4a4a4c',
                 toggle_off='#48484a', title='#c7c7cc'),
}


def g_gear(S, cx, cy, s, c):  # gearshape
    import math
    r = s / 2
    for k in range(8):
        a = math.pi * k / 4
        S.line(cx + math.cos(a) * r * .55, cy + math.sin(a) * r * .55, cx + math.cos(a) * r * .95, cy + math.sin(a) * r * .95, c, sw=s * .16, cap='round')
    S.circle(cx, cy, r * .58, stroke=c, sw=s * .13)
    S.circle(cx, cy, r * .2, fill=c)


def g_sliders(S, cx, cy, s, c):  # slider.horizontal.3
    r = s / 2
    for i, k in enumerate((-.3, .35, -.05)):
        y = cy - r * .6 + i * r * .6
        S.line(cx - r * .9, y, cx + r * .9, y, c, sw=s * .1, cap='round')
        S.circle(cx + k * r * 2, y, r * .2, fill=c)


def n_toggle(S, N, T, x, cy, on):
    S.rect(x, cy - 10, 36, 20, r=10, fill=T('accent') if on else N['toggle_off'])
    S.circle(x + (26 if on else 10), cy, 8.2, fill='#ffffff')


def n_popup(S, N, x, cy, label, w, dim=False):
    S.rect(x + .5, cy - 11, w - 1, 22, r=6, fill=N['control'], stroke=N['control_border'])
    S.text(x + 10, cy + 4.2, label, size=12.5, fill=N['secondary'] if dim else N['label'])
    g_updown(S, x + w - 12, cy, 11, N['secondary'])


def n_button(S, N, x, cy, label, w=None):
    w = w or tw(label, 12.5) + 24
    S.rect(x + .5, cy - 11, w - 1, 22, r=6, fill=N['control'], stroke=N['control_border'])
    S.text(x + w / 2, cy + 4.2, label, size=12.5, fill=N['label'], anchor='middle')
    return w


def settings_window(S, T, N, wx, wy, ww, wh, tab, cid):
    S.add(f'<rect x="{wx}" y="{wy}" width="{ww}" height="{wh}" rx="12" fill="{N["window"]}" filter="url(#winshadow)"/>')
    S.clip(cid, wx, wy, ww, wh, 12)
    S.open_group(clip=cid)
    S.rect(wx, wy, ww, wh, fill=N['window'])
    S.rect(wx, wy, ww, 78, fill=N['toolbar'])
    S.line(wx, wy + 78.5, wx + ww, wy + 78.5, N['sep'])
    for i, k in enumerate(('close', 'minimize', 'zoom')):
        S.circle(wx + 20 + i * 20, wy + 18, 6, fill=T(f'primitive.color.system-fallback.window-{k}'))
    S.text(wx + ww / 2, wy + 22.5, tab, size=13, fill=N['title'], weight=600, anchor='middle')
    tabs = [('General', g_gear), ('Repositories', g_folder), ('Advanced', g_sliders)]
    tw_ = 92
    tx = wx + ww / 2 - tw_ * len(tabs) / 2
    for name, glyph in tabs:
        on = name == tab
        if on:
            S.rect(tx + 6, wy + 34, tw_ - 12, 40, r=7, fill=N['tab_sel'])
        glyph(S, tx + tw_ / 2, wy + 48, 17, T('accent') if on else N['secondary'])
        S.text(tx + tw_ / 2, wy + 68, name, size=11, fill=N['label'] if on else N['secondary'], anchor='middle')
        tx += tw_
    return wy + 78


def n_group(S, N, x, y, w, rows_h):
    S.rect(x, y, w, rows_h, r=9, fill=N['group'])
    S.rect(x + .5, y + .5, w - 1, rows_h - 1, r=8.5, stroke=N['group_border'])


def settings_general(S, T, N, x, y, w):
    gx, gw = x + 20, w - 40
    y += 20
    n_group(S, N, gx, y, gw, 44)
    S.text(gx + 14, y + 26.5, 'Fetch automatically', size=13, fill=N['label'])
    n_popup(S, N, gx + gw - 14 - 36 - 12 - 134, y + 22, 'Every 10 minutes', 134, dim=True)
    n_toggle(S, N, T, gx + gw - 14 - 36, y + 22, False)
    S.text(gx + 4, y + 62, 'Off by default. Fetch uses your git credential helper or SSH.', size=11.5, fill=N['secondary'])
    y += 84
    n_group(S, N, gx, y, gw, 44)
    S.text(gx + 14, y + 26.5, 'Show full remote URLs', size=13, fill=N['label'])
    n_toggle(S, N, T, gx + gw - 14 - 36, y + 22, False)
    S.text(gx + 4, y + 62, 'Credentials in URLs are always masked.', size=11.5, fill=N['secondary'])
    y += 84
    n_group(S, N, gx, y, gw, 44)
    S.text(gx + 14, y + 26.5, 'Show untracked files', size=13, fill=N['label'])
    n_toggle(S, N, T, gx + gw - 14 - 36, y + 22, True)


def settings_repositories(S, T, N, x, y, w):
    gx, gw = x + 20, w - 40
    y += 20
    rows = [('api', '~/dev/api'), ('overgrove', '~/dev/overgrove')]
    rh = 52
    n_group(S, N, gx, y, gw, rh * len(rows))
    for i, (name, path) in enumerate(rows):
        ry = y + i * rh
        if i:
            S.line(gx + 14, ry + .5, gx + gw - 14, ry + .5, N['sep'])
        g_folder(S, gx + 24, ry + rh / 2, 16, N['secondary'])
        S.text(gx + 42, ry + 22, name, size=13, fill=N['label'], weight=600)
        S.text(gx + 42, ry + 39, path, size=11.5, fill=N['secondary'], mono=True)
        n_button(S, N, gx + gw - 14 - 76, ry + rh / 2, 'Remove', 76)
    y += rh * len(rows) + 14
    n_button(S, N, gx, y + 11, 'Add…', 76)
    S.text(gx + 4, y + 50, 'Overgrove only reads folders you add here.', size=11.5, fill=N['secondary'])


def settings_advanced(S, T, N, x, y, w):
    gx, gw = x + 20, w - 40
    y += 20
    n_group(S, N, gx, y, gw, 96)
    S.text(gx + 14, y + 26.5, 'Git executable', size=13, fill=N['label'])
    bw = tw('Choose…', 12.5) + 24
    n_button(S, N, gx + gw - 14 - bw, y + 22, 'Choose…', bw)
    S.line(gx + 14, y + 44.5, gx + gw - 14, y + 44.5, N['sep'])
    S.text(gx + 14, y + 66, '/usr/bin/git', size=12.5, fill=N['label'], mono=True)
    g_check_circle(S, gx + 20, y + 82, 11, T('status.ok'))
    S.text(gx + 30, y + 86, 'git 2.50.1 (Apple Git-155)', size=11.5, fill=N['secondary'])
    S.text(gx + 4, y + 116, 'Must be an absolute path. Checked with --version when changed.', size=11.5, fill=N['secondary'])
    y += 138
    n_group(S, N, gx, y, gw, 44)
    S.text(gx + 14, y + 26.5, 'Verbose logging', size=13, fill=N['label'])
    n_toggle(S, N, T, gx + gw - 14 - 36, y + 22, False)
    S.text(gx + 4, y + 62, 'Credentials are masked in logs too.', size=11.5, fill=N['secondary'])


def s08(mode):
    T = Theme(mode)
    N = NATIVE[mode]
    cw, chh = 1440, 560
    S = Svg(cw, chh, 'Overgrove — S-08 settings')
    S.defs.append('<filter id="winshadow" x="-20%" y="-20%" width="140%" height="150%">'
                  f'<feDropShadow dx="0" dy="10" stdDeviation="14" flood-color="#000000" flood-opacity="{0.28 if mode == "light" else 0.6}"/></filter>')
    S.rect(0, 0, cw, chh, fill=N['backdrop'])
    ww, wh = 448, 470
    gap = (cw - 3 * ww) / 4
    for i, (tab, fn) in enumerate((('General', settings_general), ('Repositories', settings_repositories), ('Advanced', settings_advanced))):
        wx = gap + i * (ww + gap)
        top = settings_window(S, T, N, wx, 40, ww, wh, tab, f'set{i}')
        fn(S, T, N, wx, top, ww)
        S.close_group()
        S.rect(wx + .5, 40.5, ww - 1, wh - 1, r=11.5, stroke='#00000026' if mode == 'light' else '#ffffff1f')
    return S.render()


# ---------------------------------------------------------------- screens

WIP42 = [('staged', 2), ('unstaged', 3), ('untracked', 2)]
GROUPS42 = [
    ('staged', 'Staged', [('A', 'internal/ratelimit/window.go', 58, 0), ('R', 'internal/http/{noop.go → passthrough.go}', 6, 31)], 64, 31),
    ('unstaged', 'Unstaged', [('M', 'internal/http/middleware.go', 3, 2), ('M', 'cmd/api/main.go', 2, 1), ('D', 'internal/http/noop_limiter.go', 0, 39)], 5, 42),
    ('untracked', 'Untracked', [('?', 'docs/rate-limit.md', None, None), ('?', 'internal/ratelimit/bench_test.go', None, None)], None, None),
]


def s01(mode):
    T = Theme(mode)
    S = window(T, 'Overgrove — S-01 main window')
    toolbar(S, T)
    sidebar(S, T)
    graph_panel(S, T, wip=WIP42, selected='wip')
    wip_detail(S, T, 'feat42', GROUPS42, compare=dict())
    grip(S, T, LX1 + G / 2)
    grip(S, T, CX1 + G / 2, active=True)
    g_resize_cursor(S, CX1 + G / 2 + 1, (PT + PB) / 2 + 34, 18, '#ffffff' if mode == 'dark' else '#1a1f2a', '#000000' if mode == 'dark' else '#ffffff')
    statusbar(S, T)
    return finish(S, T)


def s02(mode):
    T = Theme(mode)
    S = window(T, 'Overgrove — S-02 WIP detail')
    toolbar(S, T, focus='agent')
    sidebar(S, T, focus='agent', selected='wt:agent')
    graph_panel(S, T, wip=[('conflicted', 1), ('staged', 3), ('unstaged', 2), ('untracked', 1)], selected='wip',
                focus_lane=3, focus_idx=3, focus_branch='agent/refactor-logging')
    wip_detail(S, T, 'agent', [
        ('conflicted', 'Conflicted', [('U', 'internal/http/middleware.go', None, None)], None, None),
        ('staged', 'Staged', [('M', 'internal/log/logger.go', 41, 12), ('A', 'internal/log/requestid.go', 19, 0), ('R', 'internal/log/{format.go → encoder.go}', 4, 9)], 64, 21),
        ('unstaged', 'Unstaged', [('M', 'internal/log/logger.go', 8, 2), ('M', 'cmd/api/main.go', 3, 1)], 11, 3),
        ('untracked', 'Untracked', [('?', 'notes/agent-plan.md', None, None)], None, None),
    ], compare=dict(summary='1 commit ahead · 3 behind · 7 files', add=96, rem=30, merge_base='58de0b4'))
    grip(S, T, LX1 + G / 2)
    grip(S, T, CX1 + G / 2)
    statusbar(S, T, ab=None)
    return finish(S, T)


def s03(mode):
    T = Theme(mode)
    S = window(T, 'Overgrove — S-03 commit detail')
    toolbar(S, T)
    sidebar(S, T, selected=None)
    graph_panel(S, T, wip=WIP42, selected=0, dim_non_ai=True, active_chip='ai')
    commit_detail(S, T, 0)
    grip(S, T, LX1 + G / 2)
    grip(S, T, CX1 + G / 2)
    statusbar(S, T)
    return finish(S, T)


def s05(mode):
    T = Theme(mode)
    S = window(T, 'Overgrove — S-05 worktree detail')
    toolbar(S, T, focus='fix57')
    sidebar(S, T, focus='fix57', selected='wt:fix57')
    graph_panel(S, T, wip=[('staged', 1), ('unstaged', 2)], selected=None, focus_lane=2, focus_idx=2, focus_branch='fix/57-token-refresh')
    worktree_detail(S, T, 'fix57')
    grip(S, T, LX1 + G / 2)
    grip(S, T, CX1 + G / 2)
    statusbar(S, T, ab=(1, 0))
    return finish(S, T)


def s10(mode):
    T = Theme(mode)
    S = window(T, 'Overgrove — S-10 diff viewer')
    toolbar(S, T)
    sidebar(S, T, selected=None)
    diff_panel(S, T)
    commit_detail(S, T, 0, sel_file='internal/http/middleware.go')
    grip(S, T, LX1 + G / 2)
    grip(S, T, CX1 + G / 2)
    statusbar(S, T)
    return finish(S, T)


def s11(mode):
    T = Theme(mode)
    S = window(T, 'Overgrove — S-11 changes vs base branch')
    toolbar(S, T)
    WT = WORKTREES[2]
    sidebar(S, T, selected='wt:feat42', delta=8)
    compare_panel(S, T)
    compare_detail(S, T)
    grip(S, T, LX1 + G / 2)
    grip(S, T, CX1 + G / 2)
    statusbar(S, T)
    return finish(S, T)


def s04(mode):
    T = Theme(mode)
    S = window(T, 'Overgrove — S-04 stash detail')
    toolbar(S, T)
    sidebar(S, T, selected='st:0', scroll_px=96, scroll=(0.11, 0.89))
    graph_panel(S, T, wip=WIP42, selected=None)
    stash_detail(S, T)
    grip(S, T, LX1 + G / 2)
    grip(S, T, CX1 + G / 2)
    statusbar(S, T)
    return finish(S, T)


def s06(mode):
    T = Theme(mode)
    S = window(T, 'Overgrove — S-06 issue panel')
    toolbar(S, T)
    sidebar(S, T, selected='is:42', scroll_px=96, scroll=(0.11, 0.89), issue_filter=True)
    graph_panel(S, T, wip=WIP42, selected=None, highlight=0)
    issue_detail(S, T)
    grip(S, T, LX1 + G / 2)
    grip(S, T, CX1 + G / 2)
    statusbar(S, T)
    return finish(S, T)


def s09(mode):
    T = Theme(mode)
    S = window(T, 'Overgrove — S-09 file history')
    toolbar(S, T)
    sidebar(S, T, selected=None)
    history_panel(S, T, selected=0)
    commit_detail(S, T, 0, sel_file='internal/http/middleware.go')
    grip(S, T, LX1 + G / 2)
    grip(S, T, CX1 + G / 2)
    statusbar(S, T)
    return finish(S, T)


def s01_tags(mode):
    T = Theme(mode)
    S = window(T, 'Overgrove — S-01 sidebar TAGS')
    toolbar(S, T)
    sidebar(S, T, selected='tg:v1.4.0', scroll_px=150, scroll=(0.2, 0.95), tags=True)
    graph_panel(S, T, wip=WIP42, selected=0)
    commit_detail(S, T, 0)
    grip(S, T, LX1 + G / 2)
    grip(S, T, CX1 + G / 2)
    statusbar(S, T)
    return finish(S, T)


SCREENS = {
    'main-window': s01,
    's01-tags-sidebar': s01_tags,
    's02-wip-detail': s02,
    's03-commit-detail': s03,
    's05-worktree-detail': s05,
    's10-diff-viewer': s10,
    's11-changes-vs-base': s11,
    's07-onboarding': s07,
    's04-stash-detail': s04,
    's06-issue-panel': s06,
    's08-settings': s08,
    's09-file-history': s09,
}

if __name__ == '__main__':
    out = sys.argv[1] if len(sys.argv) > 1 else '..'
    only = sys.argv[2:] or list(SCREENS)
    for name in only:
        for mode in ('light', 'dark'):
            open(f'{out}/{name}-{mode}.svg', 'w').write(SCREENS[name](mode))
    print('wrote', len(only) * 2, 'files')
