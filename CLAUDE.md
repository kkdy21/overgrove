# CLAUDE.md — Overgrove

Overgrove는 여러 Git 워크트리를 한 화면에서 내려다보는 **macOS 전용 SwiftUI Git 클라이언트**다. 1차 범위는 조회 전용이고, 원격 쓰기는 `git fetch` 하나뿐이다. 공개 저장소(`kkdy21/overgrove`)다.

## 0. 지금 상태

- Phase 1(기획)과 Phase 2(설계) 게이트를 통과했다(2026-11-05, [phase-gates.md §4](docs/process/phase-gates.md)). **Phase 3(개발)이 진행 중이고 협업자가 참여할 수 있다.**
- 앱 코드와 Xcode 프로젝트는 아직 없다. 첫 작업은 Project skeleton Epic(#3)의 Xcode 프로젝트 생성이다. 보안 기반과 파서 테스트를 화면 기능보다 먼저 한다([roadmap.md](docs/roadmap.md)의 순서).
- 진행 상황은 GitHub 이슈, [보드](https://github.com/users/kkdy21/projects/4), 마일스톤이 기준이다. 선점 가능한 이슈는 보드의 "Ready to claim" 뷰에 있다.

## 1. 작업 전에 읽을 것

1. [`docs/README.md`](docs/README.md) — 문서 지도와 **공통 식별자**(이름, 폴더, 모델, 위협 ID, 테스트 ID, 라벨). 새 이름을 만들기 전에 반드시 확인한다.
2. 작업과 관련된 명세: [`docs/architecture/`](docs/architecture/), [`docs/design/`](docs/design/), [`docs/adr/`](docs/adr/)
3. 보안이 걸린 작업이면 [`docs/design/security-review.md`](docs/design/security-review.md)

[`HANDOFF.md`](HANDOFF.md)는 착수 시점의 원본이다. 수정하지 않는다. `docs/`와 다르면 `docs/`를 따른다.

## 2. 절대 규칙 — 보안

이 앱은 신뢰할 수 없는 저장소에 대해 `git`을 실행한다. 아래는 예외 없이 지킨다.

1. **프로세스 생성은 `Overgrove/Execution/`에서만 한다.** `Process`, `NSTask`, `posix_spawn`, `popen`, `system()`, `/bin/sh`는 다른 곳에서 쓰지 않는다. 예외는 픽스처 실행용 `OvergroveTests/Support/` 하나뿐이다. hook과 CI가 이를 막는다.
2. **셸을 쓰지 않는다.** 인자는 배열로만 넘긴다. 사용자나 저장소에서 온 값(경로, ref, 파일명)은 `--` 뒤에 둔다. `-`로 시작하는 ref는 거부한다.
3. **명령은 allowlist 타입(`ReadOnlyGitCommand`, `FetchCommand`, gh allowlist)으로만 만든다.**
   - 새 git 명령이 필요하면 [`docs/architecture/git-command-catalog.md`](docs/architecture/git-command-catalog.md)를 먼저 고친다.
   - push, pull, reset, clean, checkout, commit, stash apply/pop/drop 같은 쓰기 명령은 타입으로 만들지 않는다.
4. **공통 보안 인자와 환경 변수 allowlist를 우회하지 않는다.** 대표적인 것은 `-c core.fsmonitor=false`, `-c core.hooksPath=/dev/null`, `--no-ext-diff --no-textconv`, `RepoConfigInspector`의 무력화 인자다. 전체 목록은 [`security-review.md` §3](docs/design/security-review.md)에 있다. `-c`로 무력화되지 않는 키도 있다(`uploadpack`, `gitProxy`, `sshCommand`, `askPass`는 인자·환경 변수로 막는다). 부모 환경 변수를 상속하지 않는다.
5. **토큰을 받거나 저장하거나 기록하지 않는다.**
   - GitHub 인증은 `gh`, git 인증은 사용자의 credential helper나 SSH에 맡긴다.
   - 원격 URL과 stderr는 마스킹한 뒤에만 화면이나 로그에 쓴다.
6. **외부 의존성을 추가하지 않는다.** Swift 패키지, 바이너리, 서드파티 GitHub Action 모두 해당한다. 꼭 필요하면 ADR을 먼저 쓴다.
7. GitHub Actions는 **전체 커밋 SHA로 고정**하고 `permissions:`는 최소로 둔다. PR 제목·본문 같은 신뢰할 수 없는 값은 `env:`로만 넘긴다.

## 3. 절대 규칙 — 공개 저장소

- 커밋, 이슈, PR, 코멘트에 **토큰, 개인 경로(`/Users/<이름>/…`), 내부 저장소 이름, 개인 정보**를 넣지 않는다. 예시 경로는 `~/dev/...`로 쓴다.
- 이슈, PR, 코멘트, Discussion, 릴리스처럼 **공개 저장소에 글을 쓰는 작업은 내용을 먼저 보여주고 승인을 받는다.**
- `--no-verify`, 강제 푸시, `main` 직접 커밋·푸시, 저장소 공개 범위 변경, 저장소 삭제는 하지 않는다. hook이 막는다.

## 4. 이슈 기반 작업 흐름

### 4.0 역할을 먼저 확인한다

`gh api repos/kkdy21/overgrove --jq .permissions.admin`
- `true`면 **메인테이너**다. `origin`이 이 저장소이고, 머지와 AI 검수(`/pr-review`)를 맡는다.
- 그 밖에는 **협업자**다. `origin`이 fork, `upstream`이 이 저장소다. 처음이면 `/onboard`부터 시작한다.

협업자 규칙([collaboration.md](docs/process/collaboration.md), ADR-0013):
- 작업 전에 이슈에 `/claim` 댓글을 단다(봇이 담당자 지정).
- **5시간 안에 `Closes #n` Draft PR을 연다.** 열지 않으면 선점이 자동으로 풀린다. 그래서 첫 커밋 직후 `/pr-open --draft`를 실행한다.
- 동시에 최대 2개까지만 선점한다. 그만둘 때는 `/unclaim`.
- 남이 선점한 이슈는 건드리지 않는다. 담당자 없는 이슈는 먼저 열린 PR이 이긴다(`pr-policy`가 강제).
- `upstream`에 push하지 않는다. rebase와 강제 푸시도 하지 않는다. 최신화는 `gh pr update-branch` 또는 `git merge upstream/main`으로 한다.

### 4.1 흐름

**이슈 없이 작업을 시작하지 않는다.** 흐름의 상세는 [`docs/process/development-workflow.md`](docs/process/development-workflow.md)에 있다.

| 단계 | 할 일 | 도구 |
|---|---|---|
| 1. 이슈 | 기존 이슈를 찾거나, 템플릿 형식으로 초안을 만들어 승인받고 생성한다 | `/issue-new`, `/issue-triage` |
| 2. 시작 | 선점을 확인하고(협업자는 `/claim`) `<type>/<issue>-<slug>` 브랜치나 워크트리를 만든다 | `/onboard`, `/issue-start` |
| 3. 구현 | 명세 → 테스트 → 구현 순서. 파서 변경은 테스트와 함께 | — |
| 4. 커밋 | Conventional Commits, 영어 제목. hook이 `Refs: #n`을 붙인다 | — |
| 5. PR | 자체 점검 후 PR을 연다(협업자는 fork에서, 선점 유지용 Draft 먼저). 본문에 `Closes #n` 필수 | `/pr-open` |
| 5a. 검수·머지 | (메인테이너) AI 검수 후 확인을 받아 squash 머지 | `/pr-review` |
| 6. 리뷰 | 보안 영향이 있으면 `security-reviewer` 에이전트로 먼저 검토한다 | agents |
| 7. 결정 | 새 결정은 ADR로 남기고 이슈에 링크한다 | `/adr-new` |
| 8. Phase 종료 | 빌드, 테스트, 보안 체크리스트 결과를 보고하고 승인받는다 | `/phase-gate` |

- **한 이슈 = 한 브랜치 = 한 PR.** 하다가 범위 밖 아이디어가 생기면 구현하지 않고 `later` 이슈 초안을 만든다.
- Discussion에서 결론이 나면 `/discussion-to-issue`로 이슈나 ADR로 옮긴다.
- 추측으로 구현하지 않는다. 명세가 모호하면 질문하거나 `type:decision` 이슈를 제안한다.

## 5. 언어와 문서

- 사용자와의 대화, 내부 문서(`docs/`, ADR, 이 파일)는 한국어로 쓴다. 기술 용어는 영문 그대로 둔다.
- README, CONTRIBUTING, SECURITY, 템플릿은 영어로 쓴다.
- 이슈·PR **제목은 영어**(Conventional 형식), 본문은 한국어 또는 영어로 쓴다. ([ADR-0005](docs/adr/0005-documentation-language.md))
- 문서 머리말·링크·다이어그램 규칙은 [`docs/README.md` §3](docs/README.md)을 따른다.

## 6. 명령 모음

```sh
./scripts/bootstrap.sh                                   # hooks 설치 + 도구 점검 (최초 1회)
scripts/make-fixture-repo.sh <dir>                       # 통합 테스트용 픽스처 저장소
scripts/make-fixture-repo.sh --malicious <dir>           # 보안 테스트용 악성 설정 픽스처 (무해한 canary)
scripts/make-bench-repo.sh <dir>                         # 성능 측정용 대형 저장소
scripts/measure-git-baseline.sh <bench-dir>              # git 계층 기준 성능 측정
scripts/lint/check-forbidden-apis.sh                     # 프로세스 API 사용 위치 검사
gitleaks git --no-banner --redact -v .                   # 비밀 정보 검사 (전체 이력)
swift format lint --strict --recursive --configuration .swift-format Overgrove OvergroveTests
# Phase 3 이후
xcodebuild test -project Overgrove.xcodeproj -scheme Overgrove -destination 'platform=macOS'
```

## 7. 하네스 구성

상세는 [`docs/process/claude-code-harness.md`](docs/process/claude-code-harness.md)에 있다.

- **Skills** (`.claude/skills/`): `onboard`, `issue-new`, `issue-triage`, `issue-start`, `pr-open`, `pr-review`, `adr-new`, `phase-gate`, `discussion-to-issue`
- **Agents** (`.claude/agents/`):
  - `security-reviewer`: 위협 모델 T1–T18 기준 검토
  - `scope-guard`: 범위·비목표·ADR 위반 검토
  - `parser-test-designer`: 적대적 파서 테스트 설계
- **Hooks** (`.claude/hooks/`):
  - `guard-bash.sh`: 위험한 git·gh 명령 차단
  - `guard-edit.sh`: 프로세스 API 위치, 비밀 정보·개인 경로, 미고정 Action, HANDOFF 수정 차단
  - `session-context.sh`: 현재 브랜치와 이슈 컨텍스트 표시
