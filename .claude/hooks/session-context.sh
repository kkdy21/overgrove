#!/usr/bin/env bash
# SessionStart: give Claude the current branch / issue context and setup warnings. Output is added to context.
set -uo pipefail
root="${CLAUDE_PROJECT_DIR:-$(pwd)}"
cd "$root" 2>/dev/null || exit 0
branch=$(git symbolic-ref --short -q HEAD 2>/dev/null || echo "(detached)")
issue=$(printf '%s' "$branch" | sed -nE 's#^(feat|fix|docs|test|chore|spike|refactor|perf|ci)/([0-9]+)-.*#\2#p')
echo "Overgrove session context"
echo "- branch: $branch"
if [[ -n "$issue" ]]; then
  echo "- working on issue #$issue (run 'gh issue view $issue' for details)"
elif [[ "$branch" == "main" ]]; then
  echo "- on main: do not commit here. Pick an issue and run /issue-start first."
fi
hooks=$(git config --get core.hooksPath 2>/dev/null || true)
[[ "$hooks" == ".githooks" ]] || echo "- WARNING: Git hooks are not installed. Ask the maintainer to run ./scripts/bootstrap.sh"
command -v gitleaks >/dev/null 2>&1 || echo "- WARNING: gitleaks is not installed; commits will be blocked by the pre-commit hook."
dirty=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
[[ "$dirty" != "0" ]] && echo "- uncommitted changes: $dirty file(s)"
exit 0
