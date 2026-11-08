# ADR-0025: GitHub 호스트는 gh에 로그인된 것만 신뢰하고, 계정은 앱이 바꾸지 않는다

> 상태: Accepted · 날짜: 2026-11-08 · 관련: #446, #117, ADR-0004, ADR-0021, ADR-0023, T9, T11, T16, [git-command-catalog.md §5](../architecture/git-command-catalog.md#5-ghcommand-gh-allowlist)

## 맥락

[ADR-0004](0004-github-integration-gh-issues-only.md) §8은 호스트를 `github.com`만 지원하고 GitHub Enterprise(GHE)를 `later`로 미뤘다. v0.2.0(#117)에서는 GHE 호스트의 저장소에도 이슈·PR 정보를 보이고, gh에 계정이 여럿일 때 어느 계정으로 보는지 알리려고 한다.

판단에 쓴 사실과 제약은 다음과 같다.

- gh 2.95.0은 `--repo [HOST/]OWNER/REPO`로 호스트를 고른다(`gh issue list --help`). `gh auth status --json hosts`는 호스트별 계정 목록과 각 계정의 `active`·`login`·`state`를 준다.
- 원격 URL은 저장소 설정이다. 저장소가 원격을 아무 호스트로 바꿔 둘 수 있다. 그 호스트를 그대로 gh에 넘기면, 사용자가 그 호스트에 로그인해 두었을 때 gh가 그 호스트의 토큰으로 요청한다.
- `gh auth switch`는 사용자의 gh 설정(활성 계정)을 바꾸는 쓰기다. 앱은 사용자의 도구 설정을 바꾸지 않는다([ADR-0021](0021-read-only-scope-after-v0-1.md)). 토큰은 받지도 저장하지도 않는다(ADR-0004 §1).

## 결정

ADR-0004 §8("github.com만")만 이 결정으로 대체한다. gh 위임, 토큰 비취급, 중립 작업 디렉터리, `--repo` 명시, 환경 하드닝은 ADR-0004 그대로다.

1. **신뢰하는 호스트.** `github.com`과, `gh auth status --json hosts`에 있는 호스트(사용자가 gh로 로그인한 호스트)만 GitHub 호스트로 본다. 저장소의 원격 URL만으로는 새 호스트를 신뢰하지 않는다. 로그인하지 않은 호스트를 가리키는 원격은 지금처럼 `No GitHub remote`다. 로그인 목록을 읽기 전이나 읽지 못했을 때는 `github.com`만 신뢰한다.
2. **원격 판별.** 원격 URL에서 다음 세 형태만 인식한다. 비교는 UTF-8 바이트로 하고, `url.<base>.insteadOf`는 지금처럼 보지 않는다.
   - `https://HOST/OWNER/NAME(.git)?`
   - `git@HOST:OWNER/NAME(.git)?`
   - `ssh://git@HOST(:PORT)?/OWNER/NAME(.git)?` (포트는 받아들이되 호스트 판단에는 쓰지 않는다)

   HOST는 소문자로 바꾼 ASCII DNS 이름만 받는다. 라벨은 1–63자의 영숫자와 `-`(앞뒤 `-` 금지)이고, 전체는 253자 이하다. IP 주소 리터럴, 사용자 정보(`user:pass@`), 경로·쿼리가 섞인 값은 받지 않는다. OWNER·NAME은 기존 `GitHubRepository` 규칙 그대로다. `GitHubRepository`에 `host`를 더하고 기본값은 `github.com`이다.
3. **gh 호출.** 호스트는 `--repo`로만 고른다. `github.com`이면 지금처럼 `OWNER/NAME`, 그 밖이면 `HOST/OWNER/NAME`이다. `GH_HOST`, `GH_ENTERPRISE_TOKEN`, `GH_TOKEN` 같은 변수는 환경 allowlist에 넣지 않는다. 중립 작업 디렉터리와 실행 제한은 그대로다.
4. **계정.** 앱은 gh 계정을 바꾸지 않는다. 호스트마다 `active` 계정을 상태바의 gh 항목과 이슈 패널 머리에 `login@host`로 보인다. 같은 호스트에 계정이 여럿이면 `+n more`와 함께 복사용 명령 `gh auth switch --hostname HOST`를 둔다. 이 명령은 [ADR-0021](0021-read-only-scope-after-v0-1.md) 결정 3의 클립보드 규칙을 따른다. HOST는 결정 2를 통과한 값만 넣고, 제어·서식(bidi) 문자는 이스케이프한다. login은 표시만 하고 명령에 넣지 않는다.
5. **링크.** 이슈 URL, PR URL, Open on GitHub(#398)의 호스트 검사를 "github.com 고정"에서 "그 저장소의 HOST와 같고 https"로 넓힌다. PR URL은 [ADR-0023](0023-pull-request-status-from-gh-pr-list.md)처럼 HOST·OWNER·NAME·번호가 모두 맞을 때만 연다.

## 대안

| 대안 | 장점 | 단점 | 기각 이유 |
|---|---|---|---|
| A — 로그인된 호스트만 신뢰, 계정은 표시만 | 저장소가 정한 호스트로 토큰이 가지 않는다. 앱이 gh 설정을 쓰지 않는다 | 계정을 바꾸려면 터미널에서 명령을 친다 | **채택** |
| B — 원격 URL의 어떤 호스트든 gh에 넘김 | 설정이 필요 없다 | 저장소가 원격 호스트를 바꿔 사용자가 로그인한 다른 호스트로 요청을 보내게 할 수 있다 | 신뢰 경계가 저장소로 넘어간다 |
| C — Settings에 허용 호스트 목록을 따로 둠 | 명시적이다 | gh 로그인 목록과 중복되고, 로그인하지 않은 호스트는 어차피 쓸 수 없다 | 정보가 둘로 갈린다 |
| D — 앱에서 계정 선택(`gh auth switch` 실행) | 편하다 | 사용자 gh 설정을 앱이 쓴다. 다른 터미널 세션의 gh 동작까지 바뀐다 | ADR-0021 쓰기 범위 밖 |
| E — `GH_TOKEN`으로 계정별 토큰 주입 | 계정을 앱 안에서만 고른다 | 앱이 토큰을 다뤄야 한다 | ADR-0004 §1 |

## 결과

- 좋아지는 점
  - GHE 저장소에서도 이슈·PR 정보와 GitHub 링크를 쓴다.
  - 어느 계정으로 보고 있는지 화면에서 안다.
- 나빠지는 점, 감수하는 비용
  - 사용자가 로그인해 둔 GHE 호스트를 저장소 원격이 가리키면, 그 저장소를 열 때 그 호스트로 이슈·PR 조회가 간다. 사용자가 고른 호스트라 받아들인다.
  - 계정 전환은 터미널에서 한다.
  - 로그인 목록을 읽기 전에는 GHE 저장소의 GitHub 정보가 잠깐 비어 보인다.

## 후속 작업

- [ ] 원격 판별·호스트 신뢰·`--repo HOST/…`·링크 호스트 확장, 계정 표시 (#117)
- [ ] git-command-catalog §5, security-review.md T9·T11·T16, screens.md(상태바·이슈 패널) 갱신 (#117)
