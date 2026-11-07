#!/usr/bin/env bash
# Tests scripts/lint/check-workflows.sh against throwaway trees (SEC-T17-02, SEC-T17-03, #95). No network.
# Run: scripts/lint/check-workflows.test.sh
set -euo pipefail
CHECK="$(cd "$(dirname "$0")" && pwd)/check-workflows.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail=0

sha=0123456789abcdef0123456789abcdef01234567
sum=$(printf 'a%.0s' {1..64})

good_workflow="name: ci
on: [push]
permissions:
  contents: read
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@$sha # v7
      - uses: ./.github/actions/local
      - name: Title
        env:
          TITLE: \${{ github.event.pull_request.title }}
        run: echo \"\$TITLE\""

good_scan="name: secret-scan
on: [push]
permissions:
  contents: read
jobs:
  gitleaks:
    runs-on: ubuntu-latest
    steps:
      - name: Install
        env:
          GITLEAKS_VERSION: \"8.30.1\"
          GITLEAKS_SHA256: \"$sum\"
        run: echo \"\$GITLEAKS_SHA256  f\" | sha256sum -c -"

good_compat="name: git-compat
on: [workflow_dispatch]
permissions:
  contents: read
jobs:
  matrix:
    runs-on: macos-26
    steps:
      - name: Build
        env:
          TEST_GIT_VERSION: \"2.36.6\"
          TEST_GIT_SHA256: \"$sum\"
        run: |
          curl -sSfL -o g.tar.xz \"https://mirrors.edge.kernel.org/pub/software/scm/git/git-\${TEST_GIT_VERSION}.tar.xz\"
          echo \"\$TEST_GIT_SHA256  g.tar.xz\" | shasum -a 256 -c -"

good_dependabot="version: 2
updates:
  - package-ecosystem: github-actions
    directory: /
    schedule:
      interval: weekly"

# tree <name> [file content]... : writes a passing baseline, then overrides the given files.
tree() {
  local dir="$work/$1"
  shift
  mkdir -p "$dir/.github/workflows"
  printf '%s\n' "$good_workflow" >"$dir/.github/workflows/ci.yml"
  printf '%s\n' "$good_scan" >"$dir/.github/workflows/secret-scan.yml"
  printf '%s\n' "$good_compat" >"$dir/.github/workflows/git-compat.yml"
  printf '%s\n' "$good_dependabot" >"$dir/.github/dependabot.yml"
  while [[ $# -gt 0 ]]; do
    if [[ "$2" == "<delete>" ]]; then rm -f "$dir/$1"; else printf '%s\n' "$2" >"$dir/$1"; fi
    shift 2
  done
  echo "$dir"
}

# expect <name> <expected exit 0|1> <dir>
expect() {
  local got=0
  "$CHECK" "$3" >/dev/null 2>&1 || got=$?
  if [[ "$got" == "$2" ]]; then
    echo "ok   $1"
  else
    echo "FAIL $1: expected exit $2, got $got"
    "$CHECK" "$3" || true
    fail=1
  fi
}

ci=.github/workflows/ci.yml
expect baseline 0 "$(tree baseline)"

# SEC-T17-02: pinning.
expect tag-pin 1 "$(tree tag-pin $ci "${good_workflow/@$sha/@v7}")"
expect branch-pin 1 "$(tree branch-pin $ci "${good_workflow/@$sha/@main}")"
expect short-sha 1 "$(tree short-sha $ci "${good_workflow/@$sha/@0123456}")"
expect uppercase-sha 1 "$(tree uppercase-sha $ci "${good_workflow/@$sha/@0123456789ABCDEF0123456789ABCDEF01234567}")"
expect quoted-pin 0 "$(tree quoted-pin $ci "${good_workflow/actions\/checkout@$sha # v7/\"actions/checkout@$sha\"}")"
expect reusable-workflow-tag 1 "$(tree reusable $ci "name: r
on: [push]
permissions: {}
jobs:
  call:
    uses: org/repo/.github/workflows/x.yml@v1")"
expect reusable-workflow-sha 0 "$(tree reusable-sha $ci "name: r
on: [push]
permissions: {}
jobs:
  call:
    uses: org/repo/.github/workflows/x.yml@$sha")"
expect docker-tag 1 "$(tree docker-tag $ci "${good_workflow/actions\/checkout@$sha/docker://alpine:3}")"
expect docker-digest 0 "$(tree docker-digest $ci "${good_workflow/actions\/checkout@$sha/docker://alpine@sha256:$sum}")"

# Permissions.
expect no-permissions 1 "$(tree no-permissions $ci "${good_workflow/permissions:
  contents: read
/}")"
expect write-all 1 "$(tree write-all $ci "${good_workflow/permissions:
  contents: read/permissions: write-all}")"

# pull_request_target only in board-sync.yml.
expect prt-elsewhere 1 "$(tree prt-elsewhere $ci "${good_workflow/on: \[push\]/on: [pull_request_target]}")"
expect prt-board-sync 0 "$(tree prt-board-sync .github/workflows/board-sync.yml "${good_workflow/on: \[push\]/on: [pull_request_target]}")"

# Untrusted text only through KEY: ${{ … }} mappings.
expect inline-title 1 "$(tree inline-title $ci "${good_workflow/echo \"\$TITLE\"/echo \"\${{ github.event.pull_request.title }}\"}")"
expect inline-head-ref 1 "$(tree inline-head-ref $ci "${good_workflow/echo \"\$TITLE\"/git checkout \${{ github.head_ref }}}")"
expect inline-comment 1 "$(tree inline-comment $ci "${good_workflow/echo \"\$TITLE\"/echo \${{ github.event.comment.body }}}")"
expect inline-workflow-run 1 "$(tree inline-workflow-run $ci "${good_workflow/echo \"\$TITLE\"/echo \${{ github.event.workflow_run.head_branch }}}")"
expect inline-fork-name 1 "$(tree inline-fork-name $ci "${good_workflow/echo \"\$TITLE\"/echo \${{ github.event.pull_request.head.repo.full_name }}}")"
expect if-condition 0 "$(tree if-condition $ci "${good_workflow/      - name: Title/      - if: \${{ startsWith(github.event.comment.body, '\/claim') }}
        run: true
      - name: Title}")"

# gitleaks pinning in secret-scan.yml.
expect gitleaks-unpinned-sum 1 "$(tree gitleaks-sum .github/workflows/secret-scan.yml "${good_scan/$sum/latest}")"
expect gitleaks-no-verify 1 "$(tree gitleaks-verify .github/workflows/secret-scan.yml "${good_scan/sha256sum -c/cat}")"
expect gitleaks-missing 1 "$(tree gitleaks-missing .github/workflows/secret-scan.yml "<delete>")"

# SEC-T17-04: the compatibility matrix's git tarball.
compat=.github/workflows/git-compat.yml
expect compat-unpinned-version 1 "$(tree compat-version $compat "${good_compat/\"2.36.6\"/latest}")"
expect compat-unpinned-sum 1 "$(tree compat-sum $compat "${good_compat/$sum/latest}")"
expect compat-no-verify 1 "$(tree compat-verify $compat "${good_compat/shasum -a 256 -c/cat}")"
expect compat-sha256sum 0 "$(tree compat-sha256sum $compat "${good_compat/shasum -a 256 -c/sha256sum -c}")"
expect compat-other-source 1 "$(tree compat-source $compat "${good_compat/mirrors.edge.kernel.org/example.com}")"
expect compat-cache 1 "$(tree compat-cache $compat "$good_compat
      - uses: actions/cache@$sha")"
expect compat-missing 1 "$(tree compat-missing $compat "<delete>")"

# SEC-T17-03: Dependabot.
expect dependabot-missing 1 "$(tree dependabot-missing .github/dependabot.yml "<delete>")"
expect dependabot-other-ecosystem 1 "$(tree dependabot-other .github/dependabot.yml "${good_dependabot/github-actions/npm}")"
expect dependabot-wrong-directory 1 "$(tree dependabot-dir .github/dependabot.yml "${good_dependabot/directory: \//directory: /sub}")"

# The real repository passes.
if "$CHECK" >/dev/null; then echo "ok   this-repository"; else echo "FAIL this-repository"; fail=1; fi

exit $fail
