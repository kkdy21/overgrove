# Claude Code 하네스

> 상태: Accepted · 관련: [CLAUDE.md](../../CLAUDE.md), [`.claude/`](../../.claude/)

Overgrove는 Claude Code로 개발한다. 하네스(프로젝트 지침, 권한, hooks, skills, agents)는 저장소에 커밋되어 있다. 그래서 누가 이 저장소에서 Claude Code를 열어도 같은 규칙이 적용된다.

## 1. 구성

```
CLAUDE.md                     # 프로젝트 지침 (매 세션 자동 로드)
.claude/
├── settings.json             # 권한(allow/ask/deny)과 hooks 등록 — 커밋됨
├── settings.local.json       # 개인 설정 — .gitignore로 제외
├── hooks/
│   ├── guard-bash.sh         # PreToolUse(Bash): 위험한 git·gh 명령 차단
│   ├── guard-edit.sh         # PreToolUse(Edit|MultiEdit|Write): 코드·문서 쓰기 검사
│   └── session-context.sh    # SessionStart: 브랜치·이슈 컨텍스트 주입
├── skills/                   # /이름 으로 호출하는 작업 절차
│   ├── onboard/  issue-new/  issue-triage/  issue-start/  pr-open/  pr-review/
│   └── adr-new/  phase-gate/  discussion-to-issue/
└── agents/                   # 전문 서브에이전트 (읽기 전용)
    ├── security-reviewer.md  scope-guard.md  parser-test-designer.md
```

## 2. 권한 (`settings.json`)

| 구분 | 예 | 의도 |
|---|---|---|
| allow | `git status/diff/log/show`, `gh issue/pr view·list`, `swift format lint`, `xcodebuild build/test`, `gitleaks`, 픽스처 스크립트 | 읽기와 로컬 검증은 묻지 않는다 |
| ask | `git push`, `gh issue/pr create·edit·comment·merge`, `gh release`, `gh project`, `gh api`, `scripts/github/*` | 공개 저장소에 쓰는 작업은 매번 확인한다 |
| deny | 강제 푸시, `--no-verify`, `gh repo delete/archive`, `gh secret`, `gh auth token`, `.env`·인증서 읽기 | 하네스 안에서는 절대 하지 않는다 |

## 3. Hooks

hook은 **실수를 막는 장치이지 보안 경계가 아니다.** 같은 규칙을 Git hooks, CI, GitHub 룰셋이 서버 쪽에서 다시 강제한다.

### `guard-bash.sh` — 차단하는 명령

- hook 우회: `--no-verify`, `git commit -n`, `core.hooksPath` 변경, `OVERGROVE_ALLOW_MAIN_*` 사용
- 강제 푸시, `main` 대상 푸시, `main`에서의 인자 없는 `git push`
- `main` 브랜치에서의 `git commit`
- `gh repo delete/archive/rename`, 공개 범위 변경, `gh secret/variable`, `gh auth token/logout/refresh`, `gh api`를 통한 DELETE와 룰셋 변경
- 루트·홈·`.git` 삭제

### `guard-edit.sh` — 막는 쓰기

- `.swift` 파일: `Overgrove/Execution/`(와 `OvergroveTests/Support/`) 밖에서 프로세스·셸 API 사용. 검사는 `scripts/lint/check-forbidden-apis.sh`
- 모든 파일: 비밀 정보나 개인 홈 경로. `gitleaks stdin`에 저장소 `.gitleaks.toml`을 적용한다
- 워크플로우: SHA로 고정되지 않은 `uses:`
- `HANDOFF.md` 수정(보관 문서)

### `session-context.sh`

세션을 시작할 때 다음 정보를 Claude 컨텍스트에 넣는다.
- 현재 브랜치와 이슈 번호
- `main`에 있으면 경고
- Git hooks 미설치, gitleaks 미설치 경고
- 커밋하지 않은 변경 수

### hook 고치기

hook을 바꾸는 PR은 보안 영향 PR이다([pull-requests.md §6](pull-requests.md#6-보안-영향-pr)). 바꾼 뒤에는 차단·허용 사례를 직접 실행해 확인하고, 결과를 PR에 붙인다. 예:

```sh
printf '{"tool_input":{"command":"git push --force"},"cwd":"%s"}' "$PWD" | .claude/hooks/guard-bash.sh; echo "exit=$?"   # 2 = 차단
```

## 4. Skills

| skill | 언제 | 핵심 |
|---|---|---|
| `/onboard` | 협업자 첫 참여 | 셋업 점검(fork·remote·hooks) → 선점 가능 이슈 제시 → `/claim` → `/issue-start` |
| `/issue-new` | 새 이슈, 범위 밖 아이디어 기록 | 중복 확인 → 템플릿 형식 초안 → **승인** → 생성, sub-issue·보드 연결 |
| `/issue-triage` | `status:triage` 정리 | 라벨·마일스톤·완료 조건 제안 → 승인 → 반영 |
| `/issue-start` | 이슈 작업 시작 | 이슈 상태 확인 → 브랜치/워크트리 → 담당자·보드 갱신 → 테스트 우선 계획 |
| `/pr-open` | PR 열기 | 자체 점검 → 보안·범위 리뷰 에이전트 → 템플릿 본문 → **승인** → push(협업자는 fork)·PR(Draft 가능) → 검사 확인 |
| `/pr-review` | (메인테이너) PR 검수 | 선점·검사·범위·보안·테스트 점검 → Conventional Comments 리뷰 → 확인 후 squash 머지 |
| `/adr-new` | 결정 기록 | 다음 번호, 템플릿, 인덱스·문서·이슈 연결 |
| `/phase-gate` | Phase 종료 | 산출물·자동 점검·이슈·보안 체크리스트 보고서 → 승인 요청 |
| `/discussion-to-issue` | 토론 정리 | 결론 요약 → 이슈·ADR 초안 → **승인** → 생성, Discussion에 결론 코멘트 |

## 5. Agents

모두 **읽기 전용**이다(파일 수정 없음). 결과를 PR 코멘트나 계획에 반영하는 일은 메인 에이전트가 한다.

| agent | 언제 | 산출물 |
|---|---|---|
| `security-reviewer` | 보안 영향 PR 전 | 판정(통과/조건부/차단), T-ID별 발견 사항 표 |
| `scope-guard` | 범위가 커 보일 때, 새 기능 제안 | in-scope / creep / non-goal 위반 / later 후보 분류 |
| `parser-test-designer` | 파서 작업 전, 파서 PR 리뷰 | 실제 출력 기반 적대적 테스트 케이스 표(PAR-ID) |

## 6. 개인 설정

개인 취향(모델, 출력 스타일, 추가 허용 명령)은 `.claude/settings.local.json`에 둔다. 이 파일은 커밋되지 않는다. 프로젝트 `deny` 규칙과 hooks는 개인 설정으로 풀지 않는다.
