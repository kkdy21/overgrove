# GitHub 저장소 설정

> 상태: Accepted · 관련: [ADR-0012](../adr/0012-solo-maintainer-merge-policy.md), [`scripts/github/`](../../scripts/github/)

저장소 설정은 **스크립트로 재현할 수 있게** 관리한다. 웹 UI에서 바꾼 설정은 스크립트와 이 문서에 반영한다.

## 1. 스크립트

| 스크립트 | 내용 | 필요 권한 |
|---|---|---|
| `scripts/github/apply-repo-settings.sh` | 기능, 머지 정책, 토픽, 보안 기능, Actions 제한, 마일스톤, 라벨, 룰셋 | 저장소 admin |
| `scripts/github/sync-labels.sh [--prune]` | `.github/labels.json` → 라벨 생성·갱신(·삭제) | repo |
| `scripts/github/setup-project.sh` | Projects v2 보드 생성, 필드, Status 옵션, 저장소 연결 | `project` scope (`gh auth refresh -s project`) |

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
| 필수 상태 검사 | `gitleaks`, `pr-policy`, `build-test` (strict: 최신 main 기준) |
| 우회 권한(bypass) | 없음 |

### 보안

| 항목 | 값 |
|---|---|
| Secret scanning, Push protection | 켬 |
| Dependabot alerts, security updates | 켬 |
| Dependabot version updates | GitHub Actions만, 주 1회(`.github/dependabot.yml`) |
| Private vulnerability reporting | 켬 |
| CodeQL | advanced setup(`.github/workflows/codeql.yml`), 지금은 `actions` 언어만 |

### Actions

| 항목 | 값 |
|---|---|
| 기본 `GITHUB_TOKEN` 권한 | read |
| Actions의 PR 승인 | 끔 |
| 허용 Actions | GitHub 소유 Actions만 |
| SHA 고정 강제 | 켬(지원되는 경우). 워크플로우는 모두 전체 SHA로 고정되어 있다 |
| 외부 기여자 워크플로우 실행 | 첫 기여자만 승인 필요(`first_time_contributors`, ADR-0013) |
| `build-test` 툴체인 | 러너 `macos-26`, 이미지에 있는 가장 최신 Xcode 26.x(`XCODE_MAJOR`). 올릴 때는 `ci.yml`의 두 값을 함께 바꾸는 PR을 연다. 실패하면 `.xcresult`와 로그를 7일 보관 아티팩트로 올린다 |

### 선점·의존성 자동화 (ADR-0013, ADR-0014)

| 워크플로우 | 트리거 | 권한 | 하는 일 |
|---|---|---|---|
| `issue-claim.yml` | 이슈 댓글 `/claim`, `/unclaim` | `issues: write` | 담당자 지정·해제, 동시 선점 2개 제한, 선점 불가 라벨 거부 |
| `claim-expiry.yml` | 30분마다, 수동 실행(dry-run 가능) | `issues: write` | PR 없이 5시간 지난 선점 해제, 담당자 없는 이슈에 PR 선착순 지정 (`scripts/github/claim-expiry.sh`) |
| `dependency-closed.yml` | 메인테이너가 이슈를 닫을 때 | `pull-requests: write` | 그 이슈에 의존하는 열린 PR에 댓글로 알림(완료면 main 합치기 안내, 완료가 아니면 메인테이너 결정 요청) |

세 워크플로우는 PR 코드를 체크아웃하거나 실행하지 않는다. 댓글 본문은 `env`로만 받아 첫 단어를 고정 문자열과 비교한다. `dependency-closed.yml`은 PR·이슈 본문을 API로 읽어 이슈 번호만 뽑는다.

### 마일스톤

`v0.1.0`(#1), `v0.2.0`(#2), `later`(#3)

## 3. 웹 UI에서만 할 수 있는 일

API로 설정할 수 없어서 한 번은 직접 해야 한다.

1. **Projects 보드 뷰**: "Overgrove Roadmap" 프로젝트 → New view → Board → Group by **Status**. 열 순서는 Backlog → Ready → In progress → In review → Done.
2. **보드 자동화**: 프로젝트 → Workflows에서 아래 세 가지를 설정한다.
   - "Auto-add to project": 필터 `repo:kkdy21/overgrove is:issue,pr`
   - "Item closed" → Done
   - "Pull request merged" → Done
3. **Discussions 카테고리**: 기본 카테고리를 그대로 쓴다([discussions.md](discussions.md)). 첫 공지글 하나를 Announcements에 고정(pin)한다.

## 4. 확인 방법

```sh
gh api repos/kkdy21/overgrove --jq '{visibility, has_wiki, has_discussions, allow_squash_merge, allow_merge_commit, allow_rebase_merge, delete_branch_on_merge, security_and_analysis}'
gh api repos/kkdy21/overgrove/rulesets --jq '.[] | {id, name, enforcement}'
gh api repos/kkdy21/overgrove/actions/permissions
gh label list --repo kkdy21/overgrove --limit 100
gh api repos/kkdy21/overgrove/milestones --jq '.[] | {number, title}'
```
