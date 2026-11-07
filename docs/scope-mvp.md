# MVP 범위 (v0.1.0)

> 상태: Accepted (Phase 1 게이트, 2026-11-05) · 갱신: 2026-11-06 (#153, #155–#160, #163) · 관련: [prd.md](prd.md), [roadmap.md](roadmap.md), ADR-0004, ADR-0011

이 문서는 v0.1.0에 무엇이 들어가고 무엇이 빠지는지, 언제 끝났다고 말할 수 있는지를 정의한다. 범위에 없는 요청은 구현하지 않고 `later` 마일스톤 이슈로 등록한다.

---

## 1. v0.1.0 포함 범위

| 기능 | 목표 | 화면 | 비고 |
|---|---|---|---|
| 저장소 등록·전환·제거 | G1 | S-07, S-08 | `NSOpenPanel`, 창 하나에 저장소 하나 |
| 워크트리 목록 (브랜치, HEAD, 경로, locked, prunable, detached) | G1, G2 | S-01 사이드바 | `worktree list --porcelain -z` |
| 워크트리별 변경 수, ahead/behind | G3, G5 | S-01 사이드바 | `status`의 `branch.ab` 헤더 |
| WIP 상세 (Staged, Unstaged, Untracked, Conflicted) | G3 | S-02 | untracked 표시 상한 있음 (§4) |
| 워크트리 상세와 보안 상태 | G2, G5 | S-05 | [security-review.md §6](design/security-review.md) |
| 로컬·원격 브랜치 목록 | G1 | S-01 사이드바 | 태그는 그래프의 ref 표시로만 |
| stash 목록과 상세 (untracked 포함 변경 요약, diff) | G4 | S-04 | apply/pop/drop 없음 |
| 커밋 그래프와 WIP 행, 페이지 로드 | G6, G9 | S-01 | 앱에서 레인 계산 (ADR-0010), stash 노드 없음 |
| 커밋 상세 (파일, 줄 수, diff) | G7 | S-03, S-10 | 줄 단위 diff |
| 파일 이력 (`--follow`) | G7 | S-09 | |
| Fetch (원격별, 진행 상태, 취소, 마지막 fetch 시각) | G5 | S-01 툴바·상태바 | 단축키 `⌘⇧R`, 실패 분류 4종 |
| 자동 fetch (기본 꺼짐) | G5 | S-08 | |
| 워크트리와 기준 브랜치의 PR식 비교(갈라진 지점 기준, 미커밋 포함 선택) | G7 | S-11 | 2026-11-06 메인테이너 요청으로 추가 (#157, #158) |
| 작성자 아바타(이니셜)·작성자 필터·AI 공동 작성 배지 | G6 | S-01, S-03 | 2026-11-06 추가 (#159, #160). 네트워크 아바타는 쓰지 않음 |
| GitHub 이슈 목록, 이슈 번호 연결 | G8 | S-06 | gh 위임, github.com만 |
| 온보딩 (저장소 추가, git·gh 점검) | G10 | S-07 | |
| 검색 (커밋 메시지, 작성자, 브랜치, 이슈 번호) | G6 | S-01 | 로드된 페이지 범위 |
| 키보드 조작, VoiceOver 레이블 | — | 전체 | [design/interaction.md](design/interaction.md) |
| 보안 기반 (T1–T18 대응) | — | — | ADR-0008, ADR-0009 |

---

## 2. v0.1.0 제외 범위

| 항목 | 근거 | 보관 위치 |
|---|---|---|
| Windows, Linux | N1 | 계획 없음 |
| App Store, 서명·공증 바이너리 | N2 | 계획 없음 |
| push, PR 생성, 머지, 리뷰 작성 | N3 | 하네스에서 수행 |
| Pull (버튼 포함) | N3, ADR-0011 | `later` |
| 스테이징 토글, 인터랙티브 리베이스, 커밋 정리, stash apply/pop/drop | N4 | `later` |
| 워크트리 제거·prune 같은 앱 안의 로컬 쓰기 작업 | #155 결정: 조회 전용 유지. 쓰기는 터미널과 AI 에이전트가 맡는다 | `later` (#156) |
| 자체 Git 엔진 | N5 | 계획 없음 |
| 이슈 생성·수정, PR 상태 표시 | N6, ADR-0004 | `later` |
| 토큰 입력·저장, OAuth, GitHub App | N7 | `later` (GitHub App 검토) |
| GitHub Enterprise, 여러 GitHub 계정 전환 | ADR-0004 | `later` |
| 서명 검증 표시 (`%G?`) | T7 | 계획 없음 |
| 서브모듈 내부 변경 표시 | ADR-0009 (`--ignore-submodules=dirty`) | v0.2.0 (#108: S-02 Submodules 카드) |

---

## 3. 이후 버전

### 3.1 v0.2.0 — 보안·설정 강화

| 항목 | 내용 |
|---|---|
| git 실행 파일 경로 지정 | 절대 경로 지정과 버전 검증 (ADR-0008 후속) |
| 저장소별 "신뢰하지 않음" 모드 | fetch 차단, `protocol.file.allow=never`, 경고 강화 (ADR-0009 후속) |
| 서브모듈 안전 조회 | 서브모듈별로 설정을 검사한 뒤 내부 상태 표시 (#108, S-02 Submodules 카드) |
| 메모리 밖 캐시 | 앱 재실행 시 빠른 첫 화면 |
| 보안 보고서 내보내기 | S-05 내용을 마스킹해 텍스트로 복사 |
| CodeQL Swift 분석 정식 적용 | v0.1.0에서 적용하지 못한 경우 |
| 셸 프록시 환경 변수 전달 여부 | 결정 이슈 #153. v0.1은 전역 `http.proxy`를 안내한다 |

### 3.2 later — 백로그

[roadmap.md §10](roadmap.md)에 이슈 단위로 정리한다. 주요 항목은 다음과 같다.

- Pull, 스테이징 토글, 인터랙티브 리베이스, stash apply/pop/drop
- PR 상태 표시, 이슈 생성·수정, GitHub Enterprise, GitHub App, 여러 계정 전환
- UI 한국어 현지화
- 그래프 확대(`⌘+`/`⌘−`), 그래프 stash 노드, 두 커밋 비교, 단어 단위 diff, 공백 표시
- 태그 섹션, Quick Look, 선택 이력 뒤로/앞으로, 사용자 지정 터미널·에디터, Open on GitHub
- 워크트리 정리(#156), GitLab·Forgejo/Gitea 이슈 패널(#154)

---

## 4. v0.1.0 제약

설계 단계에서 정한 v0.1.0의 의도된 한계다. 버그로 취급하지 않는다.

| 제약 | 내용 | 해소 시점 |
|---|---|---|
| 그래프 행 높이 고정 | 그래프 행 높이는 24px(`size.row-graph`)로 고정한다. 가상화를 위해서다. 글자 크기 확대에 대응하지 않는다 | later (확대 기능) |
| 자동 새로고침은 창이 보일 때만 | FSEvents로 검증된 워크트리와 공통 git 디렉터리를 감시하고 바뀐 워크트리만 다시 조회한다(#119, #163 결정 B). 창이 가려지거나 최소화되면 감시를 멈추고, 다시 보이면 한 번 새로고침한다. 그동안의 변경은 그때 반영된다. 화면에 보이지 않는 창은 갱신하지 않는다 | 의도된 동작 |
| UI 언어 | 영어만 | later (현지화) |
| untracked 표시 상한 | 5,000개(확정, #91). 넘으면 `UNTRACKED (5,000+)`로 표시한다. `--untracked-files=all` 유지. 근거는 [performance-budget.md PB-5](performance/performance-budget.md) | 2026-11-08 확정 |
| 서브모듈 | 파일 목록에서는 커밋 변경만 표시한다. 내부 상태는 S-02의 Submodules 카드에 개수로만 보이고 파일 목록으로 펼치지 않는다(#108) | v0.2.0 |
| 로컬 필터 무력화 | 로컬에 정의된 필터(LFS 포함)를 무력화하므로 필터 대상 파일이 변경으로 보일 수 있다 | 의도된 동작 (S-05에 표시) |
| 다중 선택 없음 | 커밋·파일 다중 선택과 비교가 없다 | later |
| 검색 범위 | 로드된 그래프 페이지 안에서만 찾는다 | 성능 측정 후 재검토 |
| 이슈 범위 | 열린 이슈만, 최대 200개 | later |
| 원격 호스트 | 이슈 연동은 github.com 원격만 | later (GHE) |

---

## 5. 완료 기준 (Definition of Done, v0.1.0)

모든 항목은 검증 방법이 정해져 있다. 하나라도 실패하면 릴리스하지 않는다.

| # | 기준 | 검증 방법 |
|---|---|---|
| D1 | 저장소 등록 후 모든 워크트리가 목록에 표시된다 (main, linked, detached, locked, prunable) | INT 테스트 (픽스처) + QA 체크리스트 |
| D2 | 워크트리별 Staged, Unstaged, Untracked, Conflicted 파일이 `git status --porcelain=v2` 결과와 100% 일치한다 | PAR-STATUS-*, INT 테스트 |
| D3 | 저장소 전체 stash 목록과 각 stash의 변경 요약(untracked 포함)이 표시된다 | PAR-STASH-*, PAR-NUMSTAT-05, INT 테스트 |
| D4 | fetch 후 ahead/behind가 `branch.ab`와 일치하고, 마지막 fetch 시각이 표시된다 | INT 테스트 (원격 2개 픽스처) |
| D5 | 커밋 그래프의 레인, 작성자, 날짜, WIP 행이 표시된다 | GRA-*, QA 체크리스트 |
| D6 | gh 로그인 상태에 따라 이슈 패널이 동작하거나 안내를 표시한다 (설치됨·미설치·미로그인) | PAR-GH-*, QA 체크리스트 |
| D7 | 위협 T1–T18의 SEC 테스트가 모두 통과하고, 악성 픽스처의 canary가 하나도 생성되지 않는다 | SEC-T1~T18 |
| D8 | 자격 증명과 원격 URL의 민감 부분이 화면과 로그에서 마스킹된다 | SEC-T11-*, SEC-T16-01 |
| D9 | PB-1~PB-8을 기준 장비와 기준 저장소에서 충족한다 | PERF 테스트, Phase 4 성능 보고서 |
| D10 | 파서 단위 테스트와 임시 저장소 통합 테스트가 CI(`build-test`)에서 통과한다 | GitHub Actions |
| D11 | README만 보고 깨끗한 맥에서 소스 빌드·실행에 성공한다 | Phase 5 검증 이슈 |
| D12 | LICENSE, CONTRIBUTING, SECURITY, CODE_OF_CONDUCT, 이슈·PR 템플릿이 있다 | 저장소 확인 |
| D13 | 모든 v0.1.0 작업이 마일스톤 이슈로 추적되고 닫혀 있다 | GitHub 마일스톤 |
| D14 | `v0.1.0` 태그, 릴리스 노트, CHANGELOG가 준비되어 있다 | [qa/release-checklist.md](qa/release-checklist.md) |
| D15 | macOS 14 실기기(또는 VM)와 최신 macOS에서 수동 QA 체크리스트를 통과한다 | [qa/checklist.md](qa/checklist.md) |
