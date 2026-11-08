# ADR-0024: GitHub 인증은 gh 위임을 유지한다 (GitHub App·fine-grained 토큰을 앱이 직접 다루지 않는다)

> 상태: Accepted · 날짜: 2026-11-08 · 관련: #118, #115, #117, ADR-0004, ADR-0021, ADR-0023, N7, T10, T11, T15, [git-command-catalog.md §5](../architecture/git-command-catalog.md#5-ghcommand-gh-allowlist)

## 맥락

[ADR-0004](0004-github-integration-gh-issues-only.md)는 GitHub 접근을 `gh` CLI에 맡기고, 앱이 토큰을 읽거나 저장하지 않게 했다(N7). 대안 표에서 GitHub App은 "권한 범위를 좁힐 수 있다"는 이유로 `later` 검토 대상이었다(#118). 지금 검토하는 이유는 다음과 같다.

- v0.2.0에서 PR 상태(#115, [ADR-0023](0023-pull-request-status-from-gh-pr-list.md))가 들어오면 GitHub 조회가 이슈 하나에서 이슈와 PR 둘로 는다.
- GitHub Enterprise 지원(#117)을 설계하기 전에 인증 방식을 정해야 한다.
- gh의 기본 로그인 토큰은 앱이 쓰는 것보다 훨씬 넓다(아래 2번).

지금 앱이 실행하는 gh 명령은 allowlist의 조회뿐이다: `gh auth status --hostname github.com --json hosts`, `gh issue list`, (ADR-0023 이후) `gh pr list`. gh 실행 환경에서는 `GH_TOKEN`, `GITHUB_TOKEN`, `GH_ENTERPRISE_TOKEN`, `GH_HOST`, `GH_CONFIG_DIR`을 넘기지 않는다(카탈로그 §5). 그래서 gh는 사용자가 `gh auth login`으로 저장한 로그인만 쓴다.

비교한 세 안은 다음과 같다.

- **A — gh 위임(지금 방식).**
- **B — GitHub App.** 메인테이너가 Overgrove용 GitHub App을 등록하고, 앱이 OAuth device flow로 사용자 접근 토큰(user access token)을 받아 REST/GraphQL을 직접 호출한다.
- **C — fine-grained personal access token(PAT)을 앱이 직접 사용.** 사용자가 만든 토큰을 앱에 붙여 넣고, 앱이 Keychain에 저장해 API를 직접 호출한다.

아래 사실은 GitHub 공식 문서와 gh 매뉴얼에서 2026-11-08에 확인했다(맨 아래 출처). 로컬 gh는 2.95.0이다.

### 1. 토큰 보관 (토큰 미보관 원칙, Keychain)

| | A — gh 위임 | B — GitHub App | C — fine-grained PAT 직접 |
|---|---|---|---|
| 앱이 다루는 비밀 | **없음.** gh가 시스템 자격 증명 저장소(macOS Keychain)에 보관한다. 저장소를 쓸 수 없으면 gh가 평문 파일로 대신 쓴다(gh 매뉴얼) | 사용자 접근 토큰(8시간)과 refresh token(6개월) 두 개. refresh할 때마다 둘 다 바뀌므로 앱이 회전·저장해야 한다 | 사용자가 붙여 넣은 PAT 하나(만료는 조직 정책, 기본 최대 366일) |
| Keychain | 앱은 접근하지 않는다 | 앱이 항목을 만들고 갱신·삭제해야 한다. 앱을 지워도 항목이 남는다 | B와 같다 |
| N7·HANDOFF §7.1 | 지킨다 | **어긴다** | **어긴다** |

device flow로 받은 토큰은 client secret 없이 refresh할 수 있다. 그래서 B가 데스크톱 앱에 비밀을 넣어 배포할 필요는 없다. 하지만 사용자 토큰 두 개를 앱이 보관하는 것은 피할 수 없다.

### 2. 실제로 필요한 권한 (이슈 패널, PR 상태 #115)

- 앱이 쓰는 데이터는 이슈 목록과 PR 목록 조회뿐이다. fine-grained 권한으로는 **Issues: read, Pull requests: read, Metadata: read**면 충분하다. 공개 저장소 데이터는 인증 없이도 읽을 수 있고, fine-grained 토큰은 모든 공개 저장소를 늘 읽을 수 있다.
- gh의 기본 로그인 토큰(classic OAuth)은 **`repo`, `read:org`, `gist`**를 받는다. `repo`는 비공개 저장소 읽기·쓰기 전체다. 즉 **토큰 자체는 앱이 쓰는 것보다 훨씬 넓다.** B·C의 가장 큰 장점이 여기다.
- 다만 앱이 그 토큰으로 할 수 있는 일은 `GHCommand` allowlist(조회 3개)와 셸 금지·인자 배열 규칙(CLAUDE.md §2)으로 묶여 있다. 앱이 새 자격 증명을 만들지도 않는다. 사용자가 터미널에서 이미 쓰는 gh 로그인을 그대로 쓸 뿐이다. 넓은 토큰의 위험은 앱이 코드 실행을 빼앗겼을 때 커지는데, 그때는 공격자가 같은 사용자 권한으로 gh를 직접 실행할 수도 있다. 그래서 B·C로 바꿔도 줄어드는 위험은 크지 않다.
- B의 토큰은 "앱 권한 ∩ 사용자 권한"으로 좁혀지고, 저장소 단위로 더 좁힐 수도 있다. C는 사용자가 저장소와 권한을 직접 고른다.

### 3. 설치와 온보딩 부담

- **A.** gh를 설치하고 `gh auth login`을 한 번 한다. 대상 사용자(여러 워크트리로 GitHub 저장소를 다루는 개발자) 대부분은 이미 했다. 안 했으면 이슈·PR 표시만 꺼지고(#265 degraded mode) Git 기능은 그대로다.
- **B.** 메인테이너가 github.com에 App을 등록하고 client ID를 배포한다. 사용자는 앱 안에서 device flow 코드를 승인한다(코드는 15분 안에 입력). 공개 저장소는 App을 설치하지 않아도 사용자 토큰으로 읽을 수 있다(사용자 대신 동작할 때 공개 리소스를 읽을 암묵적 권한). **비공개·조직 저장소는 저장소 소유자나 조직 관리자가 App을 설치해야 한다.** 관리자가 아닌 기여자에게는 큰 마찰이다.
- **C.** 사용자가 GitHub 설정에서 저장소와 권한을 골라 토큰을 만든다. 조직이 승인을 요구하면 승인 전까지는 공개 리소스만 읽을 수 있다. 만료되면 다시 만들어 붙여 넣어야 한다.

### 4. GitHub Enterprise 지원 (#117)

- **A.** gh가 GHE Server를 지원한다(`gh auth login --hostname <host>`, 호스트별 로그인). 앱은 원격 판별 규칙을 넓히고 `--hostname`을 넘기기만 하면 된다. #117의 범위가 그대로 맞는다.
- **B.** github.com에 등록한 App은 GHE Server 인스턴스에는 없다. 인스턴스마다 관리자가 App을 따로 등록해야 한다. 사용자 개인이 할 수 있는 일이 아니라서 현실적이지 않다.
- **C.** 인스턴스마다 토큰을 따로 받아 저장한다. 보관하는 비밀이 호스트 수만큼 는다.

### 5. 철회

- **A.** 철회는 GitHub에서 한다. `gh auth logout`은 로컬 설정만 지우고 서버의 토큰은 그대로 둔다. 서버에서 철회하려면 GitHub 설정의 Applications에서 GitHub CLI를 Revoke하는데, 그러면 모든 기기의 gh 토큰이 함께 철회된다. Overgrove만 따로 끊을 수는 없다. 대신 앱을 지워도 남는 비밀이 없다.
- **B.** 사용자가 GitHub 설정에서 Overgrove App의 승인만 철회할 수 있다. 앱 단위로 끊을 수 있다는 점은 장점이다. 다만 앱을 지운 뒤 Keychain에 남은 refresh token은 사용자가 따로 지워야 한다.
- **C.** 토큰 목록에서 그 토큰만 지운다. 공개 저장소나 gist에 올라가면 GitHub가 자동으로 폐기하고, 1년 동안 쓰지 않아도 폐기된다.

### 6. 앱이 새로 해야 하는 일

- **B.**
  - OAuth device flow를 구현한다. 코드를 표시하고, 5초 간격으로 폴링하며 `slow_down`을 처리하고, 15분 만료와 `bad_refresh_token`이면 처음부터 다시 한다.
  - 토큰 두 개를 저장·회전·마스킹한다.
  - 앱 안에 HTTPS API 클라이언트를 둔다. 지금 앱의 네트워크는 `git fetch`와 gh 프로세스뿐이다. 앱이 직접 GitHub API를 부르면 TLS, 응답 파싱, rate limit, 오류 분류가 새 공격 면적이 된다(T11, T15).
  - App의 private key는 설치 토큰(installation token)용이다. 데스크톱 배포물에 넣으면 추출되므로 쓸 수 없다. 그래서 B는 사용자 토큰만 쓰는 반쪽 방식이 된다.
  - App 등록, client ID 관리, GitHub의 App 정책 변경 대응을 메인테이너가 맡는다.
- **C.** 토큰 입력 UI, Keychain 저장, 마스킹, 만료 안내를 만들고, B와 같은 HTTPS API 클라이언트를 둔다.
- **A.** 새로 할 일이 없다. ADR-0023의 `gh pr list`도 같은 하드닝 경로를 탄다.

## 결정

**GitHub 인증은 gh 위임(A)을 유지한다.** 앱은 GitHub App도 fine-grained 토큰도 직접 다루지 않는다. ADR-0004와 ADR-0023의 결정(gh 위임, 토큰 비취급, 환경 allowlist, 중립 작업 디렉터리, `--repo` 명시)은 그대로다.

1. 앱은 토큰을 받거나 저장하지 않는다. OAuth device flow, Keychain 항목, 앱 내 GitHub API 클라이언트를 만들지 않는다(N7 유지).
2. gh 실행 환경에서 토큰 환경 변수(`GH_TOKEN`, `GITHUB_TOKEN`, `GH_ENTERPRISE_TOKEN`)와 `GH_HOST`, `GH_CONFIG_DIR`을 계속 막는다. 사용자가 셸에서만 쓰는 토큰은 앱에 닿지 않는다.
3. **권한을 좁히고 싶은 사용자를 위한 방법은 gh 쪽에 둔다.** `gh auth login --with-token`으로 fine-grained PAT(Issues·Pull requests·Metadata 읽기)를 gh에 넣으면, 앱은 바뀌지 않고 비밀도 다루지 않은 채 좁은 토큰을 쓴다. 이 경로가 앱의 gh 명령(`auth status`, `issue list`, `pr list`)으로 동작하는지 확인하고 안내 문서에 적는 일은 후속 작업이다.
4. GHE(#117)는 gh의 호스트별 로그인을 그대로 쓰는 방향으로 설계한다. ADR-0004 §8의 github.com 한정은 #117에서 다룬다.

## 대안

| 대안 | 장점 | 단점 | 기각 이유 |
|---|---|---|---|
| A — gh 위임 유지 | 앱이 다루는 비밀 0. 새 코드 없음. GHE는 gh가 지원 | gh 기본 토큰이 넓다(`repo`). Overgrove만 따로 철회할 수 없다. gh 설치가 필요 | **채택** |
| B — GitHub App(device flow 사용자 토큰) | 권한이 좁다(앱 권한 ∩ 사용자 권한). 앱 단위 철회 | 토큰 두 개 보관·회전(N7 위반). 비공개·조직 저장소는 관리자 설치 필요. GHE 인스턴스마다 App 등록. 앱 안 HTTPS 클라이언트·device flow 구현. private key는 데스크톱에서 못 씀 | 비밀 취급 범위 0 원칙을 깨고, 줄어드는 위험보다 늘어나는 공격 면적이 크다 |
| C — fine-grained PAT를 앱에 입력 | 사용자가 권한을 정확히 고른다. gh가 필요 없다 | 토큰 보관·만료·마스킹 책임이 앱에 생긴다(ADR-0004에서 기각한 안과 같음). 만료마다 다시 입력. 호스트마다 토큰 | N7 위반 |
| A′ — A에 fine-grained PAT를 gh로 넣는 사용자 선택지 | 앱 변경 없이 권한을 좁힌다 | 사용자가 토큰을 만들고 만료를 관리해야 한다. 앱 명령과의 호환을 확인해야 한다 | 결정 3으로 채택(사용자 선택지, 후속 확인) |

## 결과

- 좋아지는 점
  - 앱이 다루는 비밀은 계속 0이다. 토큰 저장소, 회전, 유출 대응이 앱의 책임이 아니다.
  - PR 상태(ADR-0023)와 GHE(#117)를 같은 gh 경로로 붙일 수 있다.
  - 앱에 HTTPS 클라이언트나 인증 UI를 만들지 않는다.
- 나빠지는 점, 감수하는 비용
  - gh 기본 로그인 토큰은 앱이 쓰는 것보다 넓다. allowlist와 셸 금지로 앱이 쓰는 범위만 묶는다. 더 좁히려는 사용자는 결정 3의 방법을 쓴다.
  - Overgrove만 따로 철회할 수 없다. GitHub CLI 승인을 철회하면 모든 기기의 gh 토큰이 끊긴다.
  - gh가 없거나 로그아웃한 사용자는 이슈·PR 표시를 보지 못한다(#265 degraded mode).
- 다시 검토해야 하는 조건
  - 앱이 GitHub에 쓰는 기능을 갖게 될 때(ADR-0021이 바뀔 때). 넓은 토큰의 위험이 실제로 커진다.
  - gh가 필요한 데이터를 allowlist 명령으로 줄 수 없게 될 때. 예: 필드가 사라지거나 GraphQL 직접 호출이 필요해질 때(`gh api`는 금지 목록에 있다).
  - gh 미설치·미로그인이 사용자 마찰의 주된 원인으로 확인될 때.
  - gh가 토큰을 평문 파일에 두는 일이 흔해지거나, 텔레메트리 끄기 같은 환경 제어를 더 지원하지 않을 때.
  - GitHub나 gh가 범위를 지정한 로그인(App 기반 gh 로그인 등)을 제공할 때. 그때는 결정 3의 안내를 그 방법으로 바꾼다.

## 후속 작업

- [ ] fine-grained PAT를 `gh auth login --with-token`으로 넣었을 때 `gh auth status --json hosts`, `gh issue list`, `gh pr list`가 동작하는지 확인하고, 필요한 권한을 사용자 안내(README 또는 이슈 패널 도움말)에 적는다
- [ ] #117(GHE) 설계에 이 결정을 반영한다: gh 호스트별 로그인, `--hostname` 명시
- [x] [scope-mvp.md](../scope-mvp.md) N7 행에 이 ADR을 연결한다(#118, 이 PR)

## 출처 (2026-11-08 확인)

- GitHub Docs: [Generating a user access token for a GitHub App](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-a-user-access-token-for-a-github-app), [Refreshing user access tokens](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/refreshing-user-access-tokens), [Choosing permissions for a GitHub App](https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/choosing-permissions-for-a-github-app), [Authorizing GitHub Apps](https://docs.github.com/en/apps/using-github-apps/authorizing-github-apps)
- GitHub Docs: [Managing your personal access tokens](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens), [Permissions required for fine-grained personal access tokens](https://docs.github.com/en/rest/authentication/permissions-required-for-fine-grained-personal-access-tokens), [Token expiration and revocation](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/token-expiration-and-revocation)
- GitHub CLI: [gh auth login](https://cli.github.com/manual/gh_auth_login), [gh auth logout](https://cli.github.com/manual/gh_auth_logout), [Authenticating with GitHub CLI](https://docs.github.com/en/github-cli/github-cli/authenticating-with-github-cli), [gh help environment](https://cli.github.com/manual/gh_help_environment)
