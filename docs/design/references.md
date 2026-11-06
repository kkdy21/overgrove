# 디자인 참고 조사 (References)

> 상태: Draft · 관련: [screens.md](screens.md), [information-architecture.md](information-architecture.md), [interaction.md](interaction.md), [design-tokens.md](design-tokens.md), [mockups.md](mockups.md), ADR-0010, ADR-0011, #158

이 문서는 macOS Git 클라이언트와 Apple Human Interface Guidelines(HIG)에서 **배치와 정보 표시 패턴**을 조사하고, Overgrove가 무엇을 받아들이고 무엇을 받아들이지 않는지 기록한다. 확정된 화면 명세는 [screens.md](screens.md)이고, 목업은 [mockups.md](mockups.md)에 있다. 이 문서는 근거를 모아 두는 곳이며, 여기서 새 결정을 내리지 않는다. 결정이 필요한 항목은 "열린 질문"으로 표시한다.

조사 시점은 2026-11이다. 각 제품의 기능 설명은 아래 출처에 적힌 공식 문서와 릴리스 노트를 기준으로 하며, 그 뒤에 바뀌었을 수 있다.

---

## 1. 참고 범위와 원칙

**브랜드 요소는 가져오지 않는다.** 이 문서가 다루는 제품의 로고, 앱 아이콘, 제품 고유 아이콘(예: GitHub의 Octicons), 색 팔레트, 화면 문구와 고유 명칭은 Overgrove에 복제하지 않는다. 참고하는 것은 **배치와 정보 구조의 패턴**(어디에 무엇을 몇 단계로 보여 주는가)뿐이다. Overgrove의 색은 오직 [`design/tokens/tokens.json`](../../design/tokens/tokens.json)에서 오고([design-tokens.md §1](design-tokens.md#1-원칙)), 심볼은 SF Symbols 규칙([iconography.md](iconography.md))을, 화면 문구는 [interaction.md §7](interaction.md#7-화면-문구-원칙)을 따른다.

조사의 관점은 세 가지다.

1. **조회 전용.** v0.1은 쓰기 동작의 자리를 만들지 않는다 (ADR-0011, [information-architecture.md §1](information-architecture.md#1-설계-원칙)). 다른 제품에서 쓰기 동작과 묶여 있는 패턴은 표시 부분만 떼어서 본다.
2. **워크트리가 1급 객체.** 대부분의 Git 클라이언트는 워크트리를 부가 기능으로 다룬다. Overgrove에 맞는지는 "여러 워크트리를 동시에 내려다볼 때 도움이 되는가"로 판단한다.
3. **네트워크와 실행 최소화.** 보안 모델([security-review.md](security-review.md))과 외부 의존성 0개(ADR-0006) 때문에 원격 이미지, 외부 diff 도구, 서비스 연동이 필요한 패턴은 받아들이지 않는다.

---

## 2. 조사 대상

| 대상 | 종류 | 조사한 이유 |
|---|---|---|
| Tower | 상용 GUI (macOS·Windows) | 사이드바 워크트리 섹션, 브랜치 비교, Branches Review |
| Fork | 상용 GUI (macOS·Windows) | 워크트리 사이드바, 아바타 생성, stash 표시, side-by-side diff |
| Sublime Merge | 상용 GUI | diff 문맥 확장, 두 커밋 비교, 검색 |
| GitHub Desktop | 오픈소스 GUI | 변경 파일 목록, Unified/Split, co-author, PR 미리보기 |
| GitKraken Desktop | 상용 GUI | 워크트리마다 WIP 행, 에이전트 세션, 작성자 열 필터, 이니셜 표시 |
| Xcode Source Control | Apple IDE 내장 | macOS 기본 앱의 변경 목록, inline/side-by-side 비교 |
| lazygit | 오픈소스 TUI | 워크트리 패널, 작성자별 색과 이니셜, 기준 ref 대비 diff 모드 |
| Apple HIG | 플랫폼 지침 | 사이드바, 분할 보기, 툴바, 빈 상태와 문구, 색과 접근성, 로딩 |

---

## 3. 제품별 조사

### 3.1 Tower

**관찰한 패턴**

- 12.5부터 사이드바에 "Worktrees" 섹션이 생겼다(Submodules 다음). 워크트리에 체크아웃된 브랜치는 Branches 섹션에서 별도 아이콘과 작은 "+" 배지로 구분되고, 그 브랜치를 두 번 누르면 해당 워크트리로 전환한다. 공식 글에는 워크트리별 변경 수나 ahead/behind 같은 상태 표시가 언급되지 않는다.
- 브랜치의 히스토리 보기에서 "Compare" 아이콘을 켜면 그 브랜치에만 있는 커밋만 남긴다. 기준 브랜치보다 몇 커밋 뒤처졌는지 숫자로 보이고, 병합 시 충돌할 파일 수를 경고 표시로 보여 준다. 두 브랜치나 두 커밋의 비교 결과는 외부 diff 도구로 연다.
- Tower 8의 "Branches Review"는 로컬 브랜치를 기준 브랜치와 비교해 오래되었거나 쓸모없어진 브랜치를 찾게 한다. 이름 또는 마지막 갱신일로 정렬하고, Active/Stale, Fully Merged 등으로 거른다.

**채택**

- 사이드바에 워크트리 전용 섹션을 두고, 로컬 브랜치 행에 "워크트리에 체크아웃됨" 표시를 붙이는 구조. Overgrove는 이를 이미 `WORKTREES` 섹션(맨 위)과 LOCAL 행의 `tree` 심볼로 명세했다 ([information-architecture.md §4.3](information-architecture.md#43-행-구성과-배지)). Tower와 달리 워크트리 행 자체에 변경 수, ahead/behind, 잠금, prunable을 배지로 보여 준다. 여러 워크트리를 한눈에 비교하는 것이 제품의 핵심이기 때문이다.
- "기준 브랜치 대비 이 브랜치에만 있는 커밋"을 보여 주는 비교 개념은 S-11(#158)의 "commits ahead" 목록과 같은 방향이다.

**채택하지 않음**

- 워크트리 생성·이동·삭제와 Terminal/Finder 열기 같은 관리 동작 (S-05 v0.1 제외 범위).
- 비교 결과를 외부 diff 도구로 넘기는 방식. Overgrove는 외부 diff를 무력화한다(T3). 비교 결과는 앱 안의 S-10 Diff 뷰어로 본다.
- 병합 충돌 파일 수 예측. S-11의 범위가 아니다. 필요해지면 별도 이슈로 다룬다.

**출처**

- https://www.git-tower.com/blog/tower-mac-125
- https://www.git-tower.com/help/guides/worktrees/checkout/mac
- https://www.git-tower.com/help/guides/commit-history/compare-branches-revisions/mac
- https://git-tower.com/blog/tower-mac-8

Tower의 diff 보기가 Unified/Split 전환을 제공하는지는 공식 출처에서 확인하지 못했다. 그래서 diff 항목에서는 Tower를 근거로 쓰지 않는다.

### 3.2 Fork

**관찰한 패턴** (주로 공식 릴리스 노트 기준)

- 2.31(2023-07)에 기존 워크트리를 사이드바에 표시하기 시작했고, 2.32에서 사이드바 중첩, 2.59(2025-11)에서 "다른 워크트리에 체크아웃된 브랜치에 워크트리 아이콘"을 추가했다. 2.63에서 사이드바에서 워크트리를 고정(Pinned) 항목보다 앞에 두었고, 2.65에서 폴더 이름이 같은 워크트리 탭과 사이드바 항목을 구분하도록 했다.
- 1.0.4에서 Gravatar 계정이 없는 사용자를 위한 동적 아바타 생성기를 넣었고, 이후 Gravatar, GitHub 아바타 서비스를 기본으로 쓰게 바뀌었다. 1.0.81부터 커밋 목록에 아바타를 보여 준다.
- 커밋 목록에 stash를 보여 주며, 1.0.95에서 이를 숨기는 옵션을, 2.1에서 저장소별로 그 선택을 기억하게 했다.
- 1.0.94에서 커밋 그래프의 merge를 선택적으로 접는 기능을 넣었다.
- 1.0.50에서 side-by-side diff를 도입했고, 2.21에서 Local Changes 보기에도 넣었다. 이미지 diff, blame, 파일·디렉터리 이력을 제공한다.
- 1.0.64부터 사이드바에서 ⌘+클릭으로 두 브랜치를 비교한다.

**채택**

- 같은 폴더 이름의 워크트리를 구분해야 한다는 문제 인식. Overgrove는 워크트리 행의 주 텍스트를 브랜치 이름, 보조 텍스트를 경로의 마지막 디렉터리 이름(다를 때만)으로 정했다 ([information-architecture.md §4.4](information-architecture.md#44-워크트리-행의-이름)).
- "아바타가 없는 사람도 식별 가능한 그림을 받는다"는 발상. Overgrove는 이것을 **이니셜 아바타만** 쓰는 형태로 받아들인다(§4.4).
- Unified와 Split 두 보기 방식 (S-10).

**채택하지 않음**

- Gravatar, GitHub 아바타 서비스. 작성자 이메일을 외부 서비스로 보내게 되고(해시라도 추적 가능), 네트워크 요청과 이미지 디코딩이 생긴다. 조회 전용·오프라인 우선 원칙과 맞지 않는다.
- 커밋 그래프에 stash 노드 표시. stash 커밋의 부모 구조가 그래프를 어지럽히므로 v0.1에서 그리지 않는다 ([information-architecture.md §3.2](information-architecture.md#32-stash와-그래프)). Fork가 숨기기 옵션을 따로 둔 것도 같은 문제를 보여 준다.
- merge 접기, 이미지 diff, blame. v0.1 범위 밖이다. 이미지 diff는 S-10에서 명시적으로 제외했다.
- 저장소마다 탭을 여는 방식. Overgrove는 한 창에 저장소 하나를 두고 포커스 워크트리를 바꾼다.

**출처**

- https://fork.dev
- https://fork.dev/releasenotes

### 3.3 Sublime Merge

**관찰한 패턴**

- diff는 기본적으로 `git diff`처럼 압축된 보기다. hunk의 위·아래 가장자리를 끌어 문맥 줄을 늘리거나 줄일 수 있고, hunk 헤더 왼쪽의 토글로 파일 전체와 변경 부분을 오간다.
- 커밋 그래프에서 두 커밋을 고르면 그 사이의 diff가 커밋 상세 패널에 나온다.
- 저장소 전체를 입력하는 즉시 검색하며, 커밋 메시지, 작성자, 경로, 내용으로 거를 수 있다. side-by-side 비교, 글자 단위 강조, 문법 강조를 제공한다.
- 실행하는 git 명령을 그대로 보여 준다.

**채택**

- 기본은 압축된 hunk 보기이고 hunk 헤더를 구획 기준으로 삼는 구조 (S-10의 `@@ … @@` 헤더, `color.diff.hunk-header-bg`).
- 작성자로 거르는 검색. Overgrove 툴바 검색은 이미 작성자를 대상으로 하며, 작성자 필터 칩(§4.4)은 그것을 클릭 한 번으로 만드는 보조 수단이다.

**채택하지 않음**

- 문맥 줄 끌기와 전체 파일 토글. v0.1 S-10 명세에 없다. 쓸모는 크므로 later 후보로 본다.
- 문법 강조. S-10에서 v0.1 제외로 정했다. 단어 단위 강조는 토큰(`added-word-bg`, `removed-word-bg`)만 있고 later다.
- 그래프에서 임의의 두 커밋을 골라 비교하는 다중 선택. v0.1의 주 선택은 하나다 ([interaction.md §1.1](interaction.md#11-세-가지-상태)). "기준 대비 비교"는 S-11이 맡는다.

**출처**

- https://www.sublimemerge.com/
- https://www.sublimemerge.com/docs/diff_context
- https://www.sublimemerge.com/docs/faq

검색 문서(`/docs/search`)는 404였다. 검색 대상에 관한 설명은 위 홈 페이지 기준이다.

### 3.4 GitHub Desktop

**관찰한 패턴**

- 왼쪽 사이드바의 "Changes" 탭에 바뀐 파일을 모두 나열하고, 아이콘 색으로 추가·수정·삭제를 구분한다. 파일마다 체크박스로 커밋에 넣을지 고른다.
- diff 보기의 설정 메뉴에서 "Unified"(한 줄기 흐름)와 "Split"(왼쪽에 이전, 오른쪽에 이후)을 고른다. "Hide Whitespace Changes", 탭 너비 설정이 있고, 줄 번호 위아래 화살표나 "Expand Whole File"로 문맥을 펼친다.
- History 탭의 각 커밋은 메시지, 작성 시각, 커미터의 사용자 이름과 프로필 사진(있으면), SHA를 보여 준다. 연속한 여러 커밋을 고르면 합친 diff를 본다.
- 커밋 메시지 설명란에서 co-author를 추가한다. GitHub 문서는 trailer 형식을 `Co-authored-by: name <name@example.com>`으로, 메시지 끝의 빈 줄 뒤에 둔다고 정한다.
- "Preview Pull Request"는 현재 브랜치와 기준 브랜치 사이의 diff를 대화상자로 보여 준다. 기준 브랜치는 `base:` 드롭다운으로 고르고, 자동 병합 가능 여부를 알려 준다.

**채택**

- Unified(기본)/Split 전환과 선택 기억 (S-10).
- `Co-authored-by:` trailer를 co-author의 근거로 삼는 것. git 표준 trailer이므로 GitHub 연동 없이 커밋 메시지만으로 읽을 수 있다. AI 배지(§4.4)도 이 trailer에서 판정한다.
- "기준 브랜치 선택 + 기준 대비 diff"라는 PR 미리보기의 뼈대. S-11(#158)은 이것을 대화상자가 아닌 중앙 영역 화면으로 두고, 커밋 목록과 파일 목록을 함께 보여 준다.

**채택하지 않음**

- 파일 체크박스와 커밋 작성란. 쓰기 동작이다 (S-02 v0.1 제외).
- 프로필 사진. 네트워크 아바타를 쓰지 않는다(§4.4).
- 추가·수정·삭제를 색 아이콘만으로 구분하는 방식. Overgrove는 변경 종류 글자(M/A/D/R…)와 상태 심볼을 함께 쓴다 ([interaction.md §6.2](interaction.md#62-색에만-의존하지-않는다)).
- PR 생성, 병합 가능 여부 표시. GitHub 연동은 이슈 조회만이다 (ADR-0004).
- 공백 변경 숨기기. S-10에서 공백 관련 옵션은 later로 두었다.

**출처**

- https://docs.github.com/en/desktop/making-changes-in-a-branch/committing-and-reviewing-changes-to-your-project-in-github-desktop
- https://docs.github.com/en/desktop/making-changes-in-a-branch/viewing-the-branch-history-in-github-desktop
- https://docs.github.com/en/desktop/working-with-your-remote-repository-on-github-or-github-enterprise/creating-an-issue-or-pull-request-from-github-desktop
- https://docs.github.com/en/pull-requests/committing-changes-to-your-project/creating-and-editing-commits/creating-a-commit-with-multiple-authors

`desktop.github.com/features/compare-branches`는 리디렉션 페이지만 받았고, 커밋 비교 문서 한 곳은 404였다. History 화면에서 co-author가 어떻게 그려지는지는 공식 문서로 확인하지 못했으므로 이 문서에서 다루지 않는다. GitHub Desktop의 워크트리 지원도 공식 문서에서 확인하지 못했다.

### 3.5 GitKraken Desktop

**관찰한 패턴**

- 창 구성: 왼쪽 패널(로컬 브랜치, 원격, 태그, stash, 서브모듈, PR, 이슈), 가운데 커밋 그래프(최신이 위), 오른쪽 커밋 패널(Unstaged → Staged → 커밋 메시지), 위쪽 툴바(Undo, Redo, Pull, Push, Branch, Stash, Pop), 아래쪽 상태바(서비스 요약, 요금제, 확대 비율).
- 그래프 기본 열은 Branch/Tag, Graph, Commit Message이고 Author, Date/Time, SHA는 선택 열이다. 브랜치에 마우스를 올리면 관련 커밋을 강조하고 나머지를 흐린다.
- 그래프 맨 위 WIP 노드를 누르면 미커밋 변경을 본다. 12.3.0(2026-07)부터 미커밋 변경이나 활성 에이전트 세션이 있는 **모든 워크트리**에 WIP 노드를 하나씩 그리고, 다른 워크트리의 WIP 행을 고르면 "Open Worktree" 동작을 보여 준다. 12.6.1에서 WIP 행에 각 워크트리의 브랜치(또는 detached 커밋)를 표시했다.
- 12.0.0의 Agent Sessions 보기는 워크트리마다 카드를 두고 브랜치, 미커밋 변경, ahead/behind, PR, 코딩 에이전트 상태를 보여 준다. 12.6.0에서 브랜치 이름과 폴더 이름이 다르면 폴더 이름을 아래에 보여 준다.
- 12.4.1의 "View changes in PR"은 기준과 head 사이의 전체 diff를 보여 준다. 12.6.0에서 연속한 커밋을 고르면 합친 변경을 오른쪽 패널에 보여 준다.
- 환경설정에서 아바타 대신 작성자 이니셜을 표시하도록 고를 수 있다. 연동이 없으면 아바타는 생성된 identicon 또는 Gravatar다. 검색 결과로 본 도움말 요약에 따르면 Author 열에서 작성자나 팀으로 커밋을 거를 수 있다.

**채택**

- 그래프 맨 위의 WIP 행. Overgrove는 포커스 워크트리의 WIP 행 하나를 맨 위에 둔다 (S-01).
- 작성자 이니셜 표시. GitKraken은 선택 사항이지만 Overgrove는 이니셜만 쓴다(§4.4).
- 작성자로 그래프를 거르는 조작. Overgrove는 그래프 툴바의 작성자 필터 칩 줄로 둔다(§4.4).
- 브랜치 이름과 폴더 이름이 다를 때 둘 다 보여 주는 규칙. Overgrove의 워크트리 행 이름 규칙과 같은 결론이다.

**채택하지 않음**

- 툴바의 Pull, Push, Branch, Stash, Pop. v0.1 툴바에 쓰기 버튼은 없다 (S-01 툴바, ADR-0011).
- 상태바의 서비스 요약, 요금제, 확대 비율. Overgrove 상태바는 저장소 단위의 Git 상태 요약만 둔다.
- 에이전트 세션 카드와 에이전트 상태 연동. Overgrove는 git이 남긴 결과(워크트리, 커밋, trailer)만 읽고 에이전트 프로세스와 연동하지 않는다. AI의 흔적은 커밋의 `Co-authored-by:` trailer에서만 읽는다.
- 워크트리마다 WIP 노드를 그리는 방식은 v0.1에서 받아들이지 않는다. S-01은 포커스 워크트리의 WIP 행만 둔다. 다른 워크트리의 미커밋 상태는 사이드바 배지로 본다. 여러 WIP 행은 **열린 질문**이다(later 후보).
- 워크트리를 탭으로 묶는 방식, Gravatar·identicon, GitKraken 고유의 명칭과 화면 문구 ([interaction.md §7](interaction.md#7-화면-문구-원칙)), 청록·보라 계열 브랜드 톤 ([design-tokens.md §1](design-tokens.md#1-원칙)).

**출처**

- https://help.gitkraken.com/start-here/interface
- https://help.gitkraken.com/release-notes/current/
- https://help.gitkraken.com/start-here/preferences/
- https://support.gitkraken.com/gitkraken-desktop/profiles (검색 결과로만 확인. 아바타 출처와 이니셜 설정 설명)

Author 열 필터는 공식 도움말 페이지를 직접 받아 확인하지 못했고 검색 결과 요약에 근거한다. 그래서 필터가 행을 흐리게 하는지 숨기는지는 다루지 않는다.

### 3.6 Xcode Source Control

**관찰한 패턴**

- Project navigator가 마지막 커밋 이후 바뀐 파일에 `A`(새 파일), `M`(수정) 글자를 붙인다. 편집기 거터에 change bar를 그린다.
- Code Review를 켜면 현재 파일과 최근 커밋의 비교 보기로 바뀐다. 기본은 Inline Comparison이고 Side by Side Comparison으로 바꿀 수 있다. 아래쪽 컨트롤로 변경 사이를 이동하고 비교할 다른 커밋을 고른다.
- Source Control navigator의 Changes 탭은 All Changes / Unstaged / Staged 탭으로 거르고, 파일 헤더에 펼침 삼각형과 "변경만 / 파일 전체" 토글을 둔다.
- Repositories 탭에서 브랜치를 고르면 편집기 영역에 커밋 목록이 나오고 Filter 필드로 거른다.

**채택**

- 변경 종류를 한 글자(`M`, `A`, …)로 쓰는 macOS 관례. Overgrove 파일 행의 종류 글자와 같다 (S-02, S-03).
- inline(=Unified)과 side-by-side(=Split) 두 방식. macOS 사용자가 이미 아는 이원 구조다.
- 파일 단위 헤더 아래에 hunk를 모으는 구조. S-11의 파일 목록 → S-10 이동과 맞는다.

**채택하지 않음**

- change bar의 Stage/Discard 메뉴, Stage All, 커밋 작성. 쓰기 동작이다.
- Changes 탭의 탭 필터. Overgrove는 S-02에서 CONFLICTED → STAGED → UNSTAGED → UNTRACKED 그룹을 한 목록에 함께 보여 준다. 워크트리 하나의 전체 상태를 한눈에 보는 것이 목적이어서다.

**출처**

- https://developer.apple.com/documentation/xcode/tracking-code-changes-in-a-source-control-repository
- https://developer.apple.com/documentation/xcode/configuring-the-xcode-project-window
- https://help.apple.com/xcode/mac/current/en.lproj/dev5ace8e9eb.html

### 3.7 lazygit

**관찰한 패턴**

- 터미널 UI이고 Status, Files, Worktrees, Local branches, Remotes, Commits, Stash 같은 목록 패널과 diff를 보여 주는 main 패널로 나뉜다. Worktrees 패널에서 새로 만들기, 전환, 편집기로 열기, 제거를 한다.
- 커밋 패널은 작성자마다 색을 하나씩 정해 쓰고(`gui.theme.authorColors`로 사람별 지정 가능), 좁은 보기에서는 작성자 이름을 이니셜 2자로 줄인다(`gui.commitAuthorShortLength` 기본 2). 그래프 표시 여부는 `git.log.showGraph`로 정한다.
- 커밋 하나를 표시(`shift+w`)해 두면 이후 고르는 커밋을 그 기준과 비교하는 diffing 모드가 있다. 비교 방향을 뒤집을 수 있고 `<escape>`로 나간다.

**채택**

- 작성자마다 색 하나 + 이니셜 2자. 좁은 화면에서도 누가 커밋했는지 빠르게 구분된다. Overgrove는 색을 무작위가 아니라 **결정적으로**(이메일 해시) 정해서 실행할 때마다, 기기마다 같은 사람이 같은 색을 갖게 한다(§4.4).
- "기준 ref를 정해 두고 그 대비 변경을 본다"는 모드 개념. S-11은 이것을 기준 브랜치 선택기로 드러낸다.

**채택하지 않음**

- 사용자가 사람별 색을 직접 지정하는 설정. 대비 검증(흰 이니셜 4.5:1)을 보장할 수 없다.
- 워크트리 생성·제거, stash 적용 같은 쓰기 동작.
- 모드 키(숨은 상태)로 비교를 켜는 방식. GUI에서는 S-11이라는 별도 화면과 `‹ Graph` 복귀로 상태를 눈에 보이게 한다.

**출처**

- https://github.com/jesseduffield/lazygit
- https://github.com/jesseduffield/lazygit/blob/master/docs/Config.md
- https://github.com/jesseduffield/lazygit/blob/master/docs/keybindings/Keybindings_en.md

### 3.8 Apple Human Interface Guidelines

HIG 웹 페이지는 스크립트로 그려져 본문을 바로 받지 못했다. 같은 페이지의 Apple 문서 데이터(JSON)를 받아 본문을 확인했고, 아래에는 사람이 여는 페이지 URL을 적는다.

**사이드바**

- 계층은 대체로 **두 단계를 넘기지 않는다.** 더 깊으면 사이드바와 상세 사이에 목록 단을 둔다. 내용이 많으면 펼침 컨트롤로 묶는다.
- macOS에서는 보기/숨기기 버튼이나 View 메뉴의 Show/Hide Sidebar 명령을 둔다. 기본으로 숨기지 않는다.
- 사이드바 아이콘 색은 기본적으로 사용자 액센트 색을 따르고, 고정 색은 의미를 분명히 할 때만 아껴 쓴다.
- 중요한 정보나 동작을 사이드바 맨 아래에 두지 않는다. 창을 옮기다 아래쪽이 가려지는 일이 잦다.
- 가능하면 사용자가 사이드바 내용을 바꿀 수 있게 한다.

**분할 보기(Split views)**

- 상세로 이어지는 각 단에서 현재 선택을 계속 강조한다.
- 최소·최대 크기를 정해 구분선이 사라지지 않게 한다. 단을 숨길 수 있게 하고, 툴바 버튼이나 단축키가 있는 메뉴 명령처럼 여러 경로로 다시 보이게 한다. 얇은(1pt) 구분선을 우선한다.

**툴바**

- 항목을 골라서 넣고 붐비지 않게 한다. 묶음은 대체로 셋 이하로 한다.
- 앞쪽 끝에는 사이드바 토글과 제목, 가운데에는 자주 쓰는 컨트롤, 뒤쪽 끝에는 늘 보여야 할 항목과 검색 필드를 둔다.
- 창 제목에 앱 이름을 쓰지 않는다.

**빈 상태, 에러, 로딩**

- SwiftUI `ContentUnavailableView`는 내용을 보여 줄 수 없을 때(빈 목록, 검색 결과 없음, 오류) 쓰는 표준 보기이고 macOS 14부터 쓸 수 있다.
- 빈 화면에는 다음에 할 수 있는 일을 분명히 보여 주고, 가능하면 버튼을 둔다. 빈 상태는 일시적이므로 중요한 정보를 거기에만 두지 않는다.
- 에러 문구는 문제 가까이에 두고, 탓하지 않으며, 고칠 방법을 말한다. "oops" 같은 감탄사와 "we"를 피한다.
- 로딩 중에는 가능한 빨리 무엇이든 보여 주고, 다른 일을 계속할 수 있게 한다.

**색과 접근성**

- 같은 색으로 서로 다른 뜻을 나타내지 않는다. 라이트, 다크, Increase Contrast 모두에서 맞는 색을 쓴다. 시스템 색을 우선한다.
- 색만으로 정보를 전하지 않는다. 모양이나 아이콘을 함께 쓴다. 대비는 WCAG AA 수준을 기준으로 삼는다.

**Overgrove의 대응**

| HIG 지침 | Overgrove | 비고 |
|---|---|---|
| 사이드바 두 단계 이하 | WORKTREES, STASHES, ISSUES는 한 단계. LOCAL은 섹션 → `feat/` 폴더 → 브랜치 | REMOTE는 섹션 → 원격 → 폴더 → 브랜치로 지침보다 깊어질 수 있다. 원격이 하나일 때 원격 단계를 생략할지는 **열린 질문**이다 |
| 사이드바 내용 사용자 정의 | 섹션 순서 고정 | 위치 기억을 우선했다. 순서 바꾸기는 later ([information-architecture.md §6](information-architecture.md#6-v01-범위-밖-later)) |
| 아이콘은 액센트 색, 고정 색은 의미가 있을 때만 | 포커스 표시는 `accent`, 고정 색은 충돌·prunable 같은 상태에만 | [information-architecture.md §4.3](information-architecture.md#43-행-구성과-배지) |
| 사이드바 맨 아래에 중요 정보 두지 않기 | 저장소 요약은 창 하단 상태바에 두되, 경고(prunable 등)는 사이드바 행 배지에도 나온다 | 상태바가 가려져도 경고를 놓치지 않는다 |
| 단마다 선택 강조, 최소·최대 크기, 숨긴 단 복원 경로 | `size.sidebar-width-*`, `size.detail-width-*`, View 메뉴 `Hide Detail` | [screens.md S-01](screens.md#s-01-메인-창) |
| 툴바 묶음 셋 이하, 검색은 뒤쪽 끝 | 저장소 메뉴·Fetch / 포커스 브랜치 / 검색 | [screens.md 툴바](screens.md#툴바) |
| `ContentUnavailableView`, 다음 행동 제시 | 공통 빈 상태: 심볼 + 한 줄 설명 + 다음 행동 | macOS 14 최소 버전(ADR-0003)과 맞는다 |
| 색만으로 전하지 않기 | 상태 색에는 항상 심볼과 텍스트, diff에는 `+`/`−` 기호 | [interaction.md §6.2](interaction.md#62-색에만-의존하지-않는다) |

**출처**

- https://developer.apple.com/design/human-interface-guidelines/sidebars
- https://developer.apple.com/design/human-interface-guidelines/split-views
- https://developer.apple.com/design/human-interface-guidelines/toolbars
- https://developer.apple.com/design/human-interface-guidelines/writing
- https://developer.apple.com/design/human-interface-guidelines/loading
- https://developer.apple.com/design/human-interface-guidelines/color
- https://developer.apple.com/design/human-interface-guidelines/accessibility
- https://developer.apple.com/documentation/swiftui/contentunavailableview

---

## 4. 주제별 종합

### 4.1 워크트리 개관

- Tower, Fork, lazygit은 워크트리를 사이드바 섹션이나 패널 하나로 다루고, 주된 동작은 "그 워크트리로 전환"이다. Tower와 Fork는 워크트리에 체크아웃된 브랜치에 아이콘이나 배지를 붙인다.
- GitKraken은 워크트리마다 카드(브랜치, 변경, ahead/behind, 에이전트 상태)와 WIP 노드를 두어 여러 워크트리를 동시에 보여 주는 쪽으로 가장 멀리 나갔다.
- **Overgrove 결론.** 워크트리를 "전환할 대상"이 아니라 "나란히 둘 대상"으로 본다. WORKTREES 섹션을 맨 위에 두고, 행마다 충돌, prunable, 변경 수, ahead/behind, locked, 이슈 번호 배지를 보여 준다. 포커스 워크트리를 바꿔도 다른 워크트리의 배지는 그대로 보인다. 관리 동작은 없다.

### 4.2 WIP(미커밋 변경) 행

- GitKraken은 그래프 맨 위에 WIP 노드를 두고, 최근 버전은 워크트리마다 하나씩 둔다. GitHub Desktop과 Xcode는 그래프 대신 별도 Changes 탭에서 미커밋 변경을 다룬다.
- **Overgrove 결론.** 포커스 워크트리에 변경이 있을 때만 맨 위에 WIP 행 하나를 둔다. 속이 빈 점선 노드(`color.graph.wip-node`), 행 배경 `color.surface.wip-row`, 요약 `3 staged · 2 unstaged · 1 untracked`, 충돌이 있으면 `⚠ n conflicted`를 앞에 붙인다. 선택하면 S-02. 여러 워크트리의 WIP 행을 동시에 그리는 방식은 열린 질문으로 남긴다.

### 4.3 커밋 그래프 레인

- GitKraken은 열이 브랜치, 선이 merge와 관계를 나타낸다고 설명하고, 브랜치 위에 마우스를 올리면 관련 커밋만 강조한다. Fork는 merge를 접는다. lazygit은 그래프 표시를 끌 수 있고, 커밋 색에 push 여부 같은 상태를 싣는다.
- **Overgrove 결론.** 레인은 앱이 계산하고(ADR-0010), 색은 `color.graph.lane.0~7`을 순환한다. 레인 색은 "어느 줄기인가"만 뜻하고 작성자나 push 상태를 싣지 않는다. 한 색에 한 뜻만 둔다는 HIG 지침 때문이다. 작성자 색은 아바타(§4.4)에만 쓴다. stash 노드, merge 접기, 마우스 올림 강조는 v0.1에 없다.

### 4.4 작성자 표시

**이니셜 아바타.** Fork(아바타 없는 사용자용 생성 아바타), GitKraken(이니셜 표시 옵션), lazygit(작성자별 색 + 이니셜 2자)이 선례다. Overgrove는 다음과 같이 정한다.

- 네트워크 아바타(Gravatar, GitHub, identicon 서비스)를 쓰지 않는다. 이메일이 외부로 나가지 않고, 오프라인에서도 같은 화면이 나온다.
- 색은 `color.avatar.0~7` 중 하나다. 인덱스는 다듬고 소문자로 바꾼 작성자 이메일의 FNV-1a 32비트 해시를 8로 나눈 나머지다. 라이트·다크에서 같은 값이고 흰 이니셜과의 대비 4.5:1을 넘는다 ([`tokens.json`](../../design/tokens/tokens.json)의 `semantic.color.avatar`). 색은 신원 힌트일 뿐이고 이름이나 툴팁이 항상 함께 있다.
- 그래프 작성자 열은 폭이 좁으면 이니셜로 줄인다 ([screens.md 중앙: 커밋 그래프](screens.md#중앙-커밋-그래프)).

**co-author와 AI 배지.** GitHub 문서가 정한 `Co-authored-by:` trailer를 근거로 쓴다. 커밋에 AI 도구를 가리키는 co-author trailer가 있으면 그래프 행과 S-03에 "AI" 배지를 붙인다. 이번 조사에서 같은 배지를 그래프에 붙이는 Git 클라이언트는 찾지 못했다. 가장 가까운 것은 GitKraken이 워크트리 카드와 WIP 행에 보여 주는 에이전트 상태지만, 이것은 실행 중인 에이전트 프로세스와 연동한 결과다. Overgrove는 커밋에 남은 기록만 읽는다. 어떤 trailer 값을 AI로 볼지는 이 문서에서 정하지 않는다.

**작성자 필터 칩.** GitKraken은 Author 열에서, Sublime Merge는 검색에서 작성자로 거른다. Overgrove는 그래프 툴바에 작성자 칩 줄을 두고, 칩을 고르면 검색과 같은 방식(일치 행 강조, 나머지 흐림)으로 동작한다.

**원격 브랜치의 마지막 커미터.** 사이드바 REMOTE 행에 마지막 커밋 작성자를 붙이는 직접적인 선례는 확인하지 못했다. 가장 가까운 것은 Tower Branches Review의 마지막 갱신일 정렬이다. Overgrove에서는 "이 원격 브랜치를 누가 마지막으로 밀었는가"가 팀원과 에이전트의 작업을 구분하는 단서여서 넣는다. 배지 우선순위 규칙([information-architecture.md §4.3](information-architecture.md#43-행-구성과-배지))을 따라 폭이 모자라면 먼저 숨긴다.

### 4.5 Diff 뷰어

| 측면 | 관찰 | Overgrove (S-10) |
|---|---|---|
| 보기 방식 | GitHub Desktop Unified/Split, Xcode Inline/Side by Side, Fork side-by-side | `Unified`(기본) / `Split`, 선택 기억 |
| hunk 헤더 | Sublime Merge는 hunk 헤더를 문맥 확장 손잡이로 씀 | `@@ … @@` 헤더, `color.diff.hunk-header-bg`. 확장 손잡이는 later 후보 |
| 줄 번호 | GitHub Desktop은 줄 번호 옆 화살표로 문맥 확장 | 이전·이후 줄 번호를 모두 표시 |
| 추가·삭제 표시 | 대부분 색 배경 | 색 배경 + `+`/`−` 기호 |
| 문맥 확장, 전체 파일 | Sublime Merge, GitHub Desktop, Xcode | v0.1 없음. later 후보 |
| 공백 숨기기 | GitHub Desktop | later |
| 글자 단위 강조 | Sublime Merge, Xcode | 토큰만 있음. later |
| 문법 강조, 이미지 diff | Sublime Merge, Fork | v0.1 제외 |
| 외부 diff 도구 | Tower | 쓰지 않음 (`--no-ext-diff --no-textconv`, T3) |
| 줄 단위 스테이징 | Sublime Merge, Fork, Xcode, lazygit | 쓰기 동작이므로 없음 |

### 4.6 PR식 "변경된 파일" 보기 (S-11, #158)

- 선례: GitHub Desktop의 Preview Pull Request(기준 브랜치 드롭다운 + 기준 대비 diff), Tower의 Compare(브랜치에만 있는 커밋 + 뒤처진 수), GitKraken의 View changes in PR(기준과 head 사이 전체 diff)과 연속 커밋 합친 변경, lazygit의 diffing 모드(표시한 ref 대비), Sublime Merge의 두 커밋 비교.
- 공통 뼈대는 **기준 선택 → 기준 이후 커밋 → 합친 파일 변경 → 파일별 diff**다. 에이전트가 만든 워크트리를 "PR로 올리기 전에 무엇이 바뀌었나" 관점으로 검토하는 데 바로 맞는다.
- **Overgrove 결론.** S-11은 중앙 영역 화면이다. 기준 브랜치 선택기, 미커밋 변경 포함 토글, ahead 커밋 목록, 파일 목록(`+n −m`), untracked 구역을 두고, 파일을 고르면 S-10을 보여 준다. 다른 제품에는 없는 "미커밋 포함" 토글은 커밋하지 않은 에이전트 작업까지 한 번에 검토하려고 둔다. 대화상자로 띄우지 않는 이유는 `‹ Graph`와 `⎋` 복귀 같은 기존 중앙 영역 전환 규칙([interaction.md §1.3](interaction.md#13-중앙-영역-전환))을 그대로 쓰기 위해서다.
- 받아들이지 않음: PR 생성, 병합 가능 여부, 충돌 파일 수 예측, 외부 diff 도구.

### 4.7 상태바

- GitKraken은 상태바에 서비스 요약, 요금제, 확대 비율을 둔다. 다른 조사 대상의 공식 문서에서는 상태바 구성을 확인하지 못했다.
- **Overgrove 결론.** 상태바는 저장소 단위 요약만 둔다: 마지막 fetch, 포커스 워크트리의 ahead/behind, 워크트리 수, 경고, 진행 중 작업, gh 상태 ([screens.md 상태바](screens.md#상태바)). 계정 홍보, 요금제, 확대 비율 같은 앱 운영 정보는 두지 않는다. HIG가 창 아래쪽이 가려질 수 있다고 하므로 상태바에만 있는 경고를 만들지 않는다. prunable 같은 경고는 사이드바 배지에도 나온다.

### 4.8 빈 상태와 에러 상태

- HIG는 `ContentUnavailableView`, 다음 행동 제시, 탓하지 않는 에러 문구를 권한다. 조사한 Git 클라이언트의 공식 문서에서는 빈 상태 화면을 자세히 다루지 않았다.
- **Overgrove 결론.** 공통 상태 표기를 그대로 쓴다 ([screens.md](screens.md) 머리의 공통 상태 표). 빈 상태는 심볼 + 한 줄 설명 + 다음 행동, 에러는 `exclamationmark.triangle` + 요약 + `Details`(마스킹한 stderr), 로딩은 150ms 지연 뒤 표시, 새로고침 실패는 이전 데이터를 흐리게 유지한다. 앱이 대신 하지 않는 일(prune, `safe.directory` 설정, `gh auth login`)은 명령을 복사할 수 있게만 한다.

---

## 5. 요약 표

| 패턴 | 출처 | Overgrove 결정 | 명세 위치 |
|---|---|---|---|
| 사이드바 워크트리 섹션 | Tower, Fork, lazygit | 채택. 맨 위 고정, 행마다 상태 배지 | [information-architecture.md §4](information-architecture.md#4-사이드바-섹션), [screens.md 사이드바](screens.md#사이드바) |
| 워크트리에 체크아웃된 브랜치 표시 | Tower, Fork | 채택. LOCAL 행에 `tree` 심볼 | [information-architecture.md §4.3](information-architecture.md#43-행-구성과-배지) |
| 같은 폴더 이름 구분, 브랜치·폴더 이름 병기 | Fork, GitKraken | 채택. 다를 때만 보조 텍스트 | [information-architecture.md §4.4](information-architecture.md#44-워크트리-행의-이름) |
| 워크트리 관리(생성·이동·삭제) | Tower, Fork, GitKraken, lazygit | 채택 안 함 (쓰기) | [screens.md S-05](screens.md#s-05-워크트리-상세) |
| 그래프 맨 위 WIP 행 | GitKraken | 채택. 포커스 워크트리 하나만 | [screens.md S-01](screens.md#s-01-메인-창), [S-02](screens.md#s-02-wip-상세) |
| 워크트리마다 WIP 행 | GitKraken | v0.1 채택 안 함. 열린 질문 | — |
| 에이전트 세션 카드·상태 | GitKraken | 채택 안 함. trailer만 읽음 | — |
| 그래프의 stash 노드 | Fork | 채택 안 함 (later) | [information-architecture.md §3.2](information-architecture.md#32-stash와-그래프) |
| merge 접기, 마우스 올림 강조 | Fork, GitKraken | v0.1 없음 | — |
| 레인 색 순환 | GitKraken (열 = 브랜치) | 채택. `color.graph.lane.0~7`, 레인에만 색 | [screens.md 중앙: 커밋 그래프](screens.md#중앙-커밋-그래프) |
| 이니셜 아바타 + 결정적 작성자 색 | Fork, GitKraken, lazygit | 채택. `color.avatar.0~7`, 이메일 해시 | [screens.md 중앙: 커밋 그래프](screens.md#중앙-커밋-그래프), [mockups.md](mockups.md) |
| 네트워크 아바타(Gravatar 등) | Fork, GitKraken, GitHub Desktop | 채택 안 함 | — |
| `Co-authored-by:` co-author | GitHub Desktop, GitHub 문서 | 채택. S-03 메타와 AI 배지의 근거 | [screens.md S-03](screens.md#s-03-커밋-상세), [mockups.md](mockups.md) |
| AI 배지 | (직접 선례 없음) | 채택. AI co-author trailer가 있는 커밋 | [screens.md S-03](screens.md#s-03-커밋-상세), [mockups.md](mockups.md) |
| 작성자 필터 | GitKraken, Sublime Merge | 채택. 그래프 툴바 칩 줄 | [screens.md 작성자 표현](screens.md#작성자-표현과-ai-배지), [mockups.md](mockups.md) |
| 원격 브랜치 마지막 커미터 | (가까운 것: Tower Branches Review) | 채택. 배지 우선순위 최하위 | [screens.md 작성자 표현](screens.md#작성자-표현과-ai-배지), [mockups.md](mockups.md) |
| Unified / Split | GitHub Desktop, Xcode, Fork | 채택. Unified 기본 | [screens.md S-10](screens.md#s-10-diff-뷰어) |
| hunk 헤더, 양쪽 줄 번호, `+`/`−` 기호 | Sublime Merge, GitHub Desktop | 채택 | [screens.md S-10](screens.md#s-10-diff-뷰어) |
| 문맥 확장, 전체 파일 토글 | Sublime Merge, GitHub Desktop, Xcode | later 후보 | [screens.md S-10](screens.md#s-10-diff-뷰어) |
| 공백 숨기기, 글자 단위 강조, 문법 강조 | GitHub Desktop, Sublime Merge, Xcode | later / v0.1 제외 | [screens.md S-10](screens.md#s-10-diff-뷰어) |
| 외부 diff 도구 | Tower | 채택 안 함 (T3) | [security-review.md](security-review.md) |
| 기준 브랜치 대비 변경 (PR 미리보기) | GitHub Desktop, Tower, GitKraken, lazygit, Sublime Merge | 채택. 미커밋 포함 토글 추가 | S-11 (#158) |
| 병합 가능 여부, 충돌 예측 | GitHub Desktop, Tower | 채택 안 함 | S-11 (#158) |
| 상태바 저장소 요약 | GitKraken (반면 사례) | 채택. Git 상태만, 운영 정보 없음 | [screens.md 상태바](screens.md#상태바) |
| 툴바 세 묶음, 검색 뒤쪽 끝 | Apple HIG | 채택. 쓰기 버튼 없음 | [screens.md 툴바](screens.md#툴바) |
| 사이드바 두 단계 이하 | Apple HIG | 대부분 지킴. REMOTE 깊이는 열린 질문 | [information-architecture.md §4.1](information-architecture.md#41-섹션-순서) |
| 단 숨기기·크기 제한·선택 강조 | Apple HIG | 채택 | [screens.md S-01](screens.md#s-01-메인-창), [interaction.md §1](interaction.md#1-선택과-포커스-모델) |
| `ContentUnavailableView`, 다음 행동 제시 | Apple HIG | 채택 | [screens.md S-01 상태](screens.md#상태) |
| 색만으로 전하지 않기, WCAG AA 대비 | Apple HIG | 채택 | [interaction.md §6](interaction.md#6-접근성), [design-tokens.md](design-tokens.md) |

---

## 6. 확인하지 못한 것

- Apple HIG 웹 페이지 본문은 직접 받지 못했다. 같은 페이지의 Apple 문서 데이터(JSON)로 내용을 확인했다.
- Sublime Merge 검색 문서(`https://www.sublimemerge.com/docs/search`)와 GitHub Desktop 커밋 비교 문서 한 곳은 404였다. GitHub Desktop의 compare-branches 기능 페이지는 리디렉션만 받았다.
- Tower의 Unified/Split 전환, GitHub Desktop History의 co-author 표시 방식, GitHub Desktop의 워크트리 지원은 공식 출처로 확인하지 못해 근거로 쓰지 않았다.
- GitKraken Author 열 필터와 아바타 출처 설명(`https://support.gitkraken.com/gitkraken-desktop/profiles`)은 검색 결과 요약에만 근거한다.
- 원격 브랜치 행에 마지막 커미터를 붙이는 선례, 커밋에 AI 배지를 붙이는 선례는 찾지 못했다.
