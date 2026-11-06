# 개발 흐름 (이슈 기반)

> 상태: Accepted · 관련: [issues.md](issues.md), [pull-requests.md](pull-requests.md), [branching-and-commits.md](branching-and-commits.md), [discussions.md](discussions.md), ADR-0012, ADR-0014

Overgrove의 모든 작업은 GitHub 이슈에서 시작해서 이슈가 닫히며 끝난다. **이슈 없는 PR은 머지하지 않는다.**

## 1. 전체 흐름

```mermaid
flowchart LR
    D[Discussion<br/>아이디어·질문·설계 토론] -->|결론| I
    X[직접 발견한 작업<br/>버그·잡무] --> I
    I[Issue<br/>템플릿·라벨·마일스톤] --> T{트리아지}
    T -->|범위 밖| L[later 마일스톤]
    T -->|결정 필요| DEC[type:decision → ADR]
    DEC --> I
    T -->|준비됨| B[Branch / Worktree<br/>type/issue-slug]
    B --> C[Commits<br/>Conventional, Refs: #n]
    C --> P[Pull Request<br/>Closes #n]
    P --> CI[Required checks<br/>gitleaks · pr-policy · build-test]
    CI --> R[Review<br/>Conventional Comments<br/>스레드 전부 해결]
    R --> M[Squash merge<br/>PR 제목 = 커밋 제목]
    M --> Z[Issue 자동 종료<br/>보드 Done]
```

## 2. 단계별 규칙

| 단계 | 규칙 | 산출물 | 보드 Status |
|---|---|---|---|
| 토론 | 확정되지 않은 아이디어, 설계 질문은 Discussions에서 시작한다 | Discussion | — |
| 이슈 | 템플릿을 쓴다. 제목은 영어 Conventional 형식, 본문은 한국어 가능. 완료 조건은 검증 가능한 체크리스트로 쓴다 | Issue | Backlog |
| 준비 | 완료 조건이 명확하고 의존 이슈가 모두 끝났으면 Ready로 옮긴다. Ready는 바로 시작하기 좋은 이슈라는 뜻이다. 의존 이슈가 남은 이슈도 착수할 수 있다([collaboration.md §4.1](collaboration.md#41-의존-이슈가-아직-끝나지-않았을-때)) | — | Ready |
| 시작 | 담당자를 지정하고(협업자는 `/claim`) 브랜치나 워크트리를 만든다. 협업자는 5시간 안에 Draft PR을 연다 | `feat/12-worktree-list` | In progress |
| 구현 | 명세 → 테스트 → 구현 순서. 명세가 바뀌면 같은 PR에서 문서도 고친다 | 커밋 | In progress |
| PR | `Closes #n`, 템플릿 체크리스트, 보안 영향 섹션을 채운다 | Pull request | In review |
| 리뷰 | 필수 검사 통과(`pr-policy`는 의존 이슈가 모두 끝나야 통과), 리뷰 스레드 전부 해결 | 리뷰 코멘트 | In review |
| 머지 | squash merge, 브랜치 자동 삭제 | `main`의 커밋 1개 | Done |

## 3. 크기와 단위

- **한 이슈 = 한 브랜치 = 한 PR.** PR이 400줄(테스트 제외)을 넘을 것 같으면 이슈를 나눈다.
- Phase나 큰 주제는 Epic 이슈(`type:epic`)로 묶고, 하위 이슈를 GitHub 네이티브 sub-issue로 연결한다.
- 작은 잡무도 `type:chore` 이슈를 만든다. 템플릿이 짧아서 1분이면 된다.
- 조사 작업은 `type:spike`로 시간 상자를 둔다. 스파이크 코드는 머지하지 않는다. 결과는 이슈 코멘트, 문서, ADR로 남긴다.

## 4. 역할

| 역할 | 누가 | 하는 일 |
|---|---|---|
| 메인테이너 | @kkdy21 | 이슈 승인, 범위·결정 승인, Phase 승인, 머지 결정 |
| 구현 에이전트 | Claude Code (프로젝트 하네스) | 이슈 초안, 구현, 테스트, PR 초안. 공개 글쓰기 전에 승인을 요청한다 |
| 협업자 | 누구나 (fork) | `/claim`으로 이슈 선점(5시간 안에 Draft PR), fork에서 구현, PR 제출, 리뷰 대응. 규칙: [collaboration.md](collaboration.md) |

Claude Code 하네스 사용법은 [claude-code-harness.md](claude-code-harness.md)에 있다.

## 5. 워크트리로 병렬 작업하기

이 프로젝트 자체가 워크트리 도구이므로 개발에도 워크트리를 쓴다(dogfooding).

```sh
git fetch origin
git worktree add ../overgrove-worktrees/12-worktree-list -b feat/12-worktree-list origin/main
cd ../overgrove-worktrees/12-worktree-list
# 작업 → PR → 머지 후
git worktree remove ../overgrove-worktrees/12-worktree-list
```

- `core.hooksPath=.githooks`는 저장소 설정이라 모든 워크트리에 적용된다.
- 워크트리마다 브랜치는 하나다. 같은 브랜치를 두 워크트리에서 체크아웃하지 않는다.

## 6. 막혔을 때

| 상황 | 할 일 |
|---|---|
| 명세가 모호하다 | 추측해서 구현하지 않는다. 이슈에 질문 코멘트를 달거나 `type:decision` 이슈를 만든다 |
| 결정이 필요하다 | 이슈에 `status:needs-decision`을 붙이고 decision 이슈를 링크한다 |
| 다른 이슈의 결과물이 필요하다 | 기다리지 않는다. stand-in으로 개발하고 PR은 Draft로 둔다. 이슈 본문에 없는 의존성은 PR 본문에 `Depends on #<n>`으로 적는다([collaboration.md §4.1](collaboration.md#41-의존-이슈가-아직-끝나지-않았을-때)) |
| 외부 요인을 기다린다 | 메인테이너가 `status:blocked`를 붙이고 이유를 코멘트로 남긴다. 다른 저장소의 수정, 도구 출시처럼 이 저장소의 이슈가 아닌 것만 해당한다 |
| 범위 밖 아이디어가 생겼다 | 구현하지 않고 `later` 마일스톤 이슈로 남긴다 |
| 보안 문제를 발견했다 | 공개 이슈를 만들지 않는다. [SECURITY.md](../../SECURITY.md) 절차를 따른다 |
