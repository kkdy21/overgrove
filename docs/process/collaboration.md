# 협업 규칙 (외부 기여, 이슈 선점, AI 기여)

> 상태: Accepted · 관련: [ADR-0013](../adr/0013-external-contributions-and-issue-claiming.md), [CONTRIBUTING.md](../../CONTRIBUTING.md), [issues.md](issues.md), [pull-requests.md](pull-requests.md)

이 문서는 메인테이너 외의 협업자(사람, 또는 Claude Code 같은 AI 에이전트를 쓰는 사람)가 이슈를 가져가 개발하는 규칙을 정한다. 영어 요약은 [CONTRIBUTING.md](../../CONTRIBUTING.md)에 있다.

## 1. 역할

| 역할 | 저장소 권한 | 하는 일 |
|---|---|---|
| 메인테이너 (@kkdy21) | admin | 이슈·범위·Phase 승인, AI 검수(`/pr-review`) 후 머지 |
| 협업자 | 없음 (fork 사용) | `/claim`으로 선점, fork에서 개발, PR 제출, 리뷰 대응 |
| 봇 (GitHub Actions) | `issues: write` | 선점 지정·해제, 선점 만료, PR 선착순 지정 |

## 2. 처음 시작하기 (Claude Code 기준)

```sh
gh auth login                                  # GitHub 로그인
gh repo fork kkdy21/overgrove --clone --remote # origin=내 fork, upstream=kkdy21/overgrove
cd overgrove
./scripts/bootstrap.sh                         # Git hooks 설치, 도구 점검
claude                                         # Claude Code 실행 → "/onboard"
```

`/onboard` 스킬이 하는 일:
1. 셋업 점검
2. 선점 가능한 이슈 목록 제시. 조건은 담당자 없음, Epic·blocked·undecided 아님, 의존 이슈 닫힘
3. 사용자가 고른 이슈에 `/claim` 댓글
4. `/issue-start`로 브랜치나 워크트리 생성
5. 첫 커밋 직후 `/pr-open --draft`

프로젝트 지침(`CLAUDE.md`), 권한, hooks, skills, agents가 저장소에 들어 있다. 그래서 클론만 하면 모든 협업자의 Claude Code가 같은 규칙으로 동작한다.

## 3. 이슈 선점 수명 주기

```mermaid
stateDiagram-v2
    [*] --> Open: 이슈 생성·트리아지
    Open --> Claimed: /claim (봇이 담당자 지정)
    Open --> Claimed: 담당자 없이 PR이 먼저 열림 (PR 선착순)
    Claimed --> InPR: 5시간 안에 Closes #n PR 열림 (Draft 가능)
    Claimed --> Open: 5시간 동안 PR 없음 (자동 해제)
    Claimed --> Open: /unclaim
    InPR --> Done: 메인테이너 squash 머지 → 이슈 자동 종료
    InPR --> Open: PR이 머지 없이 닫힘 (다음 주기에 해제)
    Done --> [*]
```

| 규칙 | 값 | 강제 수단 |
|---|---|---|
| 선점 | 이슈에 `/claim` 댓글(첫 단어) | `issue-claim.yml` |
| 해제 | `/unclaim` 또는 자동 만료 | `issue-claim.yml`, `claim-expiry.yml` |
| 선점 기한 | 선점 후 **5시간** 안에 PR(Draft 가능) | `claim-expiry.yml` (30분 주기) |
| 동시 선점 | 1인당 **2개** | `issue-claim.yml` |
| 선점 불가 | Epic, `status:blocked`, `status:needs-decision`, `status:triage`, 닫힌 이슈 | `issue-claim.yml` |
| 남의 이슈 PR | 실패 | `pr-policy` |
| 담당자 없는 이슈 | 먼저 열린 PR이 이긴다. 뒤에 열린 PR은 실패하고, `/claim`도 거부된다 | `pr-policy`, `issue-claim.yml`, `claim-expiry.yml` |
| 인정되는 PR | 열려 있고, `Closes #n`, `<type>/<n>-<slug>` 브랜치, 72시간 안에 갱신 | `claim-expiry.yml`, `pr-policy` |
| 재선점 제한 | 만료된 같은 이슈는 24시간 동안 다시 선점 불가 | `issue-claim.yml` |
| 메인테이너 | 기한·선점 검사 면제 | — |

- 시각은 봇 댓글의 UTC 마감 시각을 기준으로 한다. GitHub 스케줄 실행은 지연될 수 있어서 실제 해제는 마감보다 조금 늦을 수 있다.
- 5시간 안에 끝낼 필요는 없다. **5시간 안에 Draft PR만 열면** 선점이 유지된다. 이후에는 PR이 열려 있는 동안 계속 유지된다.
- PR이 72시간 넘게 갱신되지 않으면 선점이 풀린다. 다른 사람이 가져갈 수 있다.

## 4. 개발과 PR

- 브랜치는 fork에서 `<type>/<issue>-<slug>`로 만든다. 기준은 `upstream/main`이다.
- 커밋은 Conventional Commits, 영어 제목으로 쓴다. hook이 `Refs: #n`을 붙인다.
- PR 본문에 `Closes #n`, 템플릿 체크리스트, 검증 방법을 쓴다.
- **rebase와 강제 푸시는 필요 없다.** `main`이 앞서 나가면 `gh pr update-branch <n>`(또는 `git merge upstream/main`)을 쓴다. squash 머지라서 브랜치 안의 merge 커밋은 `main` 이력에 남지 않는다.
- "Allow edits by maintainers"를 켜 둔다. 메인테이너가 브랜치를 대신 최신화할 수 있다.
- 외부 기여자의 **첫 PR**은 메인테이너가 워크플로우 실행을 승인해야 필수 검사가 돈다. 두 번째 PR부터는 자동으로 돈다.

## 5. AI 기여 규칙

- AI로 만든 코드도 **제출한 사람이 책임진다.** 직접 읽고, 로컬에서 테스트하고, 설명할 수 있어야 한다.
- 큰 변경을 AI로 만들었다면 PR 본문에 `AI-assisted: <도구>`를 적는다. 커밋의 `Co-Authored-By` 트레일러도 허용한다.
- 저장소의 `CLAUDE.md`, hooks, 금지 규칙을 끄거나 우회하지 않는다. `--no-verify`, `core.hooksPath` 변경은 금지다.
- 이슈 하나에 PR 하나. AI가 범위를 넓히면 범위 밖 변경을 빼고 `later` 이슈로 제안한다.
- 같은 이슈를 여러 에이전트로 동시에 돌리지 않는다. 비교 실험은 자기 fork 안에서만 하고 PR은 하나만 올린다.

## 6. 메인테이너의 검수와 머지

- `/pr-review` 스킬이 다음을 점검하고 Conventional Comments로 리뷰를 남긴다.
  - 연결 이슈의 완료 조건, 선점, 필수 검사
  - 범위(`scope-guard`), 보안(`security-reviewer`), 테스트, 문서
- **모든 협업자 PR은 검수를 거친다.** 메인테이너 계정의 Approve 리뷰가 있어야 머지한다. 메인테이너가 판정을 확인하면 squash 머지(또는 auto-merge)한다. 머지 권한은 메인테이너에게만 있다.
- 리뷰 스레드는 코멘트 작성자가 resolve한다. 모든 스레드가 해결되어야 머지할 수 있다(룰셋).

## 7. 분쟁과 예외

- 선점이나 PR 선착순에 이견이 있으면 이슈에서 논의한다. 메인테이너가 담당자를 직접 바꿀 수 있다.
- 같은 이슈의 PR이 둘 이상 생기면 먼저 열린 PR을 리뷰한다. 뒤의 PR에서 좋은 부분은 앞 PR에 제안으로 옮긴다.
- 보안 문제는 이 흐름 밖에서 비공개로 제보한다([SECURITY.md](../../SECURITY.md)).
