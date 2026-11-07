#!/usr/bin/env bash
# Tests scripts/lint/check-no-dependencies.sh against throwaway git repositories (SEC-T17-01). No network.
# Run: scripts/lint/check-no-dependencies.test.sh
set -euo pipefail
CHECK="$(cd "$(dirname "$0")" && pwd)/check-no-dependencies.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail=0

# case <name> <expected exit 0|1> <file path> <file content>
case_() {
  local repo="$work/$1"
  git init -q "$repo"
  mkdir -p "$repo/$(dirname "$3")"
  printf '%s\n' "$4" >"$repo/$3"
  git -C "$repo" add -A
  local got=0
  "$CHECK" "$repo" >/dev/null 2>&1 || got=$?
  if [[ "$got" == "$2" ]]; then
    echo "ok   $1"
  else
    echo "FAIL $1: expected exit $2, got $got"
    fail=1
  fi
}

empty_project='packageProductDependencies = (
);
packageReferences = (
);'

case_ clean-project 0 App.xcodeproj/project.pbxproj "$empty_project"
case_ source-only 0 Sources/Main.swift 'print("hi")'
case_ package-swift 1 Package.swift '// swift-tools-version:5.9'
case_ package-resolved 1 App.xcworkspace/xcshareddata/swiftpm/Package.resolved '{}'
case_ remote-package 1 App.xcodeproj/project.pbxproj 'isa = XCRemoteSwiftPackageReference;'
case_ local-package 1 App.xcodeproj/project.pbxproj 'isa = XCLocalSwiftPackageReference;'
case_ package-product 1 App.xcodeproj/project.pbxproj 'isa = XCSwiftPackageProductDependency;'
case_ package-references 1 App.xcodeproj/project.pbxproj 'packageReferences = (
	ABCDEF /* XCRemote */,
);'
case_ podfile 1 Podfile "pod 'Alamofire'"
case_ cartfile 1 Cartfile 'github "x/y"'

# Untracked files are not dependencies of the repository.
repo="$work/untracked"
git init -q "$repo"
printf '{}\n' >"$repo/Package.resolved"
if "$CHECK" "$repo" >/dev/null 2>&1; then echo "ok   untracked-ignored"; else echo "FAIL untracked-ignored"; fail=1; fi

# The real repository passes.
if "$CHECK" >/dev/null; then echo "ok   this-repository"; else echo "FAIL this-repository"; fail=1; fi

exit $fail
