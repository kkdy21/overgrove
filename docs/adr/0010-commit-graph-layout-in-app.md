# ADR-0010: 커밋 그래프 레인은 앱에서 계산한다

> 상태: Proposed (Phase 2 승인 대기) · 날짜: 2026-11-05 · 관련: G6, G9, PB-3, PB-4, [architecture/parsing-spec.md](../architecture/parsing-spec.md)

## 맥락

HANDOFF §9는 그래프에 `log --all --graph --date-order -z`를 적었다. `--graph`의 ASCII 출력에는 다음 문제가 있다.

1. 그래프 문자와 커밋 데이터가 한 줄에 섞여 파싱이 깨지기 쉽다. `-z`와 함께 쓰면 줄 구조도 흐트러진다.
2. 레인 색과 위치를 앱이 통제하지 못한다. 자체 렌더링(디자인 토큰의 레인 색)을 할 수 없다.
3. 10만 커밋에서 git이 전체 그래프를 그린 뒤에야 첫 화면을 그릴 수 있다. 페이지 단위로 불러올 수 없다 (PB-3).

또 `--all`은 `refs/stash`도 포함한다. 그래서 stash 커밋과 그 index·untracked 부모가 그래프에 섞인다 (실험으로 확인).

## 결정

1. 그래프 데이터는 `git log --exclude=refs/stash --all --date-order -z --format=%H%x00%P%x00%an%x00%ae%x00%at%x00%s`로 받는다. `--graph`는 쓰지 않는다.
2. `GraphEngine`(UI 무관 순수 Swift)이 커밋 순서와 부모 목록(`%P`)으로 레인을 계산한다. 결과는 행별로 다음을 담는다.
   - 노드 열
   - 지나가는 선
   - 병합·분기 연결선
   - 레인 색 인덱스
3. **페이지 단위로 불러온다.**
   - 첫 페이지 500개(`-n 500`)를 먼저 그린다.
   - 다음 페이지는 같은 명령에 `--skip=<n> -n 500`을 붙여 읽는다. ref 집합이 같으면 순서가 결정적이므로, 엔진이 열린 레인 상태를 유지한 채 이어서 계산한다. ref 집합 해시가 바뀌면 처음부터 다시 계산한다.
   - 10만 커밋의 뒤쪽 페이지에서 `--skip` 재탐색 비용이 PB-4를 넘으면, 한 프로세스의 출력을 페이지 단위로 소비하는 스트리밍 읽기로 바꾼다. Phase 3 측정 뒤에 이 ADR을 갱신한다.
4. 레인 색은 **레인이 처음 생길 때의 열 인덱스 mod 8**로 정하고, 그 레인이 끝날 때까지 바꾸지 않는다. 색은 디자인 토큰 `graph.lane.0`~`graph.lane.7`이다 ([design/design-tokens.md](../design/design-tokens.md)). 페이지를 이어 읽어도 기존 레인의 색은 유지된다.
5. v0.1은 stash 노드를 그래프에 그리지 않는다. stash는 사이드바와 S-04에서만 보여 준다.
6. WIP 행은 GraphEngine 밖에서, 선택한 워크트리의 HEAD 위에 가상 행으로 얹는다.
7. 서명 관련 포맷(`%G?`, `%GS` 등)은 쓰지 않는다 (T7).

## 대안

| 대안 | 장점 | 단점 | 기각 이유 |
|---|---|---|---|
| `--graph` ASCII 파싱 | 구현이 빠름 | 파싱 취약, 페이지 불가, 색 통제 불가 | 위 맥락 |
| `--topo-order` | 브랜치별로 묶여 보임 | 큰 저장소에서 첫 출력이 느림 (전체 정렬 필요) | PB-3. `--date-order`도 전체 정렬이 필요할 수 있어 Phase 3에서 측정 |
| commit-graph 파일 직접 읽기 | 매우 빠름 | 자체 Git 엔진에 가까움 | N5 |

## 결과

- 그래프 모양을 테스트(GRA-xx)로 고정할 수 있고, 렌더링을 자유롭게 바꿀 수 있다.
- 레인 계산 알고리즘을 직접 구현·유지해야 한다. 문어발 병합(octopus), 고아 브랜치, 매우 긴 레인 등 경계 사례를 테스트로 다룬다.
- `--date-order`의 첫 출력 지연은 저장소 크기에 따라 다르다. `scripts/make-bench-repo.sh`로 측정한 결과에 따라 정렬 옵션을 조정한다.

## 후속 작업

- [ ] GraphEngine 구현과 GRA 테스트 (Phase 3 파서·모델 Epic)
- [ ] 10만 커밋에서 첫 페이지 지연 측정 PERF-xx ([performance/benchmark-plan.md](../performance/benchmark-plan.md))
- [ ] 페이지 방식 재검토: commit-graph가 없으면 `graphPage(skip:limit:)`가 페이지마다 약 400ms 든다. 프로세스 하나로 전체를 스트리밍하며 점진 렌더링하는 방식(첫 500개 약 400ms, 전체 약 560ms 실측)과 비교해 Phase 3에서 결정한다
