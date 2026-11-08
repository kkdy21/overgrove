# ADR-0021: v0.1 이후에도 조회 전용을 유지하고, 원격 쓰기는 `git fetch` 하나만 둔다

> 상태: Accepted · 날짜: 2026-11-06 · 관련: #155, #111, #112, #113, #114, #156, #124, N3, N4, ADR-0008, ADR-0009, ADR-0011

## 맥락

v0.1.0은 조회와 `git fetch`만 한다(N3, N4, [ADR-0011](0011-no-pull-in-v0-1.md)). #155는 그다음에 어떤 쓰기 작업을 앱에 넣을지 물었다. 판단에 쓴 제약은 다음과 같다.

- **역할 분담.** AI 주도 개발에서는 코딩, 커밋, PR 같은 쓰기를 에이전트가 각 워크트리에서 한다. 사람에게 필요한 것은 여러 워크트리를 한눈에 보는 관제와 검토다. 이것이 Overgrove의 자리다.
- **잠금 충돌.** 에이전트가 작업 중인 워크트리에 앱이 쓰면 `index.lock`이 충돌하고 작업이 꼬인다. 조회는 index를 쓰지 않는다: `--no-optional-locks`, `GIT_OPTIONAL_LOCKS=0`, `-c diff.autoRefreshIndex=false`를 함께 건다([security-review.md T13](../design/security-review.md#t13-의도치-않은-쓰기-명령-실행), #208).
- **hooks를 끈다.** 앱은 신뢰할 수 없는 저장소를 다루려고 hooks, fsmonitor, 필터, 외부 diff를 무력화한다([ADR-0008](0008-git-invocation-model.md), [ADR-0009](0009-repo-config-neutralization.md)). commit처럼 hooks에 기대는 작업을 앱에서 하면 저장소의 안전장치(gitleaks, 커밋 형식 검사)를 우회하게 된다.
- **실행 경로가 늘어난다.** pull, checkout, merge, stash apply는 merge driver, 필터, 작업 트리 쓰기를 부른다. 위협 모델(T1–T19)과 명령 allowlist(`ReadOnlyGitCommand`, `FetchCommand`)가 그만큼 넓어진다.
- **정리 작업도 안전하지 않다.** `git worktree remove`는 `--force` 없이도 ignored 파일을 확인 없이 지운다(#156에 재현 기록). 깨끗해 보이는 워크트리에도 `.env`, 로컬 DB, 빌드 캐시가 남아 있을 수 있다.

## 결정

**Overgrove는 v0.1 이후에도 조회 전용이다. 원격에 쓰는 명령은 `git fetch` 하나뿐이다.** 커밋, push, pull, 워크트리 정리까지 모든 git 쓰기는 AI 에이전트와 터미널이 맡는다. (메인테이너 결정, 2026-11-06. #155 선택지 A)

1. 쓰기 명령은 타입으로 만들지 않는다. `ReadOnlyGitCommand`와 `FetchCommand` 밖의 git 명령, 그리고 `git-command-catalog.md`에 없는 명령은 추가하지 않는다(CLAUDE.md §2 규칙 3, ADR-0008).
2. 로컬 쓰기도 같다. 워크트리 remove·prune, stash drop처럼 에이전트와 겹치지 않아 보이는 정리 작업도 앱에서 실행하지 않는다.
3. 앱이 git을 실행하지 않는 보조 기능(명령 복사, 터미널 열기)은 git 쓰기 범위와 충돌하지 않는다. 실행은 사용자가 자기 도구에서 한다. 다만 이런 기능은 앱의 보안 인자가 걸리지 않는 곳으로 사용자를 보내므로, 기존 규칙을 따른다: 터미널은 `TerminalGuard`가 설정 finding마다 확인하고(T14, #278), 복사용 명령은 hook이 있으면 내보내지 않으며(T5), 클립보드 값은 제어·bidi 문자를 이스케이프하고(T14), 스냅샷 상태에서는 터미널을 막는다(T19). 에디터 열기처럼 새 외부 앱 연동은 착수 전에 보안 검토가 필요하다(#124).
4. 앞으로 쓰기 기능을 넣으려면 먼저 다음이 있어야 한다.
   - 이 ADR을 대체하는 새 `type:decision` 이슈와 ADR
   - 그 명령의 보안 설계: hooks·merge driver·필터를 어떻게 다루는지, 위협 모델과 카탈로그 갱신, 보안 테스트(SEC-T*)

## 대안

| 대안 | 장점 | 단점 | 기각 이유 |
|---|---|---|---|
| A — 조회 전용(+fetch) 유지 | 실행 경로와 공격 면적이 늘지 않는다. 에이전트 워크트리의 index 잠금과 충돌하지 않는다 | 사용자는 정리·pull을 터미널에서 해야 한다 | **채택** |
| B — 에이전트와 겹치지 않는 로컬 정리(워크트리 remove·prune, stash drop) | 관제 화면에서 바로 정리할 수 있다 | `worktree remove`가 ignored 파일을 확인 없이 지운다(#156). 쓰기 명령 타입이 생긴다 | 데이터 손실 위험, 앱의 역할 밖 |
| C — B + `pull --ff-only`(에이전트가 쓰지 않는 워크트리에서만) | 충돌이 없는 동기화 | 작업 트리를 쓰고 checkout 계열 실행 경로(필터, hooks)가 생긴다. "에이전트가 쓰지 않는다"를 앱이 알 수 없다 | ADR-0011과 같은 이유 |
| D — 일반 Git 클라이언트 수준(commit, push 등) | 한 앱에서 모든 작업 | hooks를 끈 채 commit하면 저장소 안전장치를 우회한다. 기존 Git 클라이언트와 겹친다 | N3·N4, 제품 정체성 |

## 결과

- 실행 경로가 지금의 조회 명령과 fetch로 한정된다. 위협 모델과 명령 allowlist를 넓히지 않는다.
- 에이전트가 쓰는 워크트리의 index 잠금과 충돌하지 않는다. fetch는 공통 디렉터리의 ref·`packed-refs`·`FETCH_HEAD` 잠금을 잡으므로(T13의 허용된 쓰기), 에이전트의 fetch·push와 겹치면 ref 잠금 충돌은 여전히 날 수 있다.
- 사용자는 pull, 스테이징, rebase, stash 적용, 워크트리 정리를 터미널이나 에이전트에게 맡겨야 한다. 앱은 그 전후 상태를 보여 준다.
- 다음 later 이슈는 `later`에 그대로 둔다. 착수하려면 결정 4의 새 ADR과 보안 설계가 먼저 필요하다.
  - #111 pull (ADR-0011의 조건도 그대로 적용)
  - #112 스테이징 토글
  - #113 인터랙티브 rebase
  - #114 stash apply·pop·drop
  - #156 워크트리 정리
- 다시 검토하는 조건: 쓰기 작업에 대한 반복된 사용자 요청이 있고, 그 작업을 hooks를 끈 상태로도 안전하게 할 설계가 나왔을 때. 새 decision 이슈로 시작한다.

## 후속 작업

- [x] #156을 `later`로 이동 (#155)
- [x] roadmap.md §9의 V2-07을 결정 완료로 표시하고 이 ADR에 연결
- [x] scope-mvp.md 제외 범위의 N3·N4 행에 이 ADR 연결
