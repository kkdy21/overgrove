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
- "## 의존성"의 이슈가 열려 있으면 경고하고 진행 여부를 묻는다.

## 3. 선점 보장 (ADR-0013)
- **담당자가 나**면 그대로 진행한다.
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
- 메인테이너만 보드 Status를 `In progress`로 바꾼다(`gh project item-edit`, `project` scope 필요).

## 5. 계획
- 관련 명세를 읽는다: `docs/architecture/*`, `docs/design/*`, ADR, `docs/README.md` §2 식별자
- 완료 조건마다 **테스트 → 구현** 순서의 작업 목록을 만든다.
- 보안 영향(T-xx)이 있으면 계획에 `security-reviewer` 검토 단계를 넣는다.
- 범위 밖 요소는 따로 표시하고 `/issue-new`로 later 이슈 초안을 만든다.
- 협업자: 첫 의미 있는 커밋 직후 `/pr-open --draft`를 계획의 2번째 단계로 넣는다(선점 유지).
