---
name: pr-open
description: Overgrove의 현재 이슈 브랜치로 PR을 연다. 자체 점검(포맷·테스트·gitleaks·금지 API·범위·보안 체크리스트)을 돌리고, PR 템플릿을 채운 본문을 사용자에게 보여 승인받은 뒤 push와 gh pr create를 수행한다. "PR 올려줘", "PR 만들어" 요청 시 사용.
---

# pr-open — 자체 점검 → 승인 → PR

## 1. 전제 확인
- 현재 브랜치가 `<type>/<n>-<slug>` 형식인지, `main`이 아닌지 확인한다.
- 이슈 #n이 열려 있는지 확인한다.

## 2. 자체 점검 (하나라도 실패하면 고치고 다시)
```sh
scripts/lint/check-forbidden-apis.sh
gitleaks git --no-banner --redact --log-opts="origin/main..HEAD" .
# Phase 3 이후
swift format lint --strict --recursive --configuration .swift-format Overgrove OvergroveTests
xcodebuild test -project Overgrove.xcodeproj -scheme Overgrove -destination 'platform=macOS'
```
- `git diff origin/main...HEAD --stat`으로 변경 범위가 이슈 하나에 맞는지 확인한다.
- 다음 경로를 건드렸으면 **`security-reviewer` 에이전트**로 검토한다: `Overgrove/Execution|Git|GitHub|Parsing|Security`, `.github/workflows`, `.githooks`, `.claude/hooks`
- 범위가 의심되면 `scope-guard` 에이전트로 확인한다.

## 3. PR 초안
- **제목**: 영어 Conventional 형식. squash 커밋 제목이 된다. 예: `feat(parser): parse porcelain v2 rename records`
- **본문**: `.github/pull_request_template.md`를 채운다.
  - 첫 줄에 `Closes #<n>`
  - 검증 방법(실행한 명령과 결과)
  - 체크리스트에서 해당 없는 항목은 이유를 적는다
- **라벨**: 이슈와 같은 type과 area. 보안 영향이 있으면 `area:security`
- **마일스톤**: 이슈와 같게

## 4. 승인 요청
제목, 본문, 라벨, 커밋 목록(`git log --oneline origin/main..HEAD`)을 보여주고 승인을 받는다.

## 5. 생성
```sh
git push -u origin HEAD
gh pr create --repo kkdy21/overgrove --base main --title "<title>" --body-file <tmpfile> \
  --label "<labels>" --milestone "<milestone>"
```
- 보드 Status를 `In review`로 바꾼다.
- `gh pr checks --watch`로 `gitleaks`, `pr-policy`, `build-test` 결과를 확인해 보고한다.

## 6. 머지
머지는 메인테이너가 결정한다. 요청받으면 `gh pr merge --squash --delete-branch`를 쓴다. 리뷰 스레드가 모두 해결되어 있어야 한다.
