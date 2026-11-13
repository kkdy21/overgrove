# 아트 디렉션 (Art Direction)

> 상태: Accepted (#166) · 관련: [ADR-0014](../adr/0014-panel-theme-and-split-layout.md), [design-tokens.md](design-tokens.md), [screens.md](screens.md), [interaction.md](interaction.md), [mockups.md](mockups.md), [references.md](references.md)

Overgrove 메인 창이 어떻게 보여야 하는지를 수치로 정한다. 색 값의 원본은 [`design/tokens/tokens.json`](../../design/tokens/tokens.json)이고, 이 문서는 그 값을 어떻게 조합하는지 설명한다. 화면별 동작은 [screens.md](screens.md)가 기준이다.

---

## 0. 다시 만든 이유

#159의 첫 목업에 대한 메인테이너 피드백(2026-11-06)과, 그 원인을 정리한다.

| 피드백 | 원인 |
|---|---|
| 왼쪽·오른쪽 패널이 영역으로 보이지 않는다 | 시스템 색 근삿값(`#1e1e1e`, `#2a2a2a`)으로 칠한 평평한 면을 1px 선으로만 나눴다 |
| 영역 크기를 조절할 수 있어 보이지 않는다 | 분할선에 손잡이가 없었고, 스크롤 표시도 없었다 |
| 그래프 색이 흐리다 | 데이터 시각화용 범주형 팔레트(중간 명도, 중간 채도)를 그대로 썼다. 레인 2px, 노드 8px 점이었다 |
| 전체가 GitLens(VS Code)처럼 보인다 | 에디터 회색 면, 제목 뒤에 붙는 인라인 ref 알약, 좁은 그래프 열이 VS Code 확장과 같은 인상을 줬다 |

새 방향은 "어두운 바탕 위에 상자로 나뉜 세 영역, 그 가운데 선명한 레인의 그래프"다. GitKraken이 좋게 느껴지는 성질(분명한 영역, 굵고 선명한 레인, 아바타 노드)을 목표로 하되, **배치 패턴만 참고하고 색 값, 아이콘, 문구는 가져오지 않는다**(HANDOFF 원칙, §11).

---

## 1. 원칙

1. **영역이 먼저 보인다.** 사이드바, 그래프, 상세는 각각 둥근 상자다. 상자 사이의 홈(gutter)이 곧 크기 조절 손잡이다.
2. **그래프가 주인공이다.** 다크 모드에서 그래프 캔버스는 패널 중 가장 어둡고, 레인은 화면에서 가장 선명한 색이다. 다른 UI 요소는 채도를 낮춰 레인과 다투지 않는다.
3. **색은 정보다.** 레인 색은 브랜치의 정체성이다. 사이드바 워크트리 타일, ref 알약, 툴바 포커스 칩, 선택 행에 같은 레인 색을 이어서 쓴다. 그래서 "어느 워크트리가 그래프의 어느 줄인지" 색으로 바로 이어진다.
4. **읽기 전용임을 드러낸다.** 쓰기 버튼은 비활성으로도 두지 않는다. 툴바에는 조회·비교·외부 앱 열기만 있고, 상태바 맨 앞에 `Read-only`를 둔다.
5. **동작은 네이티브, 외형은 자체 테마.** 메뉴, 시트, 팝오버, 설정 창, 포커스 링, 단축키, VoiceOver는 macOS 표준을 따른다. 메인 창의 패널 표면만 자체 테마(Slate)를 쓴다.

## 2. 피할 것

- VS Code Dark+ 계열의 무채색 회색 면과, 1px 선으로만 나눈 평평한 영역
- 2px 레인, 점 노드, 제목 뒤에 이어 붙인 ref 알약
- 다른 제품의 색 값, 아이콘, 로고, 문구, 테마 이름. GitKraken도 포함한다
- 장식용 그라데이션, 유리 효과, 큰 그림자. 깊이는 표면 단계와 1px 테두리로 만든다
- 같은 색에 두 가지 뜻 싣기. 예를 들어 상태 색(staged 초록)을 선택 표시에 쓰지 않는다

---

## 3. 창 구조

기준 크기는 1440×900pt다.

```
 0 ┌──────────────────────────────────────────────────────────────────────────────────────────┐
   │ ●●●  ◧  [▭ api acme ⌃] › [🌳 feat/42-rate-limit ↑2 ⌘J]   Fetch Refresh │ Compare │ Terminal Finder   [⌕ Search … ⌘F] │
52 ├─┬──────────────────┬─┬───────────────────────────────────────────────┬─┬──────────────────────┬─┤
   │ │ ⌕ Filter     ⌥⌘F │ │ 👥 All · Jordan Lee 9 · Alex Kim 8 …  ✦ AI 7 ⋯ │ │ 🌳 feat/42…  Changes|Worktree │ │
   │ ├──────────────────┤ │ Refs │ Graph │ Message        │Author│Date│SHA │ │──────────────────────│ │
   │ │ ˅ WORKTREES    6 │▕│ ⟨42-rate-limit⟩┈┈◌  WIP 2 staged · 3 unstaged │▕│ 7 changed files ▬▬▬  │ │
   │ │ 🌳 main          │▕│ ⟨■ feat/42…⟩───◉  feat(ratelimit): …   AI     │▕│ ┌ Staged 2 ───────┐  │ │
   │ │ 🌳 agent/…  ⚠1 ✎6│ │ ⟨fix/57…⟩──────◉  fix(auth): …               │ │ │ A window.go  +58 │  │ │
   │ │▌🌳 feat/42  ✎7 ↑2│ │ ⟨main⟩─────────•  Merge pull request #51 …    │ │ └──────────────────┘  │ │
   │ │ …                │ │ …                                         ▐  │ │ ┌ Changes vs [main]┐  │ │
   │ │                ▐ │ │                                              │ │ │ Compare with Base…│  │ │
870├─┴──────────────────┴─┴───────────────────────────────────────────────┴─┴──────────────────────┴─┤
   │ 🛡 Read-only · ⟳ Fetched 2 min ago · ↑2 ↓0 · 6 worktrees · ⚠ 1 prunable           gh: @login ✓ │
900└──────────────────────────────────────────────────────────────────────────────────────────┘
     8   sidebar 256      8              graph ≥ 480                     8   detail 344        8
```

| 요소 | 값 | 토큰 |
|---|---|---|
| 툴바 | 높이 52, 배경 `surface.window` | — |
| 상태바 | 높이 30, 배경 `surface.window` | — |
| 홈(gutter) | 패널 사이와 바깥 8 | `size.panel-gap` |
| 패널 | 반경 10, 1px `border.panel` 테두리. 다크는 위 안쪽에 흰색 3.5% 하이라이트 1px, 라이트는 아래로 1px·5% 그림자 | `radius.lg` |
| 패널 머리 | 높이 40, `surface.panel-header`, 아래 1px `border.separator` | `size.panel-header` |
| 사이드바 폭 | 기본 256, 최소 220, 최대 420 | `size.sidebar-width-*` |
| 상세 폭 | 기본 344, 최소 300, 최대 560 | `size.detail-width-*` |
| 그래프 폭 | 최소 480, 나머지를 모두 차지 | `size.graph-width-min` |
| 창 최소 | 1040×600. 패널을 접으면 그만큼 줄어든다 | `size.window-min-*` |

### 3.1 표면 단계

다크 모드에서는 바깥이 가장 어둡고, 안으로 들어갈수록 한 단계씩 밝아진다. 그래프 캔버스만 예외로 패널보다 한 단계 어둡다. 레인이 가장 선명하게 보이도록 하기 위해서다.

| 토큰 | 다크 | 라이트 | 쓰임 |
|---|---|---|---|
| `surface.window` | `#0e1116` | `#e3e6ec` | 툴바, 홈, 상태바 |
| `surface.canvas` | `#14181e` | `#ffffff` | 그래프와 diff 본문 |
| `surface.panel` | `#191d24` | `#f9fafc` | 사이드바·상세 본문 |
| `surface.panel-header` | `#1d2229` | `#f3f5f9` | 패널 머리, 열 머리, 상세 하단 고정 영역 |
| `surface.raised` | `#21252e` | `#eef0f4` | 패널 안의 카드 |
| `surface.selection` | `#252f3c` | `#dee7f4` | 사이드바·상세 목록의 선택 행 |

### 3.2 분할선

- **홈 전체(폭 8pt)가 잡는 영역이다.** 가운데에 4×28pt 손잡이 캡슐(`surface.splitter-grip`)을 둔다.
- 포인터를 올리거나 끄는 동안 손잡이는 `surface.splitter-grip-active`(액센트), 홈은 액센트 10%로 칠한다. 커서는 `resizeLeftRight`이고, 최소·최대 폭에 닿으면 한쪽 방향 커서로 바꾼다.
- 더블클릭하면 기본 폭으로 돌아간다.
- 사이드바와 상세는 최소 폭보다 40pt 넘게 더 끌면 **접힌다.** 다시 열 때는 툴바의 사이드바 버튼, `⌃⌘S`(사이드바), `⌥⌘0`(상세)을 쓴다. 그래프 패널은 접히지 않는다.
- 패널 폭과 접힘 상태는 저장소마다 기억한다.
- 창 크기가 바뀌면 그래프가 먼저 늘고 준다. 그래프가 최소 폭에 닿으면 상세, 그다음 사이드바가 최소 폭까지 줄어든다.
- 상세 규칙은 [interaction.md §2.1](interaction.md#21-패널-크기-조절과-스크롤)에 있다.

### 3.3 스크롤

- 세 패널은 **각자 따로** 스크롤한다. 패널 머리와 그래프 열 머리는 고정이다.
- 사이드바 섹션 머리는 스크롤할 때 패널 위쪽에 붙는다(sticky).
- 스크롤바는 macOS 오버레이 스타일(폭 5pt, `surface.scrollbar-thumb`)이다. 시스템 설정이 "항상"이면 항상 보인다. 목업에는 스크롤 위치를 보여 주려고 썸을 그렸다.
- 그래프가 12레인(`size.graph-max-lanes-visible`)을 넘으면 Graph 열 안에서만 가로로 스크롤한다.
- 상세 패널 아래의 비교 카드는 고정이고, 그 위의 내용만 스크롤한다.

### 3.4 툴바

| 위치 | 요소 |
|---|---|
| 왼쪽 | 사이드바 토글, 저장소 전환 메뉴(`api` + 소유자 `acme`), `›`, **포커스 워크트리 칩**(레인 색 14% 채움 + 45% 테두리, 워크트리 타일, 브랜치 이름, `↑n`, `⌘J`) |
| 가운데 | `Fetch`, `Refresh` │ `Compare` │ `Terminal`, `Finder`. 아이콘 17pt 위에 라벨 10.5pt를 둔다(NSToolbar의 icon-and-label 모드). 그래프 패널 가운데에 맞춘다 |
| 오른쪽 | 검색 필드. 상세 패널 폭에 맞춘다. 자리 표시 문구 `Search commits, authors, refs, #issues`, 오른쪽에 `⌘F` 키 표시 |

`Terminal`과 `Finder`는 포커스 워크트리에 대해 워크트리 컨텍스트 메뉴의 `Open in Terminal`, `Reveal in Finder`와 같은 동작이다(보안 조건은 [interaction.md §5](interaction.md#5-컨텍스트-메뉴)). Pull, Push, Commit, Branch, Stash 버튼은 없다.

### 3.5 상태바

왼쪽부터 `🛡 Read-only`(`status.ok`) · 마지막 fetch · 포커스 워크트리의 `↑n ↓n` · 워크트리 수 · `⚠ n prunable`(있을 때)를 두고, 오른쪽 끝에 gh 상태를 둔다. 구분점은 `text.quaternary` 지름 3pt 점이다.

- 모든 필드는 한 줄이고, 줄일 때는 가운데를 자른다(#575). 창이 좁아지면 마지막 fetch가 먼저, 그다음 `↑n ↓n`이 줄어든다. 각각 앞뒤를 읽을 만큼(56pt, 56pt)은 남긴다. Read-only, 워크트리 수, prunable, gh는 줄이지 않는다.
- 눌러서 여는 필드(`Fetch failed — Details`, gh)는 공용 호버 버튼(둥근 `surface.hover`)과 손가락 커서로 정적인 글자와 구별한다. 글자 위치는 다른 필드와 같다.

---

## 4. 색

### 4.1 Slate: 표면과 텍스트

표면, 테두리, 텍스트는 모두 하나의 차가운 무채색 단계 `primitive.color.slate.*`(OKLCH 색상각 262°, 채도 0.003~0.02)에서 고른다. 완전한 회색보다 약간 푸른 기가 있어 레인 색과 잘 어울리고, VS Code의 중성 회색과 구별된다.

| 텍스트 | 다크 | 라이트 | 쓰임 | 최저 대비 |
|---|---|---|---|---|
| `text.primary` | `#e7eaef` | `#191d24` | 제목, 파일 이름, 커밋 제목 | 11.2 / 13.6 |
| `text.secondary` | `#b0b6c0` | `#4a505b` | 작성자, 경로 앞부분, 개수 | 6.6 / 6.5 |
| `text.tertiary` | `#888e99` | `#666c78` | SHA, 시각, 열 머리, 경로 꼬리 | 4.66 / 4.62 (선택 행 제외) |
| `text.quaternary` | `#5e636e` | `#9399a2` | 자리 표시 문구, 비활성. 필요한 정보에는 쓰지 않는다 | — |

`surface.selection` 위에서는 `text.tertiary` 대신 `text.secondary`를 쓴다(4.5:1을 넘기기 위해).

### 4.2 액센트: Grove

앱 아이콘의 숲색에서 가져온 초록이다. 다크 `#43d59a`(`forest.400`), 라이트 `#0e764a`(`forest.700`).

- 쓰는 곳: 키보드 포커스 링, HEAD 링, 고른 칩, 주 버튼, 활성 분할선 손잡이, 토글, WIP 행 틴트, 포커스 워크트리 표시 점
- 쓰지 않는 곳: 목록 선택 행(→ `surface.selection`), 상태 표시(→ `status.*`)
- 앱의 AccentColor로 등록한다. 사용자가 시스템 설정에서 액센트 색을 직접 골랐으면(Multicolor가 아니면) macOS가 그 색으로 바꾼다.

### 4.3 레인 팔레트

| 인덱스 | 이름 | 다크 | 라이트 | 알약 글자(다크 / 라이트) |
|---|---|---|---|---|
| 0 | azure | `#43acfc` | `#0e71b0` | slate.950 / 흰색 |
| 1 | jade | `#25df90` | `#15945e` | slate.950 / slate.950 |
| 2 | violet | `#b074fb` | `#7d2fc8` | slate.950 / 흰색 |
| 3 | coral | `#fc6764` | `#d7152c` | slate.950 / 흰색 |
| 4 | aqua | `#27dee6` | `#148b90` | slate.950 / slate.950 |
| 5 | amber | `#fda858` | `#bf7012` | slate.950 / slate.950 |
| 6 | magenta | `#f75cc7` | `#bf1e94` | slate.950 / 흰색 |
| 7 | yellow | `#f7dc27` | `#a59316` | slate.950 / slate.950 |

- **성격.** 다크 캔버스 위에서 형광에 가까운 고채도·고명도 색이다. OKLCH에서 색상마다 명도를 따로 정했다(노랑 0.89, 보라 0.68). 같은 명도로 맞추면 노랑은 탁해지고 보라는 묻히기 때문이다. 채도는 sRGB 한계의 96%까지 쓴다.
- **순서.** 이웃한 레인(i, i+1)이 항상 색상환에서 멀리 떨어지도록 배치했다. 주 브랜치는 보통 레인 0(azure)에 온다. 순서는 정상 시각과 제1·2색각 이상 시뮬레이션에서 이웃 간 최소 거리를 최대로 하는 순열 탐색으로 골랐다.
- **검증.** 모든 레인이 캔버스 대비 3:1 이상(다크 최저 5.7, 라이트 최저 3.1)이다. 이웃 레인의 OKLab 거리는 정상 시각 18.9 이상, 제1·2색각 이상 14.4 이상이다. 수치 표는 [design-tokens.md §5.1](design-tokens.md#51-그래프-레인-팔레트)에 있고, `design/mockups/generator/colorcheck.py`로 다시 확인한다.
- **색에만 의존하지 않는다.** 레인은 위치(열)와 ref 알약 이름이 함께 구분한다. 제3색각 이상에서 0-1(azure-jade)은 가깝다(ΔE 6.0). 위치로 구분되므로 허용한다.

### 4.4 상태 색과 diff

상태 색은 [design-tokens.md §3.2](design-tokens.md#32-상태-색)의 의미를 그대로 두고, 새 표면에서 다시 검증한 값으로 바꿨다. 파일 종류 배지(A/M/D/R/U/?)는 16pt 둥근 사각형을 상태 색으로 채우고 글자는 `on-status.*`(흰색 또는 `slate.950` 중 대비가 큰 쪽)로 쓴다. 옅은 틴트 위에 상태 색 글자를 쓰면 light 모드에서 4.5:1을 넘지 못하기 때문이다. diff 배경은 상태 색을 캔버스에 섞은 값이다(줄 13%/10%, 단어 30%/24%, 다크/라이트).

---

## 5. 그래프

### 5.1 열

| 열 | 기본 폭 | 범위 | 내용 |
|---|---|---|---|
| Refs | 172 | 96~280 | ref 알약 하나 + `+n` 칩, 노드까지 연결선 |
| Graph | 레인 수 × 20 + 14 | 레인에 맞춤 | 레인, 간선, 노드 |
| Message | 나머지 | 최소 200 | 커밋 제목 + AI 배지 |
| Author | 108 | 72~200 | 작성자 이름(`text.secondary`) |
| Date | 52 | 44~120 | 상대 시각(`text.tertiary`) |
| SHA | 72 | 64~96 | 짧은 SHA(`typography.mono-small`, `text.tertiary`) |

- 열 머리는 높이 28, `surface.panel-header`, 11pt Medium, Title Case다. 열 사이 구분선(1×12pt, `border.strong`)이 폭 조절 손잡이다.
- 패널 머리 오른쪽 `⋯` 메뉴에서 Author, Date, SHA 열을 숨기거나 보인다. Refs, Graph, Message는 숨길 수 없다.
- 패널이 좁아져 Message가 200 아래로 내려가면, 그릴 때만 Refs와 Author를 차례로 최소 폭까지 줄인다. 그래도 모자라면 Date, SHA 순서로 숨긴다. 저장한 폭과 `⋯` 메뉴의 표시 여부는 그대로라 패널을 넓히면 돌아온다(#574).
- Message 칸은 남는 폭만 쓰고 넘치면 잘린다. AI 배지나 이슈 알약이 있어도 Author·Date·SHA는 다른 행과 같은 자리에 있다.
- 작성자 칩 줄이 패널보다 길면 끝 16pt를 흐리게 하고 `⋯` 앞에 8pt를 둔다.

### 5.2 행

- 높이 30(`size.row-graph`).
- 선택 행: 그 커밋 레인 색 16%(`graph.selection-opacity`) + 왼쪽 3pt 레인 색 막대.
- WIP 행: `surface.wip-row`(액센트 7~9%). 선택하면 왼쪽 3pt 액센트 막대.
- 포인터 아래 행: `surface.hover`.
- 작성자·AI 칩으로 거른 상태에서는 일치하지 않는 행을 40%로 흐린다. 숨기지 않으므로 그래프 모양은 그대로다.

### 5.3 레인과 간선

- 레인 간격 20(`size.graph-lane-width`), 선 굵기 3(`size.graph-edge`), 둥근 끝.
- **분기 간선.** 자식 레인을 따라 내려오다가 부모 바로 위 행에서 부모 레인으로 S자 곡선을 그리며 들어간다. 색은 자식 레인 색이다.
- **병합 간선.** 병합 노드에서 S자 곡선으로 나가 다음 행에서 부모 레인에 닿고, 그 레인을 따라 내려간다. 색은 부모(합쳐진 브랜치) 레인 색이다.
- 곡선은 한 행 높이에 걸친 3차 베지어이고, 제어점은 양 끝에서 세로로 55% 지점이다.

### 5.4 노드

| 노드 | 모양 | 크기 |
|---|---|---|
| 일반 커밋 | 작성자 이니셜 아바타(작성자 색, 흰 이니셜 8.5pt Bold) + 레인 색 링 2.5pt | 바깥 지름 22 |
| 병합 커밋 | 레인 색 원 | 지름 10 |
| 포커스 워크트리의 HEAD | 일반 노드 바깥 2pt 간격에 액센트 링 1.75pt | 바깥 지름 30 |
| WIP | 점선 원(`graph.wip-node`) + 연필. HEAD까지 점선 | 지름 18 |

- 모든 노드 둘레에 캔버스 색 후광 2pt(`graph.node-ring`)를 둘러 뒤로 지나가는 선과 떨어뜨린다.
- 아바타 색은 `color.avatar.(FNV-1a(소문자 이메일) mod 8)`이다. 네트워크 아바타(Gravatar, GitHub 프로필)는 쓰지 않는다. 이메일 해시를 외부로 보내지 않기 위해서다.
- WIP 노드는 레인 색을 쓰지 않는다. 아직 커밋이 아님을 모양과 색으로 구분한다.

### 5.5 ref 알약

높이 18, 반경 5, 11pt Medium. 한 행에 알약 하나를 보이고, 나머지는 `+n` 칩(툴팁에 전체 목록)으로 접는다. 고르는 순서는 포커스 워크트리 브랜치 → 로컬 브랜치 → 원격 브랜치 → 태그다. 알약 오른쪽 끝에서 노드까지 1.5pt 연결선(레인 색 55%, `graph.ref-connector-opacity`)을 긋는다.

| 종류 | 모양 | 글자 |
|---|---|---|
| 포커스 워크트리가 체크아웃한 브랜치 | 레인 색 채움 + `tree` | `graph.on-lane.*` |
| 다른 워크트리가 체크아웃한 브랜치 | 레인 색 20% 채움 + 75% 테두리 + `tree` | `text.primary` |
| 로컬 브랜치 | 레인 색 20% 채움 + 75% 테두리 | `text.primary` |
| 로컬과 같은 커밋의 같은 이름 원격 | 위 로컬 알약 끝에 `network` | 같음 |
| 원격 브랜치만 | 레인 색 75% 테두리 + 앞에 `network` | `text.secondary` |
| 태그 | `text.tertiary` 16% 채움 + `tag` | `text.secondary` |
| detached HEAD 워크트리 | `text.tertiary` 테두리 + `tree` + 폴더 이름 | `text.secondary` |
| WIP 행 | `graph.wip-node` 점선 테두리 + 빈 `tree` + 워크트리 폴더 이름 | `text.secondary` |

---

## 6. 사이드바

- **머리.** 필터 필드(높이 24, 반경 6, `⌥⌘F`).
- **섹션 머리.** 높이 30. 접기 화살표 + 10.5pt Bold 대문자(자간 0.7pt, `text.tertiary`) + 오른쪽 개수 칩(높이 16, 반경 8).
- **WORKTREES 행.** 두 줄, 높이 46(`size.row-worktree`).
  - 왼쪽: 워크트리 타일 22pt(레인 색 18% 채움 + 레인 색 `tree`). 이 색이 그래프의 같은 브랜치 레인과 같다. detached와 prunable은 중립 타일.
  - 첫 줄: 브랜치 이름(13pt, 포커스면 Semibold) + 오른쪽 배지(정보 구조 §4.3의 우선순위)
  - 둘째 줄: 경로(11.5pt, `text.tertiary`, 홈은 `~`). main 워크트리는 `main worktree` 태그 + 경로. prunable은 `path missing`을 `status.prunable`로.
  - **포커스 표시:** 타일 오른쪽 위 지름 8pt 액센트 점(패널 색 테두리 2pt).
  - **선택:** `surface.selection` + 레인 색 55% 테두리, 반경 8, 좌우 6pt 안쪽.
- **나머지 섹션.** 한 줄, 높이 28. 체크아웃된 로컬 브랜치 오른쪽 끝에 레인 색 `tree`. REMOTE 브랜치 행 오른쪽에 마지막 커미터 아바타 16pt와 상대 시각.

## 7. 상세 패널

- **머리.** 높이 40. 대상 표시(워크트리 타일, 또는 커밋 노드와 같은 아바타 링) + 제목 13pt Semibold + 오른쪽 세그먼트(`Changes | Worktree`) 또는 `⋯`.
- **카드.** `surface.raised`, 반경 8, 1px `border.separator`, 좌우 10pt 안쪽. 카드 머리 32(상태 심볼 + 이름 12pt Semibold + 개수 칩 + 오른쪽 `+n −m`), 파일 행 26.
- **변경 막대.** WIP 상세 위쪽에 `n changed files`와 추가·삭제 비율 막대(높이 6, 초록·빨강).
- **비교 카드(하단 고정).** S-02, S-05 아래에 고정한다. `Changes vs [main ▾]`, `n commits ahead · n behind · n files`, `+n −m`, 기준 커밋, `Compare with Base…`(액센트 버튼, `⌘⇧B`). 액센트 7% 채움 + 35% 테두리. 커밋 작성 영역이 없는 읽기 전용 앱에서 S-11로 들어가는 입구다.

## 8. 타이포그래피

글꼴은 SF Pro(Text 광학 크기)와 SF Mono다.

| 용도 | 크기·굵기 | 토큰 |
|---|---|---|
| 커밋 제목, 파일 이름 | 13 / 12.5 Regular·Medium | `typography.body` |
| 패널 제목, 상세 제목 | 13 Semibold | `typography.body-emphasized` |
| 커밋 상세 제목 | 15 Semibold | `typography.title` |
| 메타데이터 | 12 Regular | `typography.callout` |
| 섹션 머리 | 10.5~11 Bold, 대문자, 자간 0.06em | `typography.section-header` |
| 열 머리, 카드 머리 라벨 | 11 Medium, Title Case | `typography.column-header` |
| 알약, 칩 | 11 / 10.5 Medium·Semibold | `typography.pill` |
| 아바타 이니셜 | 8.5 Bold(노드), 7.5 Bold(16pt 아바타) | `typography.initials` |
| SHA, 경로, 코드 | SF Mono 11.5~12 | `typography.mono`, `mono-small` |

## 9. 모양, 간격, 움직임

- 8pt 격자. 패널 안쪽 여백은 10~14pt.
- 반경: 창 12(시스템), 패널 10, 카드 8, 컨트롤 6~7, 알약 5, 칩과 토글은 완전한 둥근 끝.
- 분할선을 끄는 동안에는 애니메이션이 없다(포인터를 그대로 따라간다). 패널 접기·펼치기는 200ms `motion.easing-standard`, 포인터 반응은 120ms. Reduce Motion이 켜져 있으면 둘 다 즉시 바뀐다.

## 10. 접근성

- 대비: 텍스트 4.5:1, 레인·상태 심볼·포커스 링 3:1 이상. 수치는 [design-tokens.md §5](design-tokens.md#5-검증-결과)에 있다.
- **Increase Contrast.** 패널 테두리를 `border.strong`으로, `text.tertiary`를 `text.secondary`로, 칩·컨트롤 테두리를 1.5pt로 바꾼다. 레인과 상태 색은 Asset Catalog의 High Contrast 변형(다크는 더 밝게, 라이트는 더 어둡게, 배경 대비 4.5:1)을 쓴다.
- **Reduce Transparency.** 메인 창은 반투명 재질을 쓰지 않으므로 바뀌는 것이 없다.
- 상태는 항상 심볼과 글자를 함께 쓴다([interaction.md §6.2](interaction.md#62-색에만-의존하지-않는다)).
- 분할선은 VoiceOver에서 조절 가능한 요소다(`Sidebar width, 256 points`). 포커스를 둔 뒤 `←` `→`로 8pt씩 조절한다.

## 11. 참고한 것과 가져오지 않은 것

| 출처 | 참고한 배치 패턴 | 가져오지 않은 것 |
|---|---|---|
| GitKraken | 상자로 나뉜 세 영역과 크기 조절, 그래프 왼쪽의 ref 열과 노드까지의 연결선, 작성자 아바타 노드, 아이콘 위에 라벨을 둔 툴바, 열 머리 | 색 값과 레인 순서, 로고, 아이콘, 열 이름 등 문구, 테마 |
| Fork, Tower | 사이드바 섹션 구성, 상세 패널의 카드 묶음 | 색, 아이콘 |
| Xcode | 패널 토글 단축키(`⌃⌘S`, `⌥⌘0`) | — |

레인 팔레트는 이 문서 §4.3의 방법으로 새로 만들었다. 다른 제품의 값을 가져와 고친 것이 아니다. 조사 기록은 [references.md](references.md)에 있다.

## 12. 목업 만들기

- 생성기: [`design/mockups/generator/`](../../design/mockups/generator/). `render.sh`가 전부 다시 만든다.
- 글꼴: `mkfonts.py`가 시스템 SF Pro·SF Mono에서 고정 굵기 인스턴스를 만들어 `.fonts/`에 둔다(로컬 전용, 커밋하지 않음). 렌더러(rsvg-convert, pango)가 가변 시스템 글꼴의 Medium·Semibold를 고르지 못하기 때문이다.
- 색 검증: `colorcheck.py`가 `tokens.json`을 읽어 §4의 대비와 이웃 레인 거리를 다시 계산한다.
- 목업과 이 문서가 다르면 이 문서와 [screens.md](screens.md)를 따르고 목업을 고친다.
