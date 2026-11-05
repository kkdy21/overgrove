---
name: onboard
description: Overgrove에 처음 참여하는 협업자(사람 또는 AI 에이전트를 쓰는 사람)의 셋업을 끝내고, 선점 가능한 이슈를 골라 /claim으로 선점한 뒤 작업을 시작하게 한다. "참여하고 싶어", "기여 시작", "할 이슈 찾아줘", "온보딩" 요청 시 사용.
---

# onboard — 협업자 셋업 → 이슈 선택 → 선점 → 시작

기준 문서: `docs/process/collaboration.md`, `CONTRIBUTING.md`, ADR-0013

## 1. 역할 확인
```sh
gh auth status
me=$(gh api user --jq .login)
gh api repos/kkdy21/overgrove --jq '.permissions | {admin, push}'
```
- `admin: true`면 메인테이너다. 이 스킬 대신 `/issue-start`를 쓴다.
- 그 밖에는 협업자다. 저장소 권한 없이 **fork에서 작업**한다.

## 2. 작업 공간 준비 (최초 1회)
아직 클론하지 않았다면:
```sh
gh repo fork kkdy21/overgrove --clone --remote   # origin = 내 fork, upstream = kkdy21/overgrove
cd overgrove
```
이미 `kkdy21/overgrove`를 클론했다면:
```sh
gh repo fork --remote --remote-name origin      # 기존 origin은 upstream으로 바뀐다
git remote -v                                   # origin=fork, upstream=kkdy21/overgrove 인지 확인
```
그다음 할 일:
- `./scripts/bootstrap.sh`를 실행한다. Git hooks를 설치하고 gitleaks, git, Xcode를 점검한다. 실패 항목은 사용자에게 안내한다.
- `CLAUDE.md`와 `docs/README.md` §2(공통 식별자)를 읽는다.

## 3. 선점 가능한 이슈 찾기
조건: 열려 있음, 담당자 없음, Epic 아님, `status:blocked`·`status:needs-decision`·`status:triage` 없음, **의존 이슈가 모두 닫힘**.
```sh
gh issue list --repo kkdy21/overgrove --state open --search "no:assignee -label:type:epic -label:status:blocked -label:status:needs-decision -label:status:triage" \
  --json number,title,labels,milestone --limit 100
```
- 후보마다 본문의 "## 의존성" 섹션에 있는 `#번호`가 모두 닫혔는지 확인한다(`gh issue view <n> --json state`).
- `good first issue`, `priority:p0`·`p1`, 현재 Phase(`docs/process/phase-gates.md`)를 우선한다.
- 상위 3–5개를 표로 보여준다(번호, 제목, 우선순위, 크기, 의존성 상태). **사용자가 고르게 한다.**

## 4. 선점
```sh
gh issue comment <n> --repo kkdy21/overgrove --body "/claim"
```
- 봇이 담당자로 지정하고 마감 시각을 댓글로 남긴다. 10–60초 기다린 뒤 `gh issue view <n> --json assignees`로 확인한다.
- 실패 사유(이미 선점됨, 동시 선점 2개 초과, 선점 불가 라벨)는 봇 댓글로 확인하고 사용자에게 알린다.
- **선점은 5시간 기한이다.** 5시간 안에 `Closes #<n>`이 들어간 PR(Draft 가능)을 열지 않으면 자동으로 해제된다. 그래서 첫 커밋 직후 바로 Draft PR을 연다.

## 5. 시작
`/issue-start <n>`으로 넘어간다. 브랜치는 `upstream/main` 기준으로 만든다. 첫 의미 있는 커밋을 하면 바로 `/pr-open --draft`를 실행한다.

## 원칙
- 한 번에 1–2개만 선점한다. 끝내지 못할 것 같으면 `/unclaim`으로 바로 풀어 다른 사람이 가져가게 한다.
- 다른 사람(또는 다른 AI)이 선점한 이슈는 건드리지 않는다. `pr-policy` 검사에서 실패한다.
- AI로 만든 코드도 제출자가 책임진다. 직접 읽고 테스트한 뒤 올린다.
