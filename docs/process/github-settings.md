# GitHub 저장소 설정

> 상태: Accepted · 관련: [ADR-0012](../adr/0012-solo-maintainer-merge-policy.md), [ADR-0016](../adr/0016-board-status-automation.md), [`scripts/github/`](../../scripts/github/)

저장소 설정은 **스크립트로 재현할 수 있게** 관리한다. 웹 UI에서 바꾼 설정은 스크립트와 이 문서에 반영한다.

## 1. 스크립트

| 스크립트 | 내용 | 필요 권한 |
|---|---|---|
| `scripts/github/apply-repo-settings.sh` | 기능, 머지 정책, 토픽, 보안 기능, Actions 제한, 마일스톤, 라벨, 룰셋 | 저장소 admin |
| `scripts/github/sync-labels.sh [--prune]` | `.github/labels.json` → 라벨 생성·갱신(·삭제) | repo |
| `scripts/github/setup-project.sh` | Projects v2 보드 생성, 필드, Status 옵션, 저장소 연결 | `project` scope (`gh auth refresh -s project`) |
| `scripts/github/board-sync.sh {issue <n>\|pr <n>\|dependents <n>\|reconcile} [--dry-run]` | 보드 Status를 이슈·PR·선점 상태에 맞춘다(ADR-0016). 워크플로우가 쓰고, 토큰이 없을 때는 메인테이너가 직접 돌린다 | `project` scope |
| `scripts/github/board-sync-rules.test.sh` | 보드 Status 규칙(`board-status.jq`)을 가짜 이슈로 검사한다. CI `build-test`에서도 돈다 | 없음(네트워크 안 씀) |

모든 스크립트는 여러 번 실행해도 결과가 같다(idempotent).

## 2. 적용되는 설정

### 기능과 머지

| 항목 | 값 |
|---|---|
| 공개 범위 | Public |
| Issues / Discussions / Projects | 켬 |
| Wiki | 끔 — 문서는 저장소 `docs/`에만 둔다 |
| 머지 방식 | squash만 허용. squash 제목은 PR 제목, 본문은 PR 본문 |
| 머지 후 브랜치 삭제 | 켬 |
| Auto-merge, Update branch 버튼 | 켬 |
| 토픽 | macos, swiftui, git, git-worktree, git-client, developer-tools |

### 룰셋 `main-protection` (기본 브랜치)

| 규칙 | 값 |
|---|---|
| 삭제 금지, 강제 푸시 금지, 선형 이력 | 켬 |
| PR 필수 | 켬. 필수 승인 0명(1인 메인테이너, ADR-0012) |
| 리뷰 스레드 전부 해결 | 켬 |
| 허용 머지 방식 | squash |
| 필수 상태 검사 | `gitleaks`, `pr-policy`, `build-test`. strict(최신 main 기준)는 끔(2026-11-08, PR이 몰려 머지가 한 줄로 밀리는 문제). 합친 뒤의 의미 충돌은 main의 `ci`가 잡는다. 릴리스 직전에는 다시 켠다 |
| 우회 권한(bypass) | 없음 |

### 보안

| 항목 | 값 |
|---|---|
| Secret scanning, Push protection | 켬 |
| Dependabot alerts, security updates | 켬 |
| Dependabot version updates | GitHub Actions만, 주 1회(`.github/dependabot.yml`) |
| Private vulnerability reporting | 켬 |
| CodeQL | advanced setup(`.github/workflows/codeql.yml`). `actions`는 모든 PR·main·주간에 돈다. `swift`는 main 푸시·주간·수동 실행만 돈다(#34). 필수 검사가 아니다(아래) |
| git 호환성 매트릭스 | `.github/workflows/git-compat.yml` ([ADR-0020](../adr/0020-git-compatibility-matrix-in-ci.md)). Apple Git, 러너의 Homebrew git, 공식 tarball(SHA-256 고정)로 빌드한 최소 지원 git으로 INT·SEC 테스트를 돈다. 주 1회, 수동 실행, git·실행·파서·보안 경로 PR. 필수 검사가 아니다 |

**CodeQL Swift를 필수 검사로 두지 않는 이유 (#34)**:
- Swift 분석은 macOS 러너에서 추적 빌드(`xcodebuild clean build`, build-mode `manual`)를 해야 한다. macOS 분은 Ubuntu의 약 10배로 계산되고, `build-test`와 같은 크기의 빌드가 PR마다 하나 더 생긴다.
- 그래서 PR에서는 돌리지 않는다. main에 들어간 뒤와 주 1회 분석하고, 결과는 Security › Code scanning에 쌓인다.
- 경고는 메인테이너가 확인해 이슈로 옮긴다. 필요하면 브랜치에서 `gh workflow run codeql.yml --ref <branch>`로 미리 돌릴 수 있다.

### Actions

| 항목 | 값 |
|---|---|
| 기본 `GITHUB_TOKEN` 권한 | read |
| Actions의 PR 승인 | 끔 |
| 허용 Actions | GitHub 소유 Actions만 |
| SHA 고정 강제 | 켬(지원되는 경우). 워크플로우는 모두 전체 SHA로 고정되어 있다 |
| 외부 기여자 워크플로우 실행 | 첫 기여자만 승인 필요(`first_time_contributors`, ADR-0013) |
| `build-test` 툴체인 | 러너 `macos-26`, 이미지에 있는 가장 최신 Xcode 26.x(`XCODE_MAJOR`). 올릴 때는 `ci.yml`의 두 값을 함께 바꾸는 PR을 연다. 실패하면 `.xcresult`와 로그를 7일 보관 아티팩트로 올린다 |

### 선점·의존성 자동화 (ADR-0013, ADR-0015)

| 워크플로우 | 트리거 | 권한 | 하는 일 |
|---|---|---|---|
| `issue-claim.yml` | 이슈 댓글 `/claim`, `/unclaim` | `issues: write` | 담당자 지정·해제, 동시 선점 2개 제한, 선점 불가 라벨 거부 |
| `claim-expiry.yml` | 30분마다, 수동 실행(dry-run 가능) | `issues: write` | PR 없이 5시간 지난 선점 해제, 담당자 없는 이슈에 PR 선착순 지정 (`scripts/github/claim-expiry.sh`) |
| `dependency-closed.yml` | 메인테이너가 이슈를 닫을 때 | `pull-requests: write` | 그 이슈에 의존하는 열린 PR에 댓글로 알림(완료면 main 합치기 안내, 완료가 아니면 메인테이너 결정 요청) |

### 보드 자동화 (ADR-0016)

| 워크플로우 | 트리거 | 권한 | 하는 일 |
|---|---|---|---|
| `board-sync.yml` | 이슈 이벤트(열림·닫힘·다시 열림·담당자·라벨·마일스톤·본문 수정), `pull_request_target`(열림·다시 열림·Ready·Draft 전환·닫힘), 수동 실행(전체 정리, dry-run 가능) | `contents: read` + `PROJECT_TOKEN` | 그 이슈(PR이면 브랜치 이름의 이슈)의 Status를 다시 계산한다. 닫힌 이슈면 그 이슈에 의존하던 이슈도 다시 계산한다. 메인테이너가 아닌 사람의 이벤트는 동시성 그룹 하나를 공유한다 |
| `issue-claim.yml` (마지막 단계) | `/claim`·`/unclaim` 처리 직후 | `PROJECT_TOKEN` | 그 이슈의 Status를 다시 계산한다 |
| `claim-expiry.yml` (마지막 단계) | 30분마다 | `PROJECT_TOKEN` | 보드 전체를 다시 맞춘다(`reconcile`) |

- 규칙은 [development-workflow.md §2.1](development-workflow.md#21-보드-자동화), 로직은 `scripts/github/board-sync.sh`에 있다.
- 선점 봇의 담당자 변경은 `GITHUB_TOKEN`으로 만든 이벤트라 `board-sync.yml`을 실행하지 않는다. 그래서 두 봇이 스크립트를 직접 부른다.
- `PROJECT_TOKEN`이 없으면 세 곳 모두 경고만 남기고 성공한다. 그동안은 메인테이너가 로컬에서 맞춘다.
  ```sh
  scripts/github/board-sync.sh reconcile --dry-run   # 바뀔 내용만 보기
  scripts/github/board-sync.sh reconcile             # 적용 (gh에 project scope 필요)
  ```
- `pull_request_target`에서도 기본 브랜치만 체크아웃하고 PR 코드는 실행하지 않는다. 이벤트에서는 이슈·PR 번호만 쓴다.

세 워크플로우는 PR 코드를 체크아웃하거나 실행하지 않는다. 댓글 본문은 `env`로만 받아 첫 단어를 고정 문자열과 비교한다. `dependency-closed.yml`은 PR·이슈 본문을 API로 읽어 이슈 번호만 뽑는다.

### 마일스톤

`v0.1.0`(#1), `v0.2.0`(#2), `later`(#3)

## 3. 웹 UI에서만 할 수 있는 일

API로 설정할 수 없어서 한 번은 직접 해야 한다.

1. **Projects 보드 뷰**: "Overgrove Roadmap" 프로젝트 → New view → Board → Group by **Status**. 열 순서는 Backlog → Ready → In progress → In review → Done.
2. **보드 자동화 토큰 `PROJECT_TOKEN`** (ADR-0016). 이것이 없으면 보드 Status가 자동으로 바뀌지 않는다.
   0. **권장: 전용 머신 계정.** 새 GitHub 계정(예: `overgrove-board-bot`)을 만들고, 보드 #4 → ⋯ → Settings → Manage access에서 그 계정을 **Write**로 초대한다. 아래 1~2단계를 그 계정으로 한다. 토큰이 새도 영향이 보드 #4로 한정되고, API 한도도 메인테이너 계정과 분리된다. 메인테이너 계정으로 만들면 메인테이너가 쓸 수 있는 모든 보드(조직 보드 포함)가 토큰의 범위가 된다.
   1. github.com → Settings → Developer settings → Personal access tokens → **Tokens (classic)** → Generate new token (classic)
   2. Note `overgrove board-sync`, Expiration 90일, scope는 **`project` 하나만** 고른다(`repo`, `workflow`는 고르지 않는다)
   3. 토큰을 등록한다. 값은 화면에 붙여 넣기만 하고 파일이나 채팅에 남기지 않는다.
      ```sh
      gh secret set PROJECT_TOKEN --repo kkdy21/overgrove   # 실행 후 토큰을 붙여 넣는다
      ```
   4. 확인: Actions → `board-sync` → Run workflow(dry-run 켬) → 로그 끝에 `checked N issue(s)`가 나오면 된다
   5. 만료 1주 전에 같은 방법으로 새 토큰을 만들어 덮어쓴다. 메인테이너의 `gh` 로그인 토큰을 넣지 않는다(권한이 너무 넓다)
3. **보드 내장 Workflows**: `board-sync`가 같은 일을 하므로 켜지 않아도 된다. 켠다면 "Item closed → Done"만 둔다. "Auto-add to project"는 PR까지 넣지 않도록 `is:issue`로 둔다.
4. **"Ready to claim" 뷰 필터**: `status:Ready no:assignee -label:"type:epic"`. Status 동기화가 잠시 늦어도 담당자가 있는 이슈는 뷰에서 빠진다.
5. **Discussions 카테고리**: 기본 카테고리를 그대로 쓴다([discussions.md](discussions.md)). 첫 공지글 하나를 Announcements에 고정(pin)한다.

## 4. 확인 방법

```sh
gh api repos/kkdy21/overgrove --jq '{visibility, has_wiki, has_discussions, allow_squash_merge, allow_merge_commit, allow_rebase_merge, delete_branch_on_merge, security_and_analysis}'
gh api repos/kkdy21/overgrove/rulesets --jq '.[] | {id, name, enforcement}'
gh api repos/kkdy21/overgrove/actions/permissions
gh label list --repo kkdy21/overgrove --limit 100
gh api repos/kkdy21/overgrove/milestones --jq '.[] | {number, title}'
```
