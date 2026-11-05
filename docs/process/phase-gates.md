# Phase 게이트

> 상태: Accepted · 관련: [roadmap.md](../roadmap.md), Claude Code skill `phase-gate`

각 Phase는 산출물을 커밋하고 메인테이너 승인을 받아야 끝난다. 승인 요청 보고서는 `/phase-gate`로 만든다.

## 1. 게이트 요약

| Phase | 마일스톤 | 핵심 산출물 | 승인 기준 | 현재 상태 |
|---|---|---|---|---|
| 1. 기획 | v0.1.0 | PRD, MVP 범위, 용어집, 로드맵, ADR 0001–0006·0011·0012, 운영 체계(라벨·마일스톤·템플릿·보드) | 목표·비목표·범위·성능 예산 수치·보안 원칙·인증 방식 승인 | 승인 대기 |
| 2. 설계 | v0.1.0 | 정보 구조, 화면 명세, 상호작용, 디자인 토큰, 아이콘, 아키텍처, 명령 카탈로그, 파싱 명세, 보안 검토(T1–T18), ADR 0007–0010, 테스트·성능·QA 계획 | 화면 흐름·데이터 흐름·보안 체크리스트·테스트 전략 승인. Proposed ADR의 수락 여부 결정 | 승인 대기 |
| 3. 개발 | v0.1.0 | Xcode 프로젝트, 보안 기반, 파서·테스트, 화면, fetch, 이슈 패널, 온보딩·설정 | 모든 v0.1.0 dev 이슈 종료. 필수 검사 통과. SEC 테스트 전부 통과 | 시작 전 |
| 4. 검증 | v0.1.0 | QA 체크리스트 수행 기록, 성능 측정 결과, 버그 수정 | DoD 항목 충족. PB-1–PB-6 측정. S1·S2 버그 0건 | 시작 전 |
| 5. 릴리스 | v0.1.0 | README, CHANGELOG, `v0.1.0` 태그, GitHub Release | 릴리스 체크리스트 완료 | 시작 전 |

## 2. 공통 승인 절차

1. Phase Epic의 하위 이슈가 모두 닫혔는지(또는 다음 Phase로 넘겼는지) 확인한다.
2. `/phase-gate`로 보고서를 만든다. 내용: 산출물 표, 자동 점검 결과, 열린 이슈, 보안 체크리스트, 결정 필요 사항.
3. 메인테이너가 승인하면:
   - Phase Epic에 승인 코멘트를 남기고 닫는다.
   - `docs/roadmap.md`와 이 문서의 "현재 상태"를 갱신한다(PR).
   - 해당 Phase 문서의 머리말 상태를 `Proposed` → `Accepted`로 바꾼다.
   - Announcements Discussion에 짧게 공지한다(선택).
4. 반려되면 지적 사항마다 이슈를 만들고 Epic을 연 채로 둔다.

## 3. Phase별 세부 기준

### Phase 1 — 기획
- [ ] `docs/prd.md`: 목표 G1–G10, 비목표 N1–N7, 성공 지표가 측정 가능한가
- [ ] `docs/scope-mvp.md`: v0.1.0 In/Out이 G·N과 1:1로 대응하는가
- [ ] 성능 예산 PB-1–PB-6 수치 확정(HANDOFF의 "체감상 즉시"를 대체)
- [ ] 보안 원칙(HANDOFF §6)과 인증 방식(§7) 승인
- [ ] 라벨·마일스톤·이슈 템플릿·Discussion 템플릿·보드 설정 완료

### Phase 2 — 설계
- [ ] S-01–S-10 화면 명세와 상태(로딩·빈·에러) 정의
- [ ] 디자인 토큰 라이트·다크 대비 검증 결과 첨부
- [ ] 아키텍처 계층·모듈 경계·동시성 모델 승인
- [ ] 명령 카탈로그가 HANDOFF §9의 모든 화면 정보를 덮는가
- [ ] 보안 검토: T1–T18마다 대응·잔여 위험·테스트 ID가 있는가
- [ ] ADR-0009(저장소 설정 무력화), ADR-0010(그래프 레인) 수락 여부 결정
- [ ] SwiftUI 프리뷰 목업 가능성 검토(HANDOFF Phase 2 요구) — Phase 3 첫 스파이크로 넘겨도 된다

### Phase 3 — 개발
- [ ] 보안 기반(ProcessRunner, GitClient, RepoConfigInspector, 마스킹)과 파서 테스트가 화면 기능보다 먼저 머지됨
- [ ] `build-test`가 실제 빌드·테스트를 수행함(Xcode 프로젝트 존재)
- [ ] CodeQL에 `swift` 언어 추가, CI 러너·Xcode 버전 고정
- [ ] 모든 v0.1.0 dev 이슈 종료

### Phase 4 — 검증
- [ ] `docs/qa/checklist.md` 전 항목 수행 기록
- [ ] PB-1–PB-6 측정값 기록(`docs/performance/benchmark-plan.md`)
- [ ] 보안 테스트: 악성 픽스처에서 canary 미생성
- [ ] 열린 S1·S2 버그 0건

### Phase 5 — 릴리스
- [ ] `docs/qa/release-checklist.md` 완료
- [ ] README만 보고 깨끗한 맥에서 소스 빌드가 재현됨
- [ ] `v0.1.0` 태그, Release 노트, CHANGELOG 정리
