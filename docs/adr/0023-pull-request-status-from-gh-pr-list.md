# ADR-0023: PR 상태는 `gh pr list` 하나로 읽고, 브랜치와는 head 저장소까지 맞을 때만 잇는다

> 상태: Accepted · 날짜: 2026-11-08 · 관련: #397, #115, #265, ADR-0004, ADR-0021, T9, T10, T11, T15, [git-command-catalog.md §5](../architecture/git-command-catalog.md#5-ghcommand-gh-allowlist)

## 맥락

[ADR-0004](0004-github-integration-gh-issues-only.md) §2는 GitHub 연동의 1차 범위를 이슈 조회로 한정하고 PR 상태 표시를 `later`로 미뤘다. 카탈로그의 금지 목록에도 `gh pr *`가 있다.

v0.2.0(#115)에서는 워크트리마다 연결된 PR의 상태를 보이려고 한다. 워크트리 관제에서 가장 쓸모 있는 정보는 "이 워크트리의 PR이 열려 있는지, 리뷰는 어떤지, 머지됐는지"다. 머지된 PR이 있는 워크트리는 정리 대상이다(정리 자체는 앱이 하지 않는다, [ADR-0021](0021-read-only-scope-after-v0-1.md)).

판단에 쓴 사실과 제약은 다음과 같다.

- gh 2.95의 `gh pr list --json`은 `headRefName`, `headRepositoryOwner`, `headRepository`, `isCrossRepository`, `reviewDecision`, `mergedAt`, `statusCheckRollup` 같은 필드를 준다(로컬에서 필드 목록 확인).
- **공개 저장소에서는 누구나 fork에서 PR을 열 수 있고, head 브랜치 이름도 마음대로 정한다.** 브랜치 이름만으로 짝지으면 남의 PR이 내 워크트리에 붙는다(사칭, 1.3 공격자 모델).
- gh 호출의 하드닝(중립 작업 디렉터리, `--repo` 명시, 환경 allowlist, 텔레메트리 끔, 실행 제한)은 ADR-0004와 카탈로그 §5에 이미 있다.

## 결정

**PR 상태는 `gh pr list` 하나로, 인자와 JSON 필드를 고정해 읽는다.** ADR-0004 §2("PR 상태는 later")만 이 결정으로 대체한다. gh 위임, 토큰 비취급, 중립 작업 디렉터리, `--repo` 명시, 환경 하드닝, github.com만 지원하는 ADR-0004의 나머지 결정은 그대로다.

1. **명령.** `GHCommand`에 case 하나를 더한다.

   ```
   gh pr list --repo OWNER/NAME --state all --limit 200
     --json number,title,state,isDraft,isCrossRepository,headRefName,headRepositoryOwner,headRepository,baseRefName,reviewDecision,mergedAt,updatedAt,url
   ```

   - `--state all`: 열린 PR과 최근 머지·닫힌 PR을 함께 받는다. 200개는 gh의 기본 정렬, 즉 만든 시각 내림차순(번호 역순)의 앞부분이다(gh 2.95.0에서 확인). updatedAt 순이 아니므로 오래전에 연 PR은 최근에 갱신됐어도 밖으로 밀려날 수 있다.
   - `OWNER/NAME`은 이슈와 같은 `GitHubRepository` 검증을 거친다.
   - 필드는 위 13개 allowlist다. CI 상태(`statusCheckRollup`)는 중첩이 크고 출력이 커서 `later`다. 본문, 댓글, 파일, 리뷰 목록은 받지 않는다.
   - 카탈로그 금지 목록의 `gh pr *`는 "`gh pr list` 밖의 모든 `gh pr`"로 바꾼다.
2. **실행.** `GHClient`를 거친다. 실행 제한은 카탈로그 §2.5의 gh 값(15초, stdout 5MB, stderr 64KB)이고, 잘린 출력은 해석하지 않고 실패로 본다. stderr는 마스킹한 뒤에만 `GHError`에 담는다.
3. **해석.** 목록 전체를 실패로 보는 것은 JSON 최상위가 배열이 아니거나 해석할 수 없을 때뿐이다. PR 하나에 `number`·`state`·`url`이 없거나 형식이 맞지 않으면 그 PR만 버린다. `headRepository`·`headRepositoryOwner`가 null이거나 비어 있으면(fork를 지운 PR 등) 그 PR은 목록에 두되 어떤 브랜치에도 잇지 않는다. 한 사람이 PR 하나로 모든 사용자의 PR 표시를 끄지 못하게 하려는 것이다. 알 수 없는 `state`·`reviewDecision`은 `unknown`으로 둔다. 제목·브랜치 이름·로그인 이름은 표시 전에 제어·bidi 문자를 이스케이프한다.
   - URL은 조회한 저장소의 PR 주소와 같을 때만 연다: `https://github.com/<OWNER>/<NAME>/pull/<번호>`에서 OWNER·NAME은 조회한 값과 ASCII 대소문자 무시로 같고, 번호는 그 PR의 `number`와 같아야 한다. 이슈의 규칙(github.com의 어떤 OWNER/NAME이든 허용)보다 엄격하다. 저장소 이름이 바뀌어 주소가 다르면 버튼이 꺼지고 `Copy URL`만 남는다.
4. **브랜치와 잇기.** gh를 더 부르지 않고 로컬 정보로만 잇는다.
   - 로컬 브랜치의 upstream 원격 이름과 원격의 브랜치 이름은 `branch.<n>.remote`·`branch.<n>.merge`에서 구한다(refs 조회의 `%(upstream:remotename)`·`%(upstream:remoteref)`, #115에서 카탈로그와 함께). 원격 이름에 `/`가 들어갈 수 있어 `refs/remotes/<원격>/<이름>`을 쪼개지 않는다. 그 원격의 URL에서 `OWNER/NAME`을 구한다(검증된 목록의 원격, `GitHubRemote` 판별).
   - `headRepositoryOwner.login`과 `OWNER`, `headRepository.name`과 `NAME`이 ASCII 대소문자 무시로 같고(GitHub는 대소문자를 구분하지 않고, 원격 URL에는 사용자가 친 대로 남는다), `headRefName`이 원격 브랜치 이름과 바이트로 정확히 같은 PR만 잇는다. **브랜치 이름만으로는 잇지 않는다.** `isCrossRepository`는 판단에 쓰지 않는다.
   - fork 흐름(origin은 fork, 이슈·PR은 upstream)도 같은 규칙으로 맞는다.
   - 여러 PR이 맞으면 열린 PR을 먼저, 그다음 updatedAt이 최신인 것을 고른다.
   - upstream이 없거나 원격이 github.com이 아니면 잇지 않는다.
5. **표시.** 사이드바 워크트리 행과 LOCAL 브랜치 행에 PR 알약을 두고, S-05에 "Pull request" 카드를 둔다(screens.md, information-architecture.md §4.3). 머지된 PR은 사실만 보인다. 정리 안내 문구나 복사용 명령은 넣지 않는다(ADR-0021의 보조 기능 규칙).
6. **캐시와 갱신.** 이슈 목록과 같다. 저장소(`OWNER/NAME`)별로 두고, 다른 저장소를 열 때, 수동 새로고침(`⌘R`), Check Again 때 이슈 목록과 함께 다시 받는다. fetch 완료나 시간 경과로는 다시 받지 않는다(이슈 패널의 실제 동작, #115에서 overview.md 캐시 표도 맞춤). PR 조회가 실패해도 이슈 패널은 끄지 않고 PR 표시만 없앤다.
7. **gh가 없거나 로그아웃.** `#265`의 degraded mode와 같다. 로그인 상태를 확인한 뒤에만 실행하고, 안 되면 PR 표시를 숨긴다. PR 전용 안내는 두지 않는다. 상태바의 gh 상태와 이슈 패널의 안내로 충분하다.

## 대안

| 대안 | 장점 | 단점 | 기각 이유 |
|---|---|---|---|
| A — `gh pr list --state all`, 필드 13개, head 저장소까지 맞춰 잇기 | 한 번의 호출로 열린·머지된 PR을 다 본다. 사칭을 막는다 | gh 호출이 저장소마다 하나 늘어난다 | **채택** |
| B — 열린 PR만(`--state open`) | 출력이 작다 | 머지된 PR(정리 대상)을 알 수 없다 | 워크트리 관제의 핵심 정보가 빠진다 |
| C — 브랜치 이름만으로 잇기 | 구현이 단순하다 | 공개 저장소에서 fork PR이 내 워크트리에 붙는다 | 사칭 |
| D — 브랜치마다 `gh pr view <branch>` | 정확하다 | 워크트리 수만큼 gh를 실행한다(T15). `gh pr view`가 브랜치를 해석하려고 git을 부를 수 있다 | 비용과 실행 경로 |
| E — CI 상태(`statusCheckRollup`)까지 | 정보량이 많다 | 중첩 JSON이 커서 출력 상한(5MB)에 가깝고 파서가 커진다 | 이번 범위 밖(`later`) |

## 결과

- 좋아지는 점
  - 워크트리 행에서 PR이 열려 있는지, 리뷰가 어떤지, 머지됐는지를 바로 본다. 정리할 워크트리를 고르기 쉬워진다.
  - gh 실행 경로는 하드닝된 기존 경로 그대로이고, 새 명령은 조회 하나다.
- 나빠지는 점, 감수하는 비용
  - 이슈를 다시 받을 때마다 gh 호출이 하나 더 늘어난다.
  - 최근에 만든 200개 밖의 PR은 보이지 않는다.
  - upstream을 설정하지 않은 브랜치에는 PR을 잇지 않는다. 사칭을 막으려고 받아들인다.
  - 잇기는 저장소 설정을 믿는 만큼만 믿을 수 있다. 저장소 로컬 `remote.<n>.url`이 공격자 저장소를 가리키거나, 소유자가 이름을 바꾼 뒤 옛 이름을 다른 사람이 차지하면, 그 원격과 맞는 PR이 붙는다. 이때는 fetch도 이미 그곳으로 가므로 새 위험은 아니다(이슈 패널이 저장소 설정으로 조회 대상을 정하는 것과 같다).
  - 목록은 만든 시각 순이라, 누구나 새 fork PR을 많이 열어 오래전에 만든 사용자의 PR을 200개 밖으로 밀어낼 수 있다. 표시가 빠질 뿐 잘못 붙지는 않는다.
- 다시 검토해야 하는 조건
  - CI 상태를 보이자는 요구가 생길 때(대안 E)
  - GitHub Enterprise를 지원할 때(ADR-0004 §8)
  - gh의 JSON 필드가 바뀔 때(파서 테스트가 먼저 알린다)

## 후속 작업

- [ ] 구현: `GHCommand.prList`, 파서, 잇기 규칙, 사이드바 알약과 S-05 카드, 캐시와 갱신 (#115)
- [ ] SEC 테스트 (#115): 인자 스냅샷, 적대적 PR JSON(제어·bidi 제목, 같은 이름의 fork PR이 붙지 않음, head 저장소가 null·빈 PR은 그 PR만 잇지 않음, 대소문자만 다른 소유자·저장소 이름, 다른 저장소·호스트 URL, 잘린 출력), gh 환경 allowlist
- [x] 카탈로그 §5와 금지 목록, security-review.md, screens.md, information-architecture.md, overview.md 갱신 (#397, 이 PR)
