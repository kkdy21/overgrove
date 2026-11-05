---
name: issue-start
description: Overgrove 이슈 작업을 시작한다. 이슈를 확인하고 <type>/<issue>-<slug> 브랜치(선택적으로 별도 git worktree)를 만들고, 담당자·보드 상태를 갱신한 뒤 구현 계획을 세운다. "#12 시작하자", "이 이슈 작업 시작" 요청 시 사용.
---

# issue-start — 이슈 → 브랜치(워크트리) → 계획

1. **이슈 확인**: `gh issue view <n> --repo kkdy21/overgrove --json number,title,body,labels,milestone,state`
   - 닫혀 있거나 `status:blocked`, `status:needs-decision`이면 중단하고 이유를 알린다.
   - 의존 이슈("의존성" 섹션)가 열려 있으면 경고한다.
2. **브랜치명 결정**: `<type>/<n>-<slug>`
   - type은 라벨에서 정한다. feature→feat, bug→fix, docs→docs, test→test, chore→chore, spike→spike
   - slug는 영어 소문자 kebab-case, 4단어 이내
3. **작업 공간 만들기**
   - 기본: `git fetch origin && git switch -c <branch> origin/main`
   - 사용자가 워크트리를 원하면:
     `git worktree add ../overgrove-worktrees/<n>-<slug> -b <branch> origin/main`
     이 프로젝트가 바로 워크트리 도구라서 dogfooding이 된다.
4. **상태 갱신** (승인 불필요한 메타데이터 작업이지만, 무엇을 바꾸는지 알린다)
   - `gh issue edit <n> --add-assignee @me`
   - 보드 Status를 `In progress`로 바꾼다. `gh project item-edit`를 쓰며 `project` scope가 필요하다.
5. **계획 수립**
   - 관련 명세(`docs/architecture/*`, `docs/design/*`, ADR)를 읽는다.
   - 완료 조건마다 **테스트 → 구현** 순서의 작업 목록을 만든다.
   - 보안 영향(T-xx)이 있으면 계획에 `security-reviewer` 검토 단계를 넣는다.
   - 범위 밖 요소가 보이면 따로 표시하고 `/issue-new`로 later 이슈 초안을 만든다.
