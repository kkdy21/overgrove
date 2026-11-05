# PR 규칙

> 상태: Accepted · 관련: [ADR-0012](../adr/0012-solo-maintainer-merge-policy.md), [`.github/pull_request_template.md`](../../.github/pull_request_template.md), [`.github/workflows/pr-policy.yml`](../../.github/workflows/pr-policy.yml)

## 1. PR을 열기 전에

- 이슈가 있고 열려 있어야 한다. 브랜치명은 `<type>/<issue>-<slug>`.
- 로컬 점검을 통과해야 한다. Claude Code에서는 `/pr-open`이 자동으로 수행한다.
  - `scripts/lint/check-forbidden-apis.sh`
  - `gitleaks git --log-opts="origin/main..HEAD" .`
  - (Phase 3 이후) `swift format lint --strict`, `xcodebuild test`
- 변경이 이슈 하나의 범위인지 확인한다. 범위 밖 변경은 빼서 새 이슈로 보낸다.

## 2. 제목과 본문

| 항목 | 규칙 | 검사 |
|---|---|---|
| 제목 | 영어 Conventional Commits. squash 커밋 제목이 된다. 100자 이내 | `pr-policy` |
| 본문 | `Closes #<n>` 필수. 대상은 열린 **이슈**여야 한다(PR 번호 불가) | `pr-policy` |
| 브랜치 | `<type>/<issue>-<slug>`. 브랜치의 이슈 번호가 `Closes` 대상에 포함되어야 한다 | `pr-policy` |
| 템플릿 | 요약, 검증 방법, 체크리스트, 보안 영향을 채운다 | 리뷰 |
| 라벨·마일스톤 | 이슈와 같게. 보안 영향이 있으면 `area:security` | 리뷰 |
| UI 변경 | 라이트·다크 스크린샷 첨부 | 리뷰 |

Dependabot PR은 이슈 연결 규칙에서 예외다(`pr-policy`가 자동으로 통과시킨다).

`pr-policy`는 선점 규칙(ADR-0013)도 검사한다. 남이 선점한 이슈를 닫는 PR, 또는 담당자 없는 이슈에 먼저 열린 PR이 이미 있는데 뒤에 열린 PR은 실패한다. 메인테이너는 면제다.

## 3. 필수 상태 검사

`main` 룰셋이 아래 세 검사의 통과를 요구한다. 브랜치는 최신 `main` 기준이어야 한다(strict).

| 검사 | 워크플로우 | 내용 |
|---|---|---|
| `gitleaks` | `secret-scan.yml` | PR 커밋 범위의 비밀 정보·개인 경로 검사 |
| `pr-policy` | `pr-policy.yml` | 제목, 연결 이슈, 브랜치명 |
| `build-test` | `ci.yml` | 도구 검증, 픽스처 스모크, (Phase 3 이후) swift-format lint, 빌드와 테스트 |

`codeql`은 필수가 아니지만, 경고가 나오면 머지 전에 확인한다.

## 4. 머지 정책 (ADR-0012)

- **squash merge만 허용**한다. merge commit과 rebase merge는 꺼져 있다.
- squash 커밋 제목은 PR 제목, 본문은 PR 본문이다. 그래서 `main` 이력에 `Closes #n`이 남는다.
- 머지 후 브랜치는 자동으로 삭제된다.
- 필수 승인 수는 0이다. 1인 메인테이너라서 본인 PR을 승인할 수 없기 때문이다. 대신 다음을 요구한다.
  - 필수 검사 3개 통과
  - **모든 리뷰 스레드 해결**(conversation resolution)
  - 보안 영향 PR은 `security-reviewer` 에이전트 검토 결과를 PR 코멘트로 남긴다
- 강제 푸시, `main` 삭제, 비선형 이력은 룰셋이 막는다. 우회 권한(bypass)을 가진 사람은 없다.
- 외부 기여는 fork PR로 받고 머지는 메인테이너만 한다(ADR-0013). 협업자에게 머지 권한이 없으므로 승인 0 룰셋을 유지한다. 메인테이너의 검수는 `/pr-review`로 AI의 도움을 받을 수 있다.
- 외부 기여자의 첫 PR은 메인테이너가 워크플로우 실행을 승인해야 검사가 돈다(`first_time_contributors`).

## 5. 리뷰와 코멘트 규약

리뷰 코멘트는 [Conventional Comments](https://conventionalcomments.org/) 라벨로 시작해서 의도를 분명히 한다.

| 라벨 | 의미 | 머지 차단 |
|---|---|---|
| `issue:` | 고쳐야 하는 문제 | 예 |
| `security:` | 보안 문제(T-ID 함께) | 예 |
| `suggestion:` | 개선 제안 | 아니오. `(blocking)`을 붙이면 예 |
| `question:` | 이해를 위한 질문 | 답할 때까지 |
| `nitpick:` | 사소한 취향 | 아니오 |
| `todo:` | 머지 전에 해야 할 작은 일 | 예 |
| `praise:` | 좋은 점 | 아니오 |

예: `security (T9): 브랜치명이 '--'보다 앞에 들어갑니다. 'refs/heads/-x' 같은 이름이면 옵션으로 해석됩니다.`

- 스레드는 **코멘트 작성자가 resolve한다.** 작성자가 외부인이고 응답이 없으면 메인테이너가 resolve한다.
- 리뷰에서 범위 밖 제안이 나오면 이 PR에서 하지 않는다. `later` 이슈 링크를 남기고 스레드를 닫는다.
- 결정이 필요한 논쟁은 PR에서 끝내지 않고 `type:decision` 이슈로 옮긴다.

## 6. 보안 영향 PR

다음 경로를 건드리거나 `area:security`가 붙은 PR이 대상이다.
- `Overgrove/Execution/`, `Git/`, `GitHub/`, `Parsing/`, `Security/`
- `.github/workflows/`, `.githooks/`, `.claude/hooks/`, `.gitleaks.toml`

대상 PR은 다음을 지킨다.
1. PR 템플릿의 "Security impact" 체크리스트를 모두 확인한다.
2. `security-reviewer` 에이전트 결과(판정과 발견 사항 표)를 PR 코멘트로 남긴다.
3. 위협 대응이 바뀌면 [security-review.md](../design/security-review.md)와 SEC 테스트를 같은 PR에서 갱신한다.

## 7. 외부 PR을 안전하게 검토하기

- **외부 PR을 로컬에 체크아웃하지 않는다.** `core.hooksPath=.githooks`가 상대 경로라서, 체크아웃하면 PR이 넣은 hook이 메인테이너 PC에서 실행된다. PR의 `.claude/` 설정, 스크립트, 테스트도 마찬가지로 실행하지 않는다.
- 내용은 `git -c core.hooksPath=/dev/null fetch origin pull/<n>/head:refs/remotes/pr/<n>`으로 가져와 `git diff`, `git show`로 읽는다. 테스트는 CI가 맡는다.
- 하네스 hook이 `gh pr checkout`과 보호 없는 PR ref fetch를 막는다. `/pr-review` 스킬은 이 절차를 따른다.

## 8. 오래된 PR

- 협업자 PR은 72시간 동안 갱신이 없으면 선점이 자동으로 풀린다(ADR-0013). 메인테이너는 상태를 묻거나 PR을 닫는다.
- 메인테이너 자신의 PR은 14일간 움직임이 없으면 다시 검토한다.
- Draft PR은 조기 피드백용이다. 필수 검사는 Draft에서도 돈다.
