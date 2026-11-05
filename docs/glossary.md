# 용어집

> 상태: Accepted (Phase 1 게이트, 2026-11-05) · 관련: [prd.md](prd.md), [architecture/parsing-spec.md](architecture/parsing-spec.md)

문서와 UI에서 같은 뜻의 말을 같은 이름으로 쓰기 위한 목록이다. UI 문구(영어)는 [design/screens.md](design/screens.md)를 따른다.

## Git 개념

| 용어 | UI 표기 | 정의 |
|---|---|---|
| 저장소 (repository) | Repository | 사용자가 등록한 Git 저장소. 공통 디렉터리(`git-common-dir`) 하나와 워크트리 여러 개를 가진다 |
| 공통 디렉터리 (common dir) | — | 모든 워크트리가 공유하는 `.git` 디렉터리. 객체, ref, 설정이 있다 |
| 워크트리 (worktree) | Worktree | 저장소에 연결된 작업 디렉터리. 각자 HEAD와 index를 가진다 |
| 메인 워크트리 (main worktree) | main | `worktree list`의 첫 항목. 저장소를 처음 만든 디렉터리 |
| 연결 워크트리 (linked worktree) | — | `git worktree add`로 만든 추가 워크트리. 그 안의 `.git`은 파일이며 공통 디렉터리의 `worktrees/<name>`을 가리킨다 |
| locked | Locked | `git worktree lock`으로 잠긴 워크트리. 이동식 디스크처럼 자주 사라지는 경로가 prune되지 않게 막는다. 이유 문자열을 가질 수 있다 |
| prunable | Prunable | 경로가 사라지는 등의 이유로 `git worktree prune` 대상이 된 워크트리. 앱은 표시만 하고 prune하지 않는다 |
| detached HEAD | Detached | 브랜치가 아니라 커밋을 직접 가리키는 HEAD |
| unborn 브랜치 | — | 커밋이 아직 없는 브랜치. status 헤더는 `branch.oid (initial)` |
| bare 저장소 | Bare | 작업 트리가 없는 저장소 |
| HEAD | HEAD | 워크트리가 현재 가리키는 커밋 또는 브랜치 |
| index (스테이징 영역) | — | 다음 커밋에 들어갈 내용 |
| Staged | Staged | index와 HEAD가 다른 변경 (porcelain v2 XY의 X) |
| Unstaged | Unstaged | 작업 트리와 index가 다른 변경 (XY의 Y) |
| Untracked | Untracked | Git이 추적하지 않는 새 파일 (`?` 레코드) |
| Conflicted | Conflicted | 병합 충돌 상태 파일 (`u` 레코드, XY가 `UU`, `AA` 등) |
| WIP | WIP | 아직 커밋하지 않은 변경 전체 (Staged + Unstaged + Untracked + Conflicted) |
| WIP 행 | WIP row | 그래프 맨 위에 두는 가상 행. 선택한 워크트리의 미커밋 변경을 요약한다 |
| stash | Stash | `git stash`로 임시 보관한 변경. `stash@{n}`으로 표시하지만 내부적으로는 OID로 가리킨다 |
| upstream | Upstream | 로컬 브랜치가 추적하는 원격 브랜치 (예: `origin/main`) |
| ahead / behind | ↑ / ↓ | 로컬 브랜치에만 있는 커밋 수 / upstream에만 있는 커밋 수. 마지막 fetch 시점 기준 |
| upstream gone | Gone | upstream이 설정되어 있지만 원격 추적 ref가 사라진 상태 |
| fetch | Fetch | 원격의 객체와 ref를 받아 원격 추적 ref를 갱신하는 동작. 앱이 하는 유일한 원격 동작 |
| 원격 추적 ref | Remote branch | `refs/remotes/<remote>/<branch>` |
| OID (object ID) | SHA | 객체 해시. SHA-1이면 40자리, SHA-256이면 64자리 hex |
| 전체 ref 이름 | — | `refs/heads/main`처럼 `refs/`로 시작하는 이름. 앱은 git 인자로 이 형태만 쓴다 |
| 서브모듈 | Submodule | 다른 저장소를 커밋 단위로 포함하는 항목 (gitlink) |

## Git 출력·호출

| 용어 | 정의 |
|---|---|
| porcelain v2 | `git status --porcelain=v2`의 기계용 출력 형식. 버전 간 안정성이 보장된다 |
| XY | porcelain 레코드의 두 글자 상태. X는 index, Y는 작업 트리. `.`은 변경 없음 |
| `-z` | 출력 레코드를 NUL로 끝내는 옵션. 경로에 공백·개행이 있어도 안전하다 |
| pathspec 매직 | `:(exclude)`, glob 같은 특수 경로 문법. 앱은 `--literal-pathspecs`로 끈다 |
| scope (설정) | git 설정의 출처. `system`, `global`, `local`, `worktree`, `command`, `unknown`(Apple 내장) |
| 신뢰 scope | 앱이 신뢰하는 설정 출처. `system`, `global`, `unknown`, `command` |
| 공통 보안 인자 | 모든 git 호출 앞에 붙이는 고정 인자 목록 ([security-review.md §3.1](design/security-review.md)) |
| 무력화 인자 | `RepoConfigInspector`가 저장소 설정을 보고 동적으로 만드는 `-c` 인자 |
| fail closed | 보안 검사가 실패하면 실행하지 않는 원칙 |
| canary | 보안 테스트에서 실행 여부를 판정하려고 악성 설정이 만들게 해 둔 무해한 파일 |

## 앱 구조

| 용어 | 정의 |
|---|---|
| allowlist 명령 타입 | `ReadOnlyGitCommand`, `FetchCommand`, gh 명령 열거형. 여기에 없는 명령은 실행할 수 없다 |
| ProcessRunner | 앱에서 프로세스를 만드는 유일한 타입 (`Overgrove/Execution/`) |
| RepoConfigInspector | 저장소 설정을 읽어 위험한 키를 탐지하고 무력화 인자를 만드는 타입 |
| GraphEngine | 커밋 순서와 부모 목록으로 그래프 레인을 계산하는 순수 로직 |
| 레인 (lane) | 커밋 그래프의 세로 열 하나. 색은 레인이 처음 생길 때의 열 인덱스 mod 8로 고정한다 |
| Store | `@Observable` 상태 객체. 뷰는 Store를 읽고 의도만 보낸다 |
| 세대 번호 (generation) | 오래된 응답이 새 상태를 덮어쓰지 않게 요청마다 붙이는 번호 |
| 픽스처 저장소 | 테스트용으로 스크립트가 만드는 임시 저장소 (`scripts/make-fixture-repo.sh`) |
| 벤치 저장소 | 성능 측정용 대형 저장소 (`scripts/make-bench-repo.sh`) |
| PB-n | 성능 예산 항목 ID |
| T-n | 위협 ID |

## 프로젝트 운영

| 용어 | 정의 |
|---|---|
| Phase | 기획 → 설계 → 개발 → 검증 → 릴리스의 다섯 단계. 끝날 때마다 메인테이너 승인을 받는다 |
| Phase 게이트 | Phase 종료 시 빌드, 테스트, 보안 체크리스트 결과를 보고하고 승인받는 절차 |
| Epic | Phase나 기능 묶음 단위의 상위 이슈. 하위 이슈를 sub-issue와 task list로 연결한다 |
| ADR | Architecture Decision Record. `docs/adr/` |
| 하네스 | Claude Code 작업 환경 구성 (CLAUDE.md, skills, agents, hooks) |
| later | 범위 밖 아이디어를 보관하는 마일스톤 |
