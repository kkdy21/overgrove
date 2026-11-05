#!/usr/bin/env bash
# PreToolUse(Bash) guard for the Overgrove repository.
# Blocks commands that bypass the project's safety net. Exit 2 = block (stderr is shown to Claude).
# This is an accident guard, not a security boundary: the GitHub ruleset and CI enforce the same rules server-side.
set -uo pipefail
input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty')
[[ -z "$cmd" ]] && exit 0

block() { echo "BLOCKED by .claude/hooks/guard-bash.sh: $1" >&2; exit 2; }
has()   { printf '%s' "$cmd" | grep -Eq -- "$1"; }

# 1) Never bypass Git hooks (secret scan, commit format, main protection).
has '(^|[[:space:];&|])--no-verify([[:space:]]|$)' && block "--no-verify bypasses the gitleaks and commit-format hooks."
has 'git([[:space:]]+-[^[:space:]]+)*[[:space:]]+commit([^;&|]*[[:space:]])-n([[:space:]]|$)' && block "'git commit -n' bypasses hooks."
has 'git[[:space:]]+config[^;&|]*core\.hooksPath' && block "Do not change core.hooksPath (it must stay .githooks)."
has '(^|[[:space:];&|])(GIT_)?OVERGROVE_ALLOW_MAIN_(COMMIT|PUSH)=' && block "Main-branch overrides are for the maintainer only, not for Claude."

# 2) Force pushes and pushes to main.
if has 'git([[:space:]]+-[^[:space:]]+)*[[:space:]]+push'; then
  has '[[:space:]](--force|-f)([[:space:]]|$)' && block "Force push is not allowed. Use a new commit (we squash-merge anyway)."
  has '--force-with-lease' && has '(^|[[:space:]:/])main([[:space:]]|$)' && block "Force push to main is not allowed."
  has '([[:space:]:]|refs/heads/)main([[:space:]]|$)' && block "Direct push to main is not allowed. Push your branch and open a PR."
  if [[ -n "$cwd" ]]; then
    cur=$(git -C "$cwd" symbolic-ref --short -q HEAD 2>/dev/null || true)
    if [[ "$cur" == "main" ]] && ! has 'git[^;&|]*push[^;&|]*[[:space:]][^-[:space:]][^[:space:]]*[[:space:]]+[^-[:space:]]'; then
      block "You are on main; a bare 'git push' would push main. Switch to your issue branch."
    fi
  fi
fi

# 3) Commits on main.
if has 'git([[:space:]]+-[^[:space:]]+)*[[:space:]]+commit([[:space:]]|$)' && [[ -n "$cwd" ]]; then
  cur=$(git -C "$cwd" symbolic-ref --short -q HEAD 2>/dev/null || true)
  [[ "$cur" == "main" ]] && block "Do not commit on main. Start the issue branch first (/issue-start)."
fi

# 4) Destructive or sensitive GitHub operations.
has 'gh[[:space:]]+repo[[:space:]]+(delete|archive|rename)' && block "Repository delete/archive/rename is maintainer-only."
has 'gh[[:space:]]+repo[[:space:]]+edit[^;&|]*--visibility' && block "Changing repository visibility is maintainer-only."
has 'gh[[:space:]]+(secret|variable)[[:space:]]' && block "Secrets and variables are maintainer-only."
has 'gh[[:space:]]+auth[[:space:]]+(token|logout|refresh)' && block "Do not read or change the gh token."
has 'gh[[:space:]]+api[^;&|]*(-X|--method)[[:space:]]*DELETE' && block "DELETE calls through gh api are maintainer-only."
has 'gh[[:space:]]+api[^;&|]*rulesets' && has '(-X|--method)[[:space:]]*(PUT|POST|PATCH)' && block "Ruleset changes go through scripts/github/apply-repo-settings.sh by the maintainer."

# 5) Obvious foot-guns.
has 'rm[[:space:]]+-[a-zA-Z]*r[a-zA-Z]*f?[[:space:]]+(/|~|\$HOME)([[:space:]]|$)' && block "Refusing to delete a root or home directory."
has 'rm[[:space:]]+-[a-zA-Z]*r[^;&|]*[[:space:]]\.git([[:space:]/]|$)' && block "Refusing to delete .git."

exit 0
