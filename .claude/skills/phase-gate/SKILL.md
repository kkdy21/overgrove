---
name: phase-gate
description: Overgrove의 Phase(기획·설계·개발·검증·릴리스) 종료 보고서를 만든다. 산출물·빌드·테스트·보안 체크리스트·열린 이슈를 점검해 사용자 승인을 요청한다. "Phase 끝났는지 점검", "승인 요청 보고서" 요청 시 사용.
---

# phase-gate — Phase 종료 점검과 승인 요청

기준 문서: `docs/process/phase-gates.md` (Phase별 산출물과 승인 기준)

1. **대상 Phase 확인**: 사용자에게 묻거나 `docs/roadmap.md`에서 현재 Phase를 확인한다.
2. **산출물 점검**: `phase-gates.md`의 산출물 목록을 하나씩 확인한다.
   - 파일이 있는지
   - 머리말 상태가 무엇인지(Draft, Proposed, Accepted)
   - 깨진 상대 링크가 없는지
3. **자동 점검 실행**
   ```sh
   gitleaks git --no-banner --redact .
   scripts/lint/check-forbidden-apis.sh
   scripts/make-fixture-repo.sh "$(mktemp -d)"   # 픽스처 정상 생성
   # Phase 3 이후
   xcodebuild test -project Overgrove.xcodeproj -scheme Overgrove -destination 'platform=macOS'
   ```
4. **이슈 점검**
   - `gh issue list --repo kkdy21/overgrove --label phase:<phase> --state open`
   - Epic 하위 이슈가 모두 닫혔는지 본다.
5. **보안 체크리스트**: `docs/design/security-review.md`의 체크리스트를 T-ID별로 표로 정리한다. 열마다 충족 여부, 근거(테스트 ID·문서), 잔여 위험을 적는다.
6. **보고서 작성**: 다음 순서로 쓴다.
   - 요약(승인 가능 여부)
   - 산출물 표
   - 자동 점검 결과(명령과 출력 요약)
   - 열린 이슈
   - 보안 체크리스트
   - 결정이 필요한 사항
   - 다음 Phase 첫 작업
7. **승인 요청**: 승인을 받으면 Phase Epic을 닫고(코멘트 초안 승인 후) `docs/roadmap.md`의 상태를 갱신하는 PR을 제안한다.
