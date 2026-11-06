---
name: pr-open
description: Overgrove의 현재 이슈 브랜치로 PR을 연다(협업자는 fork에서, Draft 가능). 자체 점검(포맷·테스트·gitleaks·금지 API·범위·보안 체크리스트)을 돌리고 PR 템플릿을 채워 사용자 승인 후 push와 gh pr create를 수행한다. "PR 올려줘", "Draft PR 열어", "PR 만들어" 요청 시 사용.
---

# pr-open — 자체 점검 → 승인 → PR

## 1. 전제 확인
```sh
me=$(gh api user --jq .login); is_admin=$(gh api repos/kkdy21/overgrove --jq .permissions.admin)
branch=$(git branch --show-current)
```
- 브랜치가 `<type>/<n>-<slug>` 형식이어야 하고 `main`이 아니어야 한다.
- 이슈 #n이 열려 있어야 한다.
- 담당자가 나여야 한다(메인테이너는 예외). 담당자가 아니면 중단한다. `pr-policy`에서 실패하기 때문이다.
- `--draft`면 3단계의 무거운 점검(xcodebuild 등)은 건너뛰어도 된다. 협업자의 **선점 유지용 Draft PR은 빨리 여는 것이 우선**이다.

## 2. BASE 결정
- 메인테이너: `BASE=origin`
- 협업자: `BASE=upstream`, push 대상은 `origin`(fork)

## 3. 자체 점검 (Ready PR은 필수)
```sh
scripts/lint/check-forbidden-apis.sh
gitleaks git --no-banner --redact --log-opts="$BASE/main..HEAD" .
# Phase 3 이후
swift format lint --strict --recursive --configuration .swift-format Overgrove OvergroveTests
xcodebuild test -project Overgrove.xcodeproj -scheme Overgrove -destination 'platform=macOS'
```
- `git diff $BASE/main...HEAD --stat`으로 변경 범위가 이슈 하나에 맞는지 확인한다.
- 다음 경로를 건드렸으면 `security-reviewer` 에이전트를 돌린다: `Overgrove/Execution|Git|GitHub|Parsing|Security`, `.github/workflows`, `.githooks`, `.claude/hooks`, `scripts/github`
- 범위가 의심되면 `scope-guard` 에이전트를 돌린다.
- Ready로 바꾸기 전에 의존성을 확인한다(ADR-0014).
  - 연결 이슈의 `## 의존성` 절과 PR 본문의 `Depends on`에 있는 이슈가 모두 완료로 닫혔는가(`gh issue view <d> --json state,stateReason`). 하나라도 열려 있으면 Draft로 둔다.
  - stand-in이 남지 않았는가. `git diff $BASE/main...HEAD | grep -n 'STAND-IN(#'` 결과가 비어 있어야 한다.

## 4. PR 초안
- **제목**: 영어 Conventional 형식. squash 커밋 제목이 된다. 예: `feat(parser): parse porcelain v2 rename records`
- **본문**: `.github/pull_request_template.md`를 채운다.
  - 첫 줄에 `Closes #<n>`
  - 이슈의 `## 의존성` 절에 없는 의존 이슈(작업 중 발견)는 그다음 줄부터 `Depends on #<d>`로 한 줄씩 적는다. 의존 이슈가 남아 있으면 Draft로 열고, stand-in으로 대신한 부분을 요약에 적는다
  - 검증 방법(실행한 명령과 결과)
  - 체크리스트에서 해당 없는 항목은 이유를 적는다
  - AI로 만든 변경이면 "AI-assisted: Claude Code" 한 줄을 넣는다
- **라벨·마일스톤**: 이슈와 같게(협업자는 권한이 없으면 생략해도 된다)

## 5. 승인 요청
제목, 본문, 커밋 목록(`git log --oneline $BASE/main..HEAD`)을 보여주고 승인을 받는다. 사용자가 이 세션에서 PR 생성을 미리 승인했으면 생략한다.

## 6. 생성
- 메인테이너:
  ```sh
  git push -u origin HEAD
  gh pr create --repo kkdy21/overgrove --base main --title "<title>" --body-file <tmp> [--draft] --label "<labels>" --milestone "<ms>"
  ```
- 협업자(fork):
  ```sh
  git push -u origin HEAD
  gh pr create --repo kkdy21/overgrove --base main --head "$me:$branch" --title "<title>" --body-file <tmp> [--draft]
  ```
  "Allow edits by maintainers"를 켜 둔다(기본값). 메인테이너가 `Update branch`를 대신 눌러줄 수 있다.
- `gh pr checks <n> --watch`로 `gitleaks`, `pr-policy`, `build-test`를 확인하고 보고한다. 외부 기여자의 첫 PR은 메인테이너가 워크플로우 실행을 승인해야 검사가 돈다. 의존 이슈를 기다리는 Draft라면 `pr-policy`의 "Waiting on dependency" 실패는 정상이다.
- Draft로 열었다면 완료 조건을 다 채우고 의존 이슈가 모두 끝난 뒤 `gh pr ready <n>`로 바꾼다.

## 7. 이후
- 리뷰 코멘트에 대응하고 스레드는 코멘트 작성자가 resolve한다.
- `main`이 앞서 나가면 `gh pr update-branch <n>` 또는 `git merge $BASE/main`을 쓴다. rebase와 강제 푸시는 하지 않는다.
- 머지는 메인테이너가 한다(`/pr-review`).

## 8. 의존 이슈가 끝났을 때
`dependency-closed` 봇이 PR에 "🔓 #<d> is done" 댓글을 달았거나, `/onboard` 2.0에서 의존 이슈가 모두 끝난 Draft PR을 찾았을 때 한다.
```sh
git fetch $BASE
git merge $BASE/main
```
- 충돌하면 의존 이슈 쪽(main)을 택한다(`git checkout --theirs <file>`). 내 이슈에서 그 파일을 바꾼 부분이 있었다면 다시 적용한다.
- stand-in을 모두 지우고 실제 코드에 맞게 고친다.
  - `git diff $BASE/main...HEAD | grep -n 'STAND-IN(#'` 결과가 비어 있어야 한다.
  - `git diff $BASE/main...HEAD --stat`에 내 이슈의 변경만 남아야 한다.
- 3단계 점검을 모두 돌리고 push한다. push하면 `pr-policy`가 다시 돈다.
- 의존 이슈가 모두 끝났으면 `gh pr ready <n>`로 바꾸고 보고한다.
- 봇이 "⚠️ closed without being completed" 댓글을 달았다면 멈추고 사용자에게 알린다. 메인테이너의 결정(다른 이슈에 의존, stand-in을 정식 코드로 흡수, 범위 변경)이 필요하다.
