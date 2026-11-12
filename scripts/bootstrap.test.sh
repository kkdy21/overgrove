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

# Neither the cases' own git calls nor bootstrap read the user's global or system git config (#509): a global
# core.hooksPath would otherwise decide what the cases see. The stand-in home, used by both, carries a global
# core.hooksPath=.githooks, so a leak shows up: bootstrap would report the hooks as installed without setting them.
empty_git_config="$work/empty.gitconfig"
: >"$empty_git_config"
mkdir -p "$work/home"
printf '[core]\n\thooksPath = .githooks\n' >"$work/home/.gitconfig"
export HOME="$work/home" GIT_CONFIG_GLOBAL="$empty_git_config" GIT_CONFIG_NOSYSTEM=1

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
# Like the real tools, these follow DEVELOPER_DIR when it is set: it then names another Xcode (STUB_*_DEVDIR answers).
stub xcode-select '[ "$1" = "-p" ] && [ -n "$DEVELOPER_DIR" ] && { echo "$DEVELOPER_DIR"; exit 0; }
[ "$1" = "-p" ] && [ -n "$STUB_DEVDIR" ] && { echo "$STUB_DEVDIR"; exit 0; }; exit 2'
stub xcodebuild '[ -n "$DEVELOPER_DIR" ] && STUB_XCODE="$STUB_XCODE_DEVDIR"
case "$1" in
  -version) [ -n "$STUB_XCODE" ] || exit 1; printf "%s\nBuild version 1A1\n" "$STUB_XCODE" ;;
  -license) [ "$STUB_LICENSE" = ok ] ;;
  -checkFirstLaunchStatus) [ "$STUB_FIRSTLAUNCH" = ok ] ;;
  *) exit 1 ;;
esac'
stub xcrun '[ -n "$DEVELOPER_DIR" ] && STUB_GIT="$STUB_GIT_DEVDIR"
[ "$1" = git ] && [ "$2" = --version ] && { echo "$STUB_GIT"; exit 0; }; exit 1'
stub swift '[ "$1" = format ] && [ "$2" = --version ] && echo 6.2.0'

optional_stubs="$work/optional"
mkdir -p "$optional_stubs"
printf '#!/bin/sh\necho 8.30.1\n' >"$optional_stubs/gitleaks"
chmod +x "$optional_stubs/gitleaks"

# gh with a working login for the hosts in STUB_GH_OK. Like the real gh, `gh auth status` without --hostname fails
# when any host in STUB_GH_BAD has an invalid token, even if github.com is fine.
gh_stubs="$work/gh"
mkdir -p "$gh_stubs"
cat >"$gh_stubs/gh" <<'EOF'
#!/bin/sh
[ "$1" = auth ] && [ "$2" = status ] || exit 1
if [ "$3" = --hostname ]; then
  case " $STUB_GH_OK " in *" $4 "*) exit 0 ;; esac
  exit 1
fi
[ -n "$STUB_GH_OK" ] && [ -z "$STUB_GH_BAD" ]
EOF
chmod +x "$gh_stubs/gh"

# run <name> [VAR=value …] -- [bootstrap arguments]: runs bootstrap in a fresh repository with the default stub answers
# (a supported machine), overridden by the given variables. With preset_hooks=1, the repository already has
# core.hooksPath=.githooks. With no_git=1, the copy of bootstrap is not in a Git repository at all. bootstrap runs from
# the repository unless cwd names another directory, and as script names it (default: the repository's copy). The
# repository is made under base (default $work). Sets $repo, $out, and $code.
run() {
  local name="$1"
  shift
  repo="${base:-$work}/repo-$name"
  mkdir -p "$repo/scripts"
  if [[ "${no_git:-0}" != 1 ]]; then git init -q "$repo"; fi
  if [[ "${preset_hooks:-0}" == 1 ]]; then git -C "$repo" config core.hooksPath .githooks; fi
  cp "$here/bootstrap.sh" "$repo/scripts/"
  local -a vars=(
    "PATH=$stubs:/usr/bin:/bin" "HOME=$work/home" "GIT_CONFIG_GLOBAL=$empty_git_config" "GIT_CONFIG_NOSYSTEM=1"
    "STUB_MACOS=14.6" "STUB_DEVDIR=/Applications/Xcode.app/Contents/Developer"
    "STUB_XCODE=Xcode 26.1" "STUB_LICENSE=ok" "STUB_FIRSTLAUNCH=ok" "STUB_GIT=git version 2.39.5 (Apple Git-154)"
    "BOOTSTRAP_APPLICATIONS=$work/apps-with-xcode"
  )
  while [[ $# -gt 0 && "$1" != "--" ]]; do
    vars+=("$1")
    shift
  done
  [[ "${1:-}" == "--" ]] && shift
  set +e
  out=$(cd "${cwd:-$repo}" && env -i "${vars[@]}" bash "${script:-$repo/scripts/bootstrap.sh}" "$@" </dev/null 2>&1)
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
expect "build: a supported machine is ready without gitleaks or gh" 0 "Ready to build" "gitleaks" \
  "without --build"
if [[ -n "$(hooks_path)" ]]; then failed "build: core.hooksPath left unset"; else pass "build: core.hooksPath left unset"; fi
if [[ "$out" == *"core.hooksPath"* ]]; then
  failed "build: does not mention changing core.hooksPath"
else
  pass "build: does not mention changing core.hooksPath"
fi

run build-clt STUB_DEVDIR=/Library/Developer/CommandLineTools -- --build
expect "build: Command Line Tools selected, Xcode installed" 1 \
  "sudo xcode-select -s $work/apps-with-xcode/Xcode.app/Contents/Developer"

# An Xcode path with a space: the printed command must work when pasted as is (#504). It is run here through a
# stand-in for xcode-select that reports the path it received as one argument.
mkdir -p "$work/apps-spaced/Xcode 26.app"
run build-clt-spaced STUB_DEVDIR=/Library/Developer/CommandLineTools BOOTSTRAP_APPLICATIONS="$work/apps-spaced" -- --build
fix=$(printf '%s\n' "$out" | sed -n 's/.*Run: sudo //p' | head -1)
pasted=$(PATH="$work/paste:$PATH" && mkdir -p "$work/paste" &&
  printf '#!/bin/sh\n[ "$1" = -s ] && [ $# -eq 2 ] && printf %%s "$2"\n' >"$work/paste/xcode-select" &&
  chmod +x "$work/paste/xcode-select" && eval "$fix" || true)
if [[ "$pasted" == "$work/apps-spaced/Xcode 26.app/Contents/Developer" ]]; then
  pass "build: the xcode-select command works when pasted, even with a space in the path"
else
  failed "build: the xcode-select command works when pasted, even with a space in the path (got: $fix)"
fi

# Several Xcodes: the newest by CFBundleShortVersionString is suggested, not the last by name (#505). Xcode_15.4 sorts
# after Xcode by name; a copy without a readable version comes last.
xcode_app() { # xcode_app <apps folder> <app name> [version]
  mkdir -p "$1/$2/Contents"
  if [[ -n "${3:-}" ]]; then
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict>%s</dict></plist>\n' \
      "<key>CFBundleShortVersionString</key><string>$3</string>" >"$1/$2/Contents/Info.plist"
  fi
}
xcode_app "$work/apps-many" Xcode.app 26.1
xcode_app "$work/apps-many" Xcode_15.4.app 15.4
xcode_app "$work/apps-many" Xcode_26.0.1.app 26.0.1
xcode_app "$work/apps-many" Xcode_unknown.app
run build-clt-many STUB_DEVDIR=/Library/Developer/CommandLineTools BOOTSTRAP_APPLICATIONS="$work/apps-many" -- --build
expect "build: the newest Xcode is suggested, not the last by name" 1 \
  "sudo xcode-select -s $work/apps-many/Xcode.app/Contents/Developer"

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

# The app does not pass DEVELOPER_DIR on, so it runs the git of the Xcode that xcode-select chose (#493). The shell's
# DEVELOPER_DIR names a newer Xcode and git here; the checks still judge xcode-select's, and say the shell differs.
devdir_vars=("DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer" "STUB_XCODE_DEVDIR=Xcode 27.0"
  "STUB_GIT_DEVDIR=git version 2.50.1 (Apple Git-160)")
run build-developer-dir "${devdir_vars[@]}" -- --build
expect "build: DEVELOPER_DIR is ignored, as the app ignores it" 0 "Xcode 26.1 at /Applications/Xcode.app" \
  "git 2.39.5 (xcrun git, the one Overgrove runs)" "DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer"
run build-developer-dir-old-git "${devdir_vars[@]}" "STUB_GIT=git version 2.35.1 (Apple Git-131)" -- --build
expect "build: an old git is not hidden by a newer one in DEVELOPER_DIR" 1 "git 2.35.1 (xcrun git) is older than 2.36"

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

# --- gh login: only github.com counts -------------------------------------------------------------------------------

run gh-logged-in "PATH=$gh_stubs:$optional_stubs:$stubs:/usr/bin:/bin" STUB_GH_OK=github.com
expect "gh: github.com logged in" 0 "gh logged in"

# Another host's broken token makes a plain `gh auth status` fail; github.com is still logged in (#506).
run gh-other-host-bad "PATH=$gh_stubs:$optional_stubs:$stubs:/usr/bin:/bin" STUB_GH_OK=github.com \
  STUB_GH_BAD=ghe.example.com
expect "gh: another host's invalid token does not hide the github.com login" 0 "gh logged in"

run gh-only-other-host "PATH=$gh_stubs:$optional_stubs:$stubs:/usr/bin:/bin" STUB_GH_OK=ghe.example.com
expect "gh: a login to another host only is not a github.com login" 0 "not logged in"

# --- Which clone: the one bootstrap is in, wherever it is run from (#492) -------------------------------------------

other="$work/other-repo"
git init -q "$other"
cwd="$other" run from-other-repo "PATH=$optional_stubs:$stubs:/usr/bin:/bin"
expect "clone: run from inside another repository" 0 "Ready to contribute"
if [[ -z "$(git -C "$other" config --get core.hooksPath || true)" && "$(hooks_path)" == ".githooks" ]]; then
  pass "clone: hooks go to bootstrap's own clone, not the current directory's repository"
else
  failed "clone: hooks go to bootstrap's own clone, not the current directory's repository"
fi

mkdir -p "$work/not-a-repo"
cwd="$work/not-a-repo" run from-outside "PATH=$optional_stubs:$stubs:/usr/bin:/bin"
expect "clone: run from outside any repository" 0 "Ready to contribute"
if [[ "$(hooks_path)" == ".githooks" ]]; then
  pass "clone: run from outside any repository installs the hooks"
else
  failed "clone: run from outside any repository installs the hooks"
fi

# A copy that is not in a clone (a downloaded archive) can still check the build; it has no hooks to install.
no_git=1 run loose-build -- --build
expect "clone: a copy outside any clone still checks the build" 0 "Ready to build"
no_git=1 run loose-contributor "PATH=$optional_stubs:$stubs:/usr/bin:/bin"
expect "clone: a copy outside any clone cannot install the hooks" 1 "not in a Git clone" "git clone"

# A loose copy unpacked inside another repository (an archive under a home kept as a dotfiles repository) is not a
# clone of its own: the outer repository is left alone, and nothing is made executable there (#535).
outer="$work/outer-repo"
git init -q "$outer"
mkdir -p "$outer/scripts"
printf '#!/bin/sh\n' >"$outer/scripts/outer.sh"
base="$outer" no_git=1 run nested-loose "PATH=$optional_stubs:$stubs:/usr/bin:/bin" -- --yes
expect "clone: a loose copy inside another repository cannot install the hooks" 1 "not in a Git clone"
if [[ -z "$(git -C "$outer" config --get core.hooksPath || true)" && ! -x "$outer/scripts/outer.sh" ]]; then
  pass "clone: the outer repository is left alone"
else
  failed "clone: the outer repository is left alone"
fi

# The clone reached through a path typed in another case, on a case-insensitive disk (the macOS default): rev-parse
# prints the stored case, the typed path keeps the typed one, and it is still the same clone (review of #536).
mkdir -p "$work/case"
if [[ -d "$work/CASE" ]]; then
  base="$work/case" cwd="$work/CASE/repo-cased" script="$work/CASE/repo-cased/scripts/bootstrap.sh" \
    run cased "PATH=$optional_stubs:$stubs:/usr/bin:/bin"
  expect "clone: a path typed in another case is still the clone" 0 "Ready to contribute"
  if [[ "$(hooks_path)" == ".githooks" ]]; then
    pass "clone: a path typed in another case installs the hooks"
  else
    failed "clone: a path typed in another case installs the hooks"
  fi
else
  pass "clone: a path typed in another case (skipped: case-sensitive disk)"
fi

# A clone path with a space. When the hook path cannot be written, the suggested command works when pasted.
mkdir -p "$work/with space"
base="$work/with space" run spaced "PATH=$optional_stubs:$stubs:/usr/bin:/bin"
expect "clone: a path with a space installs the hooks" 0 "Ready to contribute"
spaced_repo="$work/with space/repo-spaced-fail"
mkdir -p "$spaced_repo/scripts"
git init -q "$spaced_repo"
cp "$here/bootstrap.sh" "$spaced_repo/scripts/"
chmod a-w "$spaced_repo/.git"
set +e
out=$(cd "$spaced_repo" && env -i "PATH=$optional_stubs:$stubs:/usr/bin:/bin" "HOME=$work/home" \
  "GIT_CONFIG_GLOBAL=$empty_git_config" GIT_CONFIG_NOSYSTEM=1 STUB_MACOS=14.6 \
  STUB_DEVDIR=/Applications/Xcode.app/Contents/Developer "STUB_XCODE=Xcode 26.1" STUB_LICENSE=ok STUB_FIRSTLAUNCH=ok \
  "STUB_GIT=git version 2.39.5 (Apple Git-154)" bash "$spaced_repo/scripts/bootstrap.sh" --yes </dev/null 2>&1)
code=$?
set -e
chmod u+w "$spaced_repo/.git"
fix=$(printf '%s\n' "$out" | sed -n 's/.*could not set core.hooksPath. Run: //p' | head -1)
if [[ $code -eq 1 && -n "$fix" ]] && (cd "$work" && eval "$fix") &&
  [[ "$(git -C "$spaced_repo" config --get core.hooksPath || true)" == ".githooks" ]]; then
  pass "clone: the suggested git config command works when pasted, even with a space in the path"
else
  failed "clone: the suggested git config command works when pasted (exit $code, got: $fix)"
  printf '%s\n' "$out" | sed 's/^/     | /'
fi

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
