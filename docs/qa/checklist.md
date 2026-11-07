# 수동 QA 체크리스트

> 상태: Accepted (Phase 2 게이트, 2026-11-05) · 관련: [process.md](process.md), [fixtures.md](../testing/fixtures.md), [screens.md](../design/screens.md), [interaction.md](../design/interaction.md), [security-review.md](../design/security-review.md)

Phase 4 QA 이슈 본문에 이 목록을 복사해서 쓴다. 항목마다 결과(✅ 통과 / ❌ 실패 → 버그 # / ➖ 해당 없음 + 사유)와 증거를 남긴다 ([process.md §3.1](process.md)).

- **픽스처**: 별도 표기가 없으면 `scripts/make-fixture-repo.sh ~/tmp/qa-fixture`를 쓴다. 악성은 `--malicious ~/tmp/qa-malicious`, 대형은 `make-bench-repo.sh --commit-graph ~/tmp/qa-bench`다.
- **자동화 열**: 같은 내용을 자동 테스트가 이미 검증하면 테스트 ID를 적는다. 수동 항목은 사람이 화면에서 결과가 맞게 보이는지 확인하는 데 집중한다.
- **모드**: 🌗 표시 항목은 라이트와 다크 모드 둘 다 확인한다.

---

## 워크트리 (WT)

| ID | 확인 | 기대 결과 | 자동화 |
|---|---|---|---|
| QA-WT-01 | 픽스처 `repo/`를 등록한다 | 사이드바 WORKTREES에 9개가 보이고, 메인 워크트리가 맨 위에 있다 | INT-01 |
| QA-WT-02 | 각 워크트리 행의 브랜치명, 변경 수(✎n), ahead/behind 표시 | fixtures.md §2.2, §3 표와 일치. `wt-diverged`는 ↑1 ↓1 | INT-04 |
| QA-WT-03 | `wt-locked`, `wt-prunable`, `wt-detached` 행 🌗 | 잠금·정리 필요·detached가 아이콘과 텍스트로 모두 구분된다. 색만으로 구분하지 않는다. 툴팁에 잠금 이유가 보인다 | INT-14, INT-15, INT-16 |
| QA-WT-04 | `wt-prunable` 선택 | 경로 없음 빈 상태와 안내가 보이고, 오류 대화상자나 무한 로딩이 없다 | INT-14 |
| QA-WT-05 | S-05 워크트리 상세 | 경로, HEAD, upstream, 상태 요약, 마지막 fetch 시각, SECURITY 섹션이 S-05 명세대로 보인다 | — |
| QA-WT-06 | 앱 밖에서 워크트리를 추가하거나 삭제한 뒤 ⌘R | 목록이 갱신된다. 사라진 워크트리는 prunable로 바뀐다 | — |
| QA-WT-07 | 등록한 저장소 폴더를 Finder에서 옮긴 뒤 앱을 다시 연다 | "Repository not found" 빈 상태와 `Locate…`, `Remove from List`가 보인다 | — |

## 상태 (ST)

| ID | 확인 | 기대 결과 | 자동화 |
|---|---|---|---|
| QA-ST-01 | `repo/`의 WIP 상세 (S-02) | Staged 6, Unstaged 8, Untracked 6. 파일과 상태 문자가 fixtures.md §4 표와 일치한다 | INT-02 |
| QA-ST-02 | MM 파일(`src/staged-and-unstaged.txt`) | Staged와 Unstaged 양쪽에 나온다 | PAR-STATUS-07 |
| QA-ST-03 | 이름 변경(`src/old-name.txt → src/new-name.txt`) | 한 행에 "이전 → 새" 형태로 보인다 | PAR-STATUS-08 |
| QA-ST-04 | 특수 파일명 (개행, 탭, 공백, `-`·`--` 시작, 한글, NFD, 이모지) 🌗 | 깨지지 않게 보인다. 개행과 탭은 시각적 기호로 표시되고 행 높이가 무너지지 않는다 | PAR-STATUS-10 |
| QA-ST-05 | `wt-conflict` | Conflicted 섹션에 3개(UU, AA, DU)가 보이고, 충돌 종류를 텍스트로 알 수 있다 | INT-03 |
| QA-ST-06 | 무시된 파일 `debug.log` | 목록에 없다 | INT-18 |
| QA-ST-07 | 터미널에서 파일을 수정한 뒤 ⌘R | 1초 안에 반영된다. 앱이 `.git/index`를 바꾸지 않는다 (mtime 확인) | SEC-T13-02 |

## Stash (SH)

| ID | 확인 | 기대 결과 | 자동화 |
|---|---|---|---|
| QA-SH-01 | 사이드바 STASHES | 2개, 최신(`stash@{0}`)이 위. 메시지와 상대 시간이 보인다 | INT-05 |
| QA-SH-02 | `stash@{0}` 상세 (S-04) | 파일 2개. 미추적에서 온 `stash-untracked.txt`가 구분 표시된다 | PAR-NUMSTAT-05 |
| QA-SH-03 | `Copy ref` | 클립보드에 `stash@{0}`이 들어간다 | — |
| QA-SH-04 | apply, pop, drop 메뉴 | 없다 (범위 밖, N3·ADR-0011과 같은 원칙) | SEC-T13-01 |

## 동기화: ahead/behind, fetch (SY)

| ID | 확인 | 기대 결과 | 자동화 |
|---|---|---|---|
| QA-SY-01 | Fetch(⌘⇧R) 실행 | 진행 표시 → 완료. 사이드바 REMOTE에 `origin/feat/remote-only`가 나타난다. 상태바의 마지막 fetch 시각이 갱신된다 | INT-12 |
| QA-SY-02 | fetch 중 ⌘. | 취소되고 앱이 멈추지 않는다. 부분 결과로 화면이 깨지지 않는다 | SEC-T15-02 |
| QA-SY-03 | 인증이 필요한 원격(자격 증명이 없는 private https 저장소)을 fetch | 프롬프트 없이 빠르게 실패하고 인증 문제라는 안내가 나온다. stderr 원문은 마스킹된다 | SEC-T12-02 |
| QA-SY-04 | 네트워크를 끈 상태에서 fetch | 타임아웃 또는 즉시 실패. 안내 문구에 원격 URL 자격 증명이 없다 | SEC-T11-02 |
| QA-SY-05 | 자동 fetch를 켜고(설정) 창을 비활성화 | 비활성 동안 fetch하지 않는다 | — |
| QA-SY-06 | upstream 없는 브랜치(`wt-no-upstream`) | ahead/behind 자리에 "upstream 없음"이 보이고, 0/0으로 표시하지 않는다 | INT-04 |

## 그래프와 WIP (GR)

| ID | 확인 | 기대 결과 | 자동화 |
|---|---|---|---|
| QA-GR-01 | 그래프 첫 화면 🌗 | 맨 위에 WIP 행(변경 요약). 병합 커밋 `0cbcd45`에서 레인이 합류한다. stash 커밋은 보이지 않는다 | INT-07, GRA-02 |
| QA-GR-02 | 작성자와 날짜 열 | 한글 작성자(`김개발`)가 깨지지 않는다. 날짜는 시스템 로케일 형식이다 | PAR-LOG-03 |
| QA-GR-03 | 태그와 브랜치 배지 | `v0.0.1`, `light-tag`, 로컬·원격 브랜치 배지가 해당 커밋에 붙는다 | INT-11 |
| QA-GR-04 | bench 저장소 그래프를 끝까지 스크롤 | 눈에 띄는 끊김이 없다. 레인 색이 페이지 경계에서 바뀌지 않는다 | PERF-05, GRA-05 |
| QA-GR-05 | ⌘F로 커밋 메시지, 작성자, 이슈 번호 검색 | 일치 항목으로 이동하고 ⌘G로 다음 항목을 찾는다 | — |
| QA-GR-06 | ⌘J (Jump to HEAD) | 선택한 워크트리의 HEAD로 스크롤한다 | — |

## 커밋 상세와 파일 이력 (CD)

| ID | 확인 | 기대 결과 | 자동화 |
|---|---|---|---|
| QA-CD-01 | `4202323` 상세 (S-03) | `assets/binary.bin`이 "바이너리"로 표시되고 +/− 숫자가 없다 | PAR-NUMSTAT-03 |
| QA-CD-02 | `c46c37d` 상세 | `docs/guide.md → docs/manual.md` 이름 변경이 보인다 | INT-08 |
| QA-CD-03 | `docs/manual.md` 파일 이력 (S-09) | 이름 변경 이전을 포함해 4개 커밋이 보인다 | INT-09 |
| QA-CD-04 | `-dash-leading.txt`의 diff와 이력 (S-10) | 해당 파일만 대상이 된다. 옵션으로 해석되지 않는다 | INT-10, SEC-T9-03 |
| QA-CD-05 | Diff 뷰어 🌗 | 추가와 삭제가 색 외에 `+`/`−` 기호로도 구분된다. 긴 줄이 잘리지 않는다 | — |

## 이슈 패널 (IS)

| ID | 확인 | 기대 결과 | 자동화 |
|---|---|---|---|
| QA-IS-01 | `gh` 로그인 상태에서 GitHub 원격이 있는 저장소 | 이슈 목록이 보인다. 브랜치명 `feat/12-…`이 `#12`와 연결된다 | PAR-GH-01, PAR-ISSUE-01 |
| QA-IS-02 | `gh auth logout` 상태 | 이슈 패널에 "터미널에서 `gh auth login`을 실행하세요" 안내가 나온다. Git 조회 기능은 정상이다 | PAR-GH-02 |
| QA-IS-03 | `gh`가 PATH에 없음 (설치하지 않은 계정, 또는 이름을 임시로 바꿈) | 이슈 패널만 비활성. 크래시나 반복 오류가 없다 | — |
| QA-IS-04 | GitHub이 아닌 원격만 있는 저장소 (픽스처) | 이슈 패널에 "GitHub 원격 없음"이 표시된다 | — |
| QA-IS-05 | 이슈 생성·수정 버튼 | 없다 (N6) | — |

## 온보딩과 설정 (ON)

| ID | 확인 | 기대 결과 | 자동화 |
|---|---|---|---|
| QA-ON-01 | 처음 실행 (`UserDefaults` 초기화) | S-07 온보딩: 저장소 추가, git 감지(경로와 버전), GitHub 상태 | — |
| QA-ON-02 | `Choose folder…`로 git 저장소가 아닌 폴더 선택 | 이유를 알려 주고 등록하지 않는다 | — |
| QA-ON-03 | 다른 사용자 소유 저장소 (`safe.directory` 거부) | 이유를 알려 준다. 앱이 `safe.directory`를 설정하지 않는다 (`git config --global --get-all safe.directory` 변화 없음) | — |
| QA-ON-04 | 설정 "원격 URL 전체 표시" 켜기 | URL은 보이지만 자격 증명 부분은 계속 마스킹된다 | SEC-T11-04 |
| QA-ON-05 | 앱 재실행 | 등록한 저장소와 설정이 유지된다. `UserDefaults`에 토큰이나 비밀이 없다 (`defaults read io.github.kkdy21.overgrove` 확인) | — |

## 보안 (SEC)

| ID | 확인 | 기대 결과 | 자동화 |
|---|---|---|---|
| QA-SEC-01 | 악성 픽스처를 등록하고 모든 화면을 연다 (워크트리, WIP, 그래프, 커밋 상세, 파일 이력, stash, diff) | 끝난 뒤 `ls ~/tmp/qa-malicious/canary \| wc -l`이 `0` | INT-19, SEC-T1–T7 |
| QA-SEC-02 | 악성 픽스처에서 `origin` fetch | canary 0개, fetch 성공. auto maintenance가 돌지 않았다 (`GIT_TRACE=1` 로그에 `maintenance run`·`gc --auto` 자식 프로세스 없음) | SEC-T5-02, SEC-T8-01 |
| QA-SEC-03 | 악성 픽스처에서 `sshremote`, `gitremote`, `extremote`, `redirected` fetch | 모두 실패로 표시. canary 0개. 앱이 멈추지 않는다 | SEC-T5-01, SEC-T5-03–05 |
| QA-SEC-04 | 악성 픽스처의 S-05 SECURITY 섹션 | 무력화된 설정 키 목록(값 없이)과 경고 개수가 보인다 | — |
| QA-SEC-05 | 원격 `mirror`가 보이는 모든 곳 (S-05, 상태바, 오류 popover) | `fixture-user:…@`가 어디에도 원문으로 나오지 않는다 | INT-13, SEC-T11-04 |
| QA-SEC-06 | 상세 로그를 켜고 위 항목을 반복한 뒤 Console.app에서 `io.github.kkdy21.overgrove` 필터 | 자격 증명, 원격 URL 원문, 홈 경로가 없다 | SEC-T16-01 |
| QA-SEC-07 | 저장소 밖을 가리키는 심볼릭 링크 파일의 미리보기 | 경고가 나오고 내용을 열지 않는다 | SEC-T14-02 |

## 접근성 (A11Y)

| ID | 확인 | 기대 결과 | 자동화 |
|---|---|---|---|
| QA-A11Y-01 | VoiceOver로 사이드바 → 그래프 → 상세 이동 | 각 행이 의미 있는 레이블로 읽힌다 (예: "feat/ahead, 변경 0, 앞섬 2") | 레이블 문자열: `AccessibilityLabelTests`, `WorktreeListModelTests`, `BranchListModelTests`, `WipDetailModelTests` (#75). 실제로 읽히는지는 수동 |
| QA-A11Y-02 | 키보드만으로 주요 흐름 (Tab, ⌘1–⌘4, ↑/↓, ⏎, ⎋) | 마우스 없이 모든 화면에 도달한다. 포커스가 항상 보인다 | — |
| QA-A11Y-03 | 손쉬운 사용 › 디스플레이 › 대비 증가, 투명도 줄이기 🌗 | 상태 구분이 유지되고 텍스트 대비가 부족하지 않다 | — |
| QA-A11Y-04 | 동작 줄이기 켜기 | 불필요한 애니메이션이 사라진다 | — |
| QA-A11Y-05 | Accessibility Inspector 감사 | 경고 0개 또는 사유가 기록된 경고만 남는다 | — |
| QA-A11Y-06 | VoiceOver 로터(VO-U): 사이드바에서 `Worktrees`, S-02에서 `Changes`·`Conflicted Files` | 항목 이름이 읽히고 고른 행으로 이동한다. S-02는 긴 목록(lazy)의 화면 밖 행으로도 이동하는지 본다 | — |
| QA-A11Y-07 | 그래프 커밋 행에서 VoiceOver 읽기 | `Commit <SHA>, 제목, 작성자, 2 hours ago, branches …, HEAD of worktree …`, merge면 `merge commit, 2 parents`. 잠시 뒤 힌트로 절대 날짜. WIP 행은 `Uncommitted changes in …: 3 staged, …` | `AccessibilityLabelTests` (문자열) |
| QA-A11Y-08 | 행 컨텍스트 메뉴를 VoiceOver로 열기(VO-Shift-M): 커밋·파일·워크트리·브랜치·stash·이슈 | 보기·복사 항목만 있고 모두 실행된다. 같은 동작이 키보드 명령(⌘C, ⌥⌘C, ⌘J, ⌘I)으로도 된다 | `AppStateNavigationTests` (동작) |
| QA-A11Y-09 | fetch 성공·실패 | `Fetch finished` / `Fetch failed: …` 알림이 VoiceOver로 들린다 | `FetchAnnouncement` 문자열 테스트 |
| QA-A11Y-10 | 검사되지 않았거나 실행 설정이 있는 워크트리에서 Open in Terminal(툴바 또는 행 메뉴) | 확인 창이 VoiceOver로 읽히고, `⏎`·`⎋` 모두 Cancel이다 | `TerminalGuardTests` (판정) |
| QA-A11Y-11 | 대비 증가에서 툴바의 워크트리 칩 | 테두리가 `border.strong` 1.5pt로 바뀐다 | `AccessibilityLabelTests` (두께 값) |

## 다크 모드와 외관 (DM)

| ID | 확인 | 기대 결과 | 자동화 |
|---|---|---|---|
| QA-DM-01 | 시스템 외관을 라이트 ↔ 다크로 실행 중 전환 | 재시작 없이 즉시 바뀐다. 하드코딩된 색이 남지 않는다 | — |
| QA-DM-02 | 시스템 강조 색을 바꾼다 (파랑 → 보라 → 그래파이트) | 선택 강조가 따라 바뀐다. 상태 색(디자인 토큰)은 그대로다 | — |
| QA-DM-03 | 그래프 레인 색 🌗 | 인접 레인을 구분할 수 있다. 배경 대비가 design-tokens.md 기준을 만족한다 | — |
| QA-DM-04 | 앱 아이콘 (Dock, Finder, 설정의 앱 목록) 🌗 | iconography.md의 크기별 렌더링과 일치하고 흐려지지 않는다 | — |

## 성능 스모크 (PF)

정밀 측정은 PERF 테스트가 맡는다. 이 항목은 체감 확인이다.

| ID | 확인 | 기대 결과 | 자동화 |
|---|---|---|---|
| QA-PF-01 | bench 저장소 열기 | 1초 안에 워크트리 10개와 상태 요약이 보인다 | PERF-01 |
| QA-PF-02 | 워크트리 사이를 ↑/↓로 빠르게 이동 | 지연 없이 전환되고 이전 결과가 섞여 보이지 않는다 | PERF-02 |
| QA-PF-03 | bench 그래프 첫 화면 | 0.5초 안에 보인다 (commit-graph 있음) | PERF-03 |
| QA-PF-04 | commit-graph 없는 bench (`make-bench-repo.sh` 기본) 그래프 | 1초 안에 보인다. 기다리는 동안 골격이 먼저 보인다 | PERF-03 |
| QA-PF-05 | Activity Monitor로 bench 그래프 전체 적재 뒤 메모리 확인 | 300MB 이하 | PERF-07 |
| QA-PF-06 | 앱을 30분 켜 둔 뒤 (자동 fetch 켬) | 메모리가 계속 늘지 않고, 좀비 git 프로세스가 없다 (`ps -ax \| grep git`) | SEC-T15-02 |
