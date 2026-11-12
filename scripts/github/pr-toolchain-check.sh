#!/usr/bin/env bash
# Warns, without failing, when a ready PR that touches app code does not say which Xcode and macOS it was built and
# tested with locally, or names an Xcode major other than CI's (#507). Run by pr-policy.
#
#   BODY=<PR body> DRAFT=<true|false> pr-toolchain-check.sh <path to ci.yml> < <changed file names, one per line>
#
# The PR template's line is "- Local toolchain: Xcode <version> (<build>), macOS <version>"; /pr-open fills it from
# `xcodebuild -version` and `sw_vers -productVersion`. The body is untrusted: it is only matched and quoted inside
# escaped warning messages. Always exits 0.
set -uo pipefail

warn() {
  local m="${2//%/%25}"
  m="${m//$'\r'/%0D}"
  m="${m//$'\n'/%0A}"
  echo "::warning title=$1::$m"
}

ci_workflow="${1:?usage: pr-toolchain-check.sh <ci.yml>}"
files=$(cat)

if [[ "${DRAFT:-false}" == true ]]; then
  echo "Draft PR: the local toolchain line is checked when it is ready."
  exit 0
fi
if ! grep -Eq '^(Overgrove|OvergroveTests)/|^Overgrove\.xcodeproj/' <<<"$files"; then
  echo "No app code touched: the local toolchain line is not needed."
  exit 0
fi

ci_major=$(sed -nE 's/^[[:space:]]*XCODE_MAJOR:[[:space:]]*"?([0-9]+)"?[[:space:]]*$/\1/p' "$ci_workflow" 2>/dev/null | head -1)
if [[ -z "$ci_major" ]]; then
  warn "Local toolchain" "Could not read XCODE_MAJOR from $ci_workflow, so the local Xcode was not compared with CI's."
  exit 0
fi

# HTML comments (the template's placeholder) do not count, also when they span lines.
body=$(printf '%s\n' "${BODY:-}" | tr -d '\r' | perl -0pe 's/<!--.*?-->//gs')
line=$(grep -Ei '^[[:space:]]*[-*][[:space:]]+local toolchain:' <<<"$body" | head -1)
if [[ -z "$line" ]]; then
  warn "Local toolchain" "Add the line '- Local toolchain: Xcode <version>, macOS <version>' from the PR template (xcodebuild -version, sw_vers -productVersion). CI builds with Xcode $ci_major."
  exit 0
fi
value=$(sed -E 's/^[^:]*:[[:space:]]*//; s/[[:space:]]+$//' <<<"$line")
if [[ -z "$value" ]]; then
  warn "Local toolchain" "The 'Local toolchain' line is empty. Fill it with the Xcode and macOS you built and tested with (xcodebuild -version, sw_vers -productVersion). CI builds with Xcode $ci_major."
  exit 0
fi
if [[ ! "$value" =~ Xcode[[:space:]]+([0-9]+)([^0-9]|$) ]]; then
  warn "Local toolchain" "The 'Local toolchain' line names no Xcode version: $value. CI builds with Xcode $ci_major."
  exit 0
fi
local_major=${BASH_REMATCH[1]}
if [[ "$local_major" != "$ci_major" ]]; then
  warn "Local toolchain" "Built and tested locally with Xcode $local_major, but CI builds with Xcode $ci_major ($value). Mention anything that may differ."
  exit 0
fi
echo "Local toolchain: $value (CI: Xcode $ci_major)."
exit 0
