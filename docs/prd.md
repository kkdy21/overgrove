# 제품 요구 사항 문서 (PRD)

> 상태: Accepted (Phase 1 게이트, 2026-11-05) · 관련: ADR-0001~0008, ADR-0011, [scope-mvp.md](scope-mvp.md), [roadmap.md](roadmap.md)

## 1. 요약

Overgrove는 **여러 Git 워크트리를 한 화면에서 내려다보는 macOS 전용 네이티브 Git 클라이언트**다. 어떤 워크트리에서 무엇이 진행 중인지, 원격과 얼마나 차이 나는지, 아직 커밋하지 않은 것과 stash에 남은 것이 무엇인지, 누가 언제 바꿨는지를 한 화면에서 파악하게 한다.

1차 범위(v0.1.0)는 **조회 전용**이다. 원격 쓰기는 `git fetch` 하나뿐이다. push, PR 생성, 머지는 터미널이나 Claude Code 같은 하네스에서 한다. 앱은 시스템 `git`과 `gh`를 호출하고, 외부 패키지를 쓰지 않는다. 바이너리 없이 소스 빌드로 배포한다.

---

## 2. 문제

- 기능 개발을 Git 워크트리로 병렬 진행하는 일이 많아졌다. 특히 AI 코딩 에이전트에게 워크트리마다 작업을 맡기면 동시에 열린 워크트리가 5~10개가 된다.
- 기존 도구의 한계:

  | 도구 | 한계 |
  |---|---|
  | GitKraken | 워크트리 가시성은 좋지만 조회와 쓰기가 섞여 있다. 실수로 쓰기 동작을 할 위험이 있고, 구독형이다. |
  | lazygit, tig | 저장소 하나·워크트리 하나 단위라서 여러 워크트리를 나란히 비교하기 어렵다. |
  | `git worktree list` + `git status` 반복 | 워크트리마다 명령을 반복해야 하고, stash·ahead/behind·이슈 연결을 한 번에 볼 수 없다. |

- 처음 클론한 저장소나 에이전트가 만든 워크트리를 GUI로 열면, 그 저장소의 설정(fsmonitor, 필터, 훅)이 임의 명령을 실행할 수 있다. 대부분의 GUI 클라이언트는 이 위험을 사용자에게 드러내지 않는다.

---

## 3. 페르소나

### 3.1 주 페르소나 — 병렬 워크트리를 운영하는 1인 개발자

- 백엔드 개발자, 맥 사용자
- 터미널과 AI 에이전트 워크플로우에 익숙하다. 커밋, push, PR은 터미널이나 에이전트로 한다.
- 워크트리를 여러 개 동시에 운영하며, "지금 어디에 무엇이 남아 있는지"를 자주 놓친다.
- Swift 숙련도는 낮다. 이 프로젝트의 코드는 AI가 주도하고, 구조와 결정은 본인이 검토한다.
- 한국어를 선호하고, 기술 용어는 영문 그대로 쓴다.

### 3.2 보조 페르소나 — 오픈소스 기여자

- 소스를 클론해 Xcode로 빌드한다. 이슈 템플릿과 기여 가이드를 따라 기여한다.
- 영어로 소통한다 (ADR-0005).

---

## 4. 핵심 사용 시나리오

| ID | 시나리오 | 관련 목표 |
|---|---|---|
| UC-1 | 아침에 앱을 열어 워크트리 전체의 변경 수, ahead/behind, stash 개수를 훑는다 | G1, G2, G3, G4, G5 |
| UC-2 | 에이전트가 작업한 워크트리를 골라 staged·unstaged·untracked 파일과 diff를 확인한다 | G3, G7 |
| UC-3 | PR을 올리기 전에 fetch해서 원격 대비 behind가 없는지 확인한다 | G5 |
| UC-4 | 오래된 stash가 어떤 브랜치에서 무엇을 담고 있는지 보고 정리 여부를 판단한다 | G4 |
| UC-5 | 브랜치명의 이슈 번호로 어떤 이슈 작업인지 확인하고, 열린 이슈 중 워크트리가 없는 것을 찾는다 | G8 |
| UC-6 | 경로가 사라진(prunable) 워크트리나 잠긴(locked) 워크트리를 발견한다 | G2 |
| UC-7 | 처음 클론한 저장소를 등록했을 때 실행 가능한 설정이 무력화되었는지 확인한다 | 보안 원칙 |

---

## 5. 목표 (Goals)

| ID | 목표 | 측정 기준 | 화면 | 우선순위 |
|---|---|---|---|---|
| G1 | 저장소의 모든 워크트리를 목록으로 표시한다 | 픽스처 저장소의 `git worktree list` 결과와 100% 일치 | S-01 | P0 |
| G2 | 워크트리별 브랜치, HEAD, 경로, locked·prunable 상태를 표시한다 | 픽스처의 locked·prunable·detached 워크트리가 정확히 표시됨 | S-01, S-05 | P0 |
| G3 | 워크트리별 Staged / Unstaged / Untracked / Conflicted 파일 목록을 표시한다 | 픽스처 상태별 파일 목록이 `git status --porcelain=v2`와 100% 일치 | S-02 | P0 |
| G4 | 저장소 전체 stash 목록과 각 stash의 변경 요약을 표시한다 | `stash list`·`stash show --include-untracked --numstat`과 일치 | S-04 | P0 |
| G5 | 원격 대비 ahead/behind를 마지막 fetch 시각과 함께 표시한다 | fetch 후 `branch.ab` 값과 일치, 마지막 fetch 시각 표시 | S-01, S-05 | P0 |
| G6 | 커밋 그래프, 작성자, 날짜, 메시지를 표시하고 상단에 WIP 행을 둔다 | 픽스처의 병합·분기 구조가 레인으로 정확히 표시됨 (GRA 테스트) | S-01 | P0 |
| G7 | 커밋 상세(변경 파일, diff)와 파일별 이력을 표시한다 | `diff-tree` 결과와 일치, 이름 변경 추적 | S-03, S-09, S-10 | P1 |
| G8 | GitHub 이슈 목록을 보고, 브랜치명·커밋 메시지의 이슈 번호를 연결한다 | 브랜치 `feat/12-x` → 이슈 #12 링크. gh 미로그인 시 안내 | S-06 | P1 |
| G9 | 워크트리 10개, 커밋 10만 개 규모에서도 체감상 즉시 전환된다 | PB-1~PB-8 충족 ([performance/performance-budget.md](performance/performance-budget.md)) | 전체 | P0 |
| G10 | 소스를 클론한 뒤 Xcode에서 Run 한 번으로 실행된다 | README 절차만으로 깨끗한 맥에서 빌드·실행 성공 | — | P0 |

---

## 6. 비목표 (Non-goals)

| ID | 비목표 | 이유 | 대체 수단 |
|---|---|---|---|
| N1 | Windows, Linux 지원 | 네이티브 macOS 경험에 집중 | — |
| N2 | App Store 배포, 서명·공증된 바이너리 배포 | 1인 오픈소스 운영 부담, 소스 빌드로 충분 | 소스 빌드 (Sign to Run Locally) |
| N3 | push, PR 생성, 머지, 리뷰 작성 등 원격 쓰기. Pull 포함 (ADR-0011) | 조회 전용 원칙, 실행 경로 최소화 | 터미널, Claude Code 하네스 |
| N4 | 인터랙티브 리베이스, 드래그 앤 드롭 커밋 정리, 스테이징 토글, stash apply/pop/drop | 쓰기 작업 | `later` 이슈로 보관 |
| N5 | 자체 Git 엔진 구현 | 사용자 git 설정과 동일한 동작 보장 | 시스템 `git` 호출 (ADR-0008) |
| N6 | GitHub 이슈 생성·수정 | 1차는 조회만 | `gh issue create`, 웹 |
| N7 | 자체 OAuth 서버, 토큰 직접 발급·저장 | 비밀 정보 취급 범위 0 유지 | `gh` 로그인 위임 (ADR-0004) |

---

## 7. 기능 요구 사항

| ID | 요구 사항 | 목표 |
|---|---|---|
| FR-01 | 사용자는 `NSOpenPanel`로 저장소를 등록하고, 등록한 저장소 사이를 전환하고, 목록에서 제거할 수 있다 | G1 |
| FR-02 | 사이드바는 WORKTREES, LOCAL, REMOTE, STASHES, ISSUES 섹션을 보여 준다 | G1, G4, G8 |
| FR-03 | 워크트리 행에 변경 파일 수와 ahead/behind 수, locked·prunable 표시가 있다 | G2, G3, G5 |
| FR-04 | WIP 상세는 Staged, Unstaged, Untracked, Conflicted를 분리해 보여 준다. 한 파일이 Staged와 Unstaged에 모두 있을 수 있다 | G3 |
| FR-05 | 그래프는 상단에 선택 워크트리의 WIP 행을 두고, 커밋을 페이지 단위로 불러온다 | G6, G9 |
| FR-06 | 커밋을 선택하면 변경 파일과 줄 수, 파일별 diff를 볼 수 있다 | G7 |
| FR-07 | 파일의 이름 변경을 따라가는 이력을 볼 수 있다 | G7 |
| FR-08 | stash를 선택하면 기준 커밋, 변경 파일(untracked 포함), diff를 볼 수 있다. apply/pop/drop은 없다 | G4 |
| FR-09 | Fetch 버튼(⌘⇧R)으로 원격별 fetch를 실행하고, 진행 상태와 마지막 fetch 시각을 표시한다. 실패는 인증, 네트워크, 시간 초과, 기타로 분류해 안내한다 | G5 |
| FR-10 | 자동 fetch는 기본으로 꺼져 있고, 설정에서 켤 수 있다 | G5 |
| FR-11 | gh 로그인 상태를 확인하고, 로그인되어 있으면 이슈 목록을 보여 준다. 미설치·미로그인이면 터미널 명령을 안내한다 | G8 |
| FR-12 | 워크트리 상세(S-05)는 보안 상태(무력화된 위험 설정, 마스킹 여부)를 보여 준다 | 보안 원칙 |
| FR-13 | 원격 URL은 기본으로 자격 증명을 마스킹해 표시한다 | 보안 원칙 |
| FR-14 | 검색(⌘F)으로 커밋 메시지, 작성자, 브랜치, 이슈 번호를 걸러 본다 | G6 |
| FR-15 | 온보딩은 저장소 추가, git 버전 확인(2.36 이상), gh 상태 확인을 안내한다 | G10 |

---

## 8. 비기능 요구 사항

| 분류 | 요구 사항 | 근거 |
|---|---|---|
| 보안 | 위협 T1–T18 대응과 SEC 테스트 전부 통과 | [design/security-review.md](design/security-review.md) |
| 보안 | 앱은 토큰을 받거나 저장하지 않는다. 텔레메트리 없음 | ADR-0004 |
| 성능 | PB-1~PB-8 | [performance/performance-budget.md](performance/performance-budget.md) |
| 정확성 | 파서 단위 테스트와 픽스처 통합 테스트로 git 출력과 일치함을 보장 | [testing/test-strategy.md](testing/test-strategy.md) |
| 호환성 | macOS 14+, git 2.36+, gh는 선택 | ADR-0003, ADR-0008 |
| 접근성 | VoiceOver 레이블, 키보드만으로 모든 조회 가능, 색만으로 상태를 구분하지 않음 | [design/interaction.md](design/interaction.md) |
| 외형 | 다크 모드, 시스템 액센트 컬러를 따름. 브랜드 요소는 자체 디자인 | [design/design-tokens.md](design/design-tokens.md) |
| 공급망 | 외부 패키지 0개 | ADR-0006 |
| 빌드 | 클론 후 Xcode Run 한 번 | G10 |

---

## 9. 성공 지표

텔레메트리가 없으므로 사용량 지표는 측정하지 않는다. 다음은 릴리스 시점에 검증 가능한 지표다.

| 지표 | 목표 | 확인 방법 |
|---|---|---|
| 성능 예산 | PB-1~PB-8 모두 충족 | PERF 테스트, Phase 4 성능 보고서 |
| 상태 정확도 | 픽스처 시나리오에서 git 결과와 100% 일치 | INT 테스트 |
| 보안 | SEC-T1~T18 전부 통과, 악성 픽스처 canary 0건 | SEC 테스트 |
| 빌드 진입 장벽 | README만 보고 깨끗한 맥에서 15분 이내 빌드·실행 | Phase 5 검증 이슈 |
| 추적성 | v0.1.0 작업 100%가 마일스톤 이슈로 추적되고 닫힘 | GitHub 마일스톤 |

---

## 10. 가정과 제약

| 구분 | 내용 |
|---|---|
| 가정 | 사용자는 Xcode(또는 CLT)를 설치했고, `/usr/bin/git`이 2.36 이상이다. Apple Git 2.50.1에서 확인했다 |
| 가정 | GitHub 연동은 선택이다. `gh`가 없어도 Git 조회는 완전히 동작한다 |
| 가정 | 원격 인증은 사용자의 기존 credential helper나 SSH 키로 이미 동작한다 |
| 제약 | App Sandbox를 끈다. 임의 경로 접근과 git 자식 프로세스의 credential helper 접근 때문이다. 대신 Hardened Runtime과 실행 경로 통제로 보완한다 |
| 제약 | 서명·공증 바이너리를 배포하지 않는다. 사용자는 소스에서 빌드한다 |
| 제약 | 외부 패키지를 쓰지 않는다. 파서, 그래프, diff 표시를 직접 구현한다 |
| 제약 | GitKraken의 로고, 아이콘, 문구, 색상을 쓰지 않는다. 3단 레이아웃과 WIP 행 같은 패턴만 참고한다 |

---

## 11. 리스크

| 리스크 | 영향 | 대응 |
|---|---|---|
| git 출력 형식 차이 (버전, 로케일) | 잘못된 상태 표시 | `LC_ALL=C`, porcelain v2·`-z` 고정, 파서 테스트, 최소 버전 CI 매트릭스 |
| 악성 저장소 설정으로 코드 실행 | 사용자 계정 장악 | ADR-0008, ADR-0009, SEC 테스트 |
| 대형 저장소에서 느린 로딩 | G9 실패 | 워크트리별 병렬 조회, 캐시, 그래프 페이지, untracked 조회 조정 |
| `--untracked-files=all`·fsmonitor 비활성으로 status가 느려짐 | PB-5 실패 | 측정 후 `normal` 모드나 표시 상한 검토 |
| 워크트리 경로 삭제 | 에러 남발 | prunable 표시, 새로고침 시 재검사 |
| fetch 인증 프롬프트 | 앱 정지 | `GIT_TERMINAL_PROMPT=0`, BatchMode, 타임아웃 |
| gh 미설치·미로그인·JSON 형식 변경 | 이슈 패널 오류 | Git 기능과 분리, 온보딩 안내, 파서 테스트 |
| gh 텔레메트리 | 텔레메트리 없음 원칙 위반 | `GH_TELEMETRY=0`, `DO_NOT_TRACK=1` (ADR-0004) |
| 로컬 LFS 필터 무력화 | LFS 파일이 변경으로 보임 | S-05에 무력화 사실 표시, 문서화 |
| 이슈 중심 운영의 오버헤드 | 개발 속도 저하 | 템플릿 간소화, Claude Code skill로 자동화 |
| Swift 숙련도 부족 | 구조 붕괴 | 구조 문서, 파서·UI 분리, 테스트 우선, 에이전트 리뷰 |
| Xcode·Apple Git 버전 변화 | 빌드·동작 차이 | CI의 Xcode 버전 명시, 호환성 매트릭스 |
| 공개 저장소에 민감 정보 유출 | 신뢰 손상 | gitleaks 3단계, Secret scanning, Push protection, 승인 후 게시 |

---

## 12. 미결 사항

| 질문 | 제안 | 결정 시점 |
|---|---|---|
| v0.1.0 UI 언어 | 영어만 (설계 문서 기준). 한국어 현지화는 `later`, 도입 시 String Catalog | Phase 1 승인 시 확정 (`type:decision` 이슈) |
| 자동 fetch 주기 기본값 | 꺼짐. 켜면 10분 | Phase 2 설계 검토 |
| untracked 파일 표시 상한 | 잠정 5,000개. 넘으면 "더 있음" 표시 | 성능 측정 후 [performance-budget.md](performance/performance-budget.md)에서 확정 |
| 동시에 여는 저장소 수 | 창 하나에 저장소 하나. 여러 창 허용 | Phase 2 설계 검토 |
| 그래프 첫 페이지 크기 | 500개 | Phase 3 성능 측정 후 |
