#!/usr/bin/env bash
# PreToolUse(Edit|MultiEdit|Write) guard for the Overgrove repository.
#  - Swift: process/shell APIs only in Overgrove/Execution/ (and OvergroveTests/Support/)
#  - Any file: no secrets or personal home paths (gitleaks stdin with the repo config)
#  - Workflows: every `uses:` must be pinned to a full commit SHA
#  - HANDOFF.md is an archived input document and must not change
# Exit 2 = block (stderr is shown to Claude).
set -uo pipefail
input=$(cat)
root="${CLAUDE_PROJECT_DIR:-$(pwd)}"
file=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')
[[ -z "$file" ]] && exit 0

# The relative path decides which rules apply, so take it from the worktree that holds the file: a file in a linked
# worktree outside CLAUDE_PROJECT_DIR would otherwise keep its absolute path and match no allowed folder. The checker
# script and the gitleaks config still come from $root, the checkout this session trusts.
file_root="$root"
dir=$(dirname "$file")
while [[ ! -d "$dir" && "$dir" != "/" ]]; do dir=$(dirname "$dir"); done
if top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) && [[ "$file" == "$top"/* ]]; then
  file_root="$top"
fi
rel="${file#"$file_root"/}"

# New text introduced by the tool call.
content=$(printf '%s' "$input" | jq -r '
  .tool_input as $t
  | if $t.content then $t.content
    elif $t.new_string then $t.new_string
    elif $t.edits then ($t.edits | map(.new_string // "") | join("\n"))
    else "" end')

block() { echo "BLOCKED by .claude/hooks/guard-edit.sh ($rel): $1" >&2; exit 2; }

[[ "$rel" == "HANDOFF.md" ]] && block "HANDOFF.md is the archived original brief. Put changes in docs/ instead."

if [[ "$rel" == *.swift ]]; then
  if ! out=$(printf '%s' "$content" | "$root/scripts/lint/check-forbidden-apis.sh" --stdin "$rel" 2>&1); then
    block "process creation / shell use outside Overgrove/Execution/.
$out"
  fi
fi

if [[ "$rel" == .github/workflows/*.yml || "$rel" == .github/workflows/*.yaml ]]; then
  bad=$(printf '%s\n' "$content" | grep -En '^[[:space:]-]*uses:[[:space:]]*[^.[:space:]][^@[:space:]]*@' | grep -Ev '@[0-9a-f]{40}([[:space:]]|$)' || true)
  [[ -n "$bad" ]] && block "pin every action to a full 40-character commit SHA (with a '# vX.Y.Z' comment).
$bad"
fi

if command -v gitleaks >/dev/null 2>&1 && [[ -n "$content" ]]; then
  if ! out=$(printf '%s' "$content" | gitleaks stdin --no-banner --redact --exit-code 1 -c "$root/.gitleaks.toml" 2>&1); then
    block "possible secret or personal path in the new content (gitleaks). Use placeholders like ~/dev/... and never commit tokens.
$(printf '%s' "$out" | grep -E 'RuleID|Line' | head -10)"
  fi
fi

exit 0
