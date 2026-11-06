---
name: onboard
description: Overgrove 협업자의 시작점. "백로그 확인해서 진행해줘", "check the backlog and work on it", "할 거 찾아서 해줘", "기여 시작", "온보딩"이라고 하면 사용한다. 셋업(gh 로그인·fork 원격·hooks·Xcode)을 점검하고, 선점 가능한 이슈를 추천해 사용자가 고르면 /claim으로 선점한 뒤, 브랜치 생성·테스트 우선 구현·Draft PR·Ready PR까지 끝까지 이어서 진행한다. 머지는 하지 않는다.
---

# onboard — 백로그에서 PR까지

기준 문서: `CLAUDE.md`(특히 §0.1, §2.1), `docs/process/collaboration.md`, ADR-0013

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
```sh
gh issue list --repo kkdy21/overgrove --state open --limit 200 \
  --search "no:assignee -label:type:epic -label:status:blocked -label:status:needs-decision -label:status:triage" \
  --json number,title,labels,milestone,body
```
- 후보마다 본문 "## 의존성"의 `#번호`가 모두 닫혔는지 확인한다(`gh issue view <n> --json state`). 열린 의존성이 있으면 제외한다.
- 우선순위:
  1. 현재 마일스톤 `v0.1.0`
  2. `priority:p0` → `p1` → `p2`
  3. 크기 S·M
  4. `good first issue`
- 상위 3–5개를 표로 보여준다(번호, 제목, 우선순위, 크기, 한 줄 요약). **사용자가 고르게 한다.** 사용자가 "알아서 골라"라고 하면 1순위를 고른다.

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
- PR 본문의 체크리스트와 검증 방법을 채우고 `gh pr ready <n>`로 바꾼다.
- `gh pr checks <n> --watch`로 확인한다. 첫 PR은 메인테이너가 워크플로우 실행을 승인해야 검사가 돈다는 점을 알린다.
- 사용자에게 보고한다: PR 링크, 바뀐 것, 검증 결과, 남은 질문.

## 멈추고 묻는 경우
- 이슈 선택
- 명세가 모호하거나 결정이 필요할 때: `type:decision` 이슈 초안을 제안한다
- 범위 밖 변경이 필요할 때: `later` 이슈 초안을 제안한다
- 보안 판단이 서지 않을 때
- 셋업에 사용자의 손(로그인, sudo)이 필요할 때

## 하지 않는 것
- 머지
- `upstream` push
- rebase와 강제 푸시
- `--no-verify`
- 남이 선점한 이슈 작업
- 동시에 3개 이상 선점
