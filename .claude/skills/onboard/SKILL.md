---
name: onboard
description: Overgrove 협업자의 시작점. "백로그 확인해서 진행해줘", "check the backlog and work on it", "할 거 찾아서 해줘", "기여 시작", "온보딩"이라고 하면 사용한다. 셋업(gh 로그인·fork 원격·hooks·Xcode)을 점검하고, 선점 가능한 이슈를 추천해 사용자가 고르면 /claim으로 선점한 뒤, 브랜치 생성·테스트 우선 구현·Draft PR·Ready PR까지 끝까지 이어서 진행한다. 머지는 하지 않는다.
---

# onboard — 백로그에서 PR까지

기준 문서: `CLAUDE.md`(특히 §0.1, §2.1), `docs/process/collaboration.md`(의존 이슈는 §4.1), ADR-0013, ADR-0015

## 0. 위치 확인
- `git rev-parse --show-toplevel`과 `git remote -v`를 확인한다.
- 이 저장소의 클론이 아니면 안내만 하고 멈춘다. 스킬은 저장소 안에서만 보인다.
  ```
  gh repo fork kkdy21/overgrove --clone --remote && cd overgrove && claude
  ```

## 1. 셋업 점검 — 사용자의 손이 필요한 것만 요청한다
| 항목 | 확인 | 안 되어 있으면 |
|---|---|---|
| gh 로그인 | `gh auth status` | 사용자에게 `! gh auth login -h github.com -w`(브라우저 인증)를 실행해 달라고 한다. 안 되면 별도 터미널에서 실행 |
| 역할 | `gh api repos/kkdy21/overgrove --jq .permissions.admin` | `true`면 메인테이너다. 이 스킬 대신 `/issue-start`를 쓴다 |
| 원격 | `origin`이 내 fork, `upstream`이 `kkdy21/overgrove` | `gh repo fork --remote --remote-name origin`. 기존 origin은 upstream이 된다 |
| hooks·도구 | `./scripts/bootstrap.sh` | ✗ 항목을 안내한다(gitleaks 등) |
| Xcode | `xcode-select -p`가 `Xcode.app`을 가리키는지, `xcodebuild -checkFirstLaunchStatus`의 종료 코드가 0인지 | 사용자에게 **별도 터미널에서** 실행을 요청한다(sudo 비밀번호가 필요해 대신 실행하지 않는다). 아래 순서를 지켜야 앞 명령이 실패하지 않는다 |
| 빌드 | `xcodebuild test -project Overgrove.xcodeproj -scheme Overgrove -destination 'platform=macOS'` 1회 | 실패하면 원인을 보고하고 멈춘다 |

Xcode 셋업 명령(순서 중요):
```
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept
sudo xcodebuild -runFirstLaunch
```

## 2. 이슈 고르기 — 사용자가 고른다

### 2.0 기다리던 내 PR부터
```sh
gh pr list --repo kkdy21/overgrove --author @me --state open --json number,title,isDraft,headRefName,body
```
- Draft PR마다 의존 이슈가 모두 완료로 닫혔는지 확인한다(`gh issue view <d> --json state,stateReason`). 의존 이슈는 연결 이슈의 `## 의존성` 절과 PR 본문의 `Depends on #<d>` 줄에 있는 이슈다.
- 모두 끝난 PR이 있으면 사용자에게 알리고 새 이슈보다 먼저 마무리한다(`/pr-open`의 "의존 이슈가 끝났을 때").
- 완료되지 않고 닫힌 의존 이슈(중복, not planned)가 있으면 멈추고 묻는다. 메인테이너의 결정이 필요하다.

### 2.1 새 이슈 후보
```sh
gh issue list --repo kkdy21/overgrove --state open --limit 200 \
  --search "no:assignee -label:type:epic -label:status:blocked -label:status:needs-decision -label:status:triage" \
  --json number,title,labels,milestone,body
```
- 후보마다 본문 "## 의존성"의 `#번호` 상태를 확인한다(`gh issue view <d> --json state,stateReason,assignees`).
  - 열린 의존성이 있어도 후보에서 빼지 않는다(ADR-0015). 의존 이슈의 상태를 `끝남`, `진행 중 #d(@담당자)`, `미착수 #d`로 정리한다.
  - 완료되지 않고 닫힌 의존 이슈가 있는 후보는 뺀다. 메인테이너가 의존성 절을 고쳐야 하는 상태다.
- 우선순위:
  1. 현재 마일스톤 `v0.1.0`
  2. 의존성이 모두 끝난 이슈
  3. `priority:p0` → `p1` → `p2`
  4. 크기 S·M
  5. `good first issue`
- 상위 3–5개를 표로 보여준다(번호, 제목, 우선순위, 크기, 의존성, 한 줄 요약). 의존 이슈가 남은 후보에는 stand-in으로 진행한다는 점을 적는다. **사용자가 고르게 한다.** 사용자가 "알아서 골라"라고 하면 1순위를 고른다.

## 3. 선점
```sh
gh issue comment <n> --repo kkdy21/overgrove --body "/claim"
```
- 최대 60초 동안 `gh issue view <n> --json assignees`로 확인한다.
- 봇이 거절하면 이유(이미 선점됨, 한도 2개, 선점 불가 라벨, 만료 후 24시간 재선점 제한)를 알리고 2단계로 돌아간다.
- 봇이 "GitHub이 지정을 허용하지 않음"이라고 하면 메인테이너에게 이슈 댓글로 요청하고 기다린다.
- **5시간 안에 Draft PR을 열어야 선점이 유지된다.**

## 4. 시작과 구현
1. `/issue-start <n>`으로 `upstream/main` 기준 `<type>/<n>-<slug>` 브랜치(또는 워크트리)를 만들고 계획을 세운다.
   - 의존 이슈가 남아 있으면 `/issue-start`의 "의존 이슈 준비"를 따른다. 아무도 선점하지 않은 의존 이슈는 직접 선점할지 사용자에게 묻는다. 그 밖에는 필요한 부분만 `STAND-IN(#<d>)` 주석을 단 stand-in으로 만든다. 남의 미머지 PR은 merge하거나 체크아웃하지 않는다.
2. 명세를 읽는다: 이슈 본문, `docs/architecture/*`, `docs/design/*`, 관련 ADR, `docs/README.md` §2 식별자.
3. **테스트를 먼저** 쓴다.
   - 파서: 실제 git 출력을 채집해 픽스처로 쓴다.
   - 통합 테스트: `GitTestRepository`나 `FixtureRepo`를 쓴다.
4. 첫 의미 있는 커밋을 하면 바로 `/pr-open --draft`를 실행한다(선점 유지).
5. 구현은 `CLAUDE.md` §2·§2.1 규칙을 지킨다. 특히 git은 반드시 `GitClient`와 `RepoSafetyContext`를 거친다.
6. 완료 조건을 하나씩 채우며 커밋한다(Conventional Commits, 영어 제목).

## 5. 마무리
- 아래를 모두 통과시킨다.
  ```sh
  swift format lint --strict --recursive --configuration .swift-format Overgrove OvergroveTests
  scripts/lint/check-forbidden-apis.sh
  xcodebuild test -project Overgrove.xcodeproj -scheme Overgrove -destination 'platform=macOS'
  gitleaks git --no-banner --redact --log-opts="upstream/main..HEAD" .
  ```
- 시간에 의존하는 테스트를 추가했다면 `-test-iterations 5 -run-tests-until-failure`로 불안정성을 확인한다.
- 보안 영향 경로를 건드렸다면 `security-reviewer` 에이전트를 돌린다. 경로: `Execution/`, `Git/`, `GitHub/`, `Parsing/`, `Security/`, `.github/`, `.githooks/`, `.claude/hooks/`, `scripts/github/`
- PR 본문의 체크리스트와 검증 방법을 채운다.
- 의존 이슈가 모두 완료로 닫혔고 stand-in이 남지 않았으면(`git diff upstream/main...HEAD | grep -n 'STAND-IN(#'` 결과 없음) `gh pr ready <n>`로 바꾼다.
- 의존 이슈가 남아 있으면 **Draft로 둔다.** 이때 `pr-policy`의 "Waiting on dependency" 실패는 정상이다.
- `gh pr checks <n> --watch`로 확인한다. 첫 PR은 메인테이너가 워크플로우 실행을 승인해야 검사가 돈다는 점을 알린다.
- 사용자에게 보고한다: PR 링크, 바뀐 것, 검증 결과, 남은 질문.
  - Draft로 남겼다면 무엇을 기다리는지(의존 이슈 번호와 상태)도 함께 보고한다.
  - 의존 이슈가 닫히면 봇이 PR에 댓글로 알린다. 그때 "백로그 확인해서 진행해줘"라고 하면 2.0에서 이어서 마무리한다는 점을 알린다.

## 멈추고 묻는 경우
- 이슈 선택
- 명세가 모호하거나 결정이 필요할 때: `type:decision` 이슈 초안을 제안한다
- 범위 밖 변경이 필요할 때: `later` 이슈 초안을 제안한다
- 보안 판단이 서지 않을 때
- 셋업에 사용자의 손(로그인, sudo)이 필요할 때
- 의존 이슈가 완료되지 않고 닫혔거나 의존이 순환할 때
- 아무도 선점하지 않은 의존 이슈를 직접 선점할지 정할 때

## 하지 않는 것
- 머지
- `upstream` push
- rebase와 강제 푸시
- `--no-verify`
- 남이 선점한 이슈 작업
- 동시에 3개 이상 선점
- 남의 미머지 PR을 merge하거나 체크아웃하기
- 의존 이슈가 남았거나 stand-in이 남은 PR을 Ready로 바꾸기
