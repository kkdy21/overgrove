# 릴리스 체크리스트 (v0.1.0)

> 상태: Accepted (Phase 2 게이트, 2026-11-05) · 관련: [release.md](../process/release.md), [process.md](process.md), [scope-mvp.md](../scope-mvp.md), [security-review.md](../design/security-review.md)

릴리스 이슈 `chore(release): v0.1.0`의 완료 조건으로 이 목록을 복사한다. 절차(브랜치, 태그, GitHub Release 생성)는 [release.md](../process/release.md)를 따른다. 이 문서는 "태그를 찍기 전에 무엇을 확인하는가"만 다룬다.

모든 항목에 증거(명령 출력, 링크, 스크린샷)를 릴리스 이슈 코멘트로 남긴다.

---

## 1. 범위와 추적

- [ ] `v0.1.0` 마일스톤의 열린 이슈가 0개다. 남은 이슈는 `v0.2.0` 또는 `later`로 옮겼고, 각각 사유를 코멘트로 남겼다.
- [ ] 열린 S1·S2 버그가 0개다 ([bug-triage.md](bug-triage.md)).
- [ ] 알려진 S3·S4 버그를 릴리스 노트 "Known issues"에 적었다.
- [ ] Phase 4 QA 이슈가 닫혔고, [checklist.md](checklist.md)의 모든 항목이 통과 또는 해당 없음(사유)이다.
- [ ] 모든 Phase 게이트(1–4)의 승인 기록이 있다 ([phase-gates.md](../process/phase-gates.md)).

## 2. 완료 기준 (HANDOFF §14 / scope-mvp.md DoD)

- [ ] 저장소를 등록하면 모든 워크트리가 목록에 나온다 (QA-WT-01, INT-01).
- [ ] 워크트리별 Staged, Unstaged, Untracked, Conflicted가 정확하다 (QA-ST-01, QA-ST-05, INT-02, INT-03).
- [ ] 저장소 전체 stash 목록과 각 stash의 변경 요약이 나온다 (QA-SH-01, QA-SH-02).
- [ ] fetch 뒤 ahead/behind가 정확하고 마지막 fetch 시각이 표시된다 (QA-SY-01, INT-04, INT-12).
- [ ] 커밋 그래프, 작성자, 날짜, WIP 행이 나온다 (QA-GR-01–03).
- [ ] gh 로그인 상태에 따라 이슈 패널이 동작하거나 안내를 보여준다 (QA-IS-01–03).
- [ ] §6.1 위협 항목별 보안 테스트(SEC-T1–T18)가 모두 통과한다. 건너뛴 SEC 테스트가 0개다.
- [ ] 자격 증명과 원격 URL의 민감한 부분이 화면과 로그에서 마스킹된다 (QA-SEC-05, QA-SEC-06).
- [ ] 파서 단위 테스트와 임시 저장소 통합 테스트가 CI(`build-test`)에서 통과한다.
- [ ] README만 보고 소스에서 빌드하고 실행할 수 있다 (§4).
- [ ] LICENSE, CONTRIBUTING, SECURITY, CODE_OF_CONDUCT, 이슈·PR 템플릿이 있다.
- [ ] `v0.1.0` 태그와 릴리스 노트가 준비되었다 (§6).

## 3. 품질 게이트

- [ ] `main`의 최신 커밋에서 필수 검사 3개(`gitleaks`, `pr-policy`, `build-test`)가 녹색이다.
- [ ] CodeQL 경고가 0개이거나, 남은 경고마다 사유가 기록되어 있다.
- [ ] 성능 예산 PB-1–PB-8을 기준 장비에서 측정했고 모두 지킨다. 결과를 `docs/performance/results/`에 남겼다 ([benchmark-plan.md §5](../performance/benchmark-plan.md)).
- [ ] `scripts/measure-git-baseline.sh`를 릴리스 시점의 Apple Git으로 다시 돌렸고, 기준선과 크게 다르지 않다 (±20%).
- [ ] 불안정한 테스트로 건너뛴 항목(`XCTSkip("flaky: …")`)이 모두 이슈로 추적되고 있다.
- [ ] `swift format lint --strict`의 경고가 0개다.

## 4. 소스 빌드 재현

깨끗한 환경에서 README 절차만 따라 한다. 가능하면 다른 macOS 사용자 계정을 쓴다.

- [ ] `git clone https://github.com/kkdy21/overgrove.git` → README의 요구 사항(macOS, Xcode 버전)을 확인했다.
- [ ] Xcode에서 `Overgrove.xcodeproj`를 열고 Run 한 번으로 실행된다 (G10). 서명은 "Sign to Run Locally"로 충분하다.
- [ ] `xcodebuild test -project Overgrove.xcodeproj -scheme Overgrove -destination 'platform=macOS'`가 통과한다.
- [ ] Hardened Runtime이 켜져 있다 (`codesign -d --entitlements - --verbose=2 <앱>`).
- [ ] 외부 패키지가 없다. `Package.resolved`와 SPM 의존성이 없다 (SEC-T17-01).
- [ ] 최소 지원 macOS(14)에서 실행을 확인했다. 장비가 없으면 그 사실을 릴리스 노트에 적는다.

## 5. 보안과 공개 저장소 점검

- [ ] 전체 이력 비밀 검사가 깨끗하다.
  ```sh
  gitleaks git --no-banner --redact -v .
  ```
- [ ] 개인 경로 검사가 깨끗하다. `/Users/<이름>`과 내부 저장소 이름이 커밋, 이슈, PR, 릴리스 노트, 스크린샷에 없다 (gitleaks 개인 경로 규칙 + 수동 확인).
- [ ] `SECURITY.md`의 지원 버전 표에 `0.1.x`가 있고, 비공개 제보 링크가 동작한다.
- [ ] Private vulnerability reporting, secret scanning, push protection, Dependabot alerts가 켜져 있다 ([github-settings.md](../process/github-settings.md)).
- [ ] 워크플로우의 모든 `uses:`가 40자리 SHA로 고정되어 있다 (SEC-T17-02).
- [ ] 호환성 매트릭스의 테스트용 git tarball이 버전·SHA-256으로 고정되어 있고 빌드 전에 검증된다 (SEC-T17-04, ADR-0020).
- [ ] 열린 Dependabot·CodeQL·secret scanning 알림이 0개다.
- [ ] README의 보안 주의 사항이 현재 동작과 일치한다 (신뢰할 수 없는 저장소를 열 때의 보호 범위와 한계).
- [ ] [security-review.md](../design/security-review.md) §5.2 Phase 종료 점검을 다시 확인했다.

## 6. 문서와 릴리스 노트

- [ ] `CHANGELOG.md`의 `Unreleased`를 `[0.1.0] - YYYY-MM-DD`로 바꿨고 비교 링크가 맞다 (Keep a Changelog).
- [ ] README의 스크린샷이 현재 UI다. 스크린샷은 픽스처 저장소로 찍었고 개인 정보가 없다.
- [ ] README의 요구 사항이 실제 빌드 조건과 같다 (macOS, Xcode, git 최소 버전).
- [ ] 릴리스 노트 초안에 다음이 있다: 주요 기능, 요구 사항, 소스 빌드 안내(서명·공증 바이너리 없음), 보안 주의 사항, Known issues, 감사 인사(기여자가 있으면).
- [ ] 문서의 상태 줄(`Proposed` → `Accepted`)을 실제 승인 상태와 맞췄다.

## 7. 태그 직전

- [ ] 릴리스 PR이 머지되었고 `main`이 그 커밋이다.
- [ ] 메인테이너가 서명된 annotated tag를 만든다 (`git tag -s v0.1.0`). 이 작업은 Claude Code가 하지 않는다.
- [ ] GitHub Release는 내용을 메인테이너에게 보여 주고 승인받은 뒤 만든다 (공개 저장소 쓰기).
- [ ] 릴리스 뒤 `v0.1.0` 마일스톤을 닫는다.
