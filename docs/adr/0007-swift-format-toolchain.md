# ADR-0007: 포맷과 린트는 툴체인 내장 swift-format을 쓴다

> 상태: Accepted · 날짜: 2026-11-05 · 관련: ADR-0006, HANDOFF §10 Phase 3-1

## 맥락

HANDOFF는 SwiftLint와 SwiftFormat을 적었지만, 둘 다 별도 설치가 필요한 제3자 도구다. 메인테이너 맥에는 둘 다 없다. Swift 6 툴체인에는 Apple이 관리하는 `swift-format`이 `swift format` 하위 명령으로 들어 있다. 이 맥의 Command Line Tools에서 버전 6.3.0을 확인했다.

## 결정

1. 포맷: `swift format --in-place --recursive Overgrove OvergroveTests`
2. 린트: `swift format lint --strict --recursive Overgrove OvergroveTests`
3. 설정 파일은 저장소 루트의 `.swift-format`(JSON)이다. 들여쓰기 4칸, 줄 길이 120을 기준으로 한다.
4. CI의 `build-test` 작업에서 lint를 실행하고, 위반이 있으면 실패시킨다.
5. 로컬에서는 Claude Code hook이나 pre-commit에서 강제하지 않고 권장만 한다. 앱 소스가 생기는 Phase 3에서 다시 검토한다.

## 대안

| 대안 | 장점 | 단점 | 기각 이유 |
|---|---|---|---|
| SwiftLint + SwiftFormat | 규칙이 풍부하고 커뮤니티 규칙이 많음 | Homebrew 설치와 CI 설치·버전 고정이 필요하고 공급망이 늘어남 | ADR-0006 |
| 린트 없음 | 설정 부담 없음 | AI가 생성한 코드의 스타일이 흔들림 | 품질 기준 부재 |

## 결과

- 추가 설치 없이 Xcode가 있는 모든 환경에서 같은 도구를 쓴다.
- SwiftLint의 일부 규칙(복잡도, 강제 언래핑 금지 등)은 없다. 강제 언래핑 등은 코드 리뷰 체크리스트와 `security-reviewer` 에이전트로 보완한다.
- 툴체인 버전에 따라 포맷 결과가 조금 달라질 수 있다. CI의 Xcode 버전을 기준으로 삼는다.

## 후속 작업

- [ ] `.swift-format` 설정 파일 추가 (저장소 셋업)
- [ ] CI lint 단계 활성화 (Phase 3 골격 Epic)
