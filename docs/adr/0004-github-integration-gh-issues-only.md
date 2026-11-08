# ADR-0004: GitHub 연동은 gh CLI에 위임하고, 1차 범위는 이슈 조회만 한다

> 상태: Accepted, §2(PR 상태는 later)는 [ADR-0023](0023-pull-request-status-from-gh-pr-list.md), §8(github.com만)은 [ADR-0025](0025-github-hosts-and-accounts.md)로 대체 · 날짜: 2026-11-05 · 관련: HANDOFF §7, G8, N6, N7, [architecture/git-command-catalog.md](../architecture/git-command-catalog.md)

## 맥락

G8은 GitHub 이슈 목록을 보여 주고, 브랜치명이나 커밋 메시지에 있는 이슈 번호를 연결하는 기능이다. 앱이 토큰을 직접 받거나 저장하면 공격 면적이 커지고, OAuth 앱 등록과 Keychain 처리가 필요해진다. 사용자는 이미 `gh` CLI를 쓰고 있다. `gh`는 토큰을 macOS Keychain에 보관한다.

## 결정

1. GitHub 접근은 **`gh` CLI를 `ProcessRunner`로 호출**해서만 한다. 앱은 토큰을 읽거나 저장하거나 화면에 표시하지 않는다.
2. 1차 범위는 **이슈 목록 조회와 번호 매칭만** 한다. PR 상태 표시는 `later`로 미룬다.
3. 로그인 상태는 `gh auth status --json hosts`로 확인한다. `--show-token`은 쓰지 않는다.
4. `gh`가 설치되지 않았거나 로그인하지 않았으면 이슈 패널만 끄고 안내를 보여 준다. Git 조회 기능은 영향을 받지 않는다.
5. 앱은 `gh auth login`을 직접 실행하지 않는다. 사용자가 터미널에서 실행하도록 안내만 한다.
6. `gh`는 저장소 바깥의 중립 디렉터리를 작업 디렉터리로 두고 실행하며, `--repo OWNER/NAME`을 항상 명시한다. `gh`가 내부적으로 실행하는 git이 저장소 설정을 읽지 않게 하려는 것이다 (T1~T7).
7. `gh` 실행 환경에는 `GH_TELEMETRY=0`, `DO_NOT_TRACK=1`, `GH_PROMPT_DISABLED=1`, `GH_NO_UPDATE_NOTIFIER=1`, `GH_NO_EXTENSION_UPDATE_NOTIFIER=1`, `GH_SPINNER_DISABLED=1`, `NO_COLOR=1`을 넣는다. 확인한 바로는 gh 2.95에 텔레메트리가 있다. 앱의 "텔레메트리 없음" 원칙을 지키려면 이 설정이 필요하다.
8. 호스트는 `github.com`만 지원한다. GitHub Enterprise는 `later`로 미룬다.

## 대안

| 대안 | 장점 | 단점 | 기각 이유 |
|---|---|---|---|
| GitHub REST API 직접 호출 + 토큰 입력 UI | gh 설치가 필요 없음 | 토큰 보관·회전·마스킹 책임이 앱에 생김 | N7과 HANDOFF §7.1 위반 |
| OAuth 앱 / GitHub App | 권한 범위를 좁힐 수 있음 | 서버나 앱 등록, 키 관리가 필요함 | 1차 범위 밖. GitHub App은 `later`에서 검토 |
| 이슈 + PR 상태 | 정보량이 많음 | API 호출과 UI가 늘어남 | MVP 집중을 위해 이슈만 |

## 결과

- 앱의 비밀 정보 취급 범위가 0이 된다.
- `gh` 버전에 따라 JSON 필드가 바뀔 수 있다. 파서 테스트로 대비하고, 필수 필드가 없으면 패널을 끄고 원인을 보여 준다.
- `gh` 텔레메트리와 업데이트 알림은 환경 변수로 끈다. gh가 이 변수를 지원하지 않는 버전이면 그 내용을 문서에 남긴다.

## 후속 작업

- [ ] GHClient와 env 하드닝 구현 (Phase 3 GitHub 이슈 패널 Epic)
- [ ] gh 미설치·미로그인·만료 상태 QA 항목 ([qa/checklist.md](../qa/checklist.md))
- [ ] PR 상태 표시를 `later` 이슈로 등록
