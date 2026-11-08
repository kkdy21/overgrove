# ADR-0026: GitLab·Gitea 이슈는 glab·gt에 위임해 읽고, 그 CLI에 로그인된 호스트만 신뢰한다

> 상태: Accepted · 날짜: 2026-11-08 · 관련: #448, #154, #449, #450, #117, ADR-0004, ADR-0021, ADR-0022, ADR-0025, T9, T10, T11, T13, T15, [git-command-catalog.md §5.1](../architecture/git-command-catalog.md#51-glcommand와-gtcommand-다른-제공자-cli)

## 맥락

[ADR-0004](0004-github-integration-gh-issues-only.md)는 이슈 패널을 `gh`와 github.com으로 한정했다. ADR-0025(#447)는 GitHub 안에서 호스트를 넓히되, gh에 로그인된 호스트만 신뢰하기로 했다. v0.2.0(#154, #449)에서는 사내 GitLab·Gitea를 쓰는 사용자에게도 같은 이슈 패널을 보이려고 한다. 원칙은 그대로다. 앱은 토큰을 다루지 않고, 각 제공자의 공식 CLI에 인증을 맡긴다.

판단에 쓴 사실(2026-11-08, 공식 릴리스 바이너리를 스크래치 경로에 받아 체크섬을 확인하고, 어떤 계정에도 로그인하지 않고 확인했다):

- **GitLab: glab 1.128.0** (gitlab-org/cli).
  - `glab auth status [--hostname H | --all] --output json`은 `{"hosts":[{host,state,user,error,token_source,…}]}`를 낸다. `state`는 `success` 또는 `error`다. 토큰 값은 JSON에 없다(`token_source`는 `keyring`·`environment`·`config_file`·`none` 분류만이다). `--show-token`은 JSON과 함께 쓸 수 없다. 실패한 호스트가 있으면 0이 아닌 코드로 끝난다(소스와 실측).
  - 설정에 없는 호스트를 `--hostname`으로 물으면, 네트워크 없이 바로 오류로 끝난다(실측).
  - `glab issue list --repo <URL|PATH> --output json --per-page N`은 GitLab API의 이슈 객체 배열을 낸다. 필드는 `iid`, `title`, `state`(`opened`/`closed`), `labels`(문자열 배열), `assignees[].username`, `updated_at`, `web_url` 등이다. 필드를 고르는 옵션은 없어서 `description`(본문)도 함께 온다. `web_url`은 이제 `…/-/work_items/<iid>` 형태로도 온다(실측).
  - **텔레메트리가 기본으로 켜져 있다.** 실측에서 기본값은 `POST /api/v4/usage_data/track_event`를 보냈고, `GLAB_SEND_TELEMETRY=false`면 보내지 않았다. **업데이트 확인도 기본으로 켜져 있다.** 기본값은 `GET /api/v4/projects/gitlab-org%2Fcli/releases`를 보냈고, `GLAB_CHECK_UPDATE=false`면 보내지 않았다(`GLAB_DEBUG_HTTP`로 요청 목록 확인).
  - `--repo`에 준 호스트로는, 로그인하지 않았어도 비인증 요청을 보낸다(실측).
  - 설정 파일이 없으면 첫 실행 때 `~/Library/Application Support/glab-cli/config.yml`을 만든다(실측).
  - 환경 변수가 많다. 토큰(`GITLAB_TOKEN` 등), 호스트(`GITLAB_HOST`), 설정 경로(`GLAB_CONFIG_DIR`), TLS(`GLAB_CA_CERT`, `GLAB_SKIP_TLS_VERIFY`), 프록시(`GLAB_PROXY`), Duo·Orbit CLI 자동 다운로드·실행 등이다(공식 문서).
- **Gitea: gt 1.1.0** (gitea/cli).
  - tea는 archived 상태이고, gt 1.0(2026-11-02)이 공식 후속이다. Gitea 28 이상만 지원하고 tea 설정은 읽지 않는다.
  - `gt auth status --json <필드>`는 로컬 자격 증명만 보고 네트워크를 쓰지 않는다(`--verify`를 줄 때만 서버에 묻는다). 필드는 `active, credential_available, credential_store, error, expires_at, git_credential_helper, host, method, scopes, user, verified`다. `--json`이면 종료 코드는 항상 0이다.
  - `gt issue list`는 `--json number,title,state,labels,assignees,updated_at,url`, `--state open|closed|all`, `--limit 1..1000`, `--kind issues`(기본값), `-R/--repo`, `--host URL`, `--no-input`을 받는다.
  - 계정이 없는 인스턴스에는 요청하지 않고 종료 코드 4로 끝난다(실측). 로그인 없이는 이슈 JSON을 채집할 수 없어서, `labels`·`assignees`의 모양은 #449에서 소스로 확인한다.
  - `--repo`가 없으면 git 원격·`git config gt.repository`에서 저장소를 찾는다. 첫 실행에 파일을 만들지 않았다(실측).
  - 환경 변수: `GITEA_TOKEN`, `GITEA_CLI_HOST`·`GITEA_INSTANCE_URL`, `GITEA_INSTANCE_INSECURE`, `GITEA_CLI_CONFIG_DIR`·`DATA_DIR`, `GITEA_CLI_REPO`, `GITEA_CLI_NO_UPDATE_NOTIFIER`, `GITEA_CLI_NO_EXTENSIONS` 등(gt-environment(1)).
- **Forgejo**: JSON 출력이 안정적인 공식 CLI가 없다(fj·fgj·forj는 서로 다른 커뮤니티 도구다). gt가 Forgejo에서 동작하는지도 확인되지 않았다.
- 원격 URL은 저장소 설정이다. 저장소는 원격을 아무 호스트로나 바꿔 둘 수 있다(ADR-0025 맥락과 같다).

## 결정

ADR-0004의 1차 결정(gh 위임, 토큰 비취급, 중립 작업 디렉터리, 저장소 명시, 환경 하드닝)을 GitLab·Gitea로 넓힌다. ADR-0004에서 "github.com만"으로 묶은 부분 가운데, GitHub 밖의 제공자에 해당하는 것만 이 결정이 대체한다. GitHub 호스트는 ADR-0025를 따른다.

1. **제공자.** GitLab은 `glab`(#154), Gitea는 `gt`(#449)이다. tea는 쓰지 않는다(archived). Forgejo는 `later`(#450)다. 이슈 목록만 다룬다. MR·PR 상태는 `later`다.
2. **호스트 신뢰.** 저장소 원격만으로는 어떤 새 호스트에도 요청을 보내지 않는다. 그 호스트에 대해 해당 CLI가 "로그인됨"이라고 보고할 때만 그 CLI로 이슈를 읽는다.
   - glab: `glab auth status --hostname <HOST> --output json`의 그 호스트 항목이 `state == "success"`이고 `user`가 비어 있지 않을 때만 쓴다. 설정에 없는 호스트는 glab이 네트워크 없이 거절하고, 설정된 호스트는 사용자가 로그인해 둔 곳이다. `--all`은 쓰지 않는다. 모든 설정 호스트로 요청이 나가기 때문이다.
   - gt: `gt auth status --json host,user,active,credential_available`에서 `credential_available == true`이고 `host`가 원격과 맞는 항목이 있을 때만 쓴다. 네트워크를 쓰지 않는다. 비교에는 base path까지 포함한다.
   - 원격 URL 판별(세 형태, HOST는 소문자 ASCII DNS 이름, IP·userinfo 거부)은 #117/ADR-0025가 만드는 공통 판별을 재사용한다. GitLab은 하위 그룹을 허용한다. NAMESPACE는 `/`로 이은 1–20개 구성 요소이고, 각 구성 요소는 `[A-Za-z0-9_.-]`이며 `-`·`.`로 시작하지 않는다. 전체는 255바이트 이하다.
   - github.com과 gh에 로그인된 호스트는 gh가 맡는다(ADR-0025). 한 호스트를 두 CLI가 모두 로그인됐다고 보고하면 제공자를 고르지 않고, 패널에 그 사실만 보인다.
3. **명령.** 인자를 고정한 allowlist 타입 `GLCommand`·`GTCommand`로만 만든다(카탈로그 §5.1).
   - glab
     - `version`: `["--version"]`
     - `authStatus(host:)`: `["auth", "status", "--hostname", HOST, "--output", "json"]`
     - `issueList(host:, path:)`: `["issue", "list", "--repo", "https://HOST/NAMESPACE/NAME", "--output", "json", "--per-page", "100"]` (기본값은 열린 이슈다. GitLab API 한 페이지 최대가 100이다)
   - gt
     - `version`: `["--version"]`
     - `authStatus`: `["auth", "status", "--json", "host,user,active,credential_available"]`
     - `issueList(instance:, repo:)`: `["issue", "list", "--host", INSTANCE_URL, "--repo", "OWNER/NAME", "--state", "open", "--kind", "issues", "--limit", "200", "--no-input", "--json", "number,title,state,labels,assignees,updated_at,url"]`
   - 토큰을 출력하는 옵션(`glab auth status -t/--show-token`), 쓰기 명령, `glab api`·`gt api`, 확장(`gt <ext>`), 브라우저를 여는 옵션(`--web`)은 case로 만들지 않는다.
4. **해석.** gh 파서와 같은 원칙을 따른다. 최상위가 배열·객체가 아니면 실패로 본다. 필수 필드(번호·제목·상태·URL)가 없는 항목은 그 항목만 버린다. 모르는 상태는 `unknown`으로 둔다. 제목·라벨·로그인 이름은 표시 전에 제어·bidi 문자를 이스케이프한다. 본문(`description`·`body`)은 읽지 않는다. auth status 원문은 클라이언트 밖으로 내보내지 않고 host·user·state만 쓴다.
5. **링크.** https이고, 원격의 HOST와 같고, 경로가 그 저장소의 그 이슈와 정확히 맞을 때만 연다. GitLab은 `/NAMESPACE/NAME/-/issues/<iid>`와 `/NAMESPACE/NAME/-/work_items/<iid>`, Gitea는 base path를 포함한 `/OWNER/NAME/issues/<n>`이다. 그 밖에는 `Copy URL`만 남긴다.
6. **실행 하드닝.** GHClient와 같은 틀이다.
   - 실행 파일은 `/opt/homebrew/bin/<cli>`, `/usr/local/bin/<cli>`에서만 찾는다(PATH를 쓰지 않는다, ADR-0008).
   - 작업 디렉터리는 앱 전용 중립 디렉터리다. 실행 제한은 gh 값(15초, stdout 5MB, stderr 64KB)이다.
   - 환경 변수는 `HOME`, `USER`, `TMPDIR`만 부모에서 넘긴다. 그 밖에는 아래 고정값만 둔다. 토큰·호스트·저장소·설정 경로·TLS·프록시·브라우저·편집기 변수는 넘기지 않는다(ADR-0022).
     - glab 고정값: `GLAB_SEND_TELEMETRY=false`, `GLAB_CHECK_UPDATE=false`, `GLAB_NO_PROMPT=true`, `GLAB_PAGER=cat`, `NO_COLOR=1`, `GLAB_DISPLAY_HYPERLINKS=false`, `GLAB_SHOW_WHATS_NEW=false`, `GLAB_NOTIFY_SKILL_UPDATES=false`, `GLAB_DUO_CLI_AUTO_DOWNLOAD=false`, `GLAB_DUO_CLI_AUTO_RUN=false`, `GLAB_ORBIT_CLI_AUTO_DOWNLOAD=false`, `GLAB_ORBIT_CLI_AUTO_RUN=false`, `PATH`(§2.4), `LC_ALL=C`, `GIT_TERMINAL_PROMPT=0`
     - gt 고정값: `GITEA_CLI_NO_UPDATE_NOTIFIER=1`, `GITEA_CLI_NO_EXTENSIONS=1`, `GITEA_CLI_COLOR=never`, `GITEA_CLI_PAGER=cat`, `NO_COLOR=1`, `TERM=dumb`, `PATH`(§2.4), `LC_ALL=C`, `GIT_TERMINAL_PROMPT=0`
   - **glab 설정 파일이 없으면 glab을 실행하지 않는다.** glab은 첫 실행에 사용자 설정 파일을 만든다. 앱은 사용자의 도구 설정을 쓰지 않으므로(ADR-0021), 설정 디렉터리(`~/Library/Application Support/glab-cli/` 또는 `~/.config/glab-cli/`)의 `config.yml`이 없으면 "GitLab CLI not set up"으로 보고 실행하지 않는다.
7. **없거나 로그아웃일 때.** `#265`의 degraded mode와 같다. 패널에 안내를 보이고, 복사용 명령(`brew install glab`, `glab auth login --hostname HOST`, `brew install gitea-cli`, `gt auth login --host URL`)을 둔다. HOST·URL은 결정 2를 통과한 값만 넣고 이스케이프한다. 앱은 로그인 명령을 실행하지 않는다. Git 기능과 gh 패널은 영향받지 않는다.
8. **캐시와 갱신.** gh 이슈 패널과 같다. 다른 저장소를 열 때, `⌘R`, Check Again 때 다시 받는다.

## 대안

| 대안 | 장점 | 단점 | 기각 이유 |
|---|---|---|---|
| A — glab·gt 위임, CLI에 로그인된 호스트만 신뢰 | 토큰을 다루지 않는다. 저장소가 정한 호스트로 요청이 나가지 않는다 | CLI 설치와 로그인이 필요하다 | **채택** |
| B — 원격의 어떤 호스트든 CLI에 넘김 | 설정이 필요 없다 | 저장소를 여는 것만으로 공격자 호스트로 연결이 나간다(glab은 비인증 요청도 보낸다) | 신뢰 경계가 저장소로 넘어간다 |
| C — tea | 기존에 많이 쓰였다 | archived, 더 이상 릴리스가 없다 | 유지되지 않는다 |
| D — Forgejo용 커뮤니티 CLI(fj 등) | Forgejo를 지원한다 | 도구가 갈려 있고, JSON 출력과 인증 상태 명령이 일정하지 않다 | `later`(#450) |
| E — REST API 직접 호출과 토큰 입력 | CLI가 필요 없다 | 앱이 토큰을 다룬다 | ADR-0004 §1 |
| F — `--all`로 로그인 목록을 한 번에 읽기 | 호출이 한 번이다 | 설정된 모든 호스트로 검증 요청이 나간다 | 필요한 호스트만 묻는다 |

## 결과

- 좋아지는 점
  - 사내 GitLab·Gitea 저장소에서도 이슈 패널과 `#n` 연결을 쓴다.
  - 토큰 비취급과 실행 하드닝은 gh와 같은 수준이다.
- 나빠지는 점, 감수하는 비용
  - 제공자마다 실행 파일·환경 allowlist·파서가 하나씩 늘어난다. CLI가 바뀌면(필드, 기본값) 파서·SEC 테스트가 먼저 알려야 한다.
  - glab 이슈 목록은 필드를 고를 수 없어 본문까지 받는다. 5MB 상한과 100개 한 페이지로 묶는다.
  - glab 설정 파일이 없는 사용자는 터미널에서 glab을 한 번 쓴 뒤에야 패널이 켜진다.
  - 앱에서 받는 환경 변수가 적어서, 셸에서만 `GLAB_CONFIG_DIR`·`GITEA_CLI_CONFIG_DIR`을 바꿔 쓰는 사용자는 로그인하지 않은 것으로 보인다(gh의 `GH_CONFIG_DIR`와 같은 잔여 위험).
  - glab은 실행할 때 자기 설정 파일을 갱신할 수 있다(예: 이전 설정 형식의 이전). 이것은 사용자가 설치한 도구의 자체 관리라 막지 않는다. 설정 파일이 없을 때 새로 만드는 일만 위 결정 6으로 피한다.
  - 사용자가 로그인해 둔 호스트를 저장소 원격이 가리키면, 그 저장소를 열 때 그 호스트로 이슈 조회가 간다. 사용자가 고른 호스트라 받아들인다(ADR-0025와 같다).
- 다시 검토해야 하는 조건
  - Forgejo에 공식 CLI가 생기거나, gt가 Forgejo를 공식 지원할 때
  - glab이 필드 선택 옵션을 제공할 때
  - MR·PR 상태를 보이자는 요구가 생길 때

## 후속 작업

- [ ] glab 제공자: `GLCommand`, 파서, 호스트 신뢰, 설정 파일 확인, 패널 연결, SEC 테스트(인자 스냅샷, 환경 allowlist와 텔레메트리·업데이트 확인 끔, 토큰 옵션 없음, 적대적 JSON, 로그인 안 된 호스트에는 실행 0) (#154, #117 이후)
- [ ] gt 제공자: `GTCommand`, 파서(소스로 `labels`·`assignees` 모양 확인), 호스트·base path 신뢰, 확장 끔, 같은 SEC 테스트 (#449)
- [x] 카탈로그 §5.1, ADR 목록 (#448, 이 PR)
