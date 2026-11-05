# ADR-0003: 최소 지원 macOS는 14 (Sonoma)로 한다

> 상태: Accepted · 날짜: 2026-11-05 · 관련: HANDOFF §4, [architecture/overview.md](../architecture/overview.md)

## 맥락

HANDOFF는 상태 관리에 `@Observable`을 쓰기로 했다. Observation 프레임워크(`@Observable`)는 macOS 14부터 쓸 수 있다. 메인테이너 장비는 최신 macOS(26)이고 Xcode 27이 설치되어 있다. 대상 사용자는 최신 개발 환경을 쓰는 개발자다.

## 결정

배포 대상(Deployment Target)은 **macOS 14.0**으로 한다.

- 14보다 새로운 API는 `if #available(macOS 15, *)` 같은 분기로 감싸서 쓴다. 분기 없이 쓰면 안 된다.
- CI는 최신 Xcode가 들어 있는 macOS 러너에서 빌드한다. macOS 14 실기기 점검은 QA 체크리스트([qa/checklist.md](../qa/checklist.md))에서 한다.
- Liquid Glass 등 macOS 26 디자인 요소는 시스템 컨트롤이 자동으로 적용하는 범위만 쓰고, 직접 의존하지 않는다.

## 대안

| 대안 | 장점 | 단점 | 기각 이유 |
|---|---|---|---|
| macOS 13 | 사용자 범위가 조금 더 넓음 | `@Observable`을 못 써서 `ObservableObject`로 돌아가야 함 | HANDOFF의 상태 관리 결정과 충돌 |
| macOS 15 | 최신 SwiftUI API를 분기 없이 씀 | Sonoma 사용자를 제외함 | 이득에 비해 제외 범위가 큼 |
| macOS 26 | 최신 디자인 시스템을 그대로 씀 | 사용자 범위가 너무 좁음 | 개발자 도구로서 부적절 |

## 결과

- `@Observable`과 Swift 6 동시성을 기본 도구로 쓸 수 있다.
- macOS 15 이상 API가 필요할 때마다 분기 비용이 든다.
- Apple이 macOS 14 보안 업데이트를 끝내면 상향을 검토한다.

## 후속 작업

- [ ] Xcode 프로젝트 생성 시 Deployment Target 14.0 설정 (Phase 3 골격 Epic)
- [ ] QA 체크리스트에 macOS 14 실행 항목 포함
