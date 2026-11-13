# ADR-0016: 보드 Status는 워크플로우가 project 전용 토큰으로 맞춘다

> 상태: Accepted · 날짜: 2026-11-07 · 관련: #179, [ADR-0013](0013-external-contributions-and-issue-claiming.md), [ADR-0015](0015-dependent-issues-stand-in.md), [process/development-workflow.md](../process/development-workflow.md), [process/github-settings.md](../process/github-settings.md), T17

## 맥락

개발 흐름은 보드 Status를 Backlog → Ready → In progress → In review → Done으로 정의한다([development-workflow.md §2](../process/development-workflow.md#2-단계별-규칙)). 지금은 메인테이너와 그 세션이 손으로 옮긴다. 협업자와 여러 AI 세션이 동시에 개발하면 다음 문제가 생긴다.

- 협업자는 사용자 소유 Projects 보드를 고칠 권한이 없다. 선점해도 이슈가 "Ready to claim" 뷰에 남아 다른 사람이 같은 이슈를 고른다.
- 웹 UI의 내장 Workflows는 "닫힘 → Done", "자동 추가" 정도만 한다. 선점(In progress), PR Ready(In review), 선점 해제(Ready)는 다루지 않는다.
- 선점 봇은 `GITHUB_TOKEN`으로 담당자를 지정한다. 이 토큰으로 만든 이벤트는 다른 워크플로우를 실행하지 않는다. 그래서 담당자 변경을 감지하는 별도 워크플로우만으로는 부족하다.
- `GITHUB_TOKEN`은 사용자 소유 Projects(v2)를 쓸 수 없다.

## 결정

보드 Status를 `scripts/github/board-sync.sh` 하나가 정한 규칙으로 맞춘다. 규칙은 [development-workflow.md §2.1](../process/development-workflow.md#21-보드-자동화)에 있다.

1. **실행 지점**은 세 곳이다.
   - `board-sync.yml`: 사람이 만든 이슈 이벤트와 `pull_request_target` 이벤트
   - `issue-claim.yml`: `/claim`·`/unclaim` 처리 직후
   - `claim-expiry.yml`: 30분마다 만료 처리 뒤 보드 전체를 다시 맞춘다
2. **토큰**은 저장소 비밀 `PROJECT_TOKEN`이다.
   - **`project` scope 하나만** 준 classic personal access token이다. 만료는 90일 이하로 두고 갱신한다.
   - 보드 #4에만 Write로 초대한 **전용 머신 계정**에서 만드는 것을 권장한다. 메인테이너 계정에서 만들어도 동작하지만, 그 계정이 쓸 수 있는 모든 보드가 토큰 범위에 들어간다.
   - 메인테이너의 `gh` 로그인 토큰을 넣지 않는다. 권한이 너무 넓다.
3. 토큰이 없으면 워크플로우는 경고만 남기고 성공한다. 그동안은 메인테이너 세션이 로컬에서 `board-sync.sh reconcile`을 돌린다.
4. `pull_request_target`에서도 **기본 브랜치만 체크아웃**하고 PR 코드는 체크아웃하거나 실행하지 않는다. 이벤트에서는 이슈·PR 번호만 쓴다. 제목과 본문은 API로 읽고, 이슈 번호를 찾는 데만 쓴다.
5. **남이 움직일 수 없게 한다**(보안 검토 반영).
   - PR은 `<type>/<n>-<slug>` 브랜치의 이슈 하나만, 그 이슈의 담당자·메인테이너가 낸 경우나 담당자가 없을 때(PR 선착순)만 센다. `claim-expiry.sh`와 같은 규칙이다.
   - 자동 Ready에는 `type:*` 라벨이 있어야 한다. 이 라벨은 이슈 템플릿이나 트리아지만 붙일 수 있다. 외부인이 API로 만든 이슈는 들어오지 못하고, 템플릿으로 만든 이슈는 `status:triage`가 막는다.
   - 의존 이슈는 `pr-policy`처럼 메인테이너가 완료로 닫은 이슈만 끝난 것으로 본다.
   - 의존 이슈 조회에는 상한이 있다. `pr-policy`와 같이 20개를 넘으면 조회 없이 준비되지 않은 것으로 본다. 결과가 의존성에 따라 달라질 때만 조회한다. 404가 아닌 오류(한도 초과 등)는 "없음"으로 처리하지 않고 실행을 멈춘다.
   - 메인테이너가 아닌 사람의 이벤트는 동시성 그룹 하나를 공유한다.
   - PR 본문 수정은 트리거에서 뺀다.
   - 규칙은 `scripts/github/board-status.jq` 하나에 두고 `board-sync-rules.test.sh`로 CI에서 검사한다.
6. 사람의 판단이 필요한 이동은 자동화하지 않는다. 의존성이 없는 Backlog 이슈를 Ready로 올리는 일은 트리아지가 한다.

## 대안

| 대안 | 장점 | 단점 | 기각 이유 |
|---|---|---|---|
| 손으로 옮김(현행) | 토큰 없음 | 협업자가 못 옮김, 세션이 많으면 어긋남 | 동시 개발 규모에서 유지 불가 |
| 웹 UI 내장 Workflows만 | 토큰 없음 | Done·자동 추가만 가능 | 선점·리뷰 단계를 반영 못 함 |
| 보드 뷰 필터로 대신함(`no:assignee`) | 토큰 없음 | Status 값 자체는 틀린 채 남음. 뷰 설정을 API로 검증할 수 없음 | 보조 수단으로만 쓴다 |
| GitHub App | 토큰 수명 관리 쉬움 | 사용자 소유 Projects(v2)에 쓸 수 없음 | 적용 불가 |
| 메인테이너 `gh` 토큰을 비밀로 저장 | 설정 쉬움 | `repo`, `workflow` 등 넓은 권한 노출 | 최소 권한 위반 |

## 결과

- 좋아지는 점
  - 선점, Draft PR, Ready PR, 머지, 선점 만료가 몇 분 안에 보드에 반영된다. 늦어도 30분 주기 정리로 맞는다.
  - 협업자와 여러 세션이 같은 Ready 이슈를 고르는 일이 줄어든다.
  - 의존 이슈가 끝나면 그 이슈를 기다리던 Backlog 이슈가 자동으로 Ready가 된다.
- 나빠지는 점, 감수하는 비용
  - `project` 권한 토큰이 저장소 비밀에 있다. 새면 그 계정이 쓸 수 있는 보드가 바뀔 수 있다. 전용 머신 계정이면 보드 #4뿐이고, 메인테이너 계정이면 조직 보드까지다. 저장소 코드와 이슈에는 영향이 없다.
  - `pull_request_target`은 첫 기여자 승인 없이 실행된다. 공유 동시성 그룹이 외부 이벤트를 한 번에 하나씩만 처리해 API 소모에 상한을 둔다. 밀린 이벤트는 30분 정리가 따라잡는다.
  - 토큰 만료 시 동기화가 멈춘다(경고만 남는다). 갱신 일정을 둔다.
  - 토큰이 없으면 실행이 초록색으로 끝나 빠진 것을 알아채기 어렵다. 2026-11-13에 실제로 그랬다(#595). 그래서 경고와 함께 실행 요약에도 남긴다. GitHub `schedule`은 지연되거나 건너뛸 수 있어서, "30분 주기 정리"는 보장이 아니라 보조 수단이다.
  - 이슈를 연 사람은 본문의 의존성 절을 바꿔 자기 이슈의 Status에 영향을 줄 수 있다. 다만 다른 사람의 이슈는 바꿀 수 없다. Ready로 올리려면 `type:*` 라벨과 메인테이너가 닫은 의존 이슈가 있어야 한다.
  - PR 선착순 규칙(ADR-0013) 때문에 담당자 없는 이슈마다 맞는 브랜치로 PR을 열면 동시 선점 한도(2개)보다 많은 이슈가 In progress로 보일 수 있다. 기존 선점 정책과 같은 동작이라 받아들인다. 방치되면 메인테이너가 PR을 닫는다.
- 다시 검토해야 하는 조건
  - GitHub이 사용자 소유 Projects에 fine-grained token이나 App 접근을 지원할 때
  - 보드를 조직 소유로 옮길 때

## 후속 작업

- [ ] 메인테이너: `PROJECT_TOKEN` 생성·등록([github-settings.md §3](../process/github-settings.md#3-웹-ui에서만-할-수-있는-일))
- [x] 스크립트, 워크플로우, 절차 문서, 스킬 (#179)
