> **이 문서는 프로젝트 착수 시점의 원본 요구 사항(입력 문서)이다. 수정하지 않고 보관한다.**
>
> - 가칭 `WorktreeDeck`은 **Overgrove**로 확정되었다 ([ADR-0001](docs/adr/0001-product-name-overgrove.md)).
> - 확정된 기획·설계·결정은 [`docs/`](docs/README.md)가 우선한다. 이 문서와 `docs/`가 다르면 `docs/`를 따른다.
> - 착수 시 검토에서 바뀐 주요 사항: 1인 메인테이너 머지 정책([ADR-0012](docs/adr/0012-solo-maintainer-merge-policy.md)), Pull 제외([ADR-0011](docs/adr/0011-no-pull-in-v0-1.md)), 저장소 설정 무력화 범위 확대([ADR-0009](docs/adr/0009-repo-config-neutralization.md)), 그래프 레인 앱 내 계산([ADR-0010](docs/adr/0010-commit-graph-layout-in-app.md)), SwiftLint·SwiftFormat 대신 swift-format([ADR-0007](docs/adr/0007-swift-format-toolchain.md)).

---

# HANDOFF — WorktreeDeck (macOS Git Worktree Dashboard)

> 이 문서는 Claude Desktop 대화에서 Claude Code CLI로 작업을 넘기기 위한 핸드오프 문서입니다.
> 새 저장소 루트에 `HANDOFF.md`로 두고, 저장소 루트에서 `claude`를 실행한 뒤 "HANDOFF.md를 읽고 Phase 1부터 진행해줘"라고 요청하세요.

---

## 0. 개요 (먼저 읽을 것)

| 항목 | 내용 |
|---|---|
| 제품 | 맥 전용 네이티브 Git 클라이언트. 워크트리 중심의 조회 도구 |
| 기술 | SwiftUI, 시스템 `git` 호출, Xcode 프로젝트 |
| 공개 | 공개 오픈소스 저장소. 배포 바이너리 없음, 소스 빌드 방식 |
| 쓰기 작업 | 1차 범위에서는 fetch 외 원격 쓰기 없음 (push, PR 생성은 Claude Code 하네스에서 수행) |
| 추적 | GitHub Issues + Projects 보드 + Milestones (기업형 운영) |
| 개발 방식 | 기획 → 설계 → 개발 → 검증 → 릴리스. 각 Phase 종료 시 사용자 승인 |
| UI 참고 | GitKraken의 **레이아웃 패턴**을 참고 (사이드바 / 그래프 / 상세 3단 구조, WIP 행). 로고, 아이콘, 문구, 색상 등 브랜드 요소는 복제하지 않음 |

**지금 가장 중요한 것 세 가지**
1. 워크트리별 상태 조회 (변경 파일, 스테이징, stash, 미추적 파일, ahead/behind)
2. 보안 원칙 (읽기 전용 기본, 명령 인젝션과 악성 저장소 방어, 토큰 미보관)
3. GitHub 이슈 기반 추적 (이슈 없이 PR 없음)

---

## 1. 배경과 문제

- 기능 개발을 **Git 워크트리**로 병렬 진행하는 경우가 많다.
- GitKraken은 워크트리 가시성이 좋지만 조회와 쓰기가 섞여 있고, lazygit은 여러 워크트리를 한눈에 비교하기 어렵다.
- 목표: "어떤 워크트리에 무엇이 진행 중인지, 원격과 얼마나 차이 나는지, 아직 커밋하지 않은 것과 stash에 남은 것이 무엇인지, 누가 언제 바꿨는지"를 **한 화면에서 파악**하는 것.

---

## 2. 사용자 페르소나

- 1인 백엔드 개발자, 맥 사용자, 워크트리를 여러 개 동시 운영
- 터미널과 AI 에이전트 워크플로우에 익숙함
- Swift 숙련도는 낮음 → 코드는 AI가 주도, 구조와 결정은 사용자가 검토
- 한국어 선호, 기술 용어는 영문 그대로 사용

---

## 3. 목표와 비목표

### 목표 (Goals)
- **G1.** 저장소의 모든 워크트리를 목록으로 표시한다.
- **G2.** 워크트리별 브랜치, HEAD, 경로, 잠금(locked)·정리 필요(prunable) 상태를 표시한다.
- **G3.** 워크트리별 **Staged / Unstaged / Untracked / Conflicted** 파일 목록을 표시한다.
- **G4.** 저장소 전체의 **stash 목록**과 각 stash의 변경 요약을 표시한다.
- **G5.** 원격 대비 **ahead/behind**를 표시한다 (fetch 후 기준, 마지막 fetch 시각 함께 표시).
- **G6.** 커밋 그래프, 작성자, 날짜, 메시지를 표시한다. 상단에 **WIP 행**(미커밋 변경)을 둔다.
- **G7.** 커밋 상세(변경 파일, diff)와 파일별 이력을 표시한다.
- **G8.** GitHub 이슈 목록을 보고, 브랜치명 또는 커밋 메시지에서 이슈 번호를 연결해 보여준다. (인증은 `gh` CLI 위임)
- **G9.** 성능: 워크트리 10개, 커밋 10만 개 규모에서도 체감상 즉시 전환.
- **G10.** 소스를 클론한 뒤 Xcode에서 Run 한 번으로 실행 가능해야 한다.

### 비목표 (Non-goals)
- **N1.** Windows, Linux 지원
- **N2.** App Store 배포, 서명·공증된 바이너리 배포
- **N3.** push, PR 생성, 머지, 리뷰 작성 등 원격 쓰기 (하네스에서 수행)
- **N4.** 인터랙티브 리베이스, 드래그 앤 드롭 커밋 정리, 스테이징 체크 토글 (1차 범위 밖, `later`로 기록)
- **N5.** 자체 Git 엔진 구현. 반드시 시스템 `git`을 호출한다.
- **N6.** GitHub 이슈 **생성·수정** 기능 (1차는 조회만)
- **N7.** 자체 OAuth 서버, 토큰 직접 발급·저장

---

## 4. 기술 결정 (Architecture Decisions)

| 항목 | 결정 | 이유 |
|---|---|---|
| 플랫폼 | macOS 전용 | 사용자 요구, 네이티브 성능 |
| UI | SwiftUI (필요 시 AppKit 브릿지) | 맥 표준 뷰, 다크 모드 자동 지원 |
| 최소 macOS | 14 (Sonoma) 권장 | 최신 SwiftUI API |
| Git 접근 | `/usr/bin/git`을 `Process`로 호출, **인자 배열만 사용** (셸 미사용) | 인젝션 차단, 사용자 git 설정과 동일 동작 |
| GitHub 접근 | `gh` CLI 호출 (`gh issue list --json ...`) | 인증 토큰을 앱이 다루지 않음 |
| 출력 파싱 | `--porcelain=v2 -z`, 커스텀 `--format`, NUL 구분자 | 로케일과 출력 형식 변화에 강함 |
| 상태 관리 | `@Observable`, 단방향 데이터 흐름 | 단순하고 테스트 용이 |
| 샌드박스 | 끔 (개인·오픈소스 용도) | 임의 경로 저장소 접근 권한 팝업 회피. 대신 §6 보안 원칙으로 보완 |
| 프로젝트 형식 | Xcode 프로젝트 (`.xcodeproj`) | 공개 빌드 진입 장벽이 가장 낮음 |
| 테스트 | XCTest, 파서 단위 테스트 필수 + 임시 저장소 통합 테스트 | Git 출력 파싱이 핵심 리스크 |
| 의존성 | 외부 패키지 0개 목표 | 공급망 공격 면적 최소화 |
| 설정 저장 | `UserDefaults` (경로, 옵션만). **토큰·비밀 값은 저장하지 않음** | §6 참고 |

### 미정 사항 (Phase 1에서 확정)
- 프로젝트 이름 (가칭 `WorktreeDeck`)
- 라이선스 (권장: MIT)
- 최소 macOS 버전 (권장: 14)
- `gh` 연동 범위: 이슈 목록만 할지, PR 상태까지 할지 (권장: 이슈만)

---

## 5. GitHub 이슈 기반 운영 (필수)

이 프로젝트는 **모든 작업을 GitHub Issue로 추적**한다. 이슈 없는 PR은 머지하지 않는다.

### 5.1 이슈 템플릿 (`.github/ISSUE_TEMPLATE/`)
- `feature.yml`: 배경, 목표, 완료 조건(체크리스트), 관련 Phase
- `bug.yml`: 재현 절차, 기대 결과, 실제 결과, git 버전, macOS 버전, lazygit 등 비교 대상
- `spike.yml`: 조사 질문, 시간 상자(time-box), 결과 기록 위치
- `decision.yml`: ADR 후보. 결정 질문, 선택지, 결과는 `docs/adr/`에 기록하고 이슈에 링크
- `config.yml`: 보안 취약점은 이슈 대신 **Private vulnerability reporting**으로 유도

### 5.2 라벨 체계
- `type:feature`, `type:bug`, `type:spike`, `type:decision`, `type:docs`, `type:test`, `type:chore`
- `phase:plan`, `phase:design`, `phase:dev`, `phase:qa`, `phase:release`
- `area:git-core`, `area:parser`, `area:ui`, `area:github`, `area:security`, `area:ci`
- `priority:p0`, `priority:p1`, `priority:p2`
- `status:blocked`, `status:needs-decision`
- `good first issue`, `help wanted` (공개 기여 유도용)

### 5.3 마일스톤과 보드
- 마일스톤: `v0.1.0` (MVP), `v0.2.0` (보안·설정 강화), `later` (백로그 보관)
- Projects v2 보드 컬럼: `Backlog → Ready → In progress → In review → Done`
- 보드 필드: Phase, Area, Priority, Size(S/M/L)

### 5.4 Epic과 하위 이슈
- Phase별로 Epic 이슈를 만든다. 예: `[EPIC] Phase 3 — Git 레이어`
- Epic 본문에 하위 이슈를 task list로 연결하고, 하위 이슈마다 완료 조건을 둔다.

### 5.5 브랜치, 커밋, PR 규칙
- 브랜치명: `feat/<issue-number>-<slug>`, `fix/<issue-number>-<slug>`, `docs/<issue-number>-<slug>`
  예: `feat/12-worktree-list`
- 커밋 메시지: Conventional Commits, 본문 또는 제목 끝에 `(#12)` 포함
- PR 본문에 `Closes #12` 필수 (머지 시 자동 종료)
- PR 템플릿 체크리스트: 테스트 추가, 보안 영향 검토, 문서 갱신, 스크린샷(UI 변경 시)

### 5.6 Discussions
- 아이디어, 질문, 설계 논의는 Discussions에서 먼저 한다. 확정되면 이슈로 전환한다.

### 5.7 CLI에서의 이슈 운영
- 이슈 생성과 갱신은 `gh issue create`, `gh issue edit`, `gh project item-add`로 수행한다.
- 이슈 생성 전 `gh label list`와 `gh milestone list`로 기존 항목을 확인한다.
- 이슈 생성 전에 사용자에게 제목과 본문을 보여주고 승인을 받는다. 공개 저장소이므로 외부에 노출되는 내용을 신중히 다룬다.

---

## 6. 보안 설계

이 앱은 **로컬 저장소를 실행하는 도구**이므로, 악성 저장소와 명령 인젝션이 가장 큰 위협이다.

### 6.1 위협 모델
| 위협 | 설명 | 대응 |
|---|---|---|
| 악성 저장소 설정 실행 | 신뢰할 수 없는 저장소의 `.git/config`에 `core.fsmonitor`, `core.hooksPath`, `diff.<driver>.textconv` 등이 있으면 `git status`나 `diff`가 임의 명령을 실행할 수 있음 | 모든 호출에 `-c core.fsmonitor=false -c core.hooksPath=/dev/null`, diff는 `--no-ext-diff --no-textconv` |
| 명령 인젝션 | 브랜치명, 파일명, 경로가 명령 인자로 들어감 | 셸 미사용, 인자 배열만 사용, 사용자 입력 값은 `--` 뒤에 배치, `-`로 시작하는 ref 거부 |
| 자격 증명 노출 | 원격 URL에 `https://user:token@...` 형태가 섞여 있을 수 있음 | UI와 로그에 표시하기 전 URL의 자격 증명 부분을 마스킹 |
| 자격 증명 프롬프트 | 백그라운드 fetch가 인증 입력을 요구하며 멈춤 | `GIT_TERMINAL_PROMPT=0`, `GIT_ASKPASS` 비활성, 타임아웃 적용 |
| 의도치 않은 쓰기 | 조회 앱이 실수로 쓰기 명령을 실행 | 허용 명령 **allowlist** 타입(`ReadOnlyGitCommand`, `FetchCommand`)으로 컴파일 타임에 제한. push, reset, clean, checkout 등은 1차 범위에서 타입으로 만들지 않음 |
| 파일 시스템 범위 | 임의 경로 접근 | 사용자가 `NSOpenPanel`로 고른 경로만 등록, 등록된 저장소 목록은 명시적으로 관리 |
| 로그 유출 | 경로, 저장소 이름, 커밋 메시지가 로그에 남음 | 로그 기본 수준은 최소, 디버그 로그에도 자격 증명 마스킹 적용 |
| 공급망 | 의존성 탈취 | 외부 패키지 0개 목표, 추가 시 ADR 필요, Dependabot 활성 |
| 비밀 정보 커밋 | 공개 저장소에 토큰, 개인 경로 유출 | gitleaks pre-commit 훅, CI secret scan, `.gitignore`에 `*.xcconfig.local` 등 추가 |

### 6.2 Git 호출 규칙 (구현 필수)
- 모든 `git` 호출은 `GitClient` 한 곳을 거친다. 다른 곳에서 `Process`를 직접 만들지 않는다.
- 환경 변수: `LC_ALL=C`, `LANG=C`, `GIT_TERMINAL_PROMPT=0`, `GIT_OPTIONAL_LOCKS=0`
  - `GIT_OPTIONAL_LOCKS=0`은 조회 중 `index.lock`을 잡지 않게 하여 사용자의 다른 git 작업과 충돌을 피한다.
- 타임아웃: 기본 15초, fetch는 120초. 초과 시 프로세스를 종료하고 에러로 표시한다.
- 출력 크기 상한을 둔다 (예: 10MB). 초과 시 잘라서 표시한다.
- 실패 시 stderr를 그대로 노출하지 않고, 마스킹 후 요약해서 보여준다.

### 6.3 앱 자체 보안
- Hardened Runtime 활성화 (소스 빌드 사용자도 동일 설정 사용)
- 외부 네트워크 호출은 `gh`와 `git fetch`로 한정한다. 텔레메트리 없음.
- 앱이 여는 파일은 저장소 내부 파일로 한정한다. 심볼릭 링크는 저장소 밖을 가리키면 경고한다.
- 저장소 경로와 이름은 기본적으로 화면에만 표시하고 외부로 보내지 않는다.

### 6.4 저장소 보안 (GitHub)
- `main` 브랜치 보호: PR 필수, 필수 리뷰 1명 이상(본인 승인 불가), 필수 CI 통과, 강제 푸시 금지
- 기능 브랜치에서 서명된 커밋 권장 (SSH 또는 GPG 서명, 선택)
- Secret scanning, Push protection, Dependabot alerts 활성화
- CodeQL 워크플로우 추가 (Swift 지원 범위 확인 후)
- Private vulnerability reporting 활성화, `SECURITY.md`에 제보 절차와 지원 버전 명시

### 6.5 SECURITY.md에 포함할 내용
- 보안 취약점 제보 방법 (공개 이슈 금지)
- 앱이 신뢰하지 않는 저장소를 실행하는 특성과 위험 설명
- 지원 버전 정책

---

## 7. 인증 설계

### 7.1 원칙
- 앱은 **토큰을 직접 받거나 저장하지 않는다.**
- GitHub 인증은 사용자의 `gh` CLI 로그인 상태에 위임한다. 토큰은 `gh`가 macOS Keychain에 관리한다.
- git 원격 인증은 사용자의 기존 git 설정(credential helper, SSH 키)에 위임한다. 앱은 새 자격 증명을 만들지 않는다.

### 7.2 동작 흐름
1. 앱 시작 시 `gh auth status`로 로그인 여부를 확인한다.
2. 미로그인이면 온보딩 화면에 "터미널에서 `gh auth login`을 실행하세요" 안내를 표시한다. 앱이 직접 로그인 명령을 실행하지 않는다.
3. 로그인되어 있으면 이슈 패널이 활성화된다. 미로그인이어도 Git 조회 기능은 정상 동작해야 한다.
4. fetch 실패가 인증 문제인지 `stderr` 패턴으로 구분해 안내한다.

### 7.3 1차에서 하지 않는 것
- OAuth 앱 등록, 토큰 입력 UI, 토큰 Keychain 직접 저장
- 여러 GitHub 계정 전환 (`gh`의 호스트 설정을 따른다)

### 7.4 나중에 검토할 것 (`later`)
- GitHub App 방식 전환 (권한 범위를 좁히고 싶을 때)
- GitHub Enterprise 호스트 지원

---

## 8. 화면 설계 (GitKraken 레이아웃 패턴 참고)

### 8.1 참고 원칙
- **패턴만 차용**: 3단 구조(사이드바 / 중앙 그래프 / 우측 상세), 상단 툴바, 하단 상태바, WIP 행, 그래프 열.
- **복제하지 않음**: 로고, 아이콘 세트, 색상 팔레트, 문구, 고유 명칭. 모든 요소는 자체 디자인으로 만든다.
- 맥 표준 HIG를 따른다. 다크 모드와 시스템 액센트 컬러를 기본으로 한다.

### 8.2 메인 창 와이어프레임

```
┌───────────────────────────────────────────────────────────────────────────────────────────┐
│ [◉ WorktreeDeck ▾]  [⟳ Fetch]  [↓ Pull]   Branch: feat/12-worktree-list ▾   [🔍 Search ⌘F] [⚙] │
├──────────────────┬──────────────────────────────────────────┬──────────────────────────────┤
│ SIDEBAR          │ COMMIT GRAPH                              │ DETAIL                       │
│                  │                                           │                              │
│ ▾ WORKTREES (3)  │ ○  WIP  3 staged · 2 unstaged · 1 new     │ WIP — feat/12-worktree-list  │
│   ● main         │ │                                         │                              │
│   ● feat/12  ✎5  │ ◉  a1b2c3d  feat: add status parser  Ko 2h│ STAGED (3)                   │
│   ○ hotfix   ↑2  │ │                                         │   M  Parser.swift            │
│                  │ ◉  e4f5a6b  fix: edge case           Ko 1d│   A  GitClient.swift         │
│ ▾ LOCAL          │ ├─┐                                       │   D  Old.swift               │
│   main           │ │ ◉  9c8d7e6  docs: adr                Ko 3d│                              │
│   feat/12  ●     │ │                                         │ UNSTAGED (2)                 │
│                  │ ◉  0b1c2d3  chore: deps               Ko 4d│   M  Graph.swift             │
│ ▾ REMOTE         │                                           │   M  Sidebar.swift           │
│   origin/main    │                                           │                              │
│   origin/feat/12 │                                           │ UNTRACKED (1)                │
│                  │                                           │   ?  notes.md                │
│ ▾ STASHES (2)    │                                           │                              │
│   stash@{0} WIP  │                                           │ [ Diff ]  [ Files ]  [ Log ] │
│   stash@{1} exp  │                                           │                              │
│                  │                                           │                              │
│ ▾ ISSUES (GitHub)│                                           │                              │
│   #12 ● feat/12  │                                           │                              │
│   #15 ○ open     │                                           │                              │
├──────────────────┴──────────────────────────────────────────┴──────────────────────────────┤
│ Fetched 2m ago · origin ↑2 ↓0 · 3 worktrees · ⚠ 1 prunable · gh: @ko-login (logged in)    │
└───────────────────────────────────────────────────────────────────────────────────────────┘
```

**영역 설명**
- **상단 툴바**: 저장소 전환, fetch, pull(조회 후 실행 아님, 1차에서는 fetch만 활성화 권장), 현재 HEAD 브랜치, 검색
- **사이드바**: 워크트리, 로컬 브랜치, 원격 브랜치, stash, 이슈. 워크트리 행의 `✎5`는 변경 파일 수, `↑2`는 ahead 수
- **그래프 영역**: 맨 위 WIP 행이 미커밋 변경 요약을 보여준다. 선택한 워크트리의 WIP가 기본 표시된다.
- **상세 패널**: 선택한 항목의 상세. WIP 선택 시 Staged, Unstaged, Untracked를 구분해서 보여준다.
- **상태바**: 마지막 fetch 시각, ahead/behind 요약, 경고 개수, gh 로그인 상태

### 8.3 WIP와 stash 상세 와이어프레임

```
┌──────────────────────────────────────────────────────────────────────────┐
│ STASH  stash@{0}  "WIP on feat/12: 9c8d7e6 docs: adr"        3 days ago  │
├──────────────────────────────────────────────────────────────────────────┤
│ Base commit   9c8d7e6  docs: adr                                         │
│ Files changed (4)                                                        │
│   M  Sources/Parser.swift                 +42  −8                        │
│   M  Sources/Graph.swift                  +11  −3                        │
│   A  Sources/Untracked.swift              +20  −0    (stash -u)          │
│   M  README.md                             +2  −2                        │
│                                                                          │
│ [ View diff ]   [ Copy ref ]   (apply / pop / drop 은 1차 범위 외)        │
└──────────────────────────────────────────────────────────────────────────┘
```

### 8.4 워크트리 상세와 보안 상태 와이어프레임

```
┌──────────────────────────────────────────────────────────────────────────┐
│ WORKTREE  feat/12-worktree-list                                          │
├──────────────────────────────────────────────────────────────────────────┤
│ Path      ~/dev/worktrees/feat-12                                        │
│ HEAD      feat/12-worktree-list  (upstream: origin/feat/12 ↑2 ↓0)        │
│ State     ✎ 5 changed · 1 untracked · no conflicts · not locked          │
│ Last fetch  2 min ago   [ Fetch this repo ]                              │
│                                                                          │
│ SECURITY                                                                 │
│   Hooks disabled (core.hooksPath=/dev/null)            ✓                 │
│   fsmonitor disabled                                   ✓                 │
│   External diff / textconv disabled                    ✓                 │
│   Remote URL credentials masked                        ✓                 │
└──────────────────────────────────────────────────────────────────────────┘
```

### 8.5 온보딩과 설정 와이어프레임

```
┌──────────────────────────────────────────────────────────────────────────┐
│ Welcome to WorktreeDeck                                                  │
├──────────────────────────────────────────────────────────────────────────┤
│ 1. Add repository       [ Choose folder… ]     ✓ /path/to/repo           │
│ 2. git                  ✓ git 2.45.1 detected                            │
│ 3. GitHub (optional)    ✗ not logged in                                  │
│                         Run in Terminal:  gh auth login                  │
│                         [ Check again ]                                  │
│                                                                          │
│ Settings                                                                 │
│   [ ] Auto fetch every 10 min   (default: off)                           │
│   [ ] Show remote URLs          (default: masked)                        │
└──────────────────────────────────────────────────────────────────────────┘
```

### 8.6 키보드 단축키 (초안)
- `⌘R`: 새로고침, `⌘⇧F`: fetch
- `⌘1`~`⌘4`: 사이드바, 그래프, 상세, 이슈 패널 포커스
- `↑`/`↓`: 목록 이동, `⏎`: 상세 열기, `⎋`: 선택 해제
- `⌘F`: 검색 (커밋 메시지, 작성자, 브랜치, 이슈 번호)

---

## 9. 데이터 모델과 Git 명령 매핑

| 화면 정보 | 모델 | Git 명령 (인자 배열) |
|---|---|---|
| 워크트리 목록 | `Worktree` | `worktree list --porcelain -z` |
| 워크트리 상태, 변경 파일 | `WorkingState` | `status --porcelain=v2 -z --branch --untracked-files=all` |
| 스테이징/언스테이징 구분 | `FileChange` (XY 컬럼) | 위 명령의 XY 값 (`M.`=staged, `.M`=unstaged, `??`=untracked, `u`=unmerged) |
| ahead/behind | `UpstreamStatus` | `rev-list --left-right --count @{u}...HEAD` |
| stash 목록 | `Stash` | `stash list --format=%gd%x00%gs%x00%cr` |
| stash 변경 요약 | `StashDetail` | `stash show --numstat stash@{n}` |
| 커밋 그래프 | `CommitNode` | `log --all --graph --date-order -z --format=...` |
| 커밋 상세 | `CommitDetail` | `show --numstat --format=... <sha>` + `--no-ext-diff --no-textconv` |
| 파일 이력 | `FileHistory` | `log --follow --format=... -- <path>` |
| 브랜치 목록 | `Branch` | `for-each-ref --format=... refs/heads refs/remotes` |
| 이슈 목록 | `Issue` | `gh issue list --json number,title,state,labels,assignees,updatedAt` |

**미추적 파일 주의**: `--untracked-files=all`은 큰 저장소에서 느릴 수 있다. 워크트리 10개 기준 성능 측정 후 조정한다.

---

## 10. 개발 프로세스 (기업형 흐름)

모든 단계는 **이슈 → 문서 → 검토 → 구현 → 검증** 순서로 진행한다. 각 Phase 종료 시 산출물을 커밋하고 사용자 승인을 받는다.

### Phase 1 — 기획 (Product)
- Epic 이슈 `[EPIC] Phase 1 — 기획` 생성, 하위 이슈로 분할
- 산출물: `docs/prd.md`, `docs/scope-mvp.md`, `docs/glossary.md`, `docs/adr/0001-*.md` (미정 사항 4개)
- 라벨과 마일스톤, Projects 보드 설정
- 완료 조건: 사용자가 PRD와 MVP 범위, 보안 원칙(§6)과 인증 방식(§7)을 승인

### Phase 2 — 설계 (Design)
- 산출물: `docs/design/information-architecture.md`, `docs/design/screens.md`(§8 와이어프레임을 기준으로 상세화), `docs/design/interaction.md`, `docs/design/security-review.md`(위협 모델 확정), `docs/adr/`
- 와이어프레임을 SwiftUI 프리뷰용 목업 뷰로 옮길 수 있는지 검토
- 완료 조건: 화면 흐름, 데이터 흐름, 보안 체크리스트가 승인됨

### Phase 3 — 개발 (Engineering)
1. **골격**: Xcode 프로젝트, 폴더 구조, SwiftLint·SwiftFormat 설정, CI 빌드 워크플로우
2. **보안 기반**: `GitClient`(인자 배열 전용, 보안 설정 강제, 타임아웃, 출력 상한), 자격 증명 마스킹 유틸, allowlist 명령 타입
3. **파서와 모델**: worktree, status, stash, log, rev-list 파서 + 단위 테스트, 악성 입력 테스트(공백, 개행, 특수 문자 파일명)
4. **통합 테스트 픽스처**: 임시 저장소 생성 스크립트 (워크트리 3개, stash 2개, 미추적·스테이징·충돌 상태, 원격 2개)
5. **Git 조회 화면**: 워크트리 목록 → 상태 → 상세 → 그래프 → WIP 행 → stash
6. **동기화**: fetch 버튼, 진행 상태, 마지막 fetch 시각, 선택적 자동 fetch
7. **GitHub 이슈 패널**: `gh` 연동, 로그인 상태 확인, 이슈 목록, 브랜치 번호 매칭
8. **온보딩과 설정**: 저장소 추가, git과 gh 상태 점검
9. **성능 점검**: 큰 저장소 프로파일링, 병렬 조회 최적화, 결과 캐시
10. **보안 점검**: §6.1 위협 모델 항목별 테스트 작성

작업 규칙:
- 이슈 하나당 브랜치 하나, PR 하나. PR에는 `Closes #n` 필수.
- 파서 PR에는 테스트가 함께 있어야 한다.
- 보안 관련 변경 PR에는 `area:security` 라벨과 보안 체크리스트 확인을 추가한다.

### Phase 4 — 검증 (QA)
- 단위 테스트, 통합 테스트(실제 git으로 시나리오 재현), 보안 테스트(§6.1 항목별)
- 수동 체크리스트: `docs/qa/checklist.md`
- 성능 기준: 워크트리 10개 로딩 1초 이내 (목표치, Phase 1에서 확정)
- 버그는 `type:bug` 이슈로 등록하고 재현 테스트를 먼저 작성한다.

### Phase 5 — 릴리스 (Open Source)
- `README.md` (소개, 스크린샷, 요구 사항, 소스 빌드, 사용법, 보안 주의 사항)
- `CONTRIBUTING.md` (이슈 우선 규칙, 브랜치와 커밋 규칙, PR 체크리스트)
- `CHANGELOG.md` (Keep a Changelog 형식)
- `LICENSE`, `SECURITY.md`, `CODE_OF_CONDUCT.md`
- `.github/ISSUE_TEMPLATE/`, `.github/pull_request_template.md`, `.github/workflows/`
- `v0.1.0` 태그와 GitHub Release (소스 아카이브, 릴리스 노트)
- 서명·공증 바이너리는 제공하지 않음. README에 "소스에서 빌드" 안내

---

## 11. 저장소 구조 (초안)

```
WorktreeDeck/
├── HANDOFF.md
├── README.md
├── CONTRIBUTING.md
├── CHANGELOG.md
├── LICENSE
├── SECURITY.md
├── CODE_OF_CONDUCT.md
├── docs/
│   ├── prd.md
│   ├── scope-mvp.md
│   ├── glossary.md
│   ├── design/
│   │   ├── information-architecture.md
│   │   ├── screens.md
│   │   ├── interaction.md
│   │   └── security-review.md
│   ├── adr/
│   └── qa/
├── WorktreeDeck.xcodeproj
├── WorktreeDeck/
│   ├── App/            # 진입점, 전역 상태
│   ├── Git/            # GitClient, 명령 allowlist, 보안 설정, 에러
│   ├── GitHub/         # gh 래퍼, 로그인 상태, 이슈 모델
│   ├── Parsing/        # porcelain, stash, log 파서
│   ├── Models/
│   ├── Security/       # 자격 증명 마스킹, 경로 검증
│   ├── Features/       # Worktrees, Graph, Detail, Stash, Issues, Onboarding
│   └── Resources/
├── WorktreeDeckTests/
│   ├── Parsing/
│   ├── Security/
│   └── Integration/    # 임시 저장소 픽스처 기반
├── scripts/
│   └── make-fixture-repo.sh
└── .github/
    ├── ISSUE_TEMPLATE/
    ├── workflows/      # ci.yml, codeql.yml, secret-scan.yml
    ├── pull_request_template.md
    └── dependabot.yml
```

---

## 12. 첫 작업 지시 (Claude Code CLI용)

다음 순서로 진행해 주세요.

1. 이 `HANDOFF.md`를 읽고, 목표, 비목표, 보안 원칙, 인증 방식, 화면 구조를 요약해서 보여주세요. 불명확한 점을 함께 정리하세요.
2. **Phase 1**을 주도하세요. 먼저 `gh auth status`로 GitHub 연결을 확인하고, 연결되어 있으면 저장소에 라벨, 마일스톤, 이슈 템플릿, Epic 이슈를 만들기 전에 사용자에게 내용을 보여주고 승인을 받으세요.
3. 미정 사항 4개를 질문하고, 답을 받으면 PRD, MVP 범위, ADR을 작성하세요.
4. 기획 승인 후 **Phase 2**로 넘어가 설계 문서를 작성하세요. §8 와이어프레임을 기준으로 화면 명세를 확정하고 `docs/design/security-review.md`를 작성하세요.
5. 설계 승인 후 **Phase 3**을 이슈 단위로 진행하세요. 보안 기반(§6.2)과 파서 테스트를 기능 구현보다 먼저 완료하세요.
6. 각 Phase가 끝날 때마다 빌드, 테스트, 보안 체크리스트 결과를 보고하고 승인을 받으세요.

원칙:
- 결정 사항은 `docs/adr/`에 기록하고 관련 이슈에 링크하세요.
- 추측으로 구현하지 말고, 불명확하면 질문하세요.
- 공개 저장소이므로 토큰, 개인 경로, 내부 저장소 이름을 커밋, 이슈, PR에 넣지 마세요.
- 범위 밖 요청은 `later` 마일스톤 이슈로 등록하고 지금은 구현하지 마세요.
- GitKraken의 로고, 아이콘, 문구, 색상은 사용하지 마세요. 레이아웃 패턴만 참고하세요.

---

## 13. 리스크와 대응

| 리스크 | 대응 |
|---|---|
| Git 출력 형식 차이 (버전, 로케일) | `LC_ALL=C`, porcelain v2 고정, 파서 테스트, 지원 git 버전 명시 |
| 악성 저장소 설정으로 인한 코드 실행 | §6.2 보안 설정 강제, 보안 테스트 |
| 대형 저장소에서 느린 로딩 | 워크트리별 병렬 조회, 결과 캐시, 그래프 페이지네이션, untracked 조회 조정 |
| 워크트리가 삭제되거나 경로가 사라짐 | `prunable` 표시, 새로고침 시 재검사 |
| fetch 인증 프롬프트 | `GIT_TERMINAL_PROMPT=0`, 타임아웃, 인증 실패 안내 |
| `gh` 미설치 또는 미로그인 | Git 기능과 분리, 온보딩 안내, 이슈 패널만 비활성 |
| 이슈 중심 운영의 오버헤드 | 템플릿 간소화, 작은 작업은 `chore` 이슈로 빠르게 처리 |
| Swift 숙련도 부족 | 구조 문서화, 파서와 UI 분리, 테스트 우선 |
| 공개 저장소에 민감 정보 유출 | gitleaks, secret scanning, push protection, 리뷰 체크리스트 |

---

## 14. 완료 기준 (Definition of Done, v0.1.0)

- [ ] 저장소 등록 후 모든 워크트리가 목록에 표시된다
- [ ] 워크트리별 Staged, Unstaged, Untracked, Conflicted 파일이 정확하다
- [ ] 저장소 전체 stash 목록과 각 stash의 변경 요약이 표시된다
- [ ] ahead/behind가 fetch 후 정확하고, 마지막 fetch 시각이 표시된다
- [ ] 커밋 그래프, 작성자, 날짜, WIP 행이 표시된다
- [ ] gh 로그인 상태에 따라 이슈 패널이 동작하거나 안내를 표시한다
- [ ] §6.1 보안 위협 항목별 테스트가 통과한다
- [ ] 자격 증명과 원격 URL의 민감 부분이 화면과 로그에서 마스킹된다
- [ ] 파서 단위 테스트와 임시 저장소 통합 테스트가 CI에서 통과한다
- [ ] README만 보고 소스에서 빌드하고 실행할 수 있다
- [ ] 라이선스, 기여 가이드, 보안 문서, 이슈와 PR 템플릿이 포함되어 있다
- [ ] 모든 v0.1.0 작업이 마일스톤의 이슈로 추적되고 닫혀 있다
- [ ] `v0.1.0` 태그와 릴리스 노트가 준비되어 있다
