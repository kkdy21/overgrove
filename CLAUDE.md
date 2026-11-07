# CLAUDE.md — Overgrove

Overgrove는 여러 Git 워크트리를 한 화면에서 내려다보는 **macOS 전용 SwiftUI Git 클라이언트**다. 1차 범위는 조회 전용이고, 원격 쓰기는 `git fetch` 하나뿐이다. 공개 저장소(`kkdy21/overgrove`)다.

## 0. 지금 상태

- Phase 1·2 게이트를 통과했고([phase-gates.md §4](docs/process/phase-gates.md)), **Phase 3(개발)이 진행 중이다.** 협업자 본격 모집 전에 로드맵을 정리하는 중이며, 하네스와 기여 절차는 이미 협업자 기준으로 동작한다.
- 실행·보안 기반이 들어와 있다:
  - Xcode 프로젝트, CI
  - `ProcessRunner`, `GitEnvironment`, `GitCommand`·`GitClient`, `RepoConfigInspector`
  - `CredentialMasker`, `PathValidator`, `GitError`
  - 모델, 설정·버전·gh 파서
- 이제 파서(worktree·status·stash·log·ref), GraphEngine, 픽스처 통합 테스트, 디자인 시스템이 열려 있다. 화면은 그다음이다([roadmap.md](docs/roadmap.md)의 순서). 화면 목업은 1차(#159)에 이어 패널 테마 재디자인(#166, [ADR-0014](docs/adr/0014-panel-theme-and-split-layout.md))까지 마쳤다. 모양의 기준은 [art-direction.md](docs/design/art-direction.md)다. 화면 착수 순서는 #164에서 정한다.
- 진행 상황은 GitHub 이슈, [보드](https://github.com/users/kkdy21/projects/4), 마일스톤이 기준이다. 선점 가능한 이슈는 보드의 "Ready to claim" 뷰에 있다.

## 0.1 "백로그 확인해서 진행해줘"

사용자가 이렇게(또는 "check the backlog and work on it", "할 거 찾아서 해줘") 말하면 **`/onboard` 스킬을 실행하고, 그 안의 단계를 PR이 Ready가 될 때까지 이어서 진행한다.** 순서는 이렇다.

1. 셋업 점검: gh 로그인, fork 원격, hooks, Xcode
2. 선점 가능한 이슈 추천 → **사용자가 고름**
3. `/claim`
4. `/issue-start`
5. 테스트 우선 구현
6. 첫 커밋 직후 `/pr-open --draft`
7. 완료 조건 충족
8. 전체 테스트·lint·보안 점검
9. PR Ready. 의존 이슈가 남아 있으면 Draft로 두고 무엇을 기다리는지 보고한다
10. 보고

중간에 멈추고 사용자에게 묻는 경우:
- 이슈를 고를 때
- 명세가 모호하거나 결정이 필요할 때
- 범위 밖 변경이 필요할 때
- 보안 영향 판단이 서지 않을 때
- 셋업에 사용자의 손(로그인, sudo)이 필요할 때
- 의존 이슈가 완료되지 않고 닫혔거나 의존이 순환할 때

**머지는 하지 않는다.** 머지는 메인테이너가 검수 후에 한다.

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

### 2.1 기반 코드 사용 규칙 (새 기능을 만들 때)

- **git 호출은 반드시 `GitClient`를 거친다.**
  - 명령이 필요하면 `ReadOnlyGitCommand`에 case를 추가하고, 카탈로그와 스냅샷 테스트(SEC-T9-01)를 함께 고친다.
  - `GitClient.run`에는 `RepoConfigInspector.inspect(...).safetyContext`로 만든 `RepoSafetyContext`를 넘긴다. 검사 전에는 `version`, `probeRepository`, `configList`만 실행된다.
- **gh 호출**은 GHClient(#80) 이후 그것을 거친다. 그 전에는 gh를 직접 실행하지 않는다.
- **파서**는 `Data`를 받아 실패 시 `ParseError`를 던진다. 화면에는 `GitError`(`message`, `detail`)만 쓴다.
- **stderr와 원격 URL**은 `MaskedText` 또는 `CredentialMasker`를 거친 값만 화면·로그에 쓴다.
- **파일 내용을 읽을 경로**는 `PathValidator`로 검증한다(미리보기는 `WorktreeFile`만).
- **테스트**:
  - 실제 git이 필요하면 `GitTestRepository`(임시 저장소)나 `FixtureRepo`(`scripts/make-fixture-repo.sh`, `--malicious` 포함)를 쓴다.
  - 시간에 의존하는 테스트는 준비가 끝난 뒤에 신호를 보내 경쟁을 피하고, `-test-iterations`로 불안정성을 확인한다.
  - 실제 git 출력은 채집해 픽스처로 쓴다.

## 3. 절대 규칙 — 공개 저장소

- 커밋, 이슈, PR, 코멘트에 **토큰, 개인 경로(`/Users/<이름>/…`), 내부 저장소 이름, 개인 정보**를 넣지 않는다. 예시 경로는 `~/dev/...`로 쓴다.
- 이슈, PR, 코멘트, Discussion, 릴리스처럼 **공개 저장소에 글을 쓰는 작업은 내용을 먼저 보여주고 승인을 받는다.**
- `--no-verify`, 강제 푸시, `main` 직접 커밋·푸시, 저장소 공개 범위 변경, 저장소 삭제는 하지 않는다. hook이 막는다.

## 4. 이슈 기반 작업 흐름

### 4.0 역할을 먼저 확인한다

`gh api repos/kkdy21/overgrove --jq .permissions.admin`
- `true`면 **메인테이너**다. `origin`이 이 저장소이고, 머지와 AI 검수(`/pr-review`)를 맡는다.
- 그 밖에는 **협업자**다. `origin`이 fork, `upstream`이 이 저장소다. 처음이면 `/onboard`부터 시작한다.

협업자 규칙([collaboration.md](docs/process/collaboration.md), ADR-0013, ADR-0015):
- 작업 전에 이슈에 `/claim` 댓글을 단다(봇이 담당자 지정).
- **5시간 안에 `Closes #n` Draft PR을 연다.** 열지 않으면 선점이 자동으로 풀린다. 그래서 첫 커밋 직후 `/pr-open --draft`를 실행한다.
- 동시에 최대 2개까지만 선점한다. 그만둘 때는 `/unclaim`.
- 남이 선점한 이슈는 건드리지 않는다. 담당자 없는 이슈는 먼저 열린 PR이 이긴다(`pr-policy`가 강제).
- **의존 이슈가 안 끝났어도 기다리지 않는다**(ADR-0015). 필요한 부분은 `STAND-IN(#<n>)` 주석을 단 stand-in으로 직접 만든다. 남의 미머지 PR은 merge하거나 체크아웃하지 않는다. PR은 내 이슈만 닫고, 의존 이슈가 끝날 때까지 Draft로 둔다. 상세는 [collaboration.md §4.1](docs/process/collaboration.md#41-의존-이슈가-아직-끝나지-않았을-때).
- `upstream`에 push하지 않는다. rebase와 강제 푸시도 하지 않는다. 최신화는 `gh pr update-branch` 또는 `git merge upstream/main`으로 한다.

메인테이너 세션 규칙([development-workflow.md §5.1](docs/process/development-workflow.md#51-같은-계정으로-여러-세션을-돌릴-때)):
- 같은 계정으로 여러 세션을 돌리면 **세션마다 워크트리를 따로** 쓰고, 담당자 없는 이슈만 골라 **즉시 담당자를 지정**한다.
- 담당자가 나인 이슈라도 그 이슈의 원격 브랜치, 열린 PR, 워크트리가 이미 있으면 다른 세션의 작업이다. 멈추고 묻는다.
- 보드 Status는 사람이 옮기지 않는다. 담당자, PR, 닫힘에 따라 `board-sync`가 맞춘다(ADR-0016). 의존성이 없는 Backlog 이슈를 Ready로 올리는 트리아지만 손으로 한다.

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
scripts/lint/check-no-dependencies.sh                    # 외부 의존성(SPM·CocoaPods·Carthage) 없음 검사
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
