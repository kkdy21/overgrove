# 수동 QA 체크리스트

> 상태: Accepted (Phase 2 게이트, 2026-11-05, #464에서 지금 앱에 맞게 갱신) · 관련: [process.md](process.md), [fixtures.md](../testing/fixtures.md), [screens.md](../design/screens.md), [interaction.md](../design/interaction.md), [security-review.md](../design/security-review.md), #96

Phase 4 QA 이슈 본문에 이 목록을 복사해서 쓴다. 항목마다 결과(✅ 통과 / ❌ 실패 → 버그 # / ➖ 해당 없음 + 사유)와 증거를 남긴다 ([process.md §3.1](process.md)).

## 0. 준비와 표기

**빌드.** 저장소를 clone하고 `./scripts/bootstrap.sh --build`로 도구를 확인한 뒤 Xcode에서 ⌘R로 실행한다. 명령줄로는 `xcodebuild -project Overgrove.xcodeproj -scheme Overgrove -configuration Release -derivedDataPath build/qa build` 뒤에 `open build/qa/Build/Products/Release/Overgrove.app`을 쓴다.

**두 번 한다.** 같은 빌드로 **macOS 14 Sonoma**(최소 지원)와 **최신 macOS**에서 각각 한 번씩 이 목록을 따라 한다. 결과 열을 둘로 나눠 적는다. 두 OS에서 기대 결과가 다른 항목에는 아래 표시가 붙어 있다.

| 표시 | 뜻 |
|---|---|
| 🌗 | 라이트와 다크 모드 둘 다 확인한다 |
| `[14]` | macOS 14에서만 확인한다 |
| `[15+]` | macOS 15 이상에서만 동작하는 기능이다. macOS 14에서는 **없어야** 한다 |
| `[OS별]` | 두 OS 모두 확인하고, 기대 결과가 OS마다 다르다(항목에 둘 다 적었다) |
| 🇰🇷 | 한국어로도 확인한다(§KO) |

- **픽스처**: 별도 표기가 없으면 `scripts/make-fixture-repo.sh ~/tmp/qa-fixture`를 쓴다. 악성은 `--malicious ~/tmp/qa-malicious`, 대형은 `make-bench-repo.sh --commit-graph ~/tmp/qa-bench`다.
- **자동화 열**: 같은 내용을 자동 테스트가 이미 검증하면 테스트 ID를 적는다. 수동 항목은 사람이 화면에서 결과가 맞게 보이는지 확인하는 데 집중한다.
- **화면·이슈 열**: 화면 ID는 [screens.md](../design/screens.md), 이슈는 그 기능을 만든 이슈다. 실패하면 그 이슈를 버그에 링크한다.
- **한국어**: 시스템 설정 › 일반 › 언어 및 지역 › 응용 프로그램에서 Overgrove를 `한국어`로 두고 앱을 다시 연다. 영어로 돌릴 때도 같은 곳에서 바꾼다.

---

## 워크트리 (WT)

| ID | 확인 | 기대 결과 | 화면·이슈 | 자동화 |
|---|---|---|---|---|
| QA-WT-01 | 픽스처 `repo/`를 등록한다 | 사이드바 WORKTREES에 9개가 보이고, 메인 워크트리가 맨 위에 있다 | S-01 | INT-01 |
| QA-WT-02 | 각 워크트리 행의 브랜치명, 변경 수(✎n), ahead/behind 표시 | fixtures.md §2.2, §3 표와 일치. `wt-diverged`는 ↑1 ↓1 | S-01 | INT-04 |
| QA-WT-03 | `wt-locked`, `wt-prunable`, `wt-detached` 행 🌗 | 잠금·정리 필요·detached가 아이콘과 텍스트로 모두 구분된다. 색만으로 구분하지 않는다. 툴팁에 잠금 이유가 보인다 | S-01 | INT-14, INT-15, INT-16 |
| QA-WT-04 | `wt-prunable` 선택 | 경로 없음 빈 상태와 안내가 보이고, 오류 대화상자나 무한 로딩이 없다 | S-01 | INT-14 |
| QA-WT-05 | S-05 워크트리 상세 | 경로, HEAD, upstream, 상태 요약, 마지막 fetch 시각, SECURITY 섹션이 S-05 명세대로 보인다 | S-05 | — |
| QA-WT-06 | 앱 밖에서 워크트리를 추가하거나 삭제한 뒤 ⌘R | 목록이 갱신된다. 사라진 워크트리는 prunable로 바뀐다 | S-01 | — |
| QA-WT-07 | 등록한 저장소 폴더를 Finder에서 옮긴 뒤 앱을 다시 연다 | "Repository not found" 빈 상태와 `Locate…`, `Remove from List`가 보인다 | S-01 | — |
| QA-WT-08 | 선택한 워크트리 행과 툴바 워크트리 칩 🌗 | 선택 행이 그 브랜치 레인 색으로 칠해지고 모서리가 둥글다(8pt). 툴바 칩도 같은 레인 색이다. 사이드바 타일은 레인 색 18% 채움이고, detached·경로 없음은 중립색이다 | S-01, #300, #337, #255 | — |
| QA-WT-09 | 서브모듈이 있는 저장소의 S-02 Submodules 카드 | 서브모듈마다 경로와 상태(`clean` / `n changed · n untracked` / `not checked out` / `git directory missing` / `not inspected`)가 보이고, `not inspected`는 툴팁에 이유가 있다. 서브모듈이 없으면 카드가 없다 | S-02, #108, #430 | — |
| QA-WT-10 | 파일이 아주 많은 워크트리에서 포매터로 파일을 다시 써서 status가 1초를 넘게 만든다 | S-05에 `🐢 Status n s` 카드와 이유, 복사용 `git status`가 보이고(실행 버튼 없음), 상태바에 같은 경고가 뜬다 | S-05, #168 | — |

## 상태 (ST)

| ID | 확인 | 기대 결과 | 화면·이슈 | 자동화 |
|---|---|---|---|---|
| QA-ST-01 | `repo/`의 WIP 상세 | Staged 6, Unstaged 8, Untracked 6. 파일과 상태 문자가 fixtures.md §4 표와 일치한다 | S-02 | INT-02 |
| QA-ST-02 | MM 파일(`src/staged-and-unstaged.txt`) | Staged와 Unstaged 양쪽에 나온다 | S-02 | PAR-STATUS-07 |
| QA-ST-03 | 이름 변경(`src/old-name.txt → src/new-name.txt`) | 한 행에 "이전 → 새" 형태로 보인다 | S-02 | PAR-STATUS-08 |
| QA-ST-04 | 특수 파일명 (개행, 탭, 공백, `-`·`--` 시작, 한글, NFD, 이모지) 🌗 | 깨지지 않게 보인다. 개행과 탭은 시각적 기호로 표시되고 행 높이가 무너지지 않는다 | S-02 | PAR-STATUS-10 |
| QA-ST-05 | `wt-conflict` | Conflicted 섹션에 3개(UU, AA, DU)가 보이고, 충돌 종류를 텍스트로 알 수 있다 | S-02 | INT-03 |
| QA-ST-06 | 무시된 파일 `debug.log` | 목록에 없다 | S-02 | INT-18 |
| QA-ST-07 | 터미널에서 파일을 수정한 뒤 ⌘R | 1초 안에 반영된다. 앱이 `.git/index`를 바꾸지 않는다 (mtime 확인) | S-02 | SEC-T13-02 |
| QA-ST-08 | 창을 보이게 둔 채 터미널에서 파일을 고친다. 그다음 창을 다른 창으로 완전히 가리거나 최소화하고 다시 고친 뒤 창을 앞으로 가져온다 | 보이는 동안은 ⌘R 없이 바뀐 워크트리만 갱신된다. 가려진 동안은 갱신하지 않고, 다시 보이면 한 번 갱신한다 | S-01, #119 | `AutoRefreshControllerTests` |

## Stash (SH)

| ID | 확인 | 기대 결과 | 화면·이슈 | 자동화 |
|---|---|---|---|---|
| QA-SH-01 | 사이드바 STASHES | 2개, 최신(`stash@{0}`)이 위. 메시지와 상대 시간이 보인다 | S-01 | INT-05 |
| QA-SH-02 | `stash@{0}` 상세 | 파일 2개. 미추적에서 온 `stash-untracked.txt`가 구분 표시된다 | S-04 | PAR-NUMSTAT-05 |
| QA-SH-03 | `Copy ref` | 클립보드에 `stash@{0}`이 들어간다 | S-04 | — |
| QA-SH-04 | apply, pop, drop 메뉴 | 없다 (범위 밖, N3·ADR-0011과 같은 원칙) | S-04 | SEC-T13-01 |

## 태그 (TG)

| ID | 확인 | 기대 결과 | 화면·이슈 | 자동화 |
|---|---|---|---|---|
| QA-TG-01 | 사이드바 TAGS 섹션 | REMOTE와 STASHES 사이에 있고 처음에는 접혀 있다. 펼치면 `v0.0.1`, `light-tag`가 만든 날짜 내림차순으로 보인다. 주석·가벼운 태그 구분은 툴팁에만 있다 | S-01, #377 | `TagListModelTests` |
| QA-TG-02 | 태그 행을 누른다. 행 메뉴의 Show in Graph, Copy Tag Name, Copy SHA | 그 커밋(주석 태그는 가리키는 커밋)이 그래프에서 선택되고 스크롤된다. 복사 값이 맞다 | S-01, #377 | — |
| QA-TG-03 | 사이드바 필터에 태그 이름 일부를 입력한다 | 접혀 있어도 TAGS가 펼쳐지고 맞는 태그만 남는다 | S-01, #377 | — |

## 동기화: ahead/behind, fetch (SY)

| ID | 확인 | 기대 결과 | 화면·이슈 | 자동화 |
|---|---|---|---|---|
| QA-SY-01 | Fetch(⌘⇧R) 실행 | 진행 표시 → 완료. 사이드바 REMOTE에 `origin/feat/remote-only`가 나타난다. 상태바의 마지막 fetch 시각이 갱신된다 | S-01 | INT-12 |
| QA-SY-02 | fetch 중 ⌘. | 취소되고 앱이 멈추지 않는다. 부분 결과로 화면이 깨지지 않는다 | S-01 | SEC-T15-02 |
| QA-SY-03 | 인증이 필요한 원격(자격 증명이 없는 private https 저장소)을 fetch | 프롬프트 없이 빠르게 실패하고 인증 문제라는 안내가 나온다. stderr 원문은 마스킹된다 | S-01 | SEC-T12-02 |
| QA-SY-04 | 네트워크를 끈 상태에서 fetch | 타임아웃 또는 즉시 실패. 안내 문구에 원격 URL 자격 증명이 없다 | S-01 | SEC-T11-02 |
| QA-SY-05 | 자동 fetch를 켜고(설정) 창을 비활성화 | 비활성 동안 fetch하지 않는다 | S-08 | — |
| QA-SY-06 | upstream 없는 브랜치(`wt-no-upstream`) | ahead/behind 자리에 "upstream 없음"이 보이고, 0/0으로 표시하지 않는다 | S-01 | INT-04 |

## 그래프와 WIP (GR)

| ID | 확인 | 기대 결과 | 화면·이슈 | 자동화 |
|---|---|---|---|---|
| QA-GR-01 | 그래프 첫 화면 🌗 | 맨 위에 WIP 행(변경 요약). 병합 커밋 `0cbcd45`에서 레인이 합류한다 | S-01 | INT-07, GRA-02 |
| QA-GR-02 | 작성자와 날짜 열 | 한글 작성자(`김개발`)가 깨지지 않는다. 날짜는 시스템 로케일 형식이다 | S-01 | PAR-LOG-03 |
| QA-GR-03 | 태그와 브랜치 배지 | `v0.0.1`, `light-tag`, 로컬·원격 브랜치 배지가 해당 커밋에 붙는다 | S-01 | INT-11 |
| QA-GR-04 | bench 저장소 그래프를 끝까지 스크롤 | 눈에 띄는 끊김이 없다. 레인 색이 페이지 경계에서 바뀌지 않는다 | S-01 | PERF-05, GRA-05 |
| QA-GR-05 | ⌘F로 커밋 메시지, 작성자, 이슈 번호 검색 | 일치 항목으로 이동하고 ⌘G로 다음 항목을 찾는다 | S-01, #74 | — |
| QA-GR-06 | ⌘J (Jump to HEAD) | 선택한 워크트리의 HEAD로 스크롤한다 | S-01 | — |
| QA-GR-07 | 그래프 stash 노드 🌗 | `stash@{0}`·`stash@{1}`이 기준 커밋 바로 위에 속 빈 사각 노드와 점선으로 보이고, 같은 기준이면 `stash@{0}`이 위다. 누르면 S-04가 열린다. `↑`/`↓`는 stash 행을 건너뛴다 | S-01, #384 | — |
| QA-GR-08 | 그래프 `⋯` 메뉴의 `Show Stashes`를 끈다. 검색이나 작성자 필터를 켠다 | 끄면 stash 노드가 사라지고 사이드바 STASHES는 그대로다. 앱을 다시 열어도 유지된다. 검색·필터 중에는 켜져 있어도 숨는다 | S-01, #384 | — |
| QA-GR-09 | 보기 메뉴 그래프 확대: `⌘+`(Shift 포함), US 키보드의 `⌘=`, `⌘−`, `⌘0` | 네 가지 모두 동작한다. 85·100·115·130·150% 단계로 그래프 패널만 커지고 사이드바·상세는 그대로다. 선택한 커밋이 가운데로 온다. 앱을 다시 열어도 배율이 유지된다 | S-01, #121 | `GraphZoomTests` |
| QA-GR-10 | 작성자 필터 칩(`All`, 작성자, `AI-assisted`)을 고른다 | 고른 칩 밖의 행은 흐려질 뿐 사라지지 않는다. 검색과 함께 쓰면 둘 다 맞는 행만 ⌘G가 따라간다 | S-01, #255 | — |
| QA-GR-11 | 열 머리 구분선을 끌고 더블클릭한다. `⋯`에서 Author/Date/SHA를 숨긴다. 레인이 12개를 넘는 저장소(bench) | 폭이 바뀌고 더블클릭으로 내용에 맞춰진다. 숨김과 폭이 저장소마다 유지된다. 12레인을 넘으면 Graph 열 안에서만 옆으로 스크롤된다 | S-01, #255 | — |

## 선택 이력 (NV)

| ID | 확인 | 기대 결과 | 화면·이슈 | 자동화 |
|---|---|---|---|---|
| QA-NV-01 | 워크트리 → 커밋 → stash → 다른 커밋 순으로 고른 뒤 `⌘[`를 세 번, `⌘]`를 한 번 | 고른 순서를 거꾸로 따라가고 다시 앞으로 간다. 커밋으로 돌아가면 그래프가 그 행으로 스크롤된다. 열려 있던 S-09·S-10·S-11은 닫힌다 | S-01, #378 | `SelectionHistoryTests` |
| QA-NV-02 | 맨 처음 항목에서 Navigate 메뉴를 연다. 고른 stash를 터미널에서 지운 뒤 `⌘[` | 갈 곳이 없으면 Back이 꺼져 있다. 사라진 항목은 건너뛰고, 남은 것이 모두 사라졌으면 경고음과 VoiceOver `Nothing to go back to` | S-01, #378 | — |
| QA-NV-03 | 검색 필드에 포커스를 둔 채 `⌘[` | 선택 이력이 동작한다(텍스트 편집 단축키와 겹치지 않는다) | S-01, #378 | — |

## 커밋 상세와 파일 이력 (CD)

| ID | 확인 | 기대 결과 | 화면·이슈 | 자동화 |
|---|---|---|---|---|
| QA-CD-01 | `4202323` 상세 | `assets/binary.bin`이 "바이너리"로 표시되고 +/− 숫자가 없다 | S-03 | PAR-NUMSTAT-03 |
| QA-CD-02 | `c46c37d` 상세 | `docs/guide.md → docs/manual.md` 이름 변경이 보인다 | S-03 | INT-08 |
| QA-CD-03 | `docs/manual.md` 파일 이력 | 이름 변경 이전을 포함해 4개 커밋이 보인다 | S-09 | INT-09 |
| QA-CD-04 | `-dash-leading.txt`의 diff와 이력 | 해당 파일만 대상이 된다. 옵션으로 해석되지 않는다 | S-09, S-10 | INT-10, SEC-T9-03 |
| QA-CD-05 | Diff 뷰어 🌗 | 추가와 삭제가 색 외에 `+`/`−` 기호로도 구분된다. 긴 줄이 잘리지 않는다 | S-10 | — |
| QA-CD-06 | 한 줄에서 단어 몇 개만 바꾼 파일의 diff 🌗 | 바뀐 단어만 줄 배경보다 진하게 칠해진다. **다크 모드에서** 바뀐 단어 배경(`#2d5036` / `#572b3a`)이 줄 배경과 구분되고, 그 위 글자가 충분히 읽힌다(대비 부족이면 버그) | S-10, #387 | `DiffViewerRenderTests` (색 픽셀) |
| QA-CD-07 | Diff 머리 `⋯` › `Show Whitespace` | 탭은 `→`, 추가·삭제 줄 끝 공백은 `·`, CR은 `␍`로 흐리게 보인다. 끄고 켠 상태가 기억된다 | S-10, #387 | `WordDiffTests` |

## 두 커밋 비교 (CMP)

| ID | 확인 | 기대 결과 | 화면·이슈 | 자동화 |
|---|---|---|---|---|
| QA-CMP-01 | 커밋 하나를 고르고 다른 커밋 행의 메뉴 `Compare with Selected Commit` | S-12가 열린다. 머리에 `Compare base → target`, 상세에 BASE·TARGET·COMMITS·FILES CHANGED. 파일을 고르면 S-10 diff가 보인다 | S-12, #122, #388 | `AppStateCommitComparisonTests` |
| QA-CMP-02 | `⇄`를 누른다. 기준이 대상보다 뒤인 쌍을 비교한다 | 방향이 바뀐다. 대상에 없는 커밋이면 COMMITS에 `… has no commits that … does not have`가 보인다 | S-12, #389 | — |
| QA-CMP-03 | BASE·TARGET·COMMITS 행을 누른다. `‹ Graph`와 `⎋` | 행을 누르면 S-12가 닫히고 그 커밋의 S-03이 열린다. `‹ Graph`·`⎋`는 그래프로 돌아간다. 선택 이력에는 비교가 남지 않는다 | S-12, #388 | — |
| QA-CMP-04 | S-12를 연 채 S-11(Changes)을 연다. 그 반대도 | 하나를 열면 다른 하나가 닫힌다 | S-11, S-12, #388 | — |
| QA-CMP-05 | bench 저장소에서 멀리 떨어진 두 커밋 비교 | COMMITS가 500개에서 멈추고 `COMMITS (500+)`, 파일이 1,000개를 넘으면 `Show all n files`가 보인다 | S-12, #389 | — |

## 기준 브랜치 대비 변경 (BC)

| ID | 확인 | 기대 결과 | 화면·이슈 | 자동화 |
|---|---|---|---|---|
| QA-BC-01 | `feat/ahead` 워크트리에서 `Changes` 세그먼트 | `main`에서 갈라진 뒤의 커밋, 바뀐 파일, untracked 파일이 PR처럼 보인다 | S-11, #157, #158 | — |
| QA-BC-02 | S-11을 연 채 터미널에서 커밋하거나 ⌘R | 결과가 새로 계산되고, 계산 중이거나 이전 결과면 그렇다고 표시된다(멈춘 스피너 없음) | S-11, #412 | — |

## 외부 앱 열기와 Quick Look (EX)

| ID | 확인 | 기대 결과 | 화면·이슈 | 자동화 |
|---|---|---|---|---|
| QA-EX-01 | Settings › Advanced › Apps에서 터미널(예: iTerm)과 에디터(예: 사용 중인 에디터 `.app`)를 고른다 | 고른 앱 이름이 보인다. `.app`이 아닌 것은 받지 않는다 | S-08, #124 | — |
| QA-EX-02 | 워크트리 행 메뉴 Open in Terminal, Open in Editor | 고른 앱으로 그 워크트리 폴더가 열린다. 실행 설정이 있는 워크트리는 먼저 `Open in <앱>?` 확인을 묻는다 | S-01, #124 | `TerminalGuardTests` |
| QA-EX-03 | 작업 트리 파일 행(S-02) 메뉴 Open in Editor. `.command` 파일이나 실행 비트가 있는 파일에도 | 일반 파일은 바로 에디터로 열린다. 실행될 수 있는 형식은 확인을 묻거나 열지 않는다 | S-02, #124 | — |
| QA-EX-04 | `[15+]` 작업 트리 파일 행 메뉴 `Quick Look`: 이미지, PDF, 심볼릭 링크, HTML, 100MB 넘는 파일 | 일반 파일은 Quick Look 패널로 보인다. 링크·HTML·SVG·웹 아카이브·너무 큰 파일은 열지 않고 이유를 알린다 | S-02, #399 | `QuickLookTests` |
| QA-EX-05 | `[14]` 같은 파일 행 메뉴 | `Quick Look` 항목이 **없다** | S-02, #399 | `QuickLookTests` |
| QA-EX-06 | GitHub 원격이 있는 저장소에서 커밋 행, 브랜치 행, S-03 파일 행의 `Open on GitHub` | 브라우저가 `https://github.com/OWNER/NAME/…`의 그 커밋·브랜치·파일을 연다. fork 흐름(origin=내 fork)에서 origin을 추적하는 브랜치는 내 fork 페이지를 연다. 작업 트리·stash 파일 행에는 항목이 없다 | S-01, S-03, #398, #406 | SEC-T14-12 |

## 이슈 패널과 PR 상태 (IS)

| ID | 확인 | 기대 결과 | 화면·이슈 | 자동화 |
|---|---|---|---|---|
| QA-IS-01 | `gh` 로그인 상태에서 GitHub 원격이 있는 저장소 | 이슈 목록이 보인다. 브랜치명 `feat/12-…`이 `#12`와 연결된다 | S-06 | PAR-GH-01, PAR-ISSUE-01 |
| QA-IS-02 | `gh auth logout` 상태 | 이슈 패널에 "터미널에서 `gh auth login`을 실행하세요" 안내가 나온다. Git 조회 기능은 정상이다 | S-06, #83 | PAR-GH-02 |
| QA-IS-03 | `gh`가 설치되지 않은 Mac(앱은 PATH가 아니라 `/opt/homebrew/bin/gh`, `/usr/local/bin/gh`만 찾는다. 임시로 이름을 바꿔 재현) | 이슈 패널만 비활성. 크래시나 반복 오류가 없다 | S-06, #83 | — |
| QA-IS-04 | GitHub이 아닌 원격만 있는 저장소 (픽스처) | 이슈 패널에 "GitHub 원격 없음"이 표시된다 | S-06 | — |
| QA-IS-05 | 이슈 생성·수정 버튼 | 없다 (N6) | S-06 | — |
| QA-IS-06 | 열린 PR이 있는 브랜치의 워크트리 행·LOCAL 행 🌗 | PR 알약(상태 심볼과 `#n`, 초안은 점선)이 보인다. S-05에 Pull request 카드(상태, 제목, 리뷰 결정, 기준 브랜치, `Open in Browser`·`Copy URL`) | S-01, S-05, #115 | `PullRequestModelsTests` |
| QA-IS-07 | 머지된 PR의 브랜치, 같은 이름의 브랜치를 가진 남의 fork PR | 머지된 PR은 `Merged` 사실만 보이고 정리 안내가 없다. 브랜치 이름만 같고 upstream 원격이 다른 PR은 잇지 않는다 | S-05, #115 | SEC-T9-06, SEC-T9-07 |
| QA-IS-08 | `gh auth logout` 뒤 ⌘R | PR 알약과 카드가 숨는다. 다른 표시는 그대로다 | S-01, S-05, #115 | — |

## 온보딩과 설정 (ON)

| ID | 확인 | 기대 결과 | 화면·이슈 | 자동화 |
|---|---|---|---|---|
| QA-ON-01 | 처음 실행 (`UserDefaults` 초기화) 🇰🇷 | S-07 온보딩: 저장소 추가, git 감지(경로와 버전), GitHub 상태 | S-07 | — |
| QA-ON-02 | `Choose folder…`로 git 저장소가 아닌 폴더 선택 | 이유를 알려 주고 등록하지 않는다 | S-07 | — |
| QA-ON-03 | 다른 사용자 소유 저장소 (`safe.directory` 거부) | 이유를 알려 준다. 앱이 `safe.directory`를 설정하지 않는다 (`git config --global --get-all safe.directory` 변화 없음) | S-07 | — |
| QA-ON-04 | 설정 "원격 URL 전체 표시" 켜기 | URL은 보이지만 자격 증명 부분은 계속 마스킹된다 | S-08 | SEC-T11-04 |
| QA-ON-05 | 앱 재실행 | 등록한 저장소와 설정이 유지된다. `UserDefaults`에 토큰이나 비밀이 없다 (`defaults read io.github.kkdy21.overgrove` 확인) | S-08 | — |
| QA-ON-06 | bench 저장소를 연 채 앱을 끄고 다시 연다 | git 조회가 끝나기 전에 마지막 워크트리 목록이 바로 그려지고, 조회가 끝나면 실제 값으로 바뀐다 | S-01, #109 | PERF-13, SEC-T19-01 |

## 보안 (SEC)

| ID | 확인 | 기대 결과 | 화면·이슈 | 자동화 |
|---|---|---|---|---|
| QA-SEC-01 | 악성 픽스처를 등록하고 모든 화면을 연다 (워크트리, WIP, 그래프, 커밋 상세, 파일 이력, stash, diff, S-11, S-12) | 끝난 뒤 `ls ~/tmp/qa-malicious/canary \| wc -l`이 `0` | 전체 | INT-19, SEC-T1–T7 |
| QA-SEC-02 | 악성 픽스처에서 `origin` fetch | canary 0개, fetch 성공. auto maintenance가 돌지 않았다 (`GIT_TRACE=1` 로그에 `maintenance run`·`gc --auto` 자식 프로세스 없음) | S-01 | SEC-T5-02, SEC-T8-01 |
| QA-SEC-03 | 악성 픽스처에서 `sshremote`, `gitremote`, `extremote`, `redirected` fetch | 모두 실패로 표시. canary 0개. 앱이 멈추지 않는다 | S-01 | SEC-T5-01, SEC-T5-03–05 |
| QA-SEC-04 | 악성 픽스처의 S-05 SECURITY 섹션 | 무력화된 설정 키 목록(값 없이)과 경고 개수가 보인다 | S-05 | — |
| QA-SEC-05 | 원격 `mirror`가 보이는 모든 곳 (S-05, 상태바, 오류 popover) | `fixture-user:…@`가 어디에도 원문으로 나오지 않는다 | S-05 | INT-13, SEC-T11-04 |
| QA-SEC-06 | 상세 로그를 켜고 위 항목을 반복한 뒤 Console.app에서 `io.github.kkdy21.overgrove` 필터 | 자격 증명, 원격 URL 원문, 홈 경로가 없다 | — | SEC-T16-01 |
| QA-SEC-07 | 저장소 밖을 가리키는 심볼릭 링크 파일의 미리보기 | 경고가 나오고 내용을 열지 않는다 | S-02 | SEC-T14-02 |
| QA-SEC-08 | S-05 보안 카드의 `Treat as untrusted`를 켠다. Settings › Repositories 행의 `Untrusted` | 두 곳이 같은 값으로 바뀐다. 경고에 이 Mac의 원격 이름이 마스킹되어 보인다. 앱을 다시 열어도 유지된다 | S-05, S-08, #107 | SEC-T5-19 |
| QA-SEC-09 | 신뢰하지 않음 저장소에서 로컬 경로 원격과 https 원격을 fetch | 로컬 원격은 git을 실행하지 않고 원격별 안내가 나온다(복사용 명령 없음). 네트워크 원격은 정상 fetch된다 | S-01, #107 | SEC-T5-19 |
| QA-SEC-10 | 오래 걸리는 fetch 중에 `Treat as untrusted`를 켠다 | 진행 중인 fetch가 바로 멈춘다 | S-05, #423 | — |
| QA-SEC-11 | 신뢰하지 않음 저장소에서 설정이 깨끗한 워크트리를 Open in Terminal | 항상 확인 창을 거친다 | S-01, #107 | `TerminalGuardTests` |

## 접근성 (A11Y)

| ID | 확인 | 기대 결과 | 화면·이슈 | 자동화 |
|---|---|---|---|---|
| QA-A11Y-01 | VoiceOver로 사이드바 → 그래프 → 상세 이동 🇰🇷 | 각 행이 의미 있는 레이블로 읽힌다 (예: "feat/ahead, 변경 0, 앞섬 2") | S-01 | 레이블 문자열: `AccessibilityLabelTests`, `WorktreeListModelTests`, `BranchListModelTests`, `WipDetailModelTests` (#75). 실제로 읽히는지는 수동 |
| QA-A11Y-02 | 키보드만으로 주요 흐름 (Tab, ⌘1–⌘4, ↑/↓, ⏎, ⎋, ⌘[/⌘]) | 마우스 없이 모든 화면에 도달한다. 포커스가 항상 보인다 | 전체 | — |
| QA-A11Y-03 | 손쉬운 사용 › 디스플레이 › 대비 증가, 투명도 줄이기 🌗 `[OS별]` | 상태 구분이 유지되고 텍스트 대비가 부족하지 않다. 두 OS 모두 본다 | 전체 | — |
| QA-A11Y-04 | 동작 줄이기 켜기 | 불필요한 애니메이션이 사라진다 | 전체 | — |
| QA-A11Y-05 | Accessibility Inspector 감사 | 경고 0개 또는 사유가 기록된 경고만 남는다 | 전체 | — |
| QA-A11Y-06 | VoiceOver 로터(VO-U): 사이드바에서 `Worktrees`, S-02에서 `Changes`·`Conflicted Files` | 항목 이름이 읽히고 고른 행으로 이동한다. S-02는 긴 목록(lazy)의 화면 밖 행으로도 이동하는지 본다 | S-01, S-02 | — |
| QA-A11Y-07 | 그래프 커밋 행에서 VoiceOver 읽기 | `Commit <SHA>, 제목, 작성자, 2 hours ago, branches …, HEAD of worktree …`, merge면 `merge commit, 2 parents`. 잠시 뒤 힌트로 절대 날짜. WIP 행은 `Uncommitted changes in …: 3 staged, …` | S-01 | `AccessibilityLabelTests` (문자열) |
| QA-A11Y-08 | 행 컨텍스트 메뉴를 VoiceOver로 열기(VO-Shift-M): 커밋·파일·워크트리·브랜치·태그·stash·이슈 | 보기·복사·열기 항목만 있고 모두 실행된다. 같은 동작이 키보드 명령(⌘C, ⌥⌘C, ⌘J, ⌘I)으로도 된다 | 전체 | `AppStateNavigationTests` (동작) |
| QA-A11Y-09 | fetch 성공·실패 | `Fetch finished` / `Fetch failed: …` 알림이 VoiceOver로 들린다 | S-01 | `FetchAnnouncement` 문자열 테스트 |
| QA-A11Y-10 | 검사되지 않았거나 실행 설정이 있는 워크트리에서 Open in Terminal(툴바 또는 행 메뉴) | 확인 창이 VoiceOver로 읽히고, `⏎`·`⎋` 모두 Cancel이다 | S-01 | `TerminalGuardTests` (판정) |
| QA-A11Y-11 | 대비 증가에서 툴바의 워크트리 칩 | 테두리가 `border.strong` 1.5pt로 바뀐다 | S-01, #304 | `AccessibilityLabelTests` (두께 값) |
| QA-A11Y-12 | 대비 증가를 켜고 S-01의 `Changes`\|`Worktree` 세그먼트 🌗 `[OS별]` | 시스템 테두리와 테마 테두리가 **두 겹으로 보이지 않는다**(테두리 하나). 두 OS 모두 본다 | S-01, #304 | — |
| QA-A11Y-13 | VoiceOver로 패널 분할선에 포커스 | 조절 가능한 요소로 `Sidebar width, N points`처럼 읽히고, VO-↑/↓로 폭이 바뀐다 | S-01, #174 | — |
| QA-A11Y-14 | 실제 포인터로 분할선을 최소·최대 폭까지 끈다 | 한계에서는 커서가 갈 수 있는 한쪽 방향 모양으로 바뀐다 | S-01, #174 | — |
| QA-A11Y-15 | Diff 줄을 VoiceOver로 읽기(단어가 바뀐 줄) | 줄 라벨 끝에 `, changed: …`(최대 5개)가 붙는다 | S-10, #387 | — |

## 다크 모드와 외관 (DM)

| ID | 확인 | 기대 결과 | 화면·이슈 | 자동화 |
|---|---|---|---|---|
| QA-DM-01 | 시스템 외관을 라이트 ↔ 다크로 실행 중 전환 | 재시작 없이 즉시 바뀐다. 하드코딩된 색이 남지 않는다 | 전체 | — |
| QA-DM-02 | 시스템 강조 색을 바꾼다 (파랑 → 보라 → 그래파이트) | 선택 강조가 따라 바뀐다. 상태 색(디자인 토큰)은 그대로다 | 전체 | — |
| QA-DM-03 | 그래프 레인 색 🌗 | 인접 레인을 구분할 수 있다. 배경 대비가 design-tokens.md 기준을 만족한다 | S-01 | — |
| QA-DM-04 | 앱 아이콘: Dock, Finder(앱 정보 포함), ⌘Tab 전환기, 설정의 앱 목록 🌗 `[OS별]` | **macOS 14**: `design/icon/preview.png`와 같은 PNG 세트 디자인이고, 16·32pt 작은 크기에서는 `app-icon-small` 디자인(굵은 가지 선)이 쓰인다. **최신 macOS**: 같은 PNG 세트 디자인이 보인다(v0.1은 Icon Composer `.icon`을 쓰지 않아 유리 재질·틴트 변형이 없다, iconography.md §6.2). 두 OS 모두 흐려지지 않는다 | — , #39 | — |

## 한국어 (KO)

§0의 방법으로 앱 언어를 한국어로 바꾼 뒤 확인한다. 용어는 [glossary.md](../glossary.md)의 "한국어 UI 표기" 열이 기준이다. 1단계(#120)는 아래 화면만 번역했다. 나머지 화면(사이드바, 상태바, S-02~S-05, S-09, S-11, S-12, 이슈 패널)은 2단계(#454)가 머지된 뒤에 같은 방식으로 확인한다. 그 전에는 영어로 보이는 것이 정상이다.

| ID | 확인 | 기대 결과 | 화면·이슈 | 자동화 |
|---|---|---|---|---|
| QA-KO-01 | 설정(S-08), 온보딩(S-07), 메뉴 막대의 Navigate·Find·보기(확대) 메뉴 | 한국어로 보인다. git 용어는 음차다(커밋, 브랜치, 스태시, 워크트리, 페치) | S-07, S-08, #120 | `LocalizationTests` (키 존재) |
| QA-KO-02 | 그래프 작성자 필터, 열 머리, 열 메뉴, Diff 뷰어(S-10) 머리와 `⋯` 메뉴 | 한국어로 보이고 잘리거나 겹치지 않는다(영어보다 긴 문구 포함) | S-01, S-10, #120 | — |
| QA-KO-03 | 번역하지 않는 것: 브랜치·ref 이름, SHA, 복사용 명령(`gh auth login` 등), 클립보드에 들어가는 값, git·gh 오류 원문, `WIP`·`AI-assisted` 배지, Copy Report 내용 | 원문 그대로다 | 전체, #120 | — |
| QA-KO-04 | 한국어에서 VoiceOver로 QA-A11Y-01·07을 반복한다 | 번역된 화면의 레이블과 툴팁이 한국어로 읽힌다 | 전체, #120 | — |

## 성능 스모크 (PF)

정밀 측정은 PERF 테스트가 맡는다. 이 항목은 체감 확인이다.

| ID | 확인 | 기대 결과 | 화면·이슈 | 자동화 |
|---|---|---|---|---|
| QA-PF-01 | bench 저장소 열기 | 1초 안에 워크트리 10개와 상태 요약이 보인다 | S-01 | PERF-01 |
| QA-PF-02 | 워크트리 사이를 ↑/↓로 빠르게 이동 | 지연 없이 전환되고 이전 결과가 섞여 보이지 않는다 | S-01 | PERF-02 |
| QA-PF-03 | bench 그래프 첫 화면 | 0.5초 안에 보인다 (commit-graph 있음) | S-01 | PERF-03 |
| QA-PF-04 | commit-graph 없는 bench (`make-bench-repo.sh` 기본) 그래프 | 1초 안에 보인다. 기다리는 동안 골격이 먼저 보인다 | S-01 | PERF-03 |
| QA-PF-05 | Activity Monitor로 bench 그래프 전체 적재 뒤 메모리 확인 | 300MB 이하 | S-01 | PERF-07 |
| QA-PF-06 | 앱을 30분 켜 둔 뒤 (자동 fetch 켬) | 메모리가 계속 늘지 않고, 좀비 git 프로세스가 없다 (`ps -ax \| grep git`) | — | SEC-T15-02 |
| QA-PF-07 | Instruments(Animation Hitches 또는 Core Animation)로 패널 분할선을 끌며 측정 | 리사이즈 중 눈에 띄는 프레임 드랍이 없다 | S-01, #174 | — |
| QA-PF-08 | 그래프 150% 확대 상태에서 bench 그래프 스크롤 | 100%와 비슷하게 부드럽다 | S-01, #121 | PERF-05 |
| QA-PF-09 | 터미널에서 `for i in $(seq 200); do touch src/f$i; done`처럼 파일을 한꺼번에 바꾼다 | 갱신이 몰아서 일어나고 CPU가 계속 높지 않다 | S-01, #119 | PERF-10 |
