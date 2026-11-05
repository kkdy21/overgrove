---
name: issue-new
description: Overgrove 저장소에 새 GitHub 이슈를 템플릿 형식으로 초안 작성하고, 사용자 승인 후 라벨·마일스톤·보드까지 설정해 생성한다. "이슈 만들어줘", "이거 이슈로 등록", 범위 밖 아이디어를 later로 남길 때 사용.
---

# issue-new — 이슈 초안 → 승인 → 생성

공개 저장소이므로 **승인 없이 이슈를 만들지 않는다.**

## 절차

1. **중복 확인**
   `gh issue list --repo kkdy21/overgrove --state all --search "<핵심어>" --limit 20`
   비슷한 이슈가 있으면 새로 만들지 말고 링크를 제시한다.
2. **유형 결정**: feature / bug / spike / decision / docs / chore. 템플릿은 `.github/ISSUE_TEMPLATE/<유형>.yml`이다.
   - 모든 Epic은 `type:epic`이다.
   - 범위 밖 아이디어(쓰기 작업 등)는 유형과 무관하게 마일스톤을 `later`로 둔다.
3. **초안 작성**
   - **제목**: 영어 Conventional 형식. 예: `feat(parser): parse porcelain v2 rename records`, `[EPIC] Phase 3 — Git layer`
   - **본문**: 한국어 가능. 템플릿 필드 순서를 그대로 따른다.
     feature 기준: 배경 / 목표 / 완료 조건(체크리스트) / Phase / Area / 보안 고려 사항 / 참고
   - 관련 문서는 상대 경로로 링크한다. G·N, S-xx, T-xx, 테스트 ID, ADR 번호를 적는다. 식별자는 `docs/README.md` §2 기준이다.
   - **금지**: 개인 경로, 토큰, 내부 저장소 이름
4. **라벨·마일스톤 선택**
   - 라벨은 `.github/labels.json`에 있는 것만 쓴다.
   - type 1개, phase 1개, area 1개 이상, priority 1개를 붙인다.
   - 신규 외부 제보에만 `status:triage`를 붙인다. 메인테이너가 만드는 이슈는 트리아지된 상태로 만든다.
   - 마일스톤은 `v0.1.0`, `v0.2.0`, `later` 중 하나다.
5. **승인 요청**: 제목, 라벨, 마일스톤, 본문 전체를 보여주고 승인을 받는다. 여러 개면 표로 한 번에 보여주고 일괄 승인을 받는다.
6. **생성**
   ```sh
   gh issue create --repo kkdy21/overgrove --title "<title>" --body-file <tmpfile> \
     --label "type:feature,phase:dev,area:parser,priority:p1" --milestone "v0.1.0"
   ```
7. **연결**
   - Epic의 하위 이슈면 네이티브 sub-issue로 연결한다. `sub_issue_id`는 이슈 번호가 아니라 REST `id`다.
     ```sh
     child_id=$(gh api repos/kkdy21/overgrove/issues/<child> --jq .id)
     gh api -X POST repos/kkdy21/overgrove/issues/<epic>/sub_issues -F sub_issue_id=$child_id
     ```
     Epic 본문의 task list에도 `- [ ] #<child>`를 추가한다.
   - Projects 보드에 추가한다(`project` scope 필요).
     `gh project item-add <번호> --owner kkdy21 --url <issue-url>`
8. **보고**: 생성된 이슈 URL을 알려준다.
