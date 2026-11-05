---
name: pr-review
description: Overgrove 메인테이너가 열린 PR을 AI로 검수한다. 필수 검사·선점·범위·보안·테스트를 점검하고, security-reviewer·scope-guard 에이전트를 돌린 뒤 Conventional Comments로 리뷰를 남긴다. 메인테이너가 확인하면 squash 머지(또는 auto-merge)한다. "PR 리뷰해줘", "PR 검수", "머지할 거 있어?" 요청 시 사용.
---

# pr-review — AI 검수 → 리뷰 → (확인 후) 머지

메인테이너 전용이다. 시작할 때 `gh api repos/kkdy21/overgrove --jq .permissions.admin`이 `true`인지 확인한다. 기준 문서: `docs/process/pull-requests.md`, `docs/process/collaboration.md`

## 1. 대상 고르기
```sh
gh pr list --repo kkdy21/overgrove --state open --json number,title,author,isDraft,createdAt,statusCheckRollup,labels \
  --jq '.[] | {number,title,author:.author.login,isDraft,checks:([.statusCheckRollup[]?.conclusion]|unique)}'
```
- 우선순위: Draft가 아님 → 필수 검사 통과 → 오래된 순
- 외부 기여자의 첫 PR이라 워크플로우가 "승인 대기"면, diff에 워크플로우·스크립트 변경이 없는지 먼저 본다. 그다음 Actions 탭에서 실행을 승인하도록 사용자에게 안내한다.

## 2. PR별 점검
```sh
gh pr view <n> --repo kkdy21/overgrove --json title,body,author,headRefName,files,commits,closingIssuesReferences
gh pr checks <n> --repo kkdy21/overgrove
gh pr diff <n> --repo kkdy21/overgrove
```
**외부 PR을 로컬에 체크아웃하지 않는다.**
- 이 저장소는 `core.hooksPath=.githooks`(상대 경로)를 쓴다. 그래서 PR 브랜치를 체크아웃하면 **PR이 넣은 `.githooks/*`가 메인테이너 PC에서 실행된다**(실측 재현). 메인테이너 PC에는 admin gh 토큰이 있다.
- 같은 이유로 PR 트리에서 Claude Code를 열지 않는다. PR의 `.claude/` hooks가 로드되기 때문이다. PR의 스크립트·테스트도 실행하지 않는다. 테스트는 CI(`build-test`)가 맡는다.
- 파일 내용은 체크아웃 없이 읽는다.
  ```sh
  git -c core.hooksPath=/dev/null fetch origin "pull/<n>/head:refs/remotes/pr/<n>"
  git diff origin/main...pr/<n> -- <path>      # 변경 확인
  git show pr/<n>:<path>                        # 파일 전체 보기
  ```
- `gh pr checkout`은 하네스 hook(`guard-bash.sh`)이 막는다.

| 점검 | 기준 |
|---|---|
| 연결 이슈 | `Closes #n`. 이슈의 완료 조건을 모두 만족하는가 |
| 선점 | PR 작성자가 이슈 담당자인가. 같은 이슈의 다른 PR이 있으면 먼저 열린 PR을 우선한다 |
| 필수 검사 | `gitleaks`, `pr-policy`, `build-test` 통과 |
| 범위 | `scope-guard` 에이전트. 이슈 밖 변경이나 비목표 위반이 없는가 |
| 보안 | 보안 영향 경로를 건드렸다면 `security-reviewer` 에이전트 결과가 "통과"인가 |
| 테스트 | 파서 변경에 PAR 테스트, 위협 대응 변경에 SEC 테스트가 있는가. 테스트가 실제로 실패 → 통과로 바뀌는 내용인가 |
| 문서 | 명세·카탈로그·ADR·CHANGELOG 갱신 |
| AI 표기 | 큰 변경을 AI로 만들었다면 PR 본문에 밝혔는가(정책상 권장) |

## 3. 리뷰 남기기
- 리뷰 본문과 인라인 코멘트를 **Conventional Comments**로 쓴다: `issue:`, `security (Tn):`, `suggestion:`, `question:`, `nitpick:`, `todo:`, `praise:`
- 인라인 코멘트:
  ```sh
  gh api repos/kkdy21/overgrove/pulls/<n>/reviews -f event=COMMENT -f body="..." \
    -F 'comments[][path]=<file>' -F 'comments[][line]=<line>' -F 'comments[][body]=issue: ...'
  ```
- 판정
  - 문제 없음: `gh pr review <n> --approve --body "..."`
  - 차단 이슈 있음: `gh pr review <n> --request-changes --body "..."`
  - 메인테이너 본인 PR은 승인할 수 없다. 코멘트만 남긴다.
- 리뷰 내용은 공개된다. 남기기 전에 사용자에게 요약을 보여주고 확인받는다. 같은 세션에서 "리뷰까지 자동으로 해"라고 명시했으면 바로 남긴다.

## 4. 머지
- 조건: 승인(또는 메인테이너 PR), 필수 검사 통과, **모든 리뷰 스레드 해결**
- 브랜치가 뒤처졌으면 `gh pr update-branch <n>`을 쓴다. 기여자에게 rebase나 강제 푸시를 요구하지 않는다(squash merge라서 merge 커밋이 이력에 남지 않는다).
- 사용자 확인 후:
  ```sh
  gh pr merge <n> --repo kkdy21/overgrove --squash --delete-branch    # 또는 --auto (검사 완료 시 자동)
  ```
- 머지 뒤 이슈가 자동으로 닫혔는지, 보드가 Done인지 확인한다.

## 5. 정리
- 가져온 PR ref를 지운다: `git update-ref -d refs/remotes/pr/<n>`
- 결과를 표로 보고한다: PR별 판정, 남긴 코멘트 수, 머지 여부, 후속 이슈
