# ADR-0022: 셸 프록시 환경 변수는 git에 넘기지 않고, 전역 `http.proxy`를 안내한다

> 상태: Accepted · 날짜: 2026-11-08 · 관련: #153, #150, #355, #367, T10, T11, ADR-0008, ADR-0009

## 맥락

앱은 git 자식 프로세스의 환경 변수를 allowlist로 새로 만든다([ADR-0008](0008-git-invocation-model.md), [security-review.md §3.2](../design/security-review.md#32-환경-변수-allowlist)). 부모 환경에서는 `HOME`, `USER`, `LOGNAME`, `TMPDIR`, `SSH_AUTH_SOCK`만 넘긴다(T10). 그래서 셸의 `HTTPS_PROXY`, `HTTP_PROXY`, `ALL_PROXY`, `NO_PROXY`(소문자 변형 포함)는 git에 닿지 않는다. 사내 프록시를 셸 변수로만 설정한 사용자는 Fetch가 실패한다. #153은 이 변수들을 넘길지 물었다.

판단에 쓴 사실은 다음과 같다.

- **Finder에서 실행한 GUI 앱은 셸 환경 변수를 받지 못한다.** 넘기도록 바꿔도 터미널에서 `open`이나 실행 파일로 띄웠을 때만 효과가 있다.
- **전역 `http.proxy`는 이미 동작한다.** git이 직접 읽는 신뢰 scope 설정이고, 실행 방식과 무관하다.
- **프록시 주소는 신뢰 scope에서만 온다.** 저장소 로컬의 `http.proxy`, `http.<url>.proxy`(#150), `remote.<name>.proxy`(#355)는 fetch에서 신뢰 scope의 실효 프록시나 빈 값으로 덮는다([ADR-0009](0009-repo-config-neutralization.md), security-review.md §3.3). 저장소가 고른 프록시로 신뢰 credential helper의 자격 증명이 나갈 수 있기 때문이다(T11). 셸 변수를 넘기면 이 주소에 부모 환경이라는 출처가 하나 더 생긴다. 프록시 인증·TLS 하위 키(`proxyAuthMethod`, `proxySSL*`)는 아직 덮지 않으며 #367에서 다룬다.
- git은 macOS 시스템 프록시 설정(네트워크 환경설정, PAC)을 읽지 않는다.

## 결정

**v0.2에서도 셸 프록시 환경 변수는 git에 넘기지 않는다(#153 선택지 A).** 환경 변수 allowlist(security-review.md §3.2)는 그대로 둔다. 프록시가 필요한 사용자에게는 전역 git 설정을 안내한다.

1. `HTTPS_PROXY`, `HTTP_PROXY`, `ALL_PROXY`, `NO_PROXY`와 소문자 변형은 allowlist에 넣지 않는다.
2. 프록시 URL에 비밀번호를 넣지 않도록 안내한다. 넣으면 `~/.gitconfig`에 평문으로 남는다. 사용자 이름만 두면 git이 credential helper에서 비밀번호를 받는다.
3. 사용자 안내는 [자체 호스팅·사내 Git 서버 가이드](../guides/self-hosted-git.ko.md#프록시)의 "프록시" 절에 둔다. `git config --global http.proxy …` 또는 서버별 `http.<url>.proxy`를 쓰고, SSH 원격은 `~/.ssh/config`의 `ProxyCommand`·`ProxyJump`를 쓴다.
4. macOS 시스템 프록시를 읽어 `-c http.proxy`로 넘기는 방식(선택지 C)은 일정 없는 `later` 아이디어로만 남긴다. 이슈는 열지 않는다. 다시 꺼내려면 PAC 처리, 설정 화면, 저장소 무력화(§3.3)와의 우선순위를 함께 설계해야 한다.

## 대안

| 대안 | 장점 | 단점 | 기각 이유 |
|---|---|---|---|
| A — 넘기지 않음, 전역 `http.proxy` 안내 | 공격 면적이 늘지 않는다. Finder·터미널 어디서 실행해도 같다. 부모 환경이 프록시를 정하지 않는다 | 셸 변수만 쓰던 사용자는 git 설정을 한 줄 더해야 한다 | **채택** |
| B — 프록시 변수 4종(과 소문자 변형)을 allowlist에 추가 | 터미널에서 실행하면 바로 동작한다 | 실행 방식에 따라 동작이 달라진다(Finder 실행에는 효과 없음). 부모 환경을 신뢰해야 한다(T10) | 일관성, T10 |
| C — "시스템 프록시 사용" 설정을 켜면 macOS 시스템 프록시를 읽어 `-c http.proxy`로 전달 | GUI 앱에 맞는 방식이다 | 구현이 크다(PAC 미지원, 설정 화면, 우선순위 규칙). 아직 요구가 없다 | 비용 대비 수요 부족. `later` 아이디어로 둔다 |

## 결과

- 환경 변수 allowlist와 위협 모델(T10, T11)이 바뀌지 않는다.
- 프록시 동작이 실행 방식과 무관하게 일관된다.
- 셸 변수만 쓰던 사용자는 전역 git 설정을 추가해야 한다. 가이드의 Fetch 실패 표(`Could not reach …`)가 프록시 절로 안내한다.
- 다시 검토하는 조건: 시스템 프록시(특히 PAC)만 쓰는 환경에서 Fetch를 못 쓴다는 요청이 반복될 때. 선택지 C를 새 decision 이슈로 시작한다.

## 후속 작업

- [x] 가이드(한국어·영어)의 프록시 절에서 "결정 중" 문구를 이 결정으로 바꾼다
- [x] security-review.md §3.2에 프록시 변수를 넘기지 않는다는 점과 이 ADR을 적는다
- [x] roadmap.md §9의 V2-06, scope-mvp.md §3.1 행을 결정 완료로 바꾼다
