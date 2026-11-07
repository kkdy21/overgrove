#!/usr/bin/env bash
# Fails if the repository gains a third-party dependency (ADR-0006, threat T17, SEC-T17-01).
#
# Checks tracked files only:
#   - Swift Package Manager manifests or lock files (Package.swift, Package.resolved, including the copy Xcode keeps
#     under *.xcworkspace/xcshareddata/swiftpm/)
#   - package references or package products in any Xcode project (XCRemoteSwiftPackageReference,
#     XCLocalSwiftPackageReference, XCSwiftPackageProductDependency, a non-empty packageReferences list)
#   - other dependency managers (Podfile, Podfile.lock, Cartfile, Cartfile.resolved)
#
# Usage:
#   scripts/lint/check-no-dependencies.sh            # check the repository this script lives in
#   scripts/lint/check-no-dependencies.sh DIR        # check another git work tree (used by the test)
set -euo pipefail

root="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
status=0

report() {
  echo "✋ $1" >&2
  status=1
}

while IFS= read -r -d '' path; do
  case "$(basename "$path")" in
    Package.swift | Package.resolved)
      report "$path: Swift package manifest or lock file" ;;
    Podfile | Podfile.lock | Cartfile | Cartfile.resolved)
      report "$path: dependency manager file" ;;
  esac
  if [[ "$path" == *.pbxproj ]]; then
    if grep -nE 'XCRemoteSwiftPackageReference|XCLocalSwiftPackageReference|XCSwiftPackageProductDependency' \
      "$root/$path" >/dev/null; then
      report "$path: Swift package reference or package product"
    fi
    # `packageReferences = ( ... );` with at least one entry before the closing parenthesis.
    if awk '/packageReferences = \(/ { open = 1; next } open && /\);/ { open = 0 } open && NF { found = 1 }
      END { exit found ? 0 : 1 }' "$root/$path"; then
      report "$path: non-empty packageReferences"
    fi
  fi
done < <(git -C "$root" ls-files -z)

if [[ $status -ne 0 ]]; then
  echo "Overgrove has zero external dependencies (docs/adr/0006-zero-external-dependencies.md)." >&2
  echo "Remove the dependency, or write and accept an ADR before adding one (CLAUDE.md §2 rule 6)." >&2
  exit 1
fi
echo "ok  no third-party dependencies"
