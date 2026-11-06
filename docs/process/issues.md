# 이슈 규칙

> 상태: Accepted · 관련: [development-workflow.md](development-workflow.md), [`.github/ISSUE_TEMPLATE/`](../../.github/ISSUE_TEMPLATE/), [`.github/labels.json`](../../.github/labels.json), [qa/bug-triage.md](../qa/bug-triage.md)

## 1. 템플릿

빈 이슈는 막혀 있다(`blank_issues_enabled: false`). 아래 템플릿 중 하나를 고른다.

| 템플릿 | 제목 접두사 | 자동 라벨 | 언제 |
|---|---|---|---|
| Feature | `feat:` | `type:feature`, `status:triage` | 범위 안의 새 기능 |
| Bug report | `fix:` | `type:bug`, `status:triage` | 명세와 다른 동작 |
| Spike | `spike:` | `type:spike`, `status:triage` | 시간 상자를 둔 조사 |
| Decision | `decision:` | `type:decision`, `status:needs-decision` | ADR 후보 결정 |
| Documentation | `docs:` | `type:docs`, `area:docs`, `status:triage` | 문서 추가·수정 |
| Chore | `chore:` | `type:chore`, `status:triage` | 도구, CI, 유지보수 |

보안 취약점과 Code of Conduct 신고는 템플릿 선택 화면의 링크를 따라 **비공개 경로**로 보낸다.

## 2. 제목과 본문

- **제목은 영어 Conventional 형식**으로 쓴다. 나중에 PR 제목과 squash 커밋 제목으로 이어지기 쉽다.
  - 좋음: `feat(parser): parse porcelain v2 rename records`
  - 나쁨: `파서 수정`, `Fix stuff`
- **본문은 한국어 또는 영어**로 쓴다(ADR-0005).
- **완료 조건**은 검증 가능한 체크리스트로 쓴다. "잘 동작한다" 대신 "PAR-STATUS-07 테스트 통과"처럼 쓴다.
- 관련 식별자를 적는다: 목표 G·비목표 N, 화면 S-xx, 위협 T-xx, 테스트 ID, ADR 번호([docs/README.md §2](../README.md)).
- **의존성**은 본문 마지막의 `## 의존성` 절에 `- #n 제목` 형식으로 적는다. 없으면 `- 없음`이라고 쓴다. `pr-policy`와 `dependency-closed` 워크플로우가 이 절의 `#번호`를 읽으므로, 의존성이 아닌 관련 이슈는 "참고"에 적는다(ADR-0014).
- 공개 저장소다. 토큰, 개인 경로, 비공개 저장소 이름, 고객 정보는 쓰지 않는다.

## 3. 라벨

원본은 [`.github/labels.json`](../../.github/labels.json)이고, `scripts/github/sync-labels.sh --prune`으로 저장소에 반영한다.

| 그룹 | 값 | 규칙 |
|---|---|---|
| `type:` | feature, bug, spike, decision, docs, test, chore, epic | 정확히 1개 |
| `phase:` | plan, design, dev, qa, release | 정확히 1개 |
| `area:` | git-core, parser, ui, github, security, ci, docs | 1개 이상 |
| `priority:` | p0, p1, p2 | 트리아지 후 1개 |
| `status:` | triage, blocked, needs-decision | 해당할 때만. `blocked`는 외부 요인을 기다릴 때만 쓴다. 다른 이슈를 기다리는 것은 `## 의존성` 절로 표시하고 선점을 막지 않는다 |
| `resolution:` | duplicate, wontfix, invalid | 종료 사유가 있을 때 |
| 기여 유도 | `good first issue`, `help wanted` | 외부 기여에 적합할 때 |

`area:security`가 붙은 이슈의 PR은 보안 체크리스트와 `security-reviewer` 검토가 필수다.

## 4. 마일스톤

| 마일스톤 | 의미 |
|---|---|
| `v0.1.0` | MVP: 조회 전용 대시보드와 보안 기반 |
| `v0.2.0` | 보안·설정 강화, MVP 피드백 반영 |
| `later` | 범위 밖 아이디어 보관소. 일정 없음 |

범위 밖 요청(쓰기 작업, PR 상태, GHE 등)은 거절하지 않고 `later`로 받는다. 구현은 범위를 다시 정할 때 한다.

## 5. Epic과 하위 이슈

- Epic 제목: `[EPIC] Phase N — <영문 요약>`, 라벨 `type:epic` + 해당 `phase:`
- 하위 이슈는 **GitHub 네이티브 sub-issue**로 연결하고, Epic 본문에도 task list(`- [ ] #12`)를 둔다.
- Epic은 하위 이슈가 모두 닫히고 Phase 승인([phase-gates.md](phase-gates.md))을 받으면 닫는다.
- 전체 Epic과 하위 이슈 목록은 [roadmap.md](../roadmap.md)에 있다.

## 6. 트리아지

새 이슈(`status:triage`)는 주 1회 이상 정리한다. Claude Code에서는 `/issue-triage`를 쓴다.

1. 유효성 확인: 재현 정보가 부족하면 질문한다. 14일간 응답이 없으면 `resolution:invalid`로 닫는다.
2. 중복 확인: 중복이면 원본을 링크하고 `resolution:duplicate`로 닫는다.
3. 범위 판단: 범위 밖이면 `later`로 보낸다.
4. 라벨 확정: type, phase, area, priority. bug면 심각도와 priority를 매핑한다([bug-triage.md](../qa/bug-triage.md)).
5. 완료 조건과 `## 의존성` 절 보강 → `status:triage` 제거 → 보드 Backlog 또는 Ready(의존 이슈가 모두 끝났으면)

## 7. 종료 규칙

- 정상 종료는 PR 머지 시 `Closes #n`으로 자동으로 닫힌다. 직접 닫지 않는다.
- PR 없이 닫을 때(중복, 무효, 하지 않음)는 `resolution:*` 라벨과 사유 코멘트를 남긴다.
- 스파이크는 결과 코멘트와 후속 이슈·ADR 링크를 남긴 뒤 닫는다.

## 8. 선점 (`/claim`)

메인테이너가 아닌 협업자는 이슈에 `/claim` 댓글을 달아 담당자가 된 뒤 작업한다. 선점 후 **5시간 안에** `Closes #n` PR(Draft 가능)이 없으면 자동으로 해제된다. 동시 선점은 1인당 2개이고, 담당자 없는 이슈는 PR 선착순이다. 상세는 [collaboration.md](collaboration.md)와 ADR-0013에 있다.

## 9. 코멘트 규칙

- 진행 상황, 결정, 막힌 점은 이슈 코멘트에 남긴다. 채팅이나 로컬 메모에만 두지 않는다.
- 결정이 내려지면 결정 내용을 한 문단으로 요약한 코멘트를 남기고, 필요하면 ADR을 링크한다.
- 리뷰 코멘트 규약은 [pull-requests.md §5](pull-requests.md#5-리뷰와-코멘트-규약)를 따른다.
