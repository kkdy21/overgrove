# 브랜치와 커밋

> 상태: Accepted · 관련: [`.githooks/`](../../.githooks/), [`scripts/bootstrap.sh`](../../scripts/bootstrap.sh), [pull-requests.md](pull-requests.md)

## 1. 브랜치

```
<type>/<issue-number>-<slug>
```

| type | 쓰임 |
|---|---|
| `feat` | 기능 |
| `fix` | 버그 수정 |
| `docs` | 문서 |
| `test` | 테스트, 픽스처 |
| `chore` | 도구, 유지보수 |
| `spike` | 조사(머지하지 않는 것이 원칙) |
| `refactor` | 동작 변경 없는 구조 개선 |
| `perf` | 성능 |
| `ci` | 워크플로우, hooks |

- slug는 영어 소문자 kebab-case, 4단어 이내. 예: `feat/12-worktree-list`, `fix/31-rename-path-order`
- `main`은 보호된다. 직접 커밋, 직접 푸시, 강제 푸시가 모두 막혀 있다(룰셋, hooks, Claude Code hook).
- 오래 사는 브랜치를 만들지 않는다. 이슈가 크면 이슈를 쪼갠다.
- `main`이 앞서 나가면 GitHub의 "Update branch" 버튼이나 `git merge origin/main`으로 따라간다. squash merge라서 브랜치 안의 merge 커밋은 `main` 이력에 남지 않는다. 이미 푸시한 브랜치는 rebase하지 않는다(강제 푸시가 필요해지므로).

## 2. 커밋 메시지

[Conventional Commits](https://www.conventionalcommits.org/) 형식, **영어**로 쓴다.

```
feat(parser): parse porcelain v2 rename records

Rename records carry two paths separated by NUL; the original path comes second.

Refs: #12
Co-Authored-By: Claude <noreply@anthropic.com>
```

| 요소 | 규칙 |
|---|---|
| type | `feat`, `fix`, `docs`, `test`, `refactor`, `perf`, `chore`, `ci`, `build`, `style`, `revert` |
| scope | 선택. 소문자. 예: `parser`, `git`, `ui`, `security`, `ci`, `docs` |
| 제목 | 명령형 현재 시제, 끝에 마침표 없음, 100자 이내 |
| 본문 | 선택. **무엇을 왜** 바꿨는지 쓴다 |
| `!` | 호환성을 깨는 변경. 예: `feat(parser)!: ...` |
| 트레일러 | `Refs: #n`(hook이 자동 추가), 공동 작성자면 `Co-Authored-By:` |

PR이 squash되면 `main`에는 PR 제목이 커밋 제목으로 남는다. 그러니 브랜치 안의 커밋 메시지보다 **PR 제목이 더 중요하다.**

## 3. Git hooks

`./scripts/bootstrap.sh`가 `core.hooksPath=.githooks`를 설정한다. 모든 워크트리에 적용된다.

| hook | 하는 일 | 실패 시 |
|---|---|---|
| `pre-commit` | `main` 직접 커밋 차단, staged 변경 gitleaks 검사, Swift 파일의 금지 API 검사 | 커밋 중단 |
| `prepare-commit-msg` | 브랜치명의 이슈 번호로 `Refs: #n` 트레일러 추가(메시지에 이미 있으면 생략) | — |
| `commit-msg` | Conventional 헤더와 길이 검사(merge, revert, fixup 메시지는 예외) | 커밋 중단 |
| `pre-push` | `main` 직접 푸시 차단, 푸시할 커밋 전체를 gitleaks로 검사 | 푸시 중단 |

- gitleaks가 없으면 커밋과 푸시가 막힌다(`brew install gitleaks`).
- `--no-verify`로 hook을 우회하지 않는다. CI의 `gitleaks` 검사가 같은 규칙으로 다시 확인한다.
- 오탐이면 원인을 고친다. 예를 들어 테스트용 가짜 자격 증명은 런타임에 조합한다. 어쩔 수 없을 때만 해당 줄에 `gitleaks:allow` 주석을 달고, 이유를 PR에 쓴다.
- `OVERGROVE_ALLOW_MAIN_COMMIT=1`, `OVERGROVE_ALLOW_MAIN_PUSH=1`은 저장소 초기화 같은 메인테이너의 예외 작업용이다. Claude Code는 이 변수를 쓸 수 없다(hook이 차단). `main` 푸시는 어차피 GitHub 룰셋이 거부한다.

## 4. 커밋 서명 (선택)

서명된 커밋을 권장하지만 필수는 아니다. SSH 서명 예:

```sh
git config --local gpg.format ssh
git config --local user.signingkey ~/.ssh/<your-signing-key>.pub
git config --local commit.gpgsign true
```

GitHub 계정에 같은 키를 "Signing key"로 등록하면 `Verified`로 표시된다.
