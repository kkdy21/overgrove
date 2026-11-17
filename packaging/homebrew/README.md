# Homebrew tap for Overgrove

This directory is the source of the [`kkdy21/homebrew-tap`](https://github.com/kkdy21/homebrew-tap) repository. At
release time its contents are copied there: `Formula/overgrove.rb`, `.github/`, and this README. The decision and the
test results behind it are in
[ADR-0027](https://github.com/kkdy21/overgrove/blob/main/docs/adr/0027-homebrew-bottles-in-personal-tap.md).

## Install

```sh
brew install kkdy21/tap/overgrove
```

- On Apple silicon with macOS 14 or later and Homebrew in `/opt/homebrew`, this pours a prebuilt bottle. Xcode is
  not needed.
- Anywhere else (an Intel Mac, another Homebrew prefix, or `--build-from-source`), Homebrew builds the app from the
  tagged source. That needs Xcode 26, which runs on macOS 15.6 or later.
- Installing by the full name trusts only this formula, not the whole tap
  ([tap trust](https://docs.brew.sh/Tap-Trust)).
- The app is installed at `$(brew --prefix)/opt/overgrove/Overgrove.app`. The install message shows how to link or
  copy it into `~/Applications`.

The bottle is ad-hoc signed. It is not signed with a Developer ID or notarized by Apple. Homebrew does not mark
formula downloads as quarantined, so macOS opens the app without a Gatekeeper prompt. To check that a bottle was built
by this tap's GitHub Actions workflow, use its build provenance attestation. Both ways need the
[GitHub CLI](https://cli.github.com/) logged in:

```sh
# Let Homebrew check the attestation before it pours the bottle
HOMEBREW_VERIFY_ATTESTATIONS=1 brew install kkdy21/tap/overgrove

# Or check the downloaded bottle yourself
brew tap kkdy21/tap
brew trust --formula kkdy21/tap/overgrove
brew fetch kkdy21/tap/overgrove
gh attestation verify "$(brew --cache kkdy21/tap/overgrove)" --repo kkdy21/homebrew-tap
```

## For maintainers

| Path | What it is |
|---|---|
| `Formula/overgrove.rb` | The formula. In this repository `sha256` is a placeholder and the bottle block is a comment: the tag tarball contains this file, so the file cannot hold the tarball's own checksum. |
| `.github/workflows/bottle.yml` | Builds the bottle on a GitHub-hosted Apple silicon runner, attests it, and attaches it to a release of the tap. Run by hand. It is an example here and never runs in `kkdy21/overgrove`. |
| `.github/dependabot.yml` | Keeps the tap's pinned action SHAs current. |

- Release steps: [docs/process/release.md](https://github.com/kkdy21/overgrove/blob/main/docs/process/release.md)
  §3 and [docs/qa/release-checklist.md](https://github.com/kkdy21/overgrove/blob/main/docs/qa/release-checklist.md).
- Change the build steps here first, by pull request, then copy them to the tap. If the tap's copy changes (for
  example, a Dependabot pin bump), bring that change back here.
- Never replace a published bottle. Rebuild with a higher `rebuild` number instead.
- Why the formula passes these build settings:
  - `DEVELOPER_DIR`: `depends_on xcode:` accepts an installed Xcode even when `xcode-select` points at the Command
    Line Tools, but `xcodebuild` then fails. The formula uses the Xcode that Homebrew found.
  - `OTHER_SWIFT_FLAGS=-disable-sandbox`: the Swift compiler runs macro plugins (`@Observable`) under
    `sandbox-exec`, which cannot nest inside Homebrew's build sandbox. Homebrew's sandbox still confines the build.
  - `SWIFT_TREAT_WARNINGS_AS_ERRORS=NO`, `GCC_TREAT_WARNINGS_AS_ERRORS=NO`: a newer Xcode than CI's can add
    warnings, and they should not stop an install. CI keeps treating warnings as errors.
  - `ARCHS` set to the building Mac's architecture, and ad-hoc signing with no team.
