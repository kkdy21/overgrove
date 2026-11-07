# Overgrove 문서 지도

> 상태: Accepted · 이 문서는 저장소 전체 문서의 **목차이자 공통 규약**이다. 다른 문서와 충돌하면 이 문서를 먼저 고친 뒤 나머지를 맞춘다.

Overgrove는 여러 Git 워크트리를 한 화면에서 내려다보는 macOS 전용 네이티브 Git 클라이언트다. 1차 범위는 조회 전용이며, 원격 쓰기는 `git fetch` 하나뿐이다.

원래 요구 사항은 [`HANDOFF.md`](../HANDOFF.md)에 있고, 확정된 내용은 이 디렉터리의 문서가 우선한다.

---

## 1. 문서 목록

| 영역 | 문서 | 내용 |
|---|---|---|
| 기획 | [prd.md](prd.md) | 문제, 페르소나, 목표(G), 비목표(N), 성공 지표 |
| 기획 | [scope-mvp.md](scope-mvp.md) | v0.1.0 범위, 제외 범위, 완료 기준(DoD) |
| 기획 | [glossary.md](glossary.md) | 용어집 |
| 기획 | [roadmap.md](roadmap.md) | Phase, 마일스톤, Epic과 하위 이슈 목록 (이슈 생성의 원본) |
| 결정 | [adr/](adr/) | 아키텍처 결정 기록 |
| 아키텍처 | [architecture/overview.md](architecture/overview.md) | 계층, 모듈 경계, 데이터 흐름, 동시성, 상태 관리, 캐시, 에러 모델 |
| 아키텍처 | [architecture/git-command-catalog.md](architecture/git-command-catalog.md) | 허용된 git·gh 명령의 정확한 인자, 환경, 타임아웃, 파서 매핑 |
| 아키텍처 | [architecture/parsing-spec.md](architecture/parsing-spec.md) | 출력 형식과 파서 명세, 경계 사례 |
| 설계 | [design/information-architecture.md](design/information-architecture.md) | 정보 구조, 내비게이션 |
| 설계 | [design/screens.md](design/screens.md) | 화면 명세 (S-xx) |
| 설계 | [design/interaction.md](design/interaction.md) | 상호작용, 키보드, 로딩·빈·에러 상태, 접근성 |
| 설계 | [design/art-direction.md](design/art-direction.md) | 아트 디렉션: 패널 구조, 분할선·스크롤, 색, 그래프·알약·사이드바 모양의 수치 (#166) |
| 설계 | [design/design-tokens.md](design/design-tokens.md) | 디자인 토큰 설명 (원본: `design/tokens/tokens.json`) |
| 설계 | [design/iconography.md](design/iconography.md) | 앱 아이콘과 심볼 사용 원칙 (원본: `design/icon/`) |
| 설계 | [design/references.md](design/references.md) | macOS Git 클라이언트·HIG 레퍼런스 패턴 조사 (브랜드 요소는 쓰지 않음) |
| 설계 | [design/mockups.md](design/mockups.md) | 주요 화면 목업 갤러리 (라이트·다크, 원본 SVG와 생성 스크립트) |
| 설계 원본 | [`design/`](../design/) | `tokens/tokens.json`(토큰 원본), `icon/`(아이콘 SVG 원본), `mockups/`(주요 화면 목업과 `generator/` 생성기·색 검증기) |
| 보안 | [design/security-review.md](design/security-review.md) | 위협 모델(T-xx), 대응, 보안 테스트 매핑, 체크리스트 |
| 테스트 | [testing/test-strategy.md](testing/test-strategy.md) | 테스트 피라미드, 테스트 ID 체계, CI 실행 범위 |
| 테스트 | [testing/fixtures.md](testing/fixtures.md) | 임시 저장소 픽스처 명세 (`scripts/make-fixture-repo.sh`) |
| 성능 | [performance/performance-budget.md](performance/performance-budget.md) | 성능 예산 (측정 가능한 수치) |
| 성능 | [performance/benchmark-plan.md](performance/benchmark-plan.md) | 벤치마크 방법, 대형 저장소 생성 (`scripts/make-bench-repo.sh`) |
| QA | [qa/process.md](qa/process.md) | QA 프로세스, 버그 처리 흐름 |
| QA | [qa/checklist.md](qa/checklist.md) | 수동 점검 체크리스트 (QA-xx) |
| QA | [qa/release-checklist.md](qa/release-checklist.md) | 릴리스 직전 점검 |
| QA | [qa/bug-triage.md](qa/bug-triage.md) | 버그 분류 기준, 심각도 |
| 프로세스 | [process/development-workflow.md](process/development-workflow.md) | Discussion → Issue → Branch → PR → Merge 전체 흐름 |
| 프로세스 | [process/issues.md](process/issues.md) | 이슈 규칙, 라벨, 트리아지, Epic |
| 프로세스 | [process/pull-requests.md](process/pull-requests.md) | PR 규칙, 리뷰와 코멘트 규약, 머지 정책 |
| 프로세스 | [process/branching-and-commits.md](process/branching-and-commits.md) | 브랜치명, 커밋 메시지, Git hooks |
| 프로세스 | [process/discussions.md](process/discussions.md) | Discussions 운영, 토론에서 결정과 이슈로 넘어가는 법 |
| 프로세스 | [process/collaboration.md](process/collaboration.md) | 외부 기여 모델, 이슈 선점(`/claim`, 5시간 기한, PR 선착순), 의존 이슈(stand-in, 머지 순서), AI 기여 규칙 |
| 프로세스 | [process/phase-gates.md](process/phase-gates.md) | Phase별 산출물과 승인 기준 |
| 프로세스 | [process/release.md](process/release.md) | 버전 정책, 릴리스 절차 |
| 프로세스 | [process/github-settings.md](process/github-settings.md) | 저장소 설정(룰셋, 보안, 라벨, 보드)과 재현 스크립트 |
| 프로세스 | [process/claude-code-harness.md](process/claude-code-harness.md) | Claude Code 하네스(CLAUDE.md, skills, agents, hooks) 사용법 |

---

## 2. 공통 식별자

모든 문서는 아래 이름을 그대로 쓴다. 새 이름이 필요하면 이 표에 먼저 추가한다.

### 2.1 제품과 빌드

| 항목 | 값 |
|---|---|
| 제품명 | Overgrove |
| GitHub 저장소 | `kkdy21/overgrove` |
| Xcode 프로젝트 | `Overgrove.xcodeproj` |
| 앱 타깃 / 테스트 타깃 | `Overgrove` / `OvergroveTests` |
| Bundle ID | `io.github.kkdy21.overgrove` |
| 최소 macOS | 14.0 (ADR-0003) |
| 최소 git | 2.36 (`worktree list -z` 지원 버전). 기본 실행 파일 `/usr/bin/git` (ADR-0008) |
| gh 탐색 | `/opt/homebrew/bin/gh` → `/usr/local/bin/gh` 순서, PATH 검색 없음 (ADR-0004, ADR-0008) |
| Swift | Swift 6 언어 모드, strict concurrency |
| 포맷·린트 | 툴체인 내장 `swift format` (ADR-0007), 설정 파일 `.swift-format` |
| 외부 패키지 | 0개 (ADR-0006) |

### 2.2 소스 구조 (Phase 3에서 생성)

```
Overgrove/
├── App/            # 진입점(OvergroveApp), AppState, 의존성 조립
├── Execution/      # ProcessRunner — 앱 전체에서 Process를 만드는 유일한 곳
├── Git/            # GitClient(actor), GitCommand(ReadOnlyGitCommand, FetchCommand), GitEnvironment, RepoConfigInspector, GitError,
│                   # FetchFailureGuidance, TransportName
├── GitHub/         # GHClient(actor), GHCommand(gh 명령 allowlist), GHError, GitHubRepository
├── Parsing/        # WorktreeParser, StatusParser, StashParser, LogParser, RevListParser, RefParser, NumstatParser,
│                   # ConfigParser, VersionParser, GHAuthParser, IssueParser, IssueRefExtractor, FetchProgressParser
├── GraphEngine/    # 커밋 그래프 레인 계산 (UI 무관, 순수 로직)
├── Models/         # 값 타입 모델
├── Security/       # CredentialMasker, PathValidator
├── DesignSystem/   # 디자인 토큰의 Swift 표현, 공용 컴포넌트
├── Features/       # Worktrees, Graph, Detail, Stash, Issues, Onboarding, Settings
└── Resources/      # Assets.xcassets (AppIcon, 색상 세트)
OvergroveTests/
├── Support/  ├── Parsing/  ├── Security/  ├── GraphEngine/  ├── Integration/  └── Performance/
```

규칙: `Process`, `NSTask`, `posix_spawn`, `popen`, `system()`, `/bin/sh`는 `Overgrove/Execution/` 밖에서 쓰지 않는다. 유일한 예외는 픽스처 스크립트를 실행하는 테스트 지원 코드 `OvergroveTests/Support/`다. `scripts/lint/check-forbidden-apis.sh`가 pre-commit hook, Claude Code hook, CI에서 이를 강제한다.

### 2.3 모델 이름

`Repository`, `Worktree`, `WorkingState`, `FileChange`, `UpstreamStatus`, `Stash`, `StashDetail`, `CommitNode`, `CommitDetail`, `FileHistoryEntry`, `Branch`, `Issue`, `GHAuthStatus`, `FetchRecord`, `GitPath`(raw 바이트 + 표시 문자열), `ConfigEntry`, `RepoSecurityReport`

보조 타입: `ObjectID`(SHA-1·SHA-256 검증), `ConflictKind`(unmerged XY 7종), `FileStat`(커밋·stash 파일 통계), `Tag`, `GitVersion`(최소 2.36 판정), `GitHubRepository`(`--repo`용 검증된 `OWNER/NAME`, `Overgrove/GitHub/`), `FetchProgress`(fetch 진행 단계와 숫자). 정의는 `Overgrove/Models/`에 있다. 파서 실패는 `Overgrove/Parsing/ParseError`로 내고, `GitError`가 `parseFailed`로 감싼다.

### 2.4 위협 ID (상세: design/security-review.md)

| ID | 위협 |
|---|---|
| T1 | `core.fsmonitor` 실행 |
| T2 | hooks 실행 (fetch 시 `reference-transaction` 포함) |
| T3 | 외부 diff, textconv 실행 |
| T4 | clean/smudge/process 필터 실행 (`.gitattributes` + `filter.<driver>.*`) |
| T5 | 전송 계층 명령 실행·정지 (`core.sshCommand`, `core.gitProxy`, `remote.<name>.uploadpack`, `ext::`·`fd::` URL) |
| T6 | 저장소 로컬 `credential.helper`·`credential.<url>.helper` 실행 |
| T7 | 서명 검증 프로그램 실행 (`gpg.program`, `gpg.ssh.program`) |
| T8 | fetch 중 자동 gc/maintenance (의도치 않은 쓰기, 장시간 실행) |
| T9 | 인자 인젝션 (`-`로 시작하는 ref·경로, 제어 문자) |
| T10 | 부모 환경 변수 상속 (`GIT_DIR`, `GIT_CONFIG_*`, `GIT_SSH_COMMAND`, `GIT_PAGER` 등) |
| T11 | 자격 증명 노출 (원격 URL, stderr, 로그) |
| T12 | 자격 증명 프롬프트 대기로 인한 정지, 로컬 `core.askPass` 실행 |
| T13 | 의도치 않은 쓰기 명령 실행 |
| T14 | 파일 시스템 범위 이탈, 심볼릭 링크 탈출 |
| T15 | 자원 고갈 (출력 폭주, 병적인 저장소) |
| T16 | 로그를 통한 정보 유출 |
| T17 | 공급망 (의존성, GitHub Actions) |
| T18 | 공개 저장소에 비밀 정보·개인 경로 커밋 |

### 2.5 ADR 번호

| 번호 | 제목 | 상태 |
|---|---|---|
| 0000 | 템플릿 | — |
| 0001 | 제품명 Overgrove | Accepted |
| 0002 | 라이선스 MIT | Accepted |
| 0003 | 최소 macOS 14 | Accepted |
| 0004 | GitHub 연동은 `gh` CLI 위임, 이슈 조회만 | Accepted |
| 0005 | 문서 언어 (내부 한국어, 외부 접점 영어) | Accepted |
| 0006 | 외부 의존성 0개 | Accepted |
| 0007 | 포맷·린트는 툴체인 내장 swift-format | Accepted |
| 0008 | git 호출 모델 (Process, 인자 배열, 환경 allowlist, 타임아웃, 출력 상한) | Accepted |
| 0009 | 저장소 설정 무력화 (RepoConfigInspector) | Accepted |
| 0010 | 커밋 그래프 레인을 앱에서 계산 | Accepted |
| 0011 | v0.1에서 Pull 제외 | Accepted |
| 0012 | 1인 메인테이너 머지 정책 | Accepted |
| 0013 | 외부 기여 모델과 이슈 선점 정책 (fork PR, 5시간 기한, PR 선착순) | Accepted |
| 0014 | 메인 창의 자체 패널 테마와 사용자 정의 분할 레이아웃 | Accepted |
| 0015 | 의존 이슈를 기다리지 않는다 (stand-in, 머지 순서는 `pr-policy`) | Accepted |
| 0016 | 보드 Status는 워크플로우가 project 전용 토큰으로 맞춘다 | Accepted |

### 2.6 테스트 ID

| 접두사 | 대상 | 예 |
|---|---|---|
| `SEC-T{n}-{nn}` | 보안 테스트, 위협 ID와 1:1 이상 매핑 | `SEC-T4-01` |
| `PAR-{파서}-{nn}` | 파서 단위 테스트. 파서 약어: WT, STATUS, STASH, LOG, REF, REVLIST, NUMSTAT, CONFIG, GH, VER, ISSUE | `PAR-STATUS-07` |
| `GRA-{nn}` | GraphEngine 단위 테스트 | `GRA-03` |
| `INT-{nn}` | 실제 git과 픽스처 저장소를 쓰는 통합 테스트 | `INT-12` |
| `PERF-{nn}` | 성능 측정 | `PERF-02` |
| `QA-{영역}-{nn}` | 수동 QA 체크리스트 항목. 영역: WT, ST, SH, SY, GR, CD, IS, ON, SEC, A11Y, DM, PF | `QA-WT-03` |

ID 원본 위치: SEC → [design/security-review.md](design/security-review.md), PAR → [architecture/parsing-spec.md](architecture/parsing-spec.md), GRA → [testing/test-strategy.md §4.2](testing/test-strategy.md), INT → [testing/fixtures.md §7](testing/fixtures.md), PERF → [performance/benchmark-plan.md §3](performance/benchmark-plan.md), QA → [qa/checklist.md](qa/checklist.md).

테스트 지원 규약: 픽스처는 `OvergroveTests/Support/FixtureRepo.swift`가 `scripts/make-fixture-repo.sh`를 실행해 만든다. 실패한 테스트의 픽스처를 남기려면 `OVERGROVE_KEEP_FIXTURES=1`을 설정한다.

### 2.7 화면 ID (상세: design/screens.md)

| ID | 화면 |
|---|---|
| S-01 | 메인 창 (툴바, 사이드바, 그래프, 상세, 상태바) |
| S-02 | WIP 상세 |
| S-03 | 커밋 상세 |
| S-04 | Stash 상세 |
| S-05 | 워크트리 상세 (보안 상태 포함) |
| S-06 | 이슈 패널 |
| S-07 | 온보딩 |
| S-08 | 설정 |
| S-09 | 파일 이력 |
| S-10 | Diff 뷰어 |
| S-11 | 기준 브랜치 대비 변경 (PR식 비교, #157·#158) |

### 2.7.1 단축키

단축키 원본은 [design/interaction.md §3](design/interaction.md)이다. HANDOFF 초안과 달리 Fetch는 `⌘⇧R`이다(IDE의 Find in Files `⌘⇧F`와의 충돌을 피함).

### 2.8 성능 목표 (상세: performance/performance-budget.md)

기준 장비는 Apple Silicon M1급, 기준 저장소는 `scripts/make-bench-repo.sh` 산출물이다.

| ID | 시나리오 | 목표 (p95) |
|---|---|---|
| PB-1 | 저장소 열기 → 워크트리 10개 목록과 상태 요약 표시 | 1.0초 이내 |
| PB-2 | 캐시된 워크트리 간 전환 | 100ms 이내 |
| PB-3 | 커밋 10만 개 저장소(commit-graph 있음)에서 그래프 첫 페이지(500개) 표시 | 500ms 이내 |
| PB-3b | 같은 조건, commit-graph 없음 | 1.0초 이내 |
| PB-4 | 그래프 스크롤 | 60fps, hitch ratio 5ms/s 미만 |
| PB-5 | 파일 1만 개 워크트리의 status 새로고침 | 300ms 이내 |
| PB-6 | 커밋 10만 개 메타데이터 적재 시 메모리 | 300MB 이하 |
| PB-7 | 파일 이력(`--follow`) 첫 100개 표시 | 1.0초 이내 |
| PB-8 | 커밋·stash 상세 표시 | 200ms 이내 |

git 계층 실측 기준선(이 표의 근거)은 [performance/benchmark-plan.md §4](performance/benchmark-plan.md)에 있다.

### 2.9 GitHub 운영 식별자

- 마일스톤: `v0.1.0`, `v0.2.0`, `later`
- 라벨 원본: [`.github/labels.json`](../.github/labels.json)
  - `type:` feature, bug, spike, decision, docs, test, chore, epic
  - `phase:` plan, design, dev, qa, release
  - `area:` git-core, parser, ui, github, security, ci, docs
  - `priority:` p0, p1, p2
  - `status:` triage, blocked, needs-decision
  - `resolution:` duplicate, wontfix, invalid
  - `good first issue`, `help wanted`
- 필수 상태 검사(Required checks): `gitleaks`, `pr-policy`, `build-test`
- 이슈 선점: 이슈 댓글 `/claim`·`/unclaim`, 기한 5시간(PR 없으면 해제), 1인당 2개, 담당자 없는 이슈는 PR 선착순 (ADR-0013)
- 의존성: 이슈 본문 `## 의존성` 절, PR 본문 `Depends on #<n>` 줄, 임시 구현 표시 `STAND-IN(#<n>)` 주석. 의존 이슈가 모두 완료로 닫혀야 `pr-policy`가 통과한다 (ADR-0015)
- 브랜치명: `<type>/<issue>-<slug>`. type은 `feat`, `fix`, `docs`, `test`, `chore`, `spike`, `refactor`, `perf`, `ci` 중 하나
- 커밋: Conventional Commits, 영어 제목. 이슈 번호는 `Refs: #n` 트레일러로 남긴다 (`prepare-commit-msg` hook이 브랜치명에서 자동 추가)
- 머지: squash 전용. squash 커밋 제목은 PR 제목을 쓴다
- 이슈·PR 언어: **제목은 영어**(Conventional 형식, 검색성), 본문은 한국어 또는 영어. Epic 제목은 `[EPIC] Phase N — <영문 요약>` 형식
- 하위 이슈 연결: GitHub 네이티브 sub-issue로 Epic에 연결하고, Epic 본문에도 task list를 둔다

---

## 3. 문서 작성 규칙

1. **머리말.** 제목 바로 아래에 상태 줄을 둔다.
   `> 상태: Draft | Proposed | Accepted | Superseded · 관련: ADR-000N, #이슈`
2. **언어.** 내부 문서는 한국어로 쓰고 기술 용어는 영문 그대로 둔다. 외부 기여자 접점(README, CONTRIBUTING, SECURITY, CODE_OF_CONDUCT, 템플릿)은 영어로 쓴다 (ADR-0005). `README.ko.md`는 `README.md`의 한국어판이다. 원본은 영어판이고, README를 고치는 PR에서 두 파일을 함께 고친다. 외부 기여자가 영어판만 고치면 메인테이너가 한국어판을 맞춘다.
3. **링크.** 저장소 안 문서는 상대 경로로 링크한다. 개인 홈 디렉터리 경로(`/Users/<이름>/...`)는 쓰지 않는다. 예시 경로는 `~/dev/...` 형태로 쓴다.
4. **다이어그램.** Mermaid 코드 블록을 쓴다. GitHub에서 바로 렌더링된다.
5. **결정.** 문서에서 새로운 결정을 내리면 ADR로 옮기고 링크한다. 문서 안에 결정 근거를 길게 쓰지 않는다.
6. **범위 밖.** 범위 밖 아이디어는 문서에 "later"로 적고 `later` 마일스톤 이슈로 등록한다.
