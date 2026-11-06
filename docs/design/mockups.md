# 목업 갤러리 (Mockups)

> 상태: Draft (#159, 패널 테마로 다시 그림 #166, 남은 화면 추가 #176) · 관련: [art-direction.md](art-direction.md), [screens.md](screens.md), [references.md](references.md), [design-tokens.md](design-tokens.md), [iconography.md](iconography.md), [interaction.md](interaction.md), #158, #159, #166

주요 화면의 고충실도 목업을 모은다. 화면의 동작과 문구는 [screens.md](screens.md)가 기준이고, 모양의 수치는 [art-direction.md](art-direction.md)가 기준이다. 이 문서는 그 명세를 그림으로 보여 준다. 그림과 명세가 다르면 명세를 따르고 목업을 고친다.

---

## 1. 만드는 방법과 규칙

| 항목 | 규칙 |
|---|---|
| 위치 | [`design/mockups/`](../../design/mockups/). 파일 이름은 `<화면 ID>-<이름>-<light\|dark>.svg/.png`. S-01만 기존 이름 `main-window-<light\|dark>`를 유지한다 |
| 생성기 | [`design/mockups/generator/`](../../design/mockups/generator/)의 `render.sh`가 모든 SVG와 PNG를 다시 만든다. 앱과 CI는 쓰지 않는 선택 도구다. Python 3 + fontTools, `rsvg-convert`가 필요하다 |
| 원본 | SVG가 원본이다. PNG는 렌더링한 뒤 무손실로 다시 압축했다. S-01은 README 대표 이미지라 2배(2880×1800), 나머지는 1440×900이다 |
| 크기 | 창 1440×900pt. 메인 창 화면은 전체 창으로 그려 세 패널의 관계가 보이게 했다. S-08 설정은 별도 창이라 1440×560 캔버스에 세 탭을 나란히 그렸다 |
| 색 | 메인 창의 모든 색은 [`design/tokens/tokens.json`](../../design/tokens/tokens.json)의 값이다. 대비 검증은 `generator/colorcheck.py`, 수치는 [design-tokens.md §5](design-tokens.md#5-검증-결과)에 있다. S-08은 네이티브 컨트롤이라 macOS 시스템 색 근삿값(생성기의 `NATIVE`, 토큰 아님)과 액센트만 쓴다 |
| 글꼴 | SF Pro(Text)와 SF Mono. `generator/mkfonts.py`가 시스템 가변 글꼴에서 고정 굵기 인스턴스(Regular, Medium, Semibold, Bold)를 만들어 렌더러에 넘긴다. 만든 글꼴은 로컬 전용이며 커밋하지 않는다. SVG를 브라우저로 열면 `-apple-system`으로 보인다 |
| 심볼 | SF Symbol을 흉내 낸 단순 도형이다(실제 앱은 SF Symbols를 쓴다). 상태 색은 항상 서로 다른 실루엣과 함께 쓴다: staged 채운 원+체크, unstaged 연필, untracked 빈 원+물음표, conflicted 채운 삼각형 |
| 간격 | 8pt 격자. 툴바 52, 상태바 30, 패널 사이 홈 8, 패널 머리 40, 열 머리 28, 그래프 행 30, 워크트리 행 46, 사이드바 행 28, 파일 행 26, 사이드바 256, 상세 344 |
| 스크롤과 손잡이 | 스크롤 위치를 보여 주려고 오버레이 스크롤바 썸을 그렸다. S-01은 오른쪽 분할선을 포인터를 올린 상태(액센트 손잡이 + 크기 조절 커서)로 그렸다 |
| 샘플 데이터 | 가상의 저장소 `acme/api`(Go)와 가상 인물(Mina Park, Alex Kim, Jordan Lee, Sam Rivera), AI 공동 작성자 `Coding Agent <agent@example.com>`. 경로는 `~/dev/...`. 실제 개인 정보는 없다 |
| 브랜드 | 다른 제품의 로고, 아이콘, 팔레트, 문구를 쓰지 않았다. 참고한 것은 배치 패턴뿐이다([art-direction.md §11](art-direction.md#11-참고한-것과-가져오지-않은-것)). S-07의 마크는 Overgrove의 [`mark.svg`](../../design/icon/mark.svg)다 |

샘플 데이터는 화면끼리 맞물린다. S-01의 WIP(staged 2, unstaged 3, untracked 2)는 S-11의 미커밋 파일 5개와 untracked 2개가 되고, S-03의 커밋 `a91f3c2` 파일 목록은 S-10과 S-11의 `middleware.go` 패치와 같다.

다시 만들기:

```sh
cd design/mockups/generator
python3 -m venv .venv && .venv/bin/pip install fonttools   # 처음 한 번
brew install librsvg                                       # rsvg-convert, 처음 한 번
./render.sh                                                # 글꼴 인스턴스 생성 → SVG → PNG
python3 colorcheck.py                                      # 토큰 대비 검증
```

---

## 2. 화면별

### S-01 메인 창

| Light | Dark |
|---|---|
| ![S-01 메인 창 (light)](../../design/mockups/main-window-light.png) | ![S-01 메인 창 (dark)](../../design/mockups/main-window-dark.png) |

원본: [`main-window-light.svg`](../../design/mockups/main-window-light.svg), [`main-window-dark.svg`](../../design/mockups/main-window-dark.svg)

- **구조.** 툴바, 둥근 상자 패널 3개(사이드바, 그래프, 상세), 상태바. 패널 사이 홈에 크기 조절 손잡이가 있다.
- **툴바.**
  - 저장소 전환 메뉴, 포커스 워크트리 칩(레인 색, `↑2`, `⌘J`)
  - 가운데 `Fetch`, `Refresh`, `Compare`, `Terminal`, `Finder`(아이콘 + 라벨)
  - 오른쪽 검색 필드
  - 쓰기 버튼은 없다.
- **사이드바.**
  - 필터 필드
  - WORKTREES 6개(두 줄 행, 레인 색 타일, 포커스 점): main, AI 에이전트용 `agent/refactor-logging`, 포커스 워크트리 `feat/42-rate-limit`, `fix/57-token-refresh`, detached 리뷰 워크트리(잠김), prunable
  - LOCAL, REMOTE(마지막 커미터 아바타와 시각), STASHES, ISSUES. 아래는 스크롤된다.
- **그래프.**
  - 패널 머리에 작성자 필터 칩 줄, 그 아래 열 머리 `Refs | Graph | Message | Author | Date | SHA`
  - WIP 행(점선 노드, 워크트리 폴더 점선 알약, 선택됨)
  - 아바타 노드와 레인 색 링, 병합 커밋은 작은 점, 포커스 HEAD에 액센트 링
  - 레인 0~3(azure, jade, violet, coral)
  - Refs 열 알약:
    - 포커스 브랜치는 채움
    - 다른 워크트리 브랜치는 틴트 + `tree`
    - 로컬=원격 합침은 끝에 `network`
    - detached 워크트리 알약 + `+1`
    - 태그
  - AI 공동 작성 커밋에 AI 배지
- **상세.**
  - S-02(카드로 나눈 Staged / Unstaged / Untracked, 종류 배지, 변경 막대)
  - 아래 고정 비교 카드 `Changes vs main · 2 commits ahead · 0 behind · 8 files · +272 −85`
- **상태바.** `Read-only`, fetch 시각, ↑↓, 워크트리 수, prunable 경고, gh 상태.
- 명세: [screens.md S-01](screens.md#s-01-메인-창), [art-direction.md](art-direction.md). 이슈: #159, #166

### S-02 WIP 상세

| Light | Dark |
|---|---|
| ![S-02 WIP 상세 (light)](../../design/mockups/s02-wip-detail-light.png) | ![S-02 WIP 상세 (dark)](../../design/mockups/s02-wip-detail-dark.png) |

원본: [`s02-wip-detail-light.svg`](../../design/mockups/s02-wip-detail-light.svg), [`s02-wip-detail-dark.svg`](../../design/mockups/s02-wip-detail-dark.svg)

- 충돌이 있는 에이전트 워크트리(레인 3, coral)로 포커스를 옮긴 상태.
  - 툴바 칩, 사이드바 타일과 테두리, 그래프 알약이 같은 coral로 이어진다.
  - 사이드바 행 배지는 `⚠1 ✎6`, 그래프 WIP 행 앞에는 `⚠ 1 conflicted`, 상태바는 `No upstream`.
- 그룹 순서는 Conflicted → Staged → Unstaged → Untracked. 그룹마다 카드이고, 카드 머리에 상태 심볼, 개수 칩, `+n −m`이 있다.
- `logger.go`는 staged와 unstaged에 한 번씩 나온다(`MM`). rename은 `internal/log/{format.go → encoder.go}`.
- 아래 비교 카드: `1 commit ahead · 3 behind · 7 files`, 기준 커밋 `58de0b4`.
- 명세: [screens.md S-02](screens.md#s-02-wip-상세)

### S-03 커밋 상세

| Light | Dark |
|---|---|
| ![S-03 커밋 상세 (light)](../../design/mockups/s03-commit-detail-light.png) | ![S-03 커밋 상세 (dark)](../../design/mockups/s03-commit-detail-dark.png) |

원본: [`s03-commit-detail-light.svg`](../../design/mockups/s03-commit-detail-light.svg), [`s03-commit-detail-dark.svg`](../../design/mockups/s03-commit-detail-dark.svg)

- `AI-assisted` 칩을 켠 상태. 일치하지 않는 행은 숨기지 않고 40%로 흐린다(그래프 모양 유지). 선택 행은 레인 색 틴트 + 왼쪽 막대.
- 머리: 작성자 아바타(레인 링) + `Commit a91f3c2` + 복사 + `⋯`.
- 제목(15pt), 본문, `Co-Authored-By:` 트레일러(SF Mono, `text.tertiary`).
- 메타데이터 카드:
  - Author(아바타 + 이름 + 이메일)
  - **Co-author**(AI는 `sparkles` 원 + 이름 + AI 배지)
  - Date, Parents(링크), Refs(알약), Issue
- Files 카드: 종류 배지 + 경로 + `+n −m`.
- 명세: [screens.md S-03](screens.md#s-03-커밋-상세)

### S-04 Stash 상세

| Light | Dark |
|---|---|
| ![S-04 Stash 상세 (light)](../../design/mockups/s04-stash-detail-light.png) | ![S-04 Stash 상세 (dark)](../../design/mockups/s04-stash-detail-dark.png) |

원본: [`s04-stash-detail-light.svg`](../../design/mockups/s04-stash-detail-light.svg), [`s04-stash-detail-dark.svg`](../../design/mockups/s04-stash-detail-dark.svg)

- 사이드바에서 `stash@{0}`을 고른 상태. 사이드바는 STASHES와 ISSUES가 보이도록 스크롤되어 있다. 맨 위에는 WORKTREES 섹션 머리가 붙어 있다(sticky).
- 상세 패널:
  - 머리: 중립 `tray` 타일, `stash@{0}`, `1 hour ago`
  - 메시지 전체
  - 정보 카드: Base commit(링크), Branch `(from message)`, Includes `index · working tree · untracked`
  - Files 카드: untracked 커밋에서 온 `docs/rate-limit-notes.md`에 `questionmark`와 범례
  - 아래 고정: `Copy Ref` 하나
  - apply·pop·drop은 비활성으로도, 안내 문구로도 두지 않는다.
- 그래프는 그대로다(v0.1은 stash 노드를 그리지 않음).
- 명세: [screens.md S-04](screens.md#s-04-stash-상세)

### S-05 워크트리 상세

| Light | Dark |
|---|---|
| ![S-05 워크트리 상세 (light)](../../design/mockups/s05-worktree-detail-light.png) | ![S-05 워크트리 상세 (dark)](../../design/mockups/s05-worktree-detail-dark.png) |

원본: [`s05-worktree-detail-light.svg`](../../design/mockups/s05-worktree-detail-light.svg), [`s05-worktree-detail-dark.svg`](../../design/mockups/s05-worktree-detail-dark.svg)

- `Worktree` 세그먼트.
- 정보 카드: Path(복사), HEAD, Branch, Upstream ↑1 ↓0, State, Lock, Last fetch `(repository)`.
- **Security** 카드:
  - 항상 켜진 4개 항목은 `checkmark.shield` + `status.ok`.
  - 무력화된 저장소 설정은 `exclamationmark.shield` + `status.warning` 상자이고, 펼치면 키 이름만(`filter.lfs.process`, `core.sshCommand`) 보인다. 값은 보여 주지 않는다.
- 아래 비교 카드: `1 commit ahead · 0 behind · 4 files`, `Compare with Base…`(S-11 진입, `⌘⇧B`).
- 명세: [screens.md S-05](screens.md#s-05-워크트리-상세), [security-review.md](security-review.md)

### S-06 이슈 패널

| Light | Dark |
|---|---|
| ![S-06 이슈 패널 (light)](../../design/mockups/s06-issue-panel-light.png) | ![S-06 이슈 패널 (dark)](../../design/mockups/s06-issue-panel-dark.png) |

원본: [`s06-issue-panel-light.svg`](../../design/mockups/s06-issue-panel-light.svg), [`s06-issue-panel-dark.svg`](../../design/mockups/s06-issue-panel-dark.svg)

- 사이드바 ISSUES 섹션 머리 오른쪽에 `Open ⌄` 필터. `#42`를 고른 상태다. 연결된 워크트리가 있는 이슈는 레인 색 `tree`로 표시된다.
- 그래프: 연결된 브랜치의 팁 커밋(`a91f3c2`) 행을 점선 테두리와 옅은 레인 색으로 **강조만** 한다. 선택은 하지 않는다.
- 상세 패널:
  - 머리: `#42 Rate limit per tenant`
  - 상태: 중립 `Open` 알약과 `updated 3h ago · opened by Jordan Lee`
  - 정보 카드: 라벨은 중립 알약으로 그리고 GitHub 라벨 색을 쓰지 않는다. 담당자, 마일스톤
  - Linked 카드: 워크트리, 원격 브랜치, 커밋 2개
  - 본문 미표시 안내 한 줄
  - 아래 고정: `Open in Browser`·`Copy URL`
- 명세: [screens.md S-06](screens.md#s-06-이슈-패널), ADR-0004

### S-09 파일 이력

| Light | Dark |
|---|---|
| ![S-09 파일 이력 (light)](../../design/mockups/s09-file-history-light.png) | ![S-09 파일 이력 (dark)](../../design/mockups/s09-file-history-dark.png) |

원본: [`s09-file-history-light.svg`](../../design/mockups/s09-file-history-light.svg), [`s09-file-history-dark.svg`](../../design/mockups/s09-file-history-dark.svg)

- 중앙 패널을 덮은 파일 이력.
  - 머리: `‹ Graph`, `History of internal/http/middleware.go`, `Follow renames` 토글(켜짐)
  - 열: `Commit | Message | Author | Date | This file`
  - 노드: 그래프와 같은 아바타 노드(원래 레인 색 링)를 한 줄로 이었다.
  - rename 행에 `renamed from internal/mw/middleware.go` 알약을 둔다. 마지막 행 아래에 `Beginning of history · created in c4a8e17 as …`를 둔다.
- 첫 행(`a91f3c2`, AI 배지)을 고른 상태라 상세 패널은 S-03이고, Files 카드에서 같은 파일이 선택되어 있다. 숫자는 S-10의 `+38 −4`와 같다.
- 명세: [screens.md S-09](screens.md#s-09-파일-이력). 이슈: #70

### S-10 Diff 뷰어

| Light | Dark |
|---|---|
| ![S-10 Diff 뷰어 (light)](../../design/mockups/s10-diff-viewer-light.png) | ![S-10 Diff 뷰어 (dark)](../../design/mockups/s10-diff-viewer-dark.png) |

원본: [`s10-diff-viewer-light.svg`](../../design/mockups/s10-diff-viewer-light.svg), [`s10-diff-viewer-dark.svg`](../../design/mockups/s10-diff-viewer-dark.svg)

- 중앙 패널을 덮은 Unified 보기.
  - 머리: `‹ Graph`, 종류 배지, 경로(디렉터리 흐리게), `a91f3c2 Modified`, `+38 −4`, `Unified | Split`.
  - 줄 번호 열은 `surface.panel-header`. 이전·이후 줄 번호와 `+`/`−` 기호를 함께 둔다(색만으로 구분하지 않음).
  - 배경: `diff.added-bg` / `removed-bg` / `hunk-header-bg`. 문법 강조 없음(v0.1).
- 상세 패널은 S-03 그대로이고 고른 파일 행이 선택되어 있다.
- 명세: [screens.md S-10](screens.md#s-10-diff-뷰어). 이슈: #69

### S-11 기준 브랜치 대비 변경

| Light | Dark |
|---|---|
| ![S-11 기준 브랜치 대비 변경 (light)](../../design/mockups/s11-changes-vs-base-light.png) | ![S-11 기준 브랜치 대비 변경 (dark)](../../design/mockups/s11-changes-vs-base-dark.png) |

원본: [`s11-changes-vs-base-light.svg`](../../design/mockups/s11-changes-vs-base-light.svg), [`s11-changes-vs-base-dark.svg`](../../design/mockups/s11-changes-vs-base-dark.svg)

- 중앙 머리:
  - `‹ Graph`, `Changes vs [main]` 기준 선택 팝업, `Include uncommitted` 토글(켜짐)
  - 요약 줄: `2 commits ahead · 0 behind · uncommitted: 5 files · 8 files · +272 −85`, merge base
  - 파일 머리: `WIP` 표시, `1 commit + uncommitted`
- 상세 패널:
  - Commits ahead 카드: 맨 위 `Uncommitted changes` 점선 노드, 아바타 + SHA + 제목 + AI 배지
  - Files changed 카드: 종류 배지, `{old → new}` rename, 미커밋이 섞인 파일에 `WIP` 표시, `+n −m`
  - Untracked 카드
- 중앙 본문은 선택한 파일의 패치(S-10 뷰어). 사이드바 포커스 워크트리 행에 선택 기능인 기준 대비 변경 파일 수 배지(`±8`).
- 명세: [screens.md S-11](screens.md#s-11-기준-브랜치-대비-변경). 이슈: #158

### S-07 온보딩

| Light | Dark |
|---|---|
| ![S-07 온보딩 (light)](../../design/mockups/s07-onboarding-light.png) | ![S-07 온보딩 (dark)](../../design/mockups/s07-onboarding-dark.png) |

원본: [`s07-onboarding-light.svg`](../../design/mockups/s07-onboarding-light.svg), [`s07-onboarding-dark.svg`](../../design/mockups/s07-onboarding-dark.svg)

- 저장소가 없을 때 창 가운데 패널 하나가 온보딩이 된다. 마크, `typography.large-title` 제목, 한 줄 설명, `Read-only` 배지.
- 단계 카드 3개: 1 저장소(성공), 2 git(성공), 3 GitHub(선택 사항, 미로그인). 3단계는 `gh auth login`을 복사만 할 수 있게 하고 `Check Again`과 `Skip`을 둔다. 앱은 명령을 직접 실행하지 않는다.
- `Open Repository`(액센트 버튼)는 1, 2단계가 성공해서 활성화된 상태.
- 명세: [screens.md S-07](screens.md#s-07-온보딩)

### S-08 설정

| Light | Dark |
|---|---|
| ![S-08 설정 (light)](../../design/mockups/s08-settings-light.png) | ![S-08 설정 (dark)](../../design/mockups/s08-settings-dark.png) |

원본: [`s08-settings-light.svg`](../../design/mockups/s08-settings-light.svg), [`s08-settings-dark.svg`](../../design/mockups/s08-settings-dark.svg)

- `⌘,`로 여는 표준 Settings 창의 세 탭(General, Repositories, Advanced)을 나란히 그렸다.
- 네이티브 컨트롤이라 시스템 색을 따른다(색은 근삿값). 토글과 선택된 탭 아이콘에만 앱 액센트를 쓴다(ADR-0014).
- 탭별 내용:
  - General: `Fetch automatically`(꺼짐, 간격 팝업 비활성), `Show full remote URLs`(꺼짐, 마스킹 안내), `Show untracked files`(켜짐)
  - Repositories: 등록한 저장소와 `Remove`, `Add…`, "추가한 폴더만 읽는다" 안내
  - Advanced: git 실행 파일(`/usr/bin/git`, `Choose…`, 확인된 버전), `Verbose logging`(꺼짐, 로그 마스킹 안내)
- 토큰이나 비밀 값을 입력받는 필드는 없다.
- 명세: [screens.md S-08](screens.md#s-08-설정)

---

## 3. 후속 작업

- AI 배지는 커밋 트레일러를 읽어야 한다. 로그 포맷에 트레일러 필드를 더하는 변경은 #160에서 다룬다. 서명 관련 `%G` 필드는 계속 쓰지 않는다 (T7).
- 사용자 정의 분할 컨테이너 구현은 #174, 토큰 생성은 #35에서 한다.
