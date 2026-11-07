#!/usr/bin/env bash
# Checks the GitHub Actions supply-chain rules (docs/design/security-review.md T17, #95).
#
#   SEC-T17-02  every `uses:` is pinned to a full 40-character commit SHA (local `./` actions excepted)
#               - every workflow sets top-level `permissions:` and none grants `write-all`
#               - `pull_request_target` only in board-sync.yml (ADR-0016)
#               - untrusted event text (PR/issue titles and bodies, comments, branch names) reaches a workflow only
#                 through a `KEY: ${{ … }}` mapping (env, with, if), never inline in a script
#               - the CI gitleaks download stays pinned by version and SHA-256
#   SEC-T17-03  Dependabot updates the `github-actions` ecosystem at `/`
#
# Plain bash, grep and awk: runs in CI (macOS) and locally without extra tools.
#
# Usage:
#   scripts/lint/check-workflows.sh        # check this repository
#   scripts/lint/check-workflows.sh DIR    # check another tree that has .github/ (used by the test)
set -euo pipefail

root="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
workflows="$root/.github/workflows"
status=0

report() {
  echo "✋ $1" >&2
  status=1
}

shopt -s nullglob
files=("$workflows"/*.yml "$workflows"/*.yaml)
if [[ ${#files[@]} -eq 0 ]]; then
  report "no workflows found in $workflows"
fi

# Expressions whose value an outside contributor controls.
untrusted='github\.event\.(pull_request|issue|comment|review|review_comment|discussion|discussion_comment)\.(title|body)|github\.event\.(comment|review|review_comment)\.body|github\.event\.pull_request\.head\.(ref|label)|github\.head_ref|github\.event\.head_commit\.(message|author)|github\.event\.commits'

for file in "${files[@]}"; do
  name="${file#"$root"/}"

  # SEC-T17-02: pinned actions. `uses:` may be a step key or a job key (reusable workflow).
  while IFS= read -r line; do
    number="${line%%:*}"
    value=$(printf '%s' "${line#*:}" | sed -E 's/^[[:space:]-]*uses:[[:space:]]*//; s/[[:space:]]+#.*$//; s/^["'\'']//; s/["'\'']$//')
    case "$value" in
      ./*) continue ;;  # a local action in this repository
      docker://*@sha256:*)
        [[ "$value" =~ @sha256:[0-9a-f]{64}$ ]] && continue
        report "$name:$number: docker action without a full sha256 digest: $value" ;;
      *)
        [[ "$value" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._/-]+@[0-9a-f]{40}$ ]] && continue
        report "$name:$number: action not pinned to a 40-character commit SHA: $value" ;;
    esac
  done < <(grep -nE '^[[:space:]-]*uses:' "$file" || true)

  # Minimal permissions: a top-level block, and never write-all.
  if ! grep -qE '^permissions:' "$file"; then
    report "$name: no top-level permissions: block (set the minimum, e.g. contents: read)"
  fi
  if grep -nE '^[[:space:]]*permissions:[[:space:]]*write-all' "$file" >/dev/null; then
    report "$name: permissions: write-all"
  fi

  # pull_request_target runs with secrets on fork PRs: only the board sync may use it (ADR-0016).
  # (Portable ERE: BSD grep rejects some bracket expressions, so word boundaries are spelled out.)
  if grep -qE '(^|[^A-Za-z0-9_])pull_request_target([^A-Za-z0-9_]|$)' "$file" && [[ "$(basename "$file")" != "board-sync.yml" ]]; then
    report "$name: pull_request_target is only allowed in board-sync.yml (ADR-0016)"
  fi

  # Untrusted text only through `KEY: ${{ … }}` mappings, never inside a script line.
  while IFS= read -r line; do
    number="${line%%:*}"
    text="${line#*:}"
    if ! printf '%s' "$text" | grep -qE '^[[:space:]-]*[A-Za-z_][A-Za-z0-9_-]*:[[:space:]]*\$\{\{'; then
      report "$name:$number: untrusted event text used outside a KEY: \${{ … }} mapping; pass it through env:"
    fi
  done < <(grep -nE "\\\$\\{\\{[^}]*($untrusted)" "$file" || true)
done

# The CI gitleaks binary is downloaded by version and verified by SHA-256 (T17, ADR-0006).
scan="$workflows/secret-scan.yml"
if [[ -f "$scan" ]]; then
  grep -qE 'GITLEAKS_VERSION:[[:space:]]*"?[0-9]+\.[0-9]+\.[0-9]+"?' "$scan" || report "secret-scan.yml: GITLEAKS_VERSION is not pinned"
  grep -qE 'GITLEAKS_SHA256:[[:space:]]*"?[0-9a-f]{64}"?' "$scan" || report "secret-scan.yml: GITLEAKS_SHA256 is not pinned"
  grep -qE 'sha256sum -c' "$scan" || report "secret-scan.yml: the gitleaks download is not checksum-verified"
else
  report "missing .github/workflows/secret-scan.yml"
fi

# SEC-T17-03: Dependabot keeps the pinned SHAs current.
dependabot="$root/.github/dependabot.yml"
if [[ ! -f "$dependabot" ]]; then
  report "missing .github/dependabot.yml (SEC-T17-03)"
else
  awk '
    /package-ecosystem:[[:space:]]*"?github-actions"?/ { actions = 1; next }
    actions && /directory:[[:space:]]*"?\/"?[[:space:]]*$/ { found = 1 }
    /package-ecosystem:/ { actions = 0 }
    END { exit found ? 0 : 1 }
  ' "$dependabot" || report "dependabot.yml: no github-actions update for directory / (SEC-T17-03)"
fi

if [[ $status -eq 0 ]]; then
  echo "ok  workflows: pinned actions, minimal permissions, untrusted input via env, Dependabot"
fi
exit $status
