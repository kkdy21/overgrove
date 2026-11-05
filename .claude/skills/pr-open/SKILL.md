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

## 4. PR 초안
- **제목**: 영어 Conventional 형식. squash 커밋 제목이 된다. 예: `feat(parser): parse porcelain v2 rename records`
- **본문**: `.github/pull_request_template.md`를 채운다.
  - 첫 줄에 `Closes #<n>`
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
- `gh pr checks <n> --watch`로 `gitleaks`, `pr-policy`, `build-test`를 확인하고 보고한다. 외부 기여자의 첫 PR은 메인테이너가 워크플로우 실행을 승인해야 검사가 돈다.
- Draft로 열었다면 완료 조건을 다 채운 뒤 `gh pr ready <n>`로 바꾼다.

## 7. 이후
- 리뷰 코멘트에 대응하고 스레드는 코멘트 작성자가 resolve한다.
- `main`이 앞서 나가면 `gh pr update-branch <n>` 또는 `git merge $BASE/main`을 쓴다. rebase와 강제 푸시는 하지 않는다.
- 머지는 메인테이너가 한다(`/pr-review`).
