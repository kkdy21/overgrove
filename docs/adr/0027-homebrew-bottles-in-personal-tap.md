# ADR-0027: Homebrew로는 개인 tap에서 bottle을 붙인 formula를 내고, Developer ID 서명·공증은 하지 않는다

> 상태: Accepted · 날짜: 2026-11-17 · 관련: #694, #105, #687, #675, #630, ADR-0003, ADR-0006, [prd.md](../prd.md) N2, T17, [packaging/homebrew/](../../packaging/homebrew/README.md)

## 맥락

v0.1.0을 쓰려면 지금은 저장소를 받아 `scripts/bootstrap.sh`를 돌리고 Xcode에서 Run을 눌러야 한다. Homebrew 한 줄로 설치할 수 있게 하려면 어떤 형태로 낼지 정해야 한다. 메인테이너는 Apple Developer Program에 가입하지 않았으므로 Developer ID 인증서로 서명하거나 공증을 받을 수 없다. [prd.md](../prd.md) N2는 서명·공증된 바이너리 배포를 비목표로 두고 있었고, 대체 수단은 소스 빌드였다.

판단에 쓴 사실(2026-11-17 기준):

- **Homebrew와 Gatekeeper.**
  - Homebrew 5.0.0(2025-11)은 `--no-quarantine`·`--quarantine`을 폐기 예정으로 바꿨다. macOS 보안 기능을 쉽게 우회하는 수단을 제공하지 않겠다는 이유다. 시험한 Homebrew 7.0.14는 `brew install --no-quarantine`을 `invalid option`으로 거절한다.
  - 같은 발표에서 homebrew/cask의 cask 중 Gatekeeper 검사에 실패하는 것은 2026년 9월부터 비활성화한다고 했다. 6.0.0(2026-06) 발표도 이 일정을 유지했다.
  - 이 변화는 cask에만 해당한다. Homebrew는 cask로 내려받은 앱에만 격리 표시(`com.apple.quarantine`)를 붙인다. formula의 소스와 bottle에는 붙이지 않는다(아래 시험의 `xattr`). 격리 표시가 없는 앱은 실행할 때 Gatekeeper 평가를 거치지 않는다.
  - 6.0.0부터 Homebrew는 공식이 아닌 tap의 코드를 사용자가 신뢰(tap trust)한 뒤에만 읽는다. `brew install kkdy21/tap/overgrove`처럼 이름 전체로 설치하면 tap을 받아 오고 그 formula 하나만 신뢰한다.
  - homebrew-core는 주 산출물이 `.app`인 formula를 받지 않는다([Acceptable Formulae](https://docs.brew.sh/Acceptable-Formulae)). formula로 낸다면 개인 tap에 둘 수밖에 없다.
  - Homebrew 7.0.14는 `HOMEBREW_VERIFY_ATTESTATIONS=1`일 때, 서드파티 tap bottle도 그 tap 저장소(`kkdy21/homebrew-tap`)의 build provenance attestation으로 확인한다. attestation의 subject 이름이 Homebrew가 쓰는 bottle 파일 이름(`overgrove--0.1.0.arm64_sonoma.bottle.tar.gz`)과 같아야 한다(`Library/Homebrew/attestation.rb`). 이 경로는 실제 tap이 있어야 시험할 수 있어서 이번에는 코드로만 확인했다.
- **Apple silicon의 서명 요구.** arm64 코드는 서명이 전혀 없으면 실행되지 않고, ad-hoc 서명이면 실행된다. 아래 시험에서 서명을 지운 arm64 실행 파일은 SIP가 켜진 macOS 26.5.2에서 `Killed: 9`(종료 코드 137)로 끝났고, `codesign -s -`로 ad-hoc 서명하자 실행됐다.
- **빌드 조건.** 빌드에는 Xcode 26이 필요하다(macOS 26 SDK API를 쓰고, bootstrap과 CI가 26을 요구한다). Xcode 26.0–26.3은 macOS 15.6 이상에서, 26.4부터는 macOS 26.2 이상에서 돈다. 앱은 macOS 14 이상에서 돈다(ADR-0003). 그래서 소스 빌드만 있으면 macOS 14와 15.0–15.5 사용자는 Homebrew로 설치할 수 없다.
- **아키텍처.** 프로젝트는 `ARCHS`를 정하지 않아 Release는 기본값(arm64, x86_64)으로 빌드할 수 있지만, CI는 Apple silicon 러너(`macos-26`)에서만 돈다. Intel에서의 동작은 검증하지 않는다. Homebrew는 2026년 9월부터 Intel x86_64를 Tier 3로 내리고 Intel bottle을 더 만들지 않으며, 2027년 9월부터는 Intel에서 돌지 않는다.
- **신뢰 차이.** 개인 tap 사용자는 이미 tap 주인을 믿고 그 formula 코드(Ruby)를 자기 Mac에서 실행한다. bottle을 쓰면 여기에 "tap 쪽에서 만든 바이너리를 믿는 것"이 더해진다. 출처 증명과 sha256 고정으로 그 차이를 줄일 수 있다.

### 시험

2026-11-17, `main`(0271a88)으로 로컬 tap을 만들어 시험했다. 시험한 formula는 [packaging/homebrew/Formula/overgrove.rb](../../packaging/homebrew/Formula/overgrove.rb)와 같고 `url`·`sha256`·bottle 블록만 시험용 값이었다.

- 장비 A: Apple silicon(M1) Mac, macOS 26.5.2, Xcode 26.6, Homebrew 7.0.14. `xcode-select`는 Command Line Tools를 가리킨다.
- 장비 B: 장비 A 위의 VM, macOS 14.8.7, Xcode 없음(Command Line Tools 16.2만), Homebrew 6.0.22. 이미지 기본값으로 SIP가 꺼져 있다.

**소스 빌드(장비 A)**

- 세 가지 소스로 Homebrew 빌드 샌드박스 안에서 빌드·설치됐다. `git archive` tarball(file URL), GitHub 커밋 아카이브 URL, `--HEAD`(git clone)다. `deny_network_access!`로 네트워크를 막았다. git 메타데이터, `scripts/bootstrap.sh`, `Config/Personal.xcconfig.local`은 필요 없었다. 프로젝트에 스크립트 빌드 단계도 없다.
- 시간: 빌드 1분 12–21초, `brew install` 전체 약 75초. 산출물은 arm64 단일 아키텍처 19MB다. Xcode 26.6에서 컴파일러 경고는 없었다.
- 처음 시도에서 두 군데를 고쳤다.
  1. `depends_on xcode:`는 통과했지만 `xcodebuild`가 "requires Xcode, but active developer directory … is a command line tools instance"로 실패했다. `ENV["DEVELOPER_DIR"] = ENV["HOMEBREW_DEVELOPER_DIR"]`로 Homebrew가 찾은 Xcode를 쓰게 했다. homebrew-core의 `v8`과 같은 방법이다.
  2. Swift 컴파일러가 매크로 플러그인(`@Observable`)을 `sandbox-exec`로 가두려다 `sandbox_apply: Operation not permitted`를 냈고, `ObservableMacro could not be found` 오류로 빌드가 멈췄다. Homebrew 샌드박스 안에서는 샌드박스를 겹쳐 걸 수 없다. `OTHER_SWIFT_FLAGS=$(inherited) -disable-sandbox`로 컴파일러의 샌드박스만 끈다. 빌드 전체는 여전히 Homebrew 샌드박스 안에 있다. homebrew-core의 SwiftPM formula들이 `--disable-sandbox`를 쓰는 것과 같은 이유다.
- `brew style`: no offenses. `brew audit --strict`, `--strict --online --new`: 문제 없음(audit은 formula를 신뢰한 뒤에만 돈다). `brew test`: 통과.
- 이름 전체로 설치하자 Homebrew가 `Trusted formula …`를 출력하고 그 formula만 신뢰 목록에 넣었다. 받아 두지 않은 tap도 이름 전체로 설치하면 tap을 받아 온다는 것을 다른 공개 tap으로 확인했다.

**bottle(장비 A에서 만들고 A·B에서 설치)**

- `brew install --build-bottle` 74초(빌드 1분 13초), `brew bottle --json` 8초, bottle 5.5MB다.
- `brew bottle`은 빌드한 Mac의 macOS를 따라 `arm64_tahoe` 태그를 붙였다. 파일 이름만 `arm64_sonoma`로 바꾸고 formula에 `sha256 arm64_sonoma: …`로 적었다. 내용과 sha256은 같다. Homebrew는 맞는 태그가 없으면 같은 아키텍처의 더 옛 macOS 태그를 쓰므로(`find_older_compatible_tag`), 이 bottle 하나가 macOS 14부터 최신까지 덮는다.
- 이 bottle은 relocatable이 아니다. 앱이 자식 프로세스에 넘기는 고정 `PATH`(`/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin`)에 `/opt/homebrew`가 들어 있어서, Homebrew가 cellar를 `/opt/homebrew/Cellar`로 고정했다. 다른 prefix의 Homebrew는 bottle 대신 소스 빌드를 한다.
- 장비 A(macOS 26.5.2)에서 `arm64_sonoma` bottle을 부었다(3초).
- 장비 B(macOS 14.8.7, Xcode 없음)에서 bottle을 부었다(2초). `open`으로 앱을 실행하자 Gatekeeper 확인 창 없이 메인 창이 떴고, QA용 픽스처 저장소의 워크트리·그래프·WIP가 표시됐다.
- 소스 빌드 대체 경로가 남아 있다. bottle 블록이 있는 상태에서 `brew reinstall --build-from-source`가 76초에 빌드·설치됐다. 맞는 태그가 없을 때(bottle 블록에 x86_64용 `sonoma` 태그만 둔 시험)는 Homebrew가 알아서 소스 빌드를 했다(74초). 다만 bottle 파일을 받지 못하면 소스로 넘어가지 않고 실패했다(파일 이름을 틀리게 올린 시험). 그때는 `--build-from-source`로 설치한다.

**서명과 격리 표시**

| 확인 | 장비 A (소스 빌드·bottle) | 장비 B (bottle) |
|---|---|---|
| `codesign -dv --verbose=2` | `Signature=adhoc`, `flags=0x10002(adhoc,runtime)`, `TeamIdentifier=not set` | 같음 |
| `codesign --verify --deep --strict` | valid on disk | valid on disk |
| CDHash | `1d8783715a…` (빌드 직후, bottle tarball 안, 부은 뒤 모두 같음) | 같음 |
| entitlements | `com.apple.security.get-task-allow = true` (#687에서 뺀다) | 같음 |
| `xattr` | `com.apple.quarantine` 없음 | 앱과 내려받은 bottle 모두 없음. https로 받은 homebrew-core bottle과 그 keg에도 없음 |
| `spctl -a -vv` | `rejected` | `rejected` (assessments enabled) |
| 실행 | 확인하지 않음(GUI를 쓰지 않는 장비) | 실행됨 |

- Homebrew는 bottle을 부으면서 재서명하지 않았다. CDHash가 빌드한 Mac과 같다. Homebrew는 relocation으로 Mach-O를 고친 경우에만 다시 서명하는데(`codesign_patched_binary`, Apple silicon에서는 ad-hoc), 이 bottle은 prefix가 같아 고칠 곳이 없었다.
- `spctl`은 ad-hoc 서명을 거절한다. 그래도 격리 표시가 없으면 실행할 때 이 평가를 하지 않으므로 앱이 뜬다. Xcode에서 직접 빌드한 앱과 같은 상태다.
- 장비 B는 SIP가 꺼져 있어서 서명이 없는 arm64 실행 파일도 돌았다. 서명 요구에 대한 증거는 장비 A의 결과만 쓴다.

## 결정

v0.1.0부터 Homebrew 설치는 개인 tap `kkdy21/homebrew-tap`의 formula `overgrove`로 한다. 설치 명령은 `brew install kkdy21/tap/overgrove`다. formula에는 Apple silicon용 bottle을 붙이고, bottle을 쓸 수 없는 환경에서는 소스에서 빌드한다. Developer ID 서명과 공증은 하지 않는다.

1. **배포물.** GitHub Release가 자동으로 붙이는 소스 아카이브와, tap 저장소의 Release에 붙이는 Homebrew bottle(ad-hoc 서명)이다. App Store 배포, Developer ID 서명·공증 바이너리, cask는 내지 않는다. 이에 맞춰 N2와 prd.md 제약을 고친다.
2. **원본.** formula와 tap 워크플로우의 원본은 이 저장소의 [packaging/homebrew/](../../packaging/homebrew/README.md)다. 빌드 방법은 이 저장소의 PR로 리뷰한 뒤 tap에 옮긴다. tap에는 릴리스마다 `url`·`sha256`·bottle 블록을 채운 formula가 올라간다. 태그 tarball에 이 파일도 들어가므로, 저장소의 템플릿에는 tarball 자신의 sha256을 넣을 수 없다. 그래서 자리 표시 값을 둔다.
3. **소스.** GitHub이 태그에 붙이는 소스 아카이브(`archive/refs/tags/vX.Y.Z.tar.gz`)를 sha256으로 고정한다. `head`는 `main`이다.
4. **bottle.**
   - Apple silicon(arm64)용 하나를 `arm64_sonoma` 태그로 낸다. 빌드는 Xcode 26이 있는 GitHub 러너(`macos-26`)에서 하고, macOS 14 호환은 앱의 deployment target(14.0)이 맡는다. `brew bottle`은 러너의 macOS 태그를 붙이므로 파일 이름의 태그만 `arm64_sonoma`로 바꾼다.
   - Intel(x86_64) bottle은 내지 않는다. CI가 Intel을 검증하지 않고, Homebrew도 Intel을 Tier 3로 내렸다. Intel Mac과 기본 prefix가 아닌 Homebrew는 소스 빌드로 설치한다(macOS 15.6 이상, Xcode 26).
   - 빌드와 공개는 tap 저장소의 GitHub Actions 워크플로우가 한다([예시](../../packaging/homebrew/.github/workflows/bottle.yml)). 메인테이너의 Mac에서 만든 bottle은 올리지 않는다.
   - 한 번 공개한 bottle 파일은 바꾸지 않는다. bottle을 고쳐야 하면 새 패치 버전을 낸다. 워크플로우는 버전마다 bottle 하나(`rebuild` 0)만 만든다.
5. **공급망 대책(T17).**
   - tap 워크플로우의 Action은 전체 커밋 SHA로 고정하고, tap 저장소의 Dependabot이 갱신한다.
   - 권한은 최소로 둔다. 최상위는 `contents: read`다. bottle을 빌드하는 job은 `id-token: write`와 `attestations: write`만 더하고, Release를 만드는 job만 `contents: write`를 갖는다. 트리거는 `workflow_dispatch` 하나다.
   - `actions/attest`로 bottle의 SLSA build provenance attestation을 남긴다. `actions/attest-build-provenance` v4는 이 액션을 감싼 것이고, 새로 쓰는 곳은 `actions/attest`를 쓰라는 것이 upstream 안내다. subject 이름은 Homebrew가 확인하는 이름(`name--version.tag.bottle.tar.gz`)으로 한다.
   - README에 확인 방법을 적는다. `HOMEBREW_VERIFY_ATTESTATIONS=1 brew install …`로 Homebrew가 붓기 전에 확인하게 하거나, `gh attestation verify "$(brew --cache kkdy21/tap/overgrove)" --repo kkdy21/homebrew-tap --signer-workflow kkdy21/homebrew-tap/.github/workflows/bottle.yml`으로 직접 확인한다. 둘 다 gh 로그인이 필요하다. Homebrew의 확인은 저장소 단위까지만 보므로, 직접 확인할 때는 `--signer-workflow`로 워크플로우까지 좁힌다.
   - 소스 tarball과 bottle의 sha256을 formula에 고정한다. Homebrew가 내려받을 때 검사한다.
   - Release는 bottle을 빌드한 커밋에 태그를 붙여 만들고(`--target`), 공개 job은 빌드 job이 attest한 파일의 sha256을 다시 확인한 뒤 올린다.
   - bottle을 믿지 않는 사용자는 `brew install --build-from-source kkdy21/tap/overgrove`로 같은 formula를 소스에서 빌드할 수 있다.
6. **빌드 설정.** formula는 `xcodebuild`(DSL 도우미)로 Release를 빌드한다.
   - `-derivedDataPath`는 빌드 디렉터리 안에 두고, 아키텍처는 빌드하는 Mac의 것 하나만 쓴다.
   - 서명은 ad-hoc이다(`CODE_SIGN_IDENTITY=-`, 팀 없음). Hardened Runtime은 프로젝트 설정대로 켠다.
   - `DEVELOPER_DIR`과 `-disable-sandbox`는 위 시험에서 고친 두 가지다.
   - 경고를 오류로 보지 않는다(`SWIFT_TREAT_WARNINGS_AS_ERRORS=NO`, `GCC_TREAT_WARNINGS_AS_ERRORS=NO`). CI(Xcode 26)는 계속 경고를 막는다. 설치하는 사람의 더 새로운 Xcode가 내는 새 경고 때문에 설치가 깨지지 않게 하려는 것이다(예: Xcode 27의 `[#ActorIsolatedCall]`, #630).
   - `depends_on xcode: ["26.0", :build]`, `depends_on macos: :sonoma`, `deny_network_access!`.
7. **test.** 앱에는 명령행 모드가 없어 실행하지 않는다. 번들, Bundle ID, `CFBundleShortVersionString`이 formula 버전과 같은지(HEAD는 제외), `codesign --verify --deep --strict`, ad-hoc·runtime 플래그를 확인한다. 그래서 태그를 만들기 전에 `MARKETING_VERSION`을 태그 버전과 맞춘다.
8. **설치 위치.** `prefix`에 `Overgrove.app`만 둔다. `~/Applications`에 링크하거나 복사하는 방법은 caveats로 안내하고, formula가 홈 디렉터리를 건드리지 않는다.
9. 절차는 [release.md](../process/release.md) §3, 확인 항목은 [release-checklist.md](../qa/release-checklist.md)를 따른다.

## 대안

| 대안 | 장점 | 단점 | 기각 이유 |
|---|---|---|---|
| A — 개인 tap, bottle을 붙인 formula와 소스 빌드 대체 | macOS 14 이상 Apple silicon에서 Xcode 없이 몇 초 만에 설치된다. 격리 표시가 붙지 않아 Gatekeeper를 직접 풀 필요가 없다. 비용이 없다 | tap의 CI가 만든 바이너리를 배포한다(공급망 위험). 릴리스 단계가 늘어난다 | **채택** |
| B — 개인 tap, 소스 빌드만 하는 formula | 바이너리를 배포하지 않아 기존 N2를 그대로 지킨다 | macOS 14와 15.0–15.5 사용자는 설치할 수 없다. 모든 사용자에게 Xcode 26 전체가 필요하고, 설치마다 1분 넘게 빌드한다 | 앱이 지원하는 macOS 범위를 덮지 못한다 |
| C — Developer ID 서명·공증 cask | Gatekeeper를 통과한다. homebrew/cask에도 낼 수 있고 Intel·macOS 14까지 한 번에 덮는다 | Apple Developer Program 연회비가 들고, 인증서와 공증 자격 증명을 CI 비밀로 관리해야 한다 | 메인테이너가 가입하지 않았다. 아래 조건에서 다시 본다 |
| D — 서명하지 않은(ad-hoc) cask를 개인 tap에 | Xcode 없이 설치된다 | cask 다운로드에는 격리 표시가 붙어 사용자가 매번 Gatekeeper를 직접 풀어야 한다. `--no-quarantine`도 없어졌다. 보안 기능을 끄는 법을 안내하게 된다 | 사용자 경험과 보안 안내가 모두 나쁘다 |
| E — homebrew-core formula | tap 없이 `brew install overgrove` | 주 산출물이 `.app`인 formula는 받지 않는다 | 해당 없음 |

## 결과

- 좋아지는 점
  - macOS 14 이상 Apple silicon 사용자가 Xcode 없이 한 줄로 설치한다.
  - 소스 빌드 경로가 같은 formula 안에 남는다. Xcode에서 직접 빌드하는 방법도 그대로다.
  - Gatekeeper를 끄거나 격리 표시를 지우라는 안내를 하지 않는다.
- 나빠지는 점, 감수하는 비용
  - tap 쪽 CI가 만든 바이너리를 배포하므로 공급망 위험이 늘어난다(T17). ad-hoc 서명은 출처를 보증하지 않는다. 출처 확인은 attestation뿐이고, Homebrew는 `HOMEBREW_VERIFY_ATTESTATIONS`를 켠 사용자에게만 이를 확인한다.
  - bottle은 Homebrew가 `/opt/homebrew`에 있을 때만 쓰인다. Intel Mac과 다른 prefix는 소스 빌드를 해야 하고, 그래서 macOS 15.6 이상과 Xcode 26이 필요하다. macOS 14를 쓰는 Intel Mac은 Homebrew로 설치할 방법이 없다.
  - 릴리스마다 tap formula 갱신, 워크플로우 실행, bottle 블록 커밋이 늘어난다.
  - `brew bottle`이 붙인 태그를 이름에서 바꾸는 방식에 기댄다. Homebrew는 지금 bottle 안의 빌드 정보를 태그와 대조하지 않는다.
  - #687이 머지되기 전의 Release 빌드에는 `get-task-allow`가 들어간다.
- 다시 검토해야 하는 조건
  - Homebrew가 formula나 bottle 다운로드에 격리 표시를 붙이기 시작하거나, tap의 GUI 앱 formula를 막을 때. 그때는 Developer ID 서명·공증 cask로 옮긴다. 메인테이너가 Apple Developer Program에 가입해야 하고, N2를 다시 고치는 ADR을 쓴다.
  - 메인테이너가 Apple Developer Program에 가입할 때.
  - Homebrew가 bottle의 빌드 macOS와 태그를 대조해, 이름만 바꾼 `arm64_sonoma` bottle을 거절할 때.
  - Intel bottle이나 다른 prefix용 bottle을 원하는 사용자가 많을 때.
  - Homebrew가 서드파티 tap bottle의 attestation을 기본으로 확인하게 될 때. 안내를 줄인다.

## 후속 작업

- [ ] #105: `kkdy21/homebrew-tap` 저장소를 만들고 `packaging/homebrew/`를 옮긴 뒤 첫 bottle을 공개한다. `HOMEBREW_VERIFY_ATTESTATIONS=1` 설치와 `gh attestation verify`를 실제 bottle로 확인한다
- [ ] #687: Release 빌드에서 `get-task-allow`를 뺀다. 첫 bottle은 이것이 머지된 태그로 만든다(release-checklist §8). 머지 뒤 formula test에 entitlement가 없는지 확인하는 단계를 더할지 본다
- [ ] #675: README에 Homebrew 설치와 출처 확인 방법을 적는다. SECURITY.md의 "as source only" 문구는 첫 bottle을 공개하는 릴리스 PR에서 고친다
- [ ] #703: `packaging/homebrew/.github/`의 워크플로우 예시도 `scripts/lint/check-workflows.sh`와 guard-edit hook이 검사하게 한다
- [x] prd.md N2·제약, T17, release.md, release-checklist.md, `packaging/homebrew/` (#694, 이 PR)
