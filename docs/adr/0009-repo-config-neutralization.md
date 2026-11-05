# ADR-0009: 저장소 설정을 검사해 위험한 키를 무력화한다 (RepoConfigInspector)

> 상태: Proposed (Phase 2 승인 대기) · 날짜: 2026-11-05 · 관련: T4–T8, T11, T14, [design/security-review.md](../design/security-review.md)

## 맥락

HANDOFF의 대응(`-c core.fsmonitor=false -c core.hooksPath=/dev/null`, `--no-ext-diff --no-textconv`)만으로는 막을 수 없는 실행 경로가 있다. Phase 2에서 Apple Git 2.50.1로 다음을 확인했다.

| 실험 | 결과 |
|---|---|
| `.gitattributes`나 `.git/info/attributes`의 `filter=<driver>` + 로컬 `filter.<driver>.clean` | `git status`가 stat이 바뀐 파일을 비교할 때 clean 필터를 실행한다. `GIT_OPTIONAL_LOCKS=0`이면 index가 갱신되지 않아 **status를 부를 때마다** 다시 실행된다. |
| 드라이버 이름 | 임의라서 고정 `-c`로는 막을 수 없다. |
| `--attr-source=<empty tree>` (git 2.41+) | 트리의 `.gitattributes`는 막지만 `.git/info/attributes`는 막지 못한다. |
| 로컬 `credential.helper`, `credential.<url>.helper` | fetch 인증 시 실행된다. |
| 로컬 `core.sshCommand` | 실행된다. 단 환경 변수 `GIT_SSH_COMMAND`가 설정 파일보다 우선한다. |
| 로컬 `core.gitProxy` | 실행된다. `-c core.gitProxy=`로는 **막히지 않고**, 빈 `GIT_PROXY_COMMAND` 환경 변수로 막힌다. |
| 로컬 `remote.<name>.uploadpack` (로컬 경로 원격) | 실행된다. `-c remote.<name>.uploadpack=...`로는 **막히지 않는다** (첫 값이 이긴다). `fetch --upload-pack=git-upload-pack`으로 막힌다. |
| 로컬 `core.askPass` | `GIT_TERMINAL_PROMPT=0`이어도 실행된다. `-c core.askPass=` 또는 빈 `GIT_ASKPASS`로 막힌다. |
| 로컬 `log.showSignature=true` + `gpg.program` | 일반 `log`/`show`도 서명 검증 프로그램을 실행한다. |
| 서브모듈 | 상위 저장소의 `git status`가 서브모듈로 재귀하면서 서브모듈 설정(fsmonitor 등)을 실행한다. |

## 결정

1. **조회 전 검사.** 저장소를 등록할 때와 새로고침할 때마다 `RepoConfigInspector`가 다음을 실행한다.
   ```
   git config --list --show-scope -z --includes
   ```
   - 설정을 읽기만 하는 명령이라 실행 경로가 없다.
   - 출력 형식은 `scope NUL key LF value NUL`이다.
2. **신뢰 범위.** `system`, `global`, `unknown`(Apple Git 내장 설정, 예: `credential.helper=osxkeychain`), `command`만 신뢰한다. `local`, `worktree`는 신뢰하지 않는다. `include.path`로 불러온 파일은 포함한 쪽의 scope로 보고되는 것을 확인했다.
3. **동적 무력화 인자.** 신뢰하지 않는 범위에서 찾은 키마다 다음을 적용한다.

   | 탐지 | 무력화 | 적용 명령 |
   |---|---|---|
   | `filter.<d>.(clean\|smudge\|process\|required)` | `-c filter.<d>.clean= -c filter.<d>.smudge= -c filter.<d>.process= -c filter.<d>.required=false` | 모든 명령 |
   | `credential.helper`, `credential.<url>.helper` | `-c credential.helper=` 뒤에, 신뢰 범위의 `credential.*helper` 항목을 **원래 순서와 키 그대로 다시 넣는다** | fetch |
   | `core.sshCommand` | 환경 변수 `GIT_SSH_COMMAND` = 신뢰 범위 값, 없으면 `ssh -o BatchMode=yes` | fetch (항상 설정) |
   | `core.gitProxy` | 환경 변수 `GIT_PROXY_COMMAND=`(빈 값) | fetch (항상 설정) |
   | `remote.<n>.uploadpack` | `fetch --upload-pack=git-upload-pack` | fetch (항상 적용) |
   | `http.sslVerify`, `http.<url>.sslVerify` = false | 같은 키로 `-c <key>=true` | fetch |

   - credential 재삽입 예: `credential.https://github.com.helper=`(빈 값)와 `credential.https://github.com.helper=!gh auth git-credential`처럼 `gh auth setup-git`이 만든 항목도 원래대로 복원된다.
   - `core.sshCommand`, `core.gitProxy`, `remote.<n>.uploadpack` 대응은 탐지 여부와 관계없이 fetch마다 항상 적용한다. 탐지 결과는 보고에만 쓴다.
4. **보고만 하는 키.** 공통 보안 인자로 이미 막히는 키다. `core.fsmonitor`, `core.hooksPath`, `diff.external`, `diff.<d>.(textconv|command)`, `gpg.*program`, `log.showSignature`, `protocol.*.allow`, `url.*.insteadOf`, `include*.path`, `http.*proxy`, `http.*sslCA*`, `core.worktree`, `fetch.recurseSubmodules`, `submodule.recurse`가 해당한다. 화면(S-05 SECURITY 섹션)에 "이 저장소에 실행 가능한 설정이 있으며 무력화했다"고 보여 준다.
5. **서브모듈.** status는 `--ignore-submodules=dirty`로 실행해 서브모듈 내부로 재귀하지 않는다. gitlink 커밋 변경은 여전히 보인다. fetch는 `--no-recurse-submodules`로 실행한다.
6. **실패 시 차단.** 설정 검사가 실패하면(타임아웃, 파싱 실패) 해당 저장소의 조회를 멈추고 에러를 보여 준다. 검사 결과 없이 git을 실행하지 않는다 (fail closed).
7. **`safe.directory`를 우회하지 않는다.** git이 "dubious ownership"으로 거부하면 그대로 에러로 보여 주고, `-c safe.directory=*`를 넣지 않는다.

## 대안

| 대안 | 장점 | 단점 | 기각 이유 |
|---|---|---|---|
| `GIT_CONFIG_NOSYSTEM` + 빈 HOME으로 로컬 설정만 남김 | 단순 | 로컬 설정은 그대로 남고, 사용자의 credential helper가 사라짐 | 문제를 반대로 해결함 |
| `-c credential.helper=`만 넣음 | 단순 | 사용자의 osxkeychain·gh helper까지 꺼져 fetch 인증이 깨짐 | 사용성 |
| `--attr-source=<empty tree>`만 씀 | 드라이버 이름을 몰라도 됨 | `.git/info/attributes`를 못 막고 git 2.41이 필요함 | 불완전. v0.2.0에서 심층 방어로만 검토 |
| 위험 키가 있으면 조회 자체를 거부 | 가장 안전 | 정상 저장소(LFS 필터 등)도 못 봄 | 사용성. 대신 "신뢰하지 않음 모드"를 v0.2.0에 둔다 |

## 결과

- 확인된 실행 경로를 모두 막으면서도, 사용자 자신의 신뢰된 설정(credential helper, ssh 설정)은 유지한다.
- Git LFS처럼 정당한 로컬 필터도 무력화된다. LFS 포인터 파일이 변경으로 보일 수 있는데, 조회 앱에서 감수할 수 있는 부작용이다. 화면에 표시해 혼란을 줄인다.
- 호출마다 설정 검사가 붙어 비용이 늘어난다. 결과를 캐시하고, 설정 파일들(`.git/config`, `config.worktree`, include 대상)의 mtime이 바뀔 때만 다시 검사한다.
- 로컬 경로 원격을 fetch하면 상대 저장소에서 `git-upload-pack`이 실행되는데, 그 저장소의 설정은 검사하지 않는다. 잔여 위험으로 기록한다.

## 후속 작업

- [ ] RepoConfigInspector 구현 (Phase 3 보안 기반 Epic)
- [ ] 악성 픽스처(`scripts/make-fixture-repo.sh --malicious`)의 canary 기반 SEC-T4~T8 테스트
- [ ] v0.2.0: 저장소별 "신뢰하지 않음" 모드 (fetch 차단, file 프로토콜 차단)
