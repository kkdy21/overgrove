# 릴리스

> 상태: Accepted · 관련: [qa/release-checklist.md](../qa/release-checklist.md), [CHANGELOG.md](../../CHANGELOG.md), ADR-0002, ADR-0027, [packaging/homebrew/](../../packaging/homebrew/README.md)

## 1. 버전 정책

- [Semantic Versioning](https://semver.org/)을 따른다. `0.x` 동안은 minor 버전에도 호환성을 깨는 변경이 들어갈 수 있다.
- 태그 형식은 `vMAJOR.MINOR.PATCH`(예: `v0.1.0`)다. 마일스톤 이름과 같다.
- 배포물은 GitHub Release의 **소스 아카이브**와, Homebrew 개인 tap `kkdy21/homebrew-tap`의 **bottle**(Apple silicon, ad-hoc 서명, build provenance attestation)이다. bottle을 쓸 수 없는 환경에서는 같은 formula가 소스에서 빌드한다. Developer ID 서명·공증 바이너리와 App Store 배포는 하지 않는다(N2, ADR-0027).

## 2. 변경 기록

- `CHANGELOG.md`는 [Keep a Changelog](https://keepachangelog.com/) 형식이다.
- 사용자에게 보이는 변경이 있는 PR은 `Unreleased`에 한 줄을 추가한다(PR 체크리스트 항목).
- 분류는 Added / Changed / Deprecated / Removed / Fixed / Security.
- 보안 수정은 advisory가 공개된 뒤에 상세를 적는다.

## 3. 절차

1. 릴리스 이슈를 만든다: `chore(release): v0.1.0`(`phase:release`).
2. [release-checklist.md](../qa/release-checklist.md)를 이슈의 완료 조건으로 복사해 하나씩 확인한다.
3. 릴리스 PR(`chore/<n>-release-v0-1-0`)을 연다:
   - `CHANGELOG.md`의 `Unreleased`를 `[0.1.0] - YYYY-MM-DD`로 바꾸고 비교 링크를 갱신한다.
   - README의 상태 배지와 문구를 갱신한다.
4. 머지 후 `main`에서 서명된 annotated tag를 만든다(메인테이너):
   ```sh
   git switch main && git pull --ff-only
   git tag -s v0.1.0 -m "Overgrove v0.1.0"
   git push origin v0.1.0
   ```
   태그 푸시는 룰셋의 브랜치 보호 대상이 아니다. 태그 보호 룰셋은 v0.1.0 전에 추가를 검토한다.
5. GitHub Release를 만든다. GitHub이 자동으로 붙이는 소스 아카이브만 쓴다:
   ```sh
   gh release create v0.1.0 --repo kkdy21/overgrove --title "Overgrove v0.1.0" --notes-file <changelog-section>
   ```
6. Homebrew tap을 갱신한다(ADR-0027). 원본은 이 저장소의 [packaging/homebrew/](../../packaging/homebrew/README.md)다. 첫 릴리스에서는 공개 저장소 `kkdy21/homebrew-tap`을 만들고 `Formula/`, `.github/`, `README.md`를 그대로 옮긴다(#105). tap 저장소에서 Actions의 워크플로우 권한은 기본값(읽기)으로 둔다. 쓰기 권한은 워크플로우가 job마다 직접 요청한다.
   1. 태그 아카이브의 sha256을 구한다.
      ```sh
      curl -fsSL https://github.com/kkdy21/overgrove/archive/refs/tags/v0.1.0.tar.gz | shasum -a 256
      ```
   2. tap에 브랜치(예: `update/overgrove-0.1.0`)를 만든다. `Formula/overgrove.rb`에서 `url`의 버전과 `sha256`을 바꾸고 이전 버전의 bottle 블록을 지운다. 빌드 단계가 `packaging/homebrew/Formula/overgrove.rb`와 같은지 확인하고 커밋해 push한다.
   3. 그 브랜치에서 `bottle` 워크플로우를 실행한다. Apple silicon 러너가 formula를 소스에서 빌드하고 `brew test`를 돌린 뒤, bottle에 build provenance attestation을 남기고 tap의 `overgrove-0.1.0` Release에 올린다.
      ```sh
      gh workflow run bottle.yml --repo kkdy21/homebrew-tap --ref update/overgrove-0.1.0
      gh run list --repo kkdy21/homebrew-tap --workflow bottle.yml --limit 1   # 실행 ID 확인
      gh run watch <run-id> --repo kkdy21/homebrew-tap --exit-status
      ```
   4. 실행 요약에 나온 bottle 블록을 같은 브랜치에 커밋하고 tap의 `main`에 합친다. 이렇게 해야 bottle이 없는 새 버전 formula가 `main`에 먼저 올라가 사용자가 소스 빌드로 넘어가는 일이 없다. 공개한 bottle은 바꾸지 않는다. bottle을 고쳐야 하면 새 패치 버전을 낸다.
   5. Xcode가 없는 Apple silicon Mac에서 설치를 확인한다(가능하면 macOS 14). 결과는 릴리스 이슈에 남긴다.
      ```sh
      HOMEBREW_VERIFY_ATTESTATIONS=1 brew install kkdy21/tap/overgrove   # tap을 받고 이 formula만 신뢰한 뒤 bottle을 붓는다
      brew audit --strict --online --formula kkdy21/tap/overgrove
      brew style kkdy21/tap/overgrove
      brew test kkdy21/tap/overgrove
      gh attestation verify "$(brew --cache kkdy21/tap/overgrove)" --repo kkdy21/homebrew-tap \
        --signer-workflow kkdy21/homebrew-tap/.github/workflows/bottle.yml
      app="$(brew --prefix)/opt/overgrove/Overgrove.app"
      codesign -dv --verbose=2 "$app"   # Signature=adhoc, flags=0x10002(adhoc,runtime)
      codesign -d --entitlements - "$app"   # entitlement가 없어야 한다(get-task-allow 없음, #687)
      xattr "$app"                       # com.apple.quarantine이 없어야 한다
      open "$app"
      ```
      Xcode 26이 있는 Mac에서는 `brew reinstall --build-from-source kkdy21/tap/overgrove`로 소스 빌드 경로도 확인한다.
7. Announcements Discussion에 공지하고, 마일스톤을 닫는다.

## 4. 핫픽스

`main`에서 `fix/<n>-<slug>`로 고치고 PATCH 버전을 올린다. 0.x 동안은 지난 버전용 유지보수 브랜치를 두지 않는다. 지원 범위는 [SECURITY.md](../../SECURITY.md)를 따른다.
