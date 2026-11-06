# 화면 명세 (Screens)

> 상태: Accepted (Phase 2 게이트, 2026-11-05), S-11·작성자 표현 추가 (#158, #159) · 관련: [information-architecture.md](information-architecture.md), [interaction.md](interaction.md), [design-tokens.md](design-tokens.md), [iconography.md](iconography.md), [security-review.md](security-review.md), [mockups.md](mockups.md), [references.md](references.md), ADR-0004, ADR-0011

HANDOFF §8의 와이어프레임을 출발점으로 S-01부터 S-10까지 화면을 확정한다. S-11(기준 브랜치 대비 변경)은 #158에서 추가했다. 고충실도 목업은 [mockups.md](mockups.md)에 모았고, 각 절에도 링크를 둔다. 와이어프레임의 문자열은 실제 UI 문구(영어)다. 색, 간격, 크기는 [design-tokens.md](design-tokens.md)의 토큰 이름으로 적는다.

**HANDOFF 대비 바뀐 점**

| 항목 | HANDOFF | 확정 | 근거 |
|---|---|---|---|
| 툴바 Pull 버튼 | 있음 (비활성 권장) | **제거.** 자리도 남기지 않음 | ADR-0011 |
| Fetch 단축키 | `⌘⇧F` | `⌘⇧R` | IDE의 "Find in Files" 습관과 충돌 회피. [interaction.md §3](interaction.md#3-키보드-단축키) |
| 워크트리 행 `✎5` | 색 있는 배지 | 중립 색 `pencil` + 수. 색은 충돌, prunable 같은 경고에만 사용 | [information-architecture.md §4.3](information-architecture.md#43-행-구성과-배지) |
| 상세 패널 하단 `[Diff] [Files] [Log]` 버튼 | 있음 | 제거. 파일을 고르면 중앙이 Diff 뷰어로 바뀐다. 이력은 컨텍스트 메뉴 "Show History" | 패널 안에 탭을 겹치지 않기 위해 |
| Stash 상세의 `(apply / pop / drop 은 1차 범위 외)` 문구 | 화면에 표시 | 표시하지 않음. 범위 밖 기능은 화면에 흔적을 남기지 않는다 | [information-architecture.md §1](information-architecture.md#1-설계-원칙) |

**공통 상태 표기.** 모든 화면은 아래 상태를 가진다. 화면별 문구는 각 절에 적는다.

| 상태 | 표현 |
|---|---|
| 로딩 | 150ms가 지나도 데이터가 없을 때만 `ProgressView` + 문구를 보여 준다. 이전 데이터가 있으면 그대로 두고 작은 진행 표시만 붙인다 |
| 빈 상태 | 가운데 정렬 심볼 + 한 줄 설명 + (가능하면) 다음 행동 |
| 에러 | 심볼 `exclamationmark.triangle` + 요약 한 줄 + `Details` 버튼. Details는 마스킹한 stderr 요약을 popover로 보여 준다 |
| 오래된 데이터 | 새로고침이 실패하면 이전 데이터를 `opacity.stale`로 흐리게 두고 상태바에 실패를 표시한다 |
| gh 미로그인 | 이슈 관련 영역만 안내로 바뀐다. 나머지는 정상 |

---

## S-01 메인 창

**목적.** 저장소 하나의 모든 워크트리, 브랜치, stash, 이슈를 한 화면에 놓고, 포커스 워크트리의 WIP와 커밋 그래프를 함께 보여 준다.

**진입.** 앱 실행 시 마지막으로 연 저장소. 등록한 저장소가 없으면 S-07 온보딩.

**레이아웃.** `NavigationSplitView` 3단(사이드바 / 중앙 / 상세) + 툴바 + 하단 상태바.

```
┌──────────────────────────────────────────────────────────────────────────────────────────────┐
│ ● ● ●  [overgrove ▾]   [↓ Fetch]        ⑂ feat/12-worktree-list            [ 🔍 Search   ⌘F ] │
├───────────────────┬────────────────────────────────────────────────┬─────────────────────────┤
│ WORKTREES (4)     │ ◌  WIP   3 staged · 2 unstaged · 1 untracked   │ feat/12-worktree-list   │
│ ● main      main  │ │                                              │ [ Changes | Worktree ]  │
│ ● feat/12   ✎6 ↑2 │ ◉  a1b2c3d  feat: add status parser   Ko   2h  │                         │
│   hotfix    🔒    │ │  ⟨feat/12⟩                                   │ STAGED (3)              │
│   old-spike ⚠     │ ◉  e4f5a6b  fix: handle empty stash   Ko   1d  │  ✓ M  Parser.swift      │
│                   │ ├─╮                                            │  ✓ A  GitClient.swift   │
│ LOCAL (4)         │ │ ◉  9c8d7e6  docs: add ADR-0008     Ko   3d  │  ✓ D  Old.swift         │
│   main            │ │ │  ⟨origin/docs⟩                             │                         │
│ ▸ feat/           │ ◉─╯  0b1c2d3  Merge branch 'docs'     Ko   4d  │ UNSTAGED (2)            │
│   hotfix    🌲    │ │                                              │  ✎ M  Graph.swift       │
│                   │ ◉  7f8e9d0  chore: bootstrap repo     Ko   5d  │  ✎ M  Sidebar.swift     │
│ REMOTE            │ │  ⟨main⟩ ⟨origin/main⟩ ⟨v0.0.1⟩               │                         │
│ ▸ origin (3)      │                                                │ UNTRACKED (1)           │
│                   │                                                │  ? ?  notes.md          │
│ STASHES (2)       │                                                │                         │
│   stash@{0}  WIP… │                                                │                         │
│   stash@{1}  exp  │                                                │                         │
│                   │                                                │                         │
│ ISSUES (5)        │                                                │                         │
│   #12  feat/12 🌲 │                                                │                         │
│   #15  Parse Lfs… │                                                │                         │
├───────────────────┴────────────────────────────────────────────────┴─────────────────────────┤
│ ⟳ Fetched 2 min ago · ↑2 ↓0 · 4 worktrees · ⚠ 1 prunable                     gh: @octocat ✓  │
└──────────────────────────────────────────────────────────────────────────────────────────────┘
```

와이어프레임의 `🔒 ⚠ 🌲 ✓ ✎ ?`는 SF Symbol 자리를 나타낸다. 실제 심볼은 [iconography.md §5](iconography.md#5-상태-심볼-매핑)를 따른다.

**고충실도 목업 (#159).** 토큰 값으로 그린 S-01이다. 글리프는 SF Symbol을 흉내 낸 단순 도형이고, 글꼴은 렌더러에 따라 SF Pro 대신 Helvetica Neue로 보일 수 있다. 기준은 PNG 렌더다. 설명은 [mockups.md](mockups.md#s-01-메인-창)에 있다.

| Light | Dark |
|---|---|
| ![S-01 메인 창 목업 (light)](../../design/mockups/main-window-light.png) | ![S-01 메인 창 목업 (dark)](../../design/mockups/main-window-dark.png) |

원본: [`main-window-light.svg`](../../design/mockups/main-window-light.svg), [`main-window-dark.svg`](../../design/mockups/main-window-dark.svg)

### 툴바

| 요소 | 동작 | 비고 |
|---|---|---|
| 저장소 전환 메뉴 `[overgrove ▾]` | 등록한 저장소 목록, `Add Repository…` (`⌘O`), `Manage Repositories…` | 저장소 이름은 디렉터리 이름 |
| `Fetch` 버튼 | 저장소의 모든 원격을 fetch. 진행 중에는 `Stop` 버튼으로 바뀐다 | 단축키 `⌘⇧R`. 피드백은 [interaction.md §4](interaction.md#4-새로고침과-fetch) |
| 포커스 브랜치 표시 `⑂ feat/12-…` | 누르면 그래프를 포커스 워크트리의 HEAD로 스크롤 (`⌘J`와 같음) | detached면 `detached @ a1b2c3d`. 체크아웃 기능 없음 |
| 검색 필드 | 그래프를 커밋 메시지, 작성자, SHA 앞부분, ref 이름, 이슈 번호(`#12`)로 필터 | `⌘F`. 일치 행만 강조하고 나머지는 흐리게. `⌘G` / `⌘⇧G`로 다음·이전 일치 |

v0.1 툴바에는 Pull, Push, Branch, Stash, Checkout 버튼이 **없다.**

### 사이드바

섹션, 정렬, 배지 규칙은 [information-architecture.md §4](information-architecture.md#4-사이드바-섹션)를 따른다. 너비는 `size.sidebar-width-*`(200 / 240 / 360), 행 높이는 `size.row-sidebar`, 섹션 헤더는 `typography.section-header`.

### 중앙: 커밋 그래프

| 열 | 내용 | 토큰 |
|---|---|---|
| 그래프 | 레인, 노드, 간선. 레인 색은 `color.graph.lane.0~7` 순환 (ADR-0010) | `size.graph-lane-width`, `size.graph-node`, `size.graph-edge` |
| SHA | 짧은 SHA 7자 | `typography.mono-small`, `text.secondary` |
| 제목 | 커밋 제목 첫 줄 + AI 배지(있으면) + ref 알약(로컬, 원격, 태그, `HEAD`). 폭이 모자라면 제목을 먼저 줄이고, 알약은 최대 170px | `typography.body`, 알약 `radius.sm` |
| 작성자 | 이니셜 아바타(16px) + 작성자 이름. 폭이 좁으면 아바타만 남기고 이름은 툴팁으로 | `color.avatar.*`, 이름 `text.secondary` |
| 날짜 | 상대 시각(`2h`, `3d`), 툴팁에 절대 시각(ISO 8601, 로컬 시간대) | `text.secondary` |

- **WIP 행.** 포커스 워크트리에 미커밋 변경이 있을 때만 맨 위에 둔다. 속이 빈 점선 노드(`color.graph.wip-node`)를 쓰고, 행 배경은 `color.surface.wip-row`, 요약 문구는 `3 staged · 2 unstaged · 1 untracked`. 충돌이 있으면 맨 앞에 `⚠ 2 conflicted`를 붙인다. 변경이 없으면 WIP 행을 숨긴다.
- **HEAD 링.** 포커스 워크트리의 HEAD 커밋 노드에 `color.graph.head-ring` 링을 두른다. 다른 워크트리의 HEAD에는 작은 `tree` 심볼과 워크트리 이름 알약을 붙인다.
- **ref 알약.** 로컬 브랜치는 레인 색을 `ref-pill-local-fill-opacity`(0.18)로 채운다. 원격 브랜치는 레인 색 테두리만, 태그는 `tag` 심볼 + 중립 색이다. 알약 텍스트는 항상 `text.primary`다.
  - (#159 보완) 로컬 브랜치와 같은 이름의 `origin/` 브랜치가 같은 커밋을 가리키면 알약 하나로 합친다: 채움 + 테두리 + 끝의 `network` 심볼. 툴팁에 두 ref 이름을 모두 쓴다. 다른 커밋을 가리키면 따로 그린다.
  - (#159 보완) 다른 워크트리가 체크아웃한 브랜치는 그 브랜치 알약 앞에 `tree` 심볼을 붙인다(워크트리 이름은 툴팁). 별도 워크트리 알약은 브랜치가 없는 **detached HEAD 워크트리**에만 `tree` + 디렉터리 이름으로 그린다. 같은 행에 같은 뜻의 알약이 두 개 생기지 않게 하기 위해서다.
- **페이지 단위 로드.** 처음 500개를 그리고 스크롤에 따라 다음 페이지를 불러온다 (PB-3, PB-4). 행 높이는 `size.row-graph`(24px)로 고정한다.

### 작성자 표현과 AI 배지

팀과 AI 에이전트가 함께 쓰는 저장소에서 "누가(무엇이) 이 커밋을 만들었는가"를 그래프에서 바로 읽게 한다 (#159). 근거 조사는 [references.md](references.md)에 있다.

| 요소 | 위치 | 표현 | 규칙 |
|---|---|---|---|
| 이니셜 아바타 | 그래프 작성자 열, S-03 Author, S-11 커밋 목록, 작성자 칩, 사이드바 원격 브랜치 | 지름 16px 원 + 이니셜 최대 2자(굵게, `avatar.initials`) | 색 = `color.avatar.(FNV-1a(소문자 이메일) mod 8)` ([design-tokens.md §3.4](design-tokens.md#34-작성자-아바타-159)). 네트워크 아바타(Gravatar, GitHub 프로필)는 쓰지 않는다. 선택된 행에서는 1px `text.on-selection` 링 |
| 작성자 필터 칩 줄 | 그래프 위 40px 줄 (`person.2` 심볼로 시작) | `All` + 작성자 칩(아바타 + 이름 + 불러온 커밋 수) + 구분선 + `AI-assisted` 칩(`sparkles`) | 칩 순서는 불러온 커밋 수 내림차순. 5명을 넘으면 `+n` 메뉴로 접는다. 칩 하나를 고르면 검색과 같은 방식으로 일치 행만 강조하고 나머지는 `opacity.disabled`로 흐린다(행을 숨기지 않는다. 그래프 모양이 유지된다). 고른 칩은 `accent` 채움 + `text.on-selection`. 검색어와 함께 쓰면 AND |
| AI 배지 | 그래프 제목 뒤, S-03 Co-author 행, S-11 커밋 목록 | `sparkles` + `AI` 글자, `text.secondary` 테두리 알약 | 커밋 메시지에 AI 도구를 가리키는 `Co-Authored-By:` 트레일러가 있을 때만 붙인다. 판별 목록(이름·이메일 패턴)은 후속 이슈에서 정한다. 색은 쓰지 않는다(상태 색, 레인 색과 겹치지 않게). 글자 `AI`가 의미를 전달한다 |
| AI 공동 작성자 | S-03 메타 | `text.secondary` 테두리 원 + `sparkles` (이니셜 아바타를 쓰지 않음) + 이름 + AI 배지 | 사람 아바타처럼 보이지 않게 한다 |
| 원격 브랜치 마지막 커미터 | 사이드바 REMOTE의 브랜치 행 오른쪽 | 아바타(16px) + 팁 커밋의 상대 시각 | 이름은 툴팁과 VoiceOver(`Last commit by Alex Kim, 2 hours ago`). 배지 우선순위는 행에서 가장 낮다. 폭이 모자라면 시각 → 아바타 순으로 숨긴다 |

**데이터와 후속 작업.** 아바타와 칩은 이미 읽는 작성자 이름·이메일만 쓴다. AI 배지는 커밋 트레일러를 읽어야 하므로 로그 포맷에 트레일러 필드(예: `%(trailers:key=Co-authored-by,valueonly)`)를 더해야 한다. 이 변경은 [git-command-catalog.md](../architecture/git-command-catalog.md)와 파싱 명세를 고치는 후속 이슈로 남긴다. 서명 관련 `%G` 필드는 계속 쓰지 않는다 (T7).

**새 심볼.** `sparkles`(AI), `person.2`(작성자 필터), `plus.forwardslash.minus`(기준 대비 변경). [iconography.md §5.3](iconography.md#53-객체와-동작) 표에 후속으로 더한다.

### 상세 패널

선택에 따라 S-02~S-06 중 하나를 보여 준다. 너비는 `size.detail-width-*`(280 / 340)이고, 사용자가 숨길 수 있다(View 메뉴 `Hide Detail`).

### 상태바

| 요소 | 예 | 출처 |
|---|---|---|
| 마지막 fetch | `Fetched 2 min ago` / `Never fetched` / `Fetch failed — Details` | `FetchRecord` |
| 포커스 워크트리의 ahead/behind | `↑2 ↓0` / `No upstream` | `UpstreamStatus` |
| 워크트리 수 | `3 worktrees` | `Worktree` |
| 경고 | `⚠ 1 prunable`. 누르면 해당 워크트리 선택 | `Worktree.prunable` |
| 진행 중 작업 | `Refreshing…` (작은 스피너) | — |
| gh 상태 | `gh: @login ✓` / `gh: not logged in` / `gh: not installed`. 누르면 S-07의 GitHub 단계 | `GHAuthStatus` |

### 상태

| 상태 | 표현 |
|---|---|
| 저장소 경로가 사라짐 | 창 전체에 빈 상태: `Repository not found at ~/dev/app` + `Locate…` / `Remove from List` |
| 저장소가 아님 / 소유권 거부(`safe.directory`) | 빈 상태 + 이유 한 줄. 앱은 `safe.directory`를 대신 설정하지 않는다 ([security-review.md](security-review.md)) |
| git 없음 또는 2.36 미만 | S-07의 git 단계로 안내 |
| 커밋이 없는 저장소 | 그래프 빈 상태: `No commits yet`. WIP 행은 정상 표시 |

**v0.1 제외.** Pull/Push 버튼, 그래프에서 드래그 앤 드롭, 그래프의 stash 노드, 탭으로 여러 저장소 보기.

---

## S-02 WIP 상세

**목적.** 포커스 워크트리의 미커밋 변경을 Staged / Unstaged / Untracked / Conflicted로 나눠 보여 준다.

**진입.** 그래프의 WIP 행 선택, 또는 사이드바에서 워크트리 행 선택 (`Changes` 세그먼트가 기본).

```
┌──────────────────────────────────────┐
│ WIP — feat/12-worktree-list          │
│ [ Changes | Worktree ]               │
│ ~/dev/overgrove-wt/12-worktree-list  │
├──────────────────────────────────────┤
│ CONFLICTED (1)                       │
│  ⚠ U  Sources/Graph/Layout.swift     │
│                                      │
│ STAGED (3)                  +54 −12  │
│  ✓ M  Sources/Parsing/Status.swift   │
│  ✓ A  Sources/Git/GitClient.swift    │
│  ✓ R  Old.swift → New.swift          │
│                                      │
│ UNSTAGED (2)                 +11 −3  │
│  ✎ M  Sources/Graph/Graph.swift      │
│  ✎ D  Sources/Legacy.swift           │
│                                      │
│ UNTRACKED (1)                        │
│  ? ?  notes.md                       │
└──────────────────────────────────────┘
```

| 요소 | 내용 |
|---|---|
| 제목 | `WIP — <브랜치>` 또는 `WIP — detached @ <sha>`. `typography.title` |
| 세그먼트 | `Changes`(S-02) / `Worktree`(S-05). 워크트리 행에서 들어왔을 때만 보인다 |
| 그룹 순서 | **CONFLICTED → STAGED → UNSTAGED → UNTRACKED.** 충돌을 가장 먼저 본다. 빈 그룹은 숨긴다 |
| 그룹 헤더 | 상태 심볼, 이름, 개수, 그룹 합계 `+n −m` (untracked는 합계 없음) |
| 파일 행 | 상태 심볼(그룹 색) + 변경 종류 글자(M/A/D/R/C/T/U, `typography.mono-small`, `text.secondary`) + 경로. 경로는 디렉터리를 `text.secondary`, 파일 이름을 `text.primary`로 쓴다. 길면 가운데를 줄인다 |
| rename | `Old.swift → New.swift` |
| 한 파일이 staged와 unstaged에 모두 있음 (`MM`) | 두 그룹에 각각 한 번씩 나타난다 |
| 서브모듈 | 경로 옆에 `submodule` 태그. 내부 변경은 펼치지 않는다 (later) |

**데이터.** `WorkingState`, `FileChange`. staged numstat은 `diff --cached --numstat`, unstaged는 `diff --numstat`에서 온다 ([git-command-catalog.md](../architecture/git-command-catalog.md)).

**동작.** 파일을 고르면 중앙이 S-10 Diff 뷰어로 바뀐다. 컨텍스트 메뉴는 [interaction.md §5](interaction.md#5-컨텍스트-메뉴)를 따른다.

| 상태 | 표현 |
|---|---|
| 변경 없음 | `checkmark.circle` + `Working tree clean` |
| untracked가 상한 초과 | `UNTRACKED (5,000+)` + `Showing first 5,000 files`. 상한은 성능 측정 후 확정 ([performance-budget.md](../performance/performance-budget.md)) |
| 워크트리 경로 없음 (prunable) | `questionmark.folder` + `Worktree directory is missing` + `Run git worktree prune in Terminal to clean up`. 앱은 prune하지 않는다 |

**목업.** 충돌이 있는 에이전트 워크트리를 포커스한 상태. `logger.go`가 staged와 unstaged에 모두 나오고(`MM`), rename은 `{old → new}`로 줄여 쓴다. [mockups.md](mockups.md#s-02-wip-상세)

| Light | Dark |
|---|---|
| ![S-02 WIP 상세 (light)](../../design/mockups/s02-wip-detail-light.png) | ![S-02 WIP 상세 (dark)](../../design/mockups/s02-wip-detail-dark.png) |

**v0.1 제외.** 스테이징 토글 체크박스, discard, 부분 스테이징, 커밋 메시지 입력.

---

## S-03 커밋 상세

**목적.** 커밋 하나의 메타데이터, 메시지, 변경 파일을 보여 준다.

**진입.** 그래프의 커밋 행, 사이드바 브랜치(팁 커밋), S-09에서 커밋 선택.

```
┌──────────────────────────────────────┐
│ a1b2c3d  feat: add status parser     │
├──────────────────────────────────────┤
│ Author     Ko <ko@example.com>       │
│ Date       2026-11-03 14:22 (+09:00) │
│ Committer  (same as author)          │
│ Parents    e4f5a6b                   │
│ Refs       ⟨feat/12⟩ ⟨origin/feat/12⟩│
│ Issues     #12 Worktree list         │
├──────────────────────────────────────┤
│ Parse porcelain v2 output with NUL   │
│ separators.                          │
│                                      │
│ Refs: #12                            │
├──────────────────────────────────────┤
│ FILES (4)                   +73 −11  │
│  M  Sources/Parsing/Status.swift +42 −8 │
│  A  Tests/StatusParserTests.swift +20 │
│  M  Sources/Graph/Graph.swift  +11 −3 │
│  M  README.md                   ±2   │
└──────────────────────────────────────┘
```

| 요소 | 내용 |
|---|---|
| 제목줄 | 전체 SHA는 툴팁과 `Copy SHA`로, 화면에는 7자 |
| 메타 | Author(아바타 + 이름 + 이메일), Co-author(트레일러가 있을 때만, AI면 AI 배지), Date(작성 시각), Committer(다를 때만), Parents(merge면 둘 이상, 누르면 그 커밋 선택), Refs, Issues(메시지와 ref에서 찾은 번호, gh 로그인 시 제목 표시) |
| 본문 | 메시지 전체. 고정폭이 아닌 `typography.body`. URL은 링크로 만들지 않는다(v0.1) |
| 파일 | 종류 글자 + 경로 + `+n −m`. 바이너리는 `binary`. merge 커밋은 첫 번째 부모 기준 diff이고 그 사실을 헤더에 적는다 (`Changes vs first parent`) |
| 서명 | 표시하지 않는다. 서명 검증은 `gpg.program`을 실행하므로 v0.1에서 하지 않는다 (T7) |

**데이터.** `CommitDetail` (선택 시 지연 로드).

| 상태 | 표현 |
|---|---|
| 로딩 | 메타는 `CommitNode`에 이미 있으므로 즉시 표시한다. 파일 목록만 로딩 |
| 파일 수가 많음 | 처음 1,000개를 보여 주고 `Show all 4,213 files` |

**목업.** `AI-assisted` 칩으로 그래프를 거른 상태에서 AI 공동 작성 커밋을 고른 화면. 제목은 두 줄까지 감싼다. 트레일러 줄은 본문에서 `text.secondary`로 쓴다. [mockups.md](mockups.md#s-03-커밋-상세)

| Light | Dark |
|---|---|
| ![S-03 커밋 상세 (light)](../../design/mockups/s03-commit-detail-light.png) | ![S-03 커밋 상세 (dark)](../../design/mockups/s03-commit-detail-dark.png) |

**v0.1 제외.** cherry-pick, revert, 이 커밋으로 체크아웃, GitHub에서 열기.

---

## S-04 Stash 상세

**목적.** stash 하나의 내용과 기준 커밋을 보여 준다.

**진입.** 사이드바 STASHES의 항목.

```
┌──────────────────────────────────────────────────┐
│ stash@{0}                              3 days ago │
│ WIP on feat/12: 9c8d7e6 docs: add ADR-0008        │
├──────────────────────────────────────────────────┤
│ Base commit  9c8d7e6  docs: add ADR-0008          │
│ Branch       feat/12  (from message)              │
│ Includes     index · working tree · untracked     │
├──────────────────────────────────────────────────┤
│ FILES (4)                                         │
│  M  Sources/Parsing/Status.swift     +42  −8      │
│  M  Sources/Graph/Graph.swift        +11  −3      │
│  A  Sources/Untracked.swift          +20  −0  ?   │
│  M  README.md                         +2  −2      │
├──────────────────────────────────────────────────┤
│ [ Copy Ref ]                                      │
└──────────────────────────────────────────────────┘
```

| 요소 | 내용 |
|---|---|
| 제목 | `stash@{n}` + 상대 시각. 메시지 전체를 다음 줄에 |
| Base commit | stash의 첫 번째 부모. 누르면 그래프에서 그 커밋 선택 |
| Branch | 메시지 `WIP on <branch>` / `On <branch>`에서 추정. 추정임을 `(from message)`로 밝힌다 |
| Includes | index 커밋(두 번째 부모), untracked 커밋(세 번째 부모) 존재 여부 |
| 파일 | untracked 커밋에서 온 파일은 `questionmark` 심볼로 표시 |
| 버튼 | `Copy Ref`만 둔다 |

**데이터.** `Stash`, `StashDetail`.

| 상태 | 표현 |
|---|---|
| stash 없음 | 사이드바 섹션에 `No stashes` 한 줄 (섹션은 유지) |

**v0.1 제외.** apply, pop, drop, branch from stash. 화면에 안내 문구도 두지 않는다.

---

## S-05 워크트리 상세

**목적.** 워크트리 하나의 경로, HEAD, upstream, 상태, 보안 상태를 보여 준다.

**진입.** 사이드바 워크트리 행 선택 후 `Worktree` 세그먼트.

```
┌────────────────────────────────────────────────────────┐
│ WORKTREE  feat/12-worktree-list                        │
│ [ Changes | Worktree ]                                 │
├────────────────────────────────────────────────────────┤
│ Path        ~/dev/overgrove-wt/12-worktree-list   ⧉    │
│ HEAD        a1b2c3d  feat: add status parser           │
│ Branch      feat/12-worktree-list                      │
│ Upstream    origin/feat/12-worktree-list  ↑2 ↓0        │
│ State       6 changed · 1 untracked · no conflicts     │
│ Lock        not locked                                 │
│ Last fetch  2 min ago (repository)                     │
│ Base        main  1 commit ahead · 4 files             │
│             [ ± Compare with Base… ]  ⌘⇧B              │
├────────────────────────────────────────────────────────┤
│ SECURITY                                               │
│  ✓ Hooks disabled                                      │
│  ✓ fsmonitor disabled                                  │
│  ✓ External diff and textconv disabled                 │
│  ✓ Remote URL credentials masked                       │
│  ⚠ Repository config overrides neutralized (2)  ›      │
│      filter.lfs.process, core.sshCommand               │
└────────────────────────────────────────────────────────┘
```

| 요소 | 내용 |
|---|---|
| Path | `~`로 줄인 경로 + 복사 버튼. 심볼릭 링크로 저장소 밖을 가리키면 `⚠ Symlink points outside the repository` (T14) |
| HEAD / Branch | detached면 Branch에 `detached` |
| Upstream | 없으면 `No upstream`. upstream 브랜치가 원격에서 사라졌으면 `gone` |
| State | `WorkingState` 요약 |
| Lock | `locked` + 이유(`git worktree lock --reason`이 있으면) |
| Last fetch | 저장소 단위임을 `(repository)`로 밝힌다. **이 화면에 Fetch 버튼을 두지 않는다.** fetch는 저장소 단위이므로 툴바 하나로 통일한다 |
| Base | 기준 브랜치(기본은 기본 브랜치)와 그 대비 요약. `Compare with Base…`는 S-11을 연다 (#158) |
| SECURITY | 위협 모델 대응이 이 저장소에 적용되었는지 보여 준다. 항상 켜져 있는 항목(hooks, fsmonitor, ext diff, 마스킹)은 `✓`로 표시한다. `RepoConfigInspector`가 무력화한 저장소 설정이 있으면 `⚠` + 개수, 펼치면 키 이름 목록을 보여 준다(값은 보여 주지 않는다). 항목 정의는 [security-review.md](security-review.md)와 ADR-0009를 따른다 |

**데이터.** `Worktree`, `UpstreamStatus`, `WorkingState`, `FetchRecord`, `RepoConfigInspector` 결과.

| 상태 | 표현 |
|---|---|
| prunable | Path에 `⚠ Directory missing`. 나머지 필드는 마지막으로 알려진 값을 흐리게 표시 |
| bare 저장소의 main 항목 | 목록에서 숨기므로 이 화면으로 오지 않는다 |

**목업.** SECURITY 섹션에서 무력화된 저장소 설정 2개를 펼친 상태. 키 이름만 보이고 값은 보이지 않는다. [mockups.md](mockups.md#s-05-워크트리-상세)

| Light | Dark |
|---|---|
| ![S-05 워크트리 상세 (light)](../../design/mockups/s05-worktree-detail-light.png) | ![S-05 워크트리 상세 (dark)](../../design/mockups/s05-worktree-detail-dark.png) |

**v0.1 제외.** 워크트리 추가·삭제·이동·잠금·prune.

---

## S-06 이슈 패널

**목적.** GitHub 이슈를 읽기 전용으로 보여 주고 브랜치·워크트리·커밋과의 연결을 드러낸다 (ADR-0004).

**진입.** 사이드바 ISSUES 섹션(목록) → 항목 선택 시 상세 패널(상세).

**사이드바 목록 행.** `#번호` + 제목(한 줄) + 연결 배지(`tree` 심볼 = 연결된 워크트리 있음, `arrow.triangle.branch` = 연결된 브랜치만 있음). 섹션 헤더 오른쪽에 필터 메뉴: `Open`(기본) / `All` / `Assigned to me` / `Linked`.

```
상세 패널
┌──────────────────────────────────────────┐
│ #12  Worktree list                       │
│ ● Open · updated 3h ago                  │
├──────────────────────────────────────────┤
│ Labels     type:feature  area:ui         │
│ Assignees  @octocat                      │
│ Milestone  v0.1.0                        │
├──────────────────────────────────────────┤
│ LINKED                                   │
│  🌲 feat/12-worktree-list (worktree)     │
│  ⑂ origin/feat/12-worktree-list          │
│  ◉ a1b2c3d feat: add status parser       │
├──────────────────────────────────────────┤
│ [ Open in Browser ]   [ Copy URL ]       │
└──────────────────────────────────────────┘
```

| 요소 | 내용 |
|---|---|
| 상태 | `Open` / `Closed` + 심볼(`number.circle` / `checkmark.seal`)과 텍스트 |
| 라벨 | 라벨 이름만 중립 알약으로 표시한다. GitHub 라벨 색은 쓰지 않는다 (상태 색과 충돌하고 대비를 보장할 수 없음) |
| LINKED | 연결된 워크트리, 브랜치, 커밋(최근 5개). 누르면 해당 항목 선택 |
| 본문 | v0.1에서는 표시하지 않는다. Markdown 렌더링과 원격 이미지 로드를 피하기 위해서다. `Open in Browser`로 본다 |
| Open in Browser | `gh`가 준 URL이 `https://`이고 호스트가 저장소 원격의 GitHub 호스트와 같을 때만 연다 |

**데이터.** `Issue`, `GHAuthStatus`, 연결 계산 결과.

| 상태 | 사이드바 | 상세 |
|---|---|---|
| `gh` 미설치 | `GitHub CLI not installed` 안내 행 → S-07 | — |
| 미로그인 | `Not logged in to GitHub` + `Run gh auth login in Terminal` | — |
| GitHub 원격 없음 | `No GitHub remote` | — |
| 권한 없음 / 저장소 없음 | `Cannot read issues for owner/repo` + `Details` | — |
| 이슈 없음 | `No open issues` | — |
| 불러오는 중 | 섹션 헤더에 작은 스피너 | — |

**v0.1 제외.** 이슈 생성·수정·코멘트, PR 상태, 본문 렌더링, GitHub Enterprise.

---

## S-07 온보딩

**목적.** 처음 실행했을 때 저장소를 등록하고 git과 gh 상태를 점검한다. 이후에도 상태바와 메뉴(`Help > Setup Assistant`)에서 다시 연다.

```
┌──────────────────────────────────────────────────────────────────────────┐
│                       [mark]  Welcome to Overgrove                        │
│        See every worktree of a repository at a glance. Read-only.         │
├──────────────────────────────────────────────────────────────────────────┤
│ 1  Add a repository      [ Choose Folder… ]      ✓ ~/dev/overgrove         │
│                          Only folders you choose here are ever read.     │
│                                                                          │
│ 2  git                   ✓ git 2.50.1 (Apple Git-155) at /usr/bin/git      │
│                                                                          │
│ 3  GitHub (optional)     ✗ Not logged in                                  │
│                          Run this in Terminal, then check again:         │
│                          ┌──────────────────┐                            │
│                          │ gh auth login    │  [ Copy ]                  │
│                          └──────────────────┘                            │
│                          [ Check Again ]                                 │
│                          Overgrove never asks for or stores tokens.       │
├──────────────────────────────────────────────────────────────────────────┤
│                                                    [ Open Repository ]   │
└──────────────────────────────────────────────────────────────────────────┘
```

| 단계 | 성공 | 실패 표현 |
|---|---|---|
| 1 저장소 | 경로와 `✓` | 저장소가 아님: `This folder is not a Git repository`. 소유권 거부: `Git refused this folder (ownership check)` + 설명 링크. 앱은 `safe.directory`를 바꾸지 않는다 |
| 2 git | 버전과 경로 | 없음: `Install Xcode Command Line Tools: xcode-select --install` (복사 버튼). 2.36 미만: `git 2.36 or later is required` |
| 3 GitHub | `✓ Logged in as @login` | 미설치: `Install GitHub CLI (brew install gh) to see issues` / 미로그인: 위 와이어프레임. **이 단계는 건너뛸 수 있다** |

- 앱은 `gh auth login`이나 `xcode-select --install`을 **직접 실행하지 않는다.** 명령을 복사할 수 있게만 한다 (HANDOFF §7.2).
- `Open Repository`는 1, 2단계가 성공하면 활성화된다.

**목업.** 1, 2단계 성공, 3단계(GitHub) 미로그인. 제목은 `typography.large-title`(#159에서 추가)을 쓴다. [mockups.md](mockups.md#s-07-온보딩)

| Light | Dark |
|---|---|
| ![S-07 온보딩 (light)](../../design/mockups/s07-onboarding-light.png) | ![S-07 온보딩 (dark)](../../design/mockups/s07-onboarding-dark.png) |

---

## S-08 설정

`⌘,`로 여는 표준 Settings 창. 탭은 `General`, `Repositories`, `Advanced`.

```
General
┌──────────────────────────────────────────────────────────────┐
│ Fetch          [ ] Fetch automatically every [10 min ▾]       │
│                    Off by default. Uses your git credentials. │
│ Remote URLs    [ ] Show full remote URLs                       │
│                    Credentials in URLs are always masked.     │
│ Untracked      [✓] Show untracked files                        │
└──────────────────────────────────────────────────────────────┘
Repositories
┌──────────────────────────────────────────────────────────────┐
│ overgrove      ~/dev/overgrove                    [ Remove ]  │
│ api            ~/dev/api                          [ Remove ]  │
│ [ + Add… ]                                                    │
└──────────────────────────────────────────────────────────────┘
Advanced
┌──────────────────────────────────────────────────────────────┐
│ git executable  /usr/bin/git                  [ Choose… ]     │
│                 Must be an absolute path. Checked on change.  │
│ Diagnostics     [ ] Verbose logging (credentials masked)      │
└──────────────────────────────────────────────────────────────┘
```

| 설정 | 기본값 | 저장 | 비고 |
|---|---|---|---|
| 자동 fetch | 끔, 간격 10분 | `UserDefaults` | 켜면 백그라운드 fetch. 창이 비활성일 때는 건너뛴다 |
| 원격 URL 전체 표시 | 끔 | `UserDefaults` | 켜도 자격 증명 부분은 항상 마스킹한다 (T11) |
| untracked 표시 | 켬 | `UserDefaults` | 끄면 `--untracked-files=no` |
| git 실행 파일 | `/usr/bin/git` | `UserDefaults` | 절대 경로만 허용한다. 바꿀 때 `--version`으로 검증 (ADR-0008) |
| 상세 로그 | 끔 | `UserDefaults` | 로그에도 마스킹을 적용한다 (T16) |

토큰이나 비밀 값을 입력받는 필드는 **없다.**

---

## S-09 파일 이력

**목적.** 파일 하나를 바꾼 커밋 목록을 보고, 각 커밋에서 그 파일이 어떻게 바뀌었는지 본다.

**진입.** S-02, S-03, S-04, S-10의 파일 컨텍스트 메뉴 `Show History`. 중앙 영역이 바뀌고 `⎋`로 그래프에 돌아간다.

```
┌───────────────────────────────────────────────────────────────────┐
│ ‹ Graph    History of Sources/Parsing/Status.swift   [✓] Follow renames │
├───────────────────────────────────────────────────────────────────┤
│ ◉ a1b2c3d  feat: add status parser          Ko   2h    +42  −8      │
│ ◉ e4f5a6b  fix: handle empty stash          Ko   1d     +3  −1      │
│ ◉ 0b1c2d3  refactor: split parser  (renamed from Parser.swift) 4d   │
│ ◉ 7f8e9d0  chore: bootstrap repo            Ko   5d    +80  −0      │
└───────────────────────────────────────────────────────────────────┘
```

| 요소 | 내용 |
|---|---|
| Follow renames | 기본 켬 (`--follow`). rename이 일어난 행에 `renamed from …` |
| 행 | SHA, 제목, 작성자, 날짜, 그 파일의 `+n −m` |
| 선택 | 상세 패널에 S-03. 행을 두 번 누르거나 `⏎`이면 S-10에 그 커밋의 해당 파일 diff |

| 상태 | 표현 |
|---|---|
| 이력 없음 (untracked 파일) | `This file has no history yet` |
| 긴 이력 | 처음 500개, 스크롤 시 추가 로드 |

---

## S-10 Diff 뷰어

**목적.** 파일 하나의 diff를 읽기 전용으로 보여 준다.

**진입.** S-02, S-03, S-04, S-09에서 파일 선택. 중앙 영역이 바뀌고, 상세 패널의 파일 목록은 그대로 남아 `↑`/`↓`로 다음 파일로 넘어간다. `⎋`로 그래프에 돌아간다.

```
┌─────────────────────────────────────────────────────────────────────────┐
│ ‹ Graph   Sources/Parsing/Status.swift   Staged · M    [Unified|Split]  │
├─────────────────────────────────────────────────────────────────────────┤
│ @@ -40,7 +40,9 @@ struct StatusParser                                    │
│   40   40    func parse(_ data: Data) -> [FileChange] {                 │
│   41      −      let lines = data.split(separator: 0x0A)                │
│        41 +      let records = data.split(separator: 0x00)              │
│        42 +      // porcelain v2 records are NUL-terminated             │
│   42   43        var result: [FileChange] = []                          │
└─────────────────────────────────────────────────────────────────────────┘
```

| 요소 | 내용 |
|---|---|
| 머리 | 경로, 출처(Staged / Unstaged / 커밋 SHA / stash), 변경 종류 |
| 보기 방식 | `Unified`(기본) / `Split`. 선택을 기억한다 |
| 줄 | 이전·이후 줄 번호, `+`/`−` 기호(색만으로 구분하지 않음), 본문은 `typography.mono` |
| 배경 | `color.diff.added-bg`, `removed-bg`, 단어 단위 강조는 `added-word-bg` / `removed-word-bg` (v0.1은 줄 단위만, 단어 단위는 later) |
| hunk 헤더 | `color.diff.hunk-header-bg` |
| 공백 문자 | 줄 끝 공백과 탭은 보이게 하지 않는다 (later 옵션) |

diff 명령은 항상 `--no-ext-diff --no-textconv`로 실행한다 (T3). 텍스트 변환이 필요한 파일(예: 이미지, 바이너리)은 내용을 보여 주지 않는다.

| 상태 | 표현 |
|---|---|
| 바이너리 | `Binary file — 12.4 KB → 13.0 KB` |
| 출력 상한 초과 | 상한(10MB, ADR-0008)까지 보여 주고 `Diff truncated at 10 MB` 배너 |
| 큰 diff | 1만 줄을 넘으면 먼저 `Large diff (24,310 lines)` + `Show Diff` 버튼. 누르기 전에는 렌더링하지 않는다 |
| 서브모듈 | `Submodule commit a1b2c3d → e4f5a6b` 한 줄 |
| LFS 포인터 | 포인터 텍스트를 그대로 보여 준다. LFS 필터를 실행하지 않는다 (T4) |
| 심볼릭 링크 | 링크 대상 경로 문자열의 변화만 보여 준다 |

**목업.** S-03의 파일 목록에서 파일을 고른 상태. 상세 패널의 선택 행이 남아 있고 `↑`/`↓`로 다음 파일로 넘어간다. [mockups.md](mockups.md#s-10-diff-뷰어)

| Light | Dark |
|---|---|
| ![S-10 Diff 뷰어 (light)](../../design/mockups/s10-diff-viewer-light.png) | ![S-10 Diff 뷰어 (dark)](../../design/mockups/s10-diff-viewer-dark.png) |

**v0.1 제외.** 줄 단위 스테이징, 문법 강조, 이미지 diff, 편집.

---

## S-11 기준 브랜치 대비 변경

**목적.** 워크트리가 기준 브랜치에 비해 무엇을 바꿨는지 PR의 "Files changed"처럼 본다. AI 에이전트 작업을 PR 전에 검토하는 핵심 동선이다 (#158, 데이터는 #157).

**진입.**
- 사이드바 워크트리 행 컨텍스트 메뉴 `Compare with Base`
- S-05의 `Compare with Base…` 버튼
- 단축키 `⌘⇧B` (포커스 워크트리 기준. 시스템 예약 아님. [interaction.md §3](interaction.md#3-키보드-단축키) 표에는 #158 구현 때 더한다)

S-09, S-10처럼 **중앙 영역을 잠시 덮는다.** `‹ Graph`나 `⎋`로 그래프에 돌아간다. 상세 패널에는 커밋 목록과 파일 목록이 오고, 파일을 고르면 중앙에 그 파일의 패치(S-10과 같은 뷰어)가 나온다. 앱 안의 다른 화면(S-02, S-03 → S-10)과 같은 방향이다.

```
중앙 영역                                                         상세 패널
┌──────────────────────────────────────────────────────────┐ ┌──────────────────────────────────────┐
│ ‹ Graph  Changes vs [⑂ main ⌃⌄]       Include uncommitted ●│ │ feat/42-rate-limit                    │
│ 2 commits ahead · 0 behind · uncommitted: 5 files ·       │ │ compared with main, including …       │
│ 8 files · +272 −85                  merge base 3c5d6f1    │ │ COMMITS AHEAD (2)                     │
├──────────────────────────────────────────────────────────┤ │  ◌ Uncommitted changes       5 files  │
│ internal/http/middleware.go  Modified · 1 commit + uncom… │ │  AK a91f3c2 feat(ratelimit): …  [AI]  │
├──────────────────────────────────────────────────────────┤ │  AK 7d20e18 test(ratelimit): …  [AI]  │
│ @@ -8,11 +8,24 @@ import (                                │ │ FILES CHANGED (8)           +272 −85  │
│   8   8      "net/http"                                   │ │  M internal/http/middleware.go [WIP]  │
│  11      −                                                │ │  A internal/ratelimit/limiter.go      │
│      11 +    "github.com/acme/api/internal/ratelimit"     │ │  R internal/http/{noop.go → pass…}    │
│ …                                                         │ │ UNTRACKED (2)                         │
└──────────────────────────────────────────────────────────┘ │  ? docs/rate-limit.md                 │
                                                             └──────────────────────────────────────┘
```

| 요소 | 내용 |
|---|---|
| 기준 브랜치 선택 | 팝업 버튼. 기본은 기본 브랜치(`origin/HEAD`가 가리키는 것, 없으면 `main`/`master`). 로컬·원격 브랜치를 고를 수 있다. 고른 값은 워크트리별로 기억한다 |
| `Include uncommitted` | 켜면(기본) 워크트리의 staged·unstaged 변경을 파일 목록과 패치에 합치고 UNTRACKED 섹션을 보인다. 끄면 merge base와 HEAD 사이의 커밋된 변경만 |
| 요약 줄 | ahead 커밋 수, 기준이 앞선 커밋 수(behind), 미커밋 파일 수(토글이 켜졌을 때), 파일 수, `+n −m`, merge base 짧은 SHA |
| COMMITS AHEAD | merge base 이후 이 워크트리 HEAD에만 있는 커밋. 아바타 + SHA + 제목 + AI 배지. 토글이 켜져 있으면 맨 위에 `Uncommitted changes`(점선 WIP 노드)를 둔다. 커밋을 고르면 상세가 S-03으로 바뀌고 S-11은 닫힌다 |
| FILES CHANGED | 종류 글자(M/A/D/R/C/T) + 경로 + `+n −m`. rename은 `{old → new}`. 미커밋 변경이 섞인 파일은 `WIP` 알약을 붙인다(색 없음). 정렬은 경로 오름차순 |
| UNTRACKED | 토글이 켜졌을 때만. `questionmark.circle` + `?` + 경로. 줄 수는 세지 않는다 |
| 패치 머리 | 경로, 변경 종류, 출처(`n commits`, `+ uncommitted`), 그 파일의 `+n −m` |
| 사이드바 배지 (선택) | 워크트리 행에 `plus.forwardslash.minus` + 기준 대비 변경 파일 수. 우선순위는 이슈 번호 다음(가장 낮음). 기본은 끔 |

**데이터.** #157의 비교 결과: merge base, ahead/behind 수, `diff --numstat`/`--name-status`(merge base…HEAD, 토글이 켜지면 작업 트리까지), untracked 목록. 모든 diff는 `--no-ext-diff --no-textconv` (T3). 명령은 [git-command-catalog.md](../architecture/git-command-catalog.md)에 먼저 더한다.

| 상태 | 표현 |
|---|---|
| 로딩 | 요약 줄 자리에 작은 스피너 + `Comparing with main…`. 150ms 규칙은 공통과 같다 |
| 차이 없음 | `checkmark.circle` + `No changes compared with main` |
| 기준 브랜치 없음 | `exclamationmark.triangle` + `Base branch main was not found` + `Choose Base…` |
| 갈라진 지점 없음 | `exclamationmark.triangle` + `No common ancestor with main` (관련 없는 이력) |
| 큰 비교 | 파일 1,000개 초과 시 처음 1,000개 + `Show all 4,213 files`. 패치는 S-10의 큰 diff 규칙을 따른다 |
| detached HEAD | 기준 대비 비교는 HEAD 커밋 기준으로 동작한다. 제목에 `detached @ a1b2c3d` |

**목업.** [mockups.md](mockups.md#s-11-기준-브랜치-대비-변경)

| Light | Dark |
|---|---|
| ![S-11 기준 브랜치 대비 변경 (light)](../../design/mockups/s11-changes-vs-base-light.png) | ![S-11 기준 브랜치 대비 변경 (dark)](../../design/mockups/s11-changes-vs-base-dark.png) |

**v0.1 제외.** 병합 가능 여부·충돌 예측, PR 생성, 두 임의 커밋 비교, 리뷰 코멘트.
