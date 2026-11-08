#!/usr/bin/env bash
# The stub bodies below are single-quoted on purpose: they expand when a stub runs, not here.
# shellcheck disable=SC2016
# Runs scripts/bootstrap.sh against stand-in tools (#461). No network, no Xcode needed, nothing outside a temporary
# repository is changed.
#
# The macOS and Xcode tools bootstrap asks (sw_vers, xcode-select, xcodebuild, xcrun, swift) are replaced by stubs
# earlier on PATH; their answers come from STUB_* variables. gitleaks and gh are absent unless a case adds a stub. The
# real git is used for `git config`, so the cases can check what bootstrap wrote to the repository.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail=0

pass() { echo "ok   $1"; }
failed() {
  echo "FAIL $1"
  fail=1
}

stubs="$work/stubs"
mkdir -p "$stubs" "$work/apps-with-xcode/Xcode.app" "$work/apps-empty"
stub() {
  printf '#!/bin/sh\n%s\n' "$2" >"$stubs/$1"
  chmod +x "$stubs/$1"
}
stub sw_vers 'echo "$STUB_MACOS"'
stub xcode-select '[ "$1" = "-p" ] && [ -n "$STUB_DEVDIR" ] && { echo "$STUB_DEVDIR"; exit 0; }; exit 2'
stub xcodebuild 'case "$1" in
  -version) [ -n "$STUB_XCODE" ] || exit 1; printf "%s\nBuild version 1A1\n" "$STUB_XCODE" ;;
  -license) [ "$STUB_LICENSE" = ok ] ;;
  -checkFirstLaunchStatus) [ "$STUB_FIRSTLAUNCH" = ok ] ;;
  *) exit 1 ;;
esac'
stub xcrun '[ "$1" = git ] && [ "$2" = --version ] && { echo "$STUB_GIT"; exit 0; }; exit 1'
stub swift '[ "$1" = format ] && [ "$2" = --version ] && echo 6.2.0'

optional_stubs="$work/optional"
mkdir -p "$optional_stubs"
printf '#!/bin/sh\necho 8.30.1\n' >"$optional_stubs/gitleaks"
chmod +x "$optional_stubs/gitleaks"

# run <name> [VAR=value …] -- [bootstrap arguments]: runs bootstrap in a fresh repository with the default stub answers
# (a supported machine), overridden by the given variables. With preset_hooks=1, the repository already has
# core.hooksPath=.githooks. Sets $repo, $out, and $code.
run() {
  local name="$1"
  shift
  repo="$work/repo-$name"
  mkdir -p "$repo/scripts"
  git init -q "$repo"
  if [[ "${preset_hooks:-0}" == 1 ]]; then git -C "$repo" config core.hooksPath .githooks; fi
  cp "$here/bootstrap.sh" "$repo/scripts/"
  local -a vars=(
    "PATH=$stubs:/usr/bin:/bin" "HOME=$work/home" "STUB_MACOS=14.6" "STUB_DEVDIR=/Applications/Xcode.app/Contents/Developer"
    "STUB_XCODE=Xcode 26.1" "STUB_LICENSE=ok" "STUB_FIRSTLAUNCH=ok" "STUB_GIT=git version 2.39.5 (Apple Git-154)"
    "BOOTSTRAP_APPLICATIONS=$work/apps-with-xcode"
  )
  while [[ $# -gt 0 && "$1" != "--" ]]; do
    vars+=("$1")
    shift
  done
  [[ "${1:-}" == "--" ]] && shift
  set +e
  out=$(cd "$repo" && env -i "${vars[@]}" bash scripts/bootstrap.sh "$@" </dev/null 2>&1)
  code=$?
  set -e
}

hooks_path() { git -C "$repo" config --get core.hooksPath || true; }

expect() { # expect <case> <exit code> [text the output must contain]…
  local name="$1" want="$2"
  shift 2
  if [[ "$code" != "$want" ]]; then
    failed "$name: exit $code, expected $want"
    printf '%s\n' "$out" | sed 's/^/     | /'
    return
  fi
  local text
  for text in "$@"; do
    if [[ "$out" != *"$text"* ]]; then
      failed "$name: output lacks \"$text\""
      printf '%s\n' "$out" | sed 's/^/     | /'
      return
    fi
  done
  pass "$name"
}

# --- Build mode: read-only, only what building needs is required ---------------------------------------------------

run build-ready -- --build
expect "build: a supported machine is ready without gitleaks or gh" 0 "Ready to build" "gitleaks"
if [[ -n "$(hooks_path)" ]]; then failed "build: core.hooksPath left unset"; else pass "build: core.hooksPath left unset"; fi
if [[ "$out" == *"core.hooksPath"* ]]; then
  failed "build: does not mention changing core.hooksPath"
else
  pass "build: does not mention changing core.hooksPath"
fi

run build-clt STUB_DEVDIR=/Library/Developer/CommandLineTools -- --build
expect "build: Command Line Tools selected, Xcode installed" 1 \
  "sudo xcode-select -s $work/apps-with-xcode/Xcode.app/Contents/Developer"

run build-no-xcode STUB_DEVDIR=/Library/Developer/CommandLineTools BOOTSTRAP_APPLICATIONS="$work/apps-empty" -- --build
expect "build: no Xcode installed" 1 "App Store"

run build-license STUB_LICENSE=no -- --build
expect "build: license not accepted" 1 "sudo xcodebuild -license accept"

run build-first-launch STUB_FIRSTLAUNCH=no -- --build
expect "build: first launch not done" 1 "sudo xcodebuild -runFirstLaunch"

run build-old-xcode "STUB_XCODE=Xcode 25.4" -- --build
expect "build: Xcode older than 26" 1 "Xcode 25.4 is older than 26"

run build-old-macos STUB_MACOS=13.6.1 -- --build
expect "build: macOS older than 14" 1 "macOS 13.6.1 is older than 14"

# The real git on PATH is newer; the app runs xcrun's git, so that is what counts.
run build-old-git "STUB_GIT=git version 2.35.1 (Apple Git-131)" -- --build
expect "build: xcrun's git decides, not PATH's" 1 "git 2.35.1 (xcrun git) is older than 2.36"

run build-git-unparsed "STUB_GIT=something else" -- --build
expect "build: unreadable git version" 1 "xcrun git"

# --- Contributor mode (the default): installs the hooks after saying so, gitleaks is required ------------------------

run contributor-no-gitleaks
expect "contributor: gitleaks missing fails" 1 "gitleaks not found"
if [[ "$(hooks_path)" == ".githooks" ]]; then
  pass "contributor: core.hooksPath set"
else
  failed "contributor: core.hooksPath set"
fi
notice_line=$(printf '%s\n' "$out" | grep -n "sets core.hooksPath" | head -1 | cut -d: -f1)
done_line=$(printf '%s\n' "$out" | grep -n "core.hooksPath=.githooks" | tail -1 | cut -d: -f1)
if [[ -n "$notice_line" && -n "$done_line" && "$notice_line" -lt "$done_line" ]]; then
  pass "contributor: says it changes core.hooksPath before doing it"
else
  failed "contributor: says it changes core.hooksPath before doing it"
  printf '%s\n' "$out" | sed 's/^/     | /'
fi
if [[ "$out" == *"git config --unset core.hooksPath"* ]]; then
  pass "contributor: says how to undo it"
else
  failed "contributor: says how to undo it"
fi

run contributor-ready "PATH=$optional_stubs:$stubs:/usr/bin:/bin" -- --contributor
expect "contributor: ready with gitleaks" 0 "Ready to contribute" "gitleaks 8.30.1"

preset_hooks=1 run contributor-again "PATH=$optional_stubs:$stubs:/usr/bin:/bin"
expect "contributor: already installed hooks are left as they are" 0 "already"

# Xcode problems are reported, but a contributor without Xcode can still install the hooks.
run contributor-no-xcode "PATH=$optional_stubs:$stubs:/usr/bin:/bin" STUB_DEVDIR= STUB_XCODE= \
  BOOTSTRAP_APPLICATIONS="$work/apps-empty"
expect "contributor: missing Xcode is a warning, not a failure" 0 "App Store"

# --- Wording and usage ---------------------------------------------------------------------------------------------

if grep -qi "phase" "$here/bootstrap.sh"; then
  failed "no internal terms (Phase) in bootstrap.sh"
else
  pass "no internal terms (Phase) in bootstrap.sh"
fi

run usage -- --unknown
expect "unknown option: usage error" 2 "Usage"

run help -- --help
expect "--help prints usage" 0 "--build" "--contributor"

exit $fail
