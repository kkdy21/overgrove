---
name: issue-start
description: Overgrove 이슈 작업을 시작한다. 역할(메인테이너/협업자)을 확인하고, 선점(담당자) 상태를 보장한 뒤 <type>/<issue>-<slug> 브랜치(선택적으로 별도 git worktree)를 만들고 테스트 우선 구현 계획을 세운다. "#12 시작하자", "이 이슈 작업 시작" 요청 시 사용.
---

# issue-start — 선점 확인 → 브랜치(워크트리) → 계획

## 1. 역할과 원격 확인
```sh
me=$(gh api user --jq .login)
is_admin=$(gh api repos/kkdy21/overgrove --jq .permissions.admin)
git remote -v
```
- 메인테이너(`is_admin=true`)는 `origin`이 `kkdy21/overgrove`다.
- 협업자는 `origin`이 fork이고 `upstream`이 `kkdy21/overgrove`다. 설정이 안 되어 있으면 `/onboard`부터 진행한다.
- 아래에서 `BASE`는 메인테이너면 `origin`, 협업자면 `upstream`이다.

## 2. 이슈 확인
`gh issue view <n> --repo kkdy21/overgrove --json number,title,body,labels,milestone,state,assignees`
- 닫혔거나, `type:epic`이거나, `status:blocked`·`status:needs-decision`이면 중단하고 이유를 알린다.
- "## 의존성"의 이슈 상태를 확인한다(`gh issue view <d> --json state,stateReason,assignees`).
  - 열려 있어도 멈추지 않는다. 4.1에서 준비한다(ADR-0015).
  - 완료되지 않고 닫힌 의존 이슈(중복, not planned)가 있으면 멈추고 묻는다.

## 3. 선점 보장 (ADR-0013)
- **담당자가 나**면 다른 세션이 이미 하고 있는지 먼저 확인한다(같은 계정의 여러 세션, `docs/process/development-workflow.md` §5.1).
  ```sh
  git ls-remote --heads $BASE "refs/heads/*/<n>-*"
  gh issue view <n> --repo kkdy21/overgrove --json closedByPullRequestsReferences --jq '.closedByPullRequestsReferences[].number'
  git worktree list
  ```
  셋 다 없거나, 있는 것이 이 세션이 만든 것이면 진행한다. 그 밖에는 멈추고 사용자에게 묻는다.
- **담당자가 없음**
  - 메인테이너: `gh issue edit <n> --add-assignee @me`
  - 협업자: `gh issue comment <n> --repo kkdy21/overgrove --body "/claim"`을 남기고 봇이 지정할 때까지 확인한다(최대 60초).
- **다른 사람이 담당자**면 중단한다. 그 이슈의 PR은 `pr-policy`에서 실패한다.
- 협업자는 선점한 시각부터 **5시간 안에 Draft PR**을 열어야 선점이 유지된다는 점을 알린다.

## 4. 브랜치 만들기
- 이름은 `<type>/<n>-<slug>`이다.
  - type은 라벨에서 정한다: feature→feat, bug→fix, docs→docs, test→test, chore→chore, spike→spike
  - slug는 영어 소문자 kebab-case, 4단어 이내
- 기본 방식:
  ```sh
  git fetch $BASE && git switch -c <branch> $BASE/main
  ```
- 워크트리 방식(권장, 이 프로젝트가 워크트리 도구라 dogfooding이 된다):
  ```sh
  git fetch $BASE && git worktree add ../overgrove-worktrees/<n>-<slug> -b <branch> $BASE/main
  ```
- 보드 Status는 담당자 지정과 Draft PR에 따라 자동으로 `In progress`가 된다(ADR-0016). `PROJECT_TOKEN`이 아직 없으면 메인테이너는 `scripts/github/board-sync.sh issue <n>`을 돌린다.
- 같은 계정으로 다른 세션도 돌고 있으면 **워크트리 방식을 쓴다.** 한 폴더에서 브랜치를 바꾸면 다른 세션의 작업을 덮는다.

## 4.1 의존 이슈 준비 (열린 의존성이 있을 때)
기준: `docs/process/collaboration.md` §4.1, ADR-0015
- **남의 미머지 PR은 merge하거나 체크아웃하지 않는다.** 그 PR의 `.githooks`, `.claude/` hooks, 테스트가 내 PC에서 실행된다. 이름을 맞추려면 `gh pr diff <PR> --repo kkdy21/overgrove`로 읽기만 한다.
- 의존 이슈를 아무도 선점하지 않았으면 직접 선점할지 사용자에게 묻는다. 선점했다면 그 이슈의 브랜치를 먼저 만들고 이 브랜치에 merge한다. 그 브랜치가 갱신되면 다시 merge한다.
  ```sh
  git merge --no-ff <type>/<d>-<slug>
  ```
- 그 밖에는 필요한 부분만 stand-in으로 만든다.
  - 이름과 시그니처는 의존 이슈의 명세(이슈 본문, `docs/architecture/*`)를 따른다.
  - 가능하면 별도 파일에 모으고, 블록마다 `// STAND-IN(#<d>)` 주석을 단다.
  - stand-in만 담은 커밋을 따로 만든다. 예: `chore: add stand-in for #<d>`
- 작업 중에 새로 발견한 의존성은 `/pr-open`에서 PR 본문에 `Depends on #<d>`로 적는다. 아직 이슈가 없으면 메인테이너에게 이슈를 요청하는 댓글 초안을 만들어 승인받은 뒤 이 이슈에 남긴다.

## 5. 계획
- 관련 명세를 읽는다: `docs/architecture/*`, `docs/design/*`, ADR, `docs/README.md` §2 식별자
- 완료 조건마다 **테스트 → 구현** 순서의 작업 목록을 만든다.
- 보안 영향(T-xx)이 있으면 계획에 `security-reviewer` 검토 단계를 넣는다.
- 열린 의존성이 있으면 stand-in 목록과, 의존 이슈가 머지된 뒤 실제 코드로 바꿀 지점을 계획에 적는다.
- 범위 밖 요소는 따로 표시하고 `/issue-new`로 later 이슈 초안을 만든다.
- 협업자: 첫 의미 있는 커밋 직후 `/pr-open --draft`를 계획의 2번째 단계로 넣는다(선점 유지).
