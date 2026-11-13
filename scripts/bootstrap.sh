#!/usr/bin/env bash
# Checks that this Mac can build Overgrove and, for contributors, installs the repository's Git hooks.
#
#   ./scripts/bootstrap.sh --build          only check what building and running the app needs; changes nothing
#   ./scripts/bootstrap.sh [--contributor]  also install the Git hooks (sets core.hooksPath) and require gitleaks
#
# Options: --yes skips the question before core.hooksPath is set (asked only in a terminal). Safe to re-run.
# Exit codes: 0 ready, 1 something to fix (listed with the command that fixes it), 2 usage error.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./scripts/bootstrap.sh [--build | --contributor] [--yes]

  --build        Check what building and running Overgrove needs (macOS, Xcode, git).
                 Changes nothing.
  --contributor  The default. Also install the repository's Git hooks by setting
                 core.hooksPath=.githooks in this clone, and require gitleaks,
                 which the hooks run before every commit and push.
  --yes          Do not ask before setting core.hooksPath.
EOF
}

mode=contributor
assume_yes=0
for arg in "$@"; do
  case "$arg" in
    --build) mode=build ;;
    --contributor) mode=contributor ;;
    --yes | -y) assume_yes=1 ;;
    --help | -h)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done

# Work on the clone this script is in, not on whatever repository the current directory belongs to (#492). A copy
# outside any clone (a downloaded archive) can still check the build; it has no hooks to install.
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
clone=$(git -C "$script_dir" rev-parse --show-toplevel 2>/dev/null || true)
# Only this copy's own root counts: a loose copy unpacked inside another repository must not touch that one (#535).
# Compared as files, not strings: rev-parse prints the stored case and resolves symbolic links, while the path the
# script was run by keeps what was typed (review of #536).
if [[ -n "$clone" && ! "$clone" -ef "$script_dir/.." ]]; then clone=; fi
cd "${clone:-$script_dir/..}"

# Where Xcode is looked for when the Command Line Tools are selected instead (tests point this elsewhere).
applications="${BOOTSTRAP_APPLICATIONS:-/Applications}"

if [[ -t 1 ]]; then
  green=$'\033[32m' yellow=$'\033[33m' red=$'\033[31m' reset=$'\033[0m'
else
  green='' yellow='' red='' reset=''
fi
missing=0
ok() { printf '  %s✓%s %s\n' "$green" "$reset" "$*"; }
warn() { printf '  %s!%s %s\n' "$yellow" "$reset" "$*"; }
bad() {
  printf '  %s✗%s %s\n' "$red" "$reset" "$*"
  missing=1
}
info() { printf '  · %s\n' "$*"; }

# version_at_least <version> <minimum>: dotted numeric comparison, missing parts count as 0.
version_at_least() {
  local -a have want
  IFS=. read -r -a have <<<"$1"
  IFS=. read -r -a want <<<"$2"
  local i a b
  for i in 0 1 2; do
    a=${have[i]:-0} b=${want[i]:-0}
    if ((10#$a > 10#$b)); then return 0; fi
    if ((10#$a < 10#$b)); then return 1; fi
  done
  return 0
}

# need <message>: a build requirement is not met. Required in build mode; a warning for contributors, who can work on
# documents and scripts without Xcode.
need() {
  if [[ "$mode" == build ]]; then bad "$*"; else warn "$*"; fi
}

echo "Build requirements"

macos=$(sw_vers -productVersion 2>/dev/null || true)
if [[ "$macos" =~ ^[0-9]+(\.[0-9]+)*$ ]] && version_at_least "$macos" 14; then
  ok "macOS $macos"
else
  need "macOS ${macos:-(unknown)} is older than 14 Sonoma, which Overgrove needs"
fi

# The app does not pass DEVELOPER_DIR on (it is not in its environment allowlist), so it runs the git of the Xcode that
# xcode-select chose. Check that one, as the app sees it, and say when this shell points somewhere else (#493).
if [[ -n "${DEVELOPER_DIR:-}" ]]; then
  info "DEVELOPER_DIR=$DEVELOPER_DIR is set in this shell. Overgrove does not use it, so the checks below follow xcode-select (command-line builds from this shell still use DEVELOPER_DIR)"
  unset DEVELOPER_DIR
fi

dev_dir=$(xcode-select -p 2>/dev/null || true)
if [[ "$dev_dir" != *.app/Contents/Developer ]]; then
  shopt -s nullglob
  xcodes=("$applications"/Xcode*.app)
  shopt -u nullglob
  if ((${#xcodes[@]} > 0)); then
    # Quoted for the shell so the command can be pasted as is, even with a space in the path (#504).
    # The newest by version, not the last by name: Xcode_15.4.app sorts after Xcode.app (#505). A copy whose version
    # cannot be read is suggested only when no other is installed.
    newest=${xcodes[0]} newest_version=
    for candidate in "${xcodes[@]}"; do
      version=$(plutil -extract CFBundleShortVersionString raw -o - "$candidate/Contents/Info.plist" 2>/dev/null || true)
      [[ "$version" =~ ^[0-9]+(\.[0-9]+)*$ ]] || continue
      if [[ -z "$newest_version" ]] || ! version_at_least "$newest_version" "$version"; then
        newest=$candidate newest_version=$version
      fi
    done
    printf -v developer_dir '%q' "$newest/Contents/Developer"
    need "the Command Line Tools are selected, not Xcode. Run: sudo xcode-select -s $developer_dir"
  else
    need "Xcode not found. Install Xcode 26 or later from the App Store, then run this again"
  fi
elif ! xcodebuild -license check >/dev/null 2>&1; then
  need "the Xcode license has not been accepted. Run: sudo xcodebuild -license accept"
elif ! xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
  need "Xcode has not finished its first launch. Run: sudo xcodebuild -runFirstLaunch"
else
  xcode=$(xcodebuild -version 2>/dev/null | head -1 || true)
  xcode_version=${xcode#Xcode }
  if [[ "$xcode_version" =~ ^[0-9]+(\.[0-9]+)*$ ]] && version_at_least "$xcode_version" 26; then
    ok "$xcode at $dev_dir"
  else
    need "${xcode:-Xcode (unknown version)} is older than 26, which Overgrove needs. Update Xcode from the App Store"
  fi
fi

# The app runs the git that xcrun finds (Xcode or the Command Line Tools), not the first git on PATH.
xcrun_git=$(xcrun git --version 2>/dev/null || true)
if [[ "$xcrun_git" =~ ^git\ version\ ([0-9]+\.[0-9]+(\.[0-9]+)?) ]]; then
  git_version=${BASH_REMATCH[1]}
  if version_at_least "$git_version" 2.36; then
    ok "git $git_version (xcrun git, the one Overgrove runs)"
  else
    need "git $git_version (xcrun git) is older than 2.36. Update Xcode or the Command Line Tools"
  fi
  path_git=$(command -v git || true)
  path_version=$(git --version 2>/dev/null || true)
  if [[ -n "$path_git" && "$path_version" != "$xcrun_git" ]]; then
    info "$path_git (${path_version:-unknown}) is first on PATH; Overgrove does not use it"
  fi
else
  need "could not read the version of xcrun git. Install Xcode, or the Command Line Tools with: xcode-select --install"
fi

echo "Contributor tools"
if command -v gitleaks >/dev/null 2>&1; then
  ok "gitleaks $(gitleaks version 2>/dev/null || echo '(version unknown)')"
elif [[ "$mode" == contributor ]]; then
  bad "gitleaks not found. Install it with: brew install gitleaks (the commit and push hooks need it)"
else
  info "gitleaks not found (not needed to build; contributors install it with: brew install gitleaks)"
fi

if swift format --version >/dev/null 2>&1; then
  ok "swift-format $(swift format --version)"
elif [[ "$mode" == contributor ]]; then
  warn "swift format not available (it comes with Xcode; CI checks formatting with it)"
else
  info "swift format not available (not needed to build)"
fi

if ! command -v gh >/dev/null 2>&1; then
  info "gh not installed (optional: the GitHub issues panel; contributors also use it for pull requests)"
# Only github.com: without --hostname, another host's invalid token fails the whole check (#506).
elif gh auth status --hostname github.com >/dev/null 2>&1; then
  ok "gh logged in (optional)"
else
  info "gh installed but not logged in to github.com (optional): gh auth login --hostname github.com"
fi

if [[ "$mode" == contributor ]]; then
  echo "Git hooks"
  if [[ -z "$clone" ]]; then
    bad "$script_dir is not in a Git clone, so there are no hooks to install. Get the repository with git clone, then run this again"
  elif [[ "$(git config --get core.hooksPath || true)" == ".githooks" ]]; then
    ok "already installed (core.hooksPath=.githooks)"
  else
    echo "  This sets core.hooksPath=.githooks in this clone's .git/config, for every worktree of it."
    echo "  The hooks scan commits for secrets and check commit messages. Undo with: git config --unset core.hooksPath"
    if [[ $assume_yes -eq 0 && -t 0 && -t 1 ]]; then
      # End of input (Ctrl-D) counts as no, so the refusal below explains what happened.
      read -r -p "  Install the hooks now? [Y/n] " answer || answer=n
      if [[ "$answer" =~ ^[Nn] ]]; then
        bad "hooks not installed. Run this again to install them, or use --build to only check the build"
        echo
        echo "Fix the ✗ items above, then run this again."
        exit 1
      fi
    fi
    if git config core.hooksPath .githooks; then
      ok "core.hooksPath=.githooks (pre-commit, prepare-commit-msg, commit-msg, pre-push)"
    else
      printf -v quoted_clone '%q' "$clone"
      bad "could not set core.hooksPath. Run: git -C $quoted_clone config core.hooksPath .githooks"
    fi
  fi
  chmod +x .githooks/* scripts/*.sh scripts/lint/*.sh scripts/github/*.sh 2>/dev/null || true
fi

echo
if [[ $missing -ne 0 ]]; then
  echo "Fix the ✗ items above, then run this again."
  exit 1
fi
if [[ "$mode" == build ]]; then
  echo "Ready to build. Open Overgrove.xcodeproj in Xcode (⌘R runs the app, ⌘U runs the tests), or run:"
  echo "  xcodebuild test -project Overgrove.xcodeproj -scheme Overgrove -destination 'platform=macOS'"
  echo "To contribute, run ./scripts/bootstrap.sh without --build: it installs the secret-scanning Git hooks."
else
  echo "Ready to contribute. Next: read CONTRIBUTING.md and pick an issue."
fi
