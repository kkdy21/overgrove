---
name: adr-new
description: Overgrove의 새 아키텍처 결정 기록(ADR)을 docs/adr/에 다음 번호로 만들고 관련 이슈·문서와 연결한다. 결정이 내려졌거나 type:decision 이슈를 정리할 때 사용.
---

# adr-new — 결정 기록

1. 다음 번호: `ls docs/adr/ | grep -E '^[0-9]{4}-' | sort | tail -1`의 번호에 1을 더한다.
2. 파일 만들기: `docs/adr/NNNN-<kebab-case-title>.md`
   - `docs/adr/0000-template.md` 형식을 따른다: 상태, 날짜, 맥락, 결정, 대안, 결과, 후속 작업
   - 상태
     - 사용자가 승인한 결정이면 `Accepted`
     - 제안 단계면 `Proposed`
     - 기존 ADR을 대체하면 새 ADR은 `Accepted`, 기존 ADR은 `Superseded by ADR-NNNN`으로 바꾼다
3. 연결
   - `docs/adr/README.md` 인덱스와 `docs/README.md` §2.5 표에 행을 추가한다.
   - 결정의 영향을 받는 명세 문서에 링크를 추가한다.
   - 관련 `type:decision` 이슈에 ADR 링크를 단다(코멘트는 승인 후). PR 본문에 `Closes #<decision-issue>`를 넣는다.
4. 문서 안에 결정 근거를 중복해서 쓰지 말고 ADR을 링크한다.
