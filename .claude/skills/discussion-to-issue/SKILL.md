---
name: discussion-to-issue
description: Overgrove GitHub Discussion의 토론 내용을 요약해 결론을 정리하고, 이슈(필요하면 ADR 후보)로 전환한 뒤 Discussion에 링크와 결론 코멘트를 남긴다. "이 토론 이슈로 옮겨줘" 요청 시 사용.
---

# discussion-to-issue — 토론 → 결정 → 이슈

기준 문서: `docs/process/discussions.md`

1. **토론 읽기**: Discussion 번호로 본문과 댓글을 가져온다.
   ```sh
   gh api graphql -f query='query($n:Int!){repository(owner:"kkdy21",name:"overgrove"){discussion(number:$n){title body category{name} comments(first:100){nodes{author{login} body replies(first:50){nodes{author{login} body}}}}}}}' -F n=<번호>
   ```
2. **결론 요약**: 다음 항목으로 정리한다. 합의가 없으면 이슈로 옮기지 말고 남은 쟁점을 정리해 보고한다.
   - 문제
   - 합의된 결론
   - 기각된 대안과 이유
   - 열린 질문
   - 범위 판단(v0.1 / v0.2 / later)
3. **산출물 결정**
   - 결정 자체가 핵심이면 `type:decision` 이슈를 만든다. 이후 `/adr-new`로 넘어간다.
   - 구현할 일이면 feature, chore 등의 이슈를 만든다. 크면 Epic과 하위 이슈로 나눈다.
4. **이슈 초안**: `/issue-new` 절차를 따른다. 본문 참고 섹션에 Discussion 링크를 넣는다.
5. **승인 요청**: 이슈 초안과 Discussion에 남길 결론 코멘트 초안을 함께 보여주고 승인을 받는다.
6. **반영**
   - 이슈를 생성한다.
   - Discussion에 결론 코멘트를 단다(이슈 링크 포함). GraphQL `addDiscussionComment`를 쓴다.
   - Q&A 카테고리면 답변을 채택하도록 안내한다.
