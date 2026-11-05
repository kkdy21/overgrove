---
name: issue-triage
description: status:triage 상태인 Overgrove 이슈(주로 외부 제보)를 점검해 라벨·마일스톤·완료 조건·보드 상태를 제안하고 승인 후 반영한다. "트리아지 해줘", "새 이슈 정리" 요청 시 사용.
---

# issue-triage — 새 이슈 정리

1. 대상 조회
   `gh issue list --repo kkdy21/overgrove --label status:triage --json number,title,body,labels,author,createdAt`
2. 이슈별 판단 (기준: `docs/qa/bug-triage.md`, `docs/scope-mvp.md`, `docs/process/issues.md`)
   - **유효성**: 재현 정보가 부족하면 필요한 정보를 묻는 코멘트 초안을 만든다. 중복이나 무효면 `resolution:*` 라벨과 종료 사유를 단다.
   - **보안 내용이 공개 이슈에 올라온 경우**: 세부 내용을 더 퍼뜨리지 않는다. 메인테이너에게 즉시 알리고, private advisory로 옮기도록 안내하는 코멘트 초안을 만든다.
   - **범위**: v0.1 범위(조회 + fetch) 밖이면 마일스톤을 `later`로 둔다.
   - **라벨**: type, phase, area, priority를 정한다. bug면 심각도 S1–S4를 priority에 매핑한다.
   - **완료 조건**: 비어 있으면 검증 가능한 체크리스트를 제안한다.
3. 변경 사항(라벨 추가·제거, 마일스톤, 코멘트 초안)을 이슈별 표로 보여주고 **승인**을 받는다.
4. 반영
   - `gh issue edit <n> --add-label ... --remove-label status:triage --milestone ...`
   - 필요하면 `gh issue comment <n> --body-file ...`
