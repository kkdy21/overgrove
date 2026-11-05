#!/usr/bin/env bash
# Applies repository settings as code (docs/process/github-settings.md). Idempotent.
#   - merge policy (squash only, PR title as commit title, delete branch on merge)
#   - features (issues, discussions, projects on; wiki off), topics
#   - security (secret scanning + push protection, Dependabot alerts/updates, private vulnerability reporting)
#   - Actions hardening (read-only token, GitHub-owned actions only, SHA pinning)
#   - milestones and labels
#   - ruleset for the default branch (ADR-0012)
# Requires: gh with admin rights on the repository, jq.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
REPO="${REPO:-kkdy21/overgrove}"
step() { printf '\n== %s\n' "$*"; }
try()  { "$@" >/dev/null 2>&1 && echo "  ok: ${*: -1}" || echo "  skipped (not available for this repo/plan): ${*: -1}"; }

step "Repository features and merge policy"
gh api -X PATCH "repos/$REPO" \
  -F has_issues=true -F has_projects=true -F has_wiki=false -F has_discussions=true \
  -F allow_squash_merge=true -F allow_merge_commit=false -F allow_rebase_merge=false \
  -F allow_auto_merge=true -F allow_update_branch=true -F delete_branch_on_merge=true \
  -f squash_merge_commit_title=PR_TITLE -f squash_merge_commit_message=PR_BODY >/dev/null
echo "  ok"

step "Topics"
gh repo edit "$REPO" --add-topic macos,swiftui,git,git-worktree,git-client,developer-tools >/dev/null
echo "  ok"

step "Security features"
gh api -X PATCH "repos/$REPO" --input - >/dev/null <<'JSON'
{"security_and_analysis":{"secret_scanning":{"status":"enabled"},"secret_scanning_push_protection":{"status":"enabled"}}}
JSON
echo "  ok: secret scanning + push protection"
try gh api -X PUT "repos/$REPO/vulnerability-alerts"
try gh api -X PUT "repos/$REPO/automated-security-fixes"
try gh api -X PUT "repos/$REPO/private-vulnerability-reporting"

step "Actions hardening"
gh api -X PUT "repos/$REPO/actions/permissions/workflow" -f default_workflow_permissions=read -F can_approve_pull_request_reviews=false >/dev/null
echo "  ok: GITHUB_TOKEN read-only by default"
gh api -X PUT "repos/$REPO/actions/permissions" -F enabled=true -f allowed_actions=selected >/dev/null
gh api -X PUT "repos/$REPO/actions/permissions/selected-actions" --input - >/dev/null <<'JSON'
{"github_owned_allowed":true,"verified_allowed":false,"patterns_allowed":[]}
JSON
echo "  ok: only GitHub-owned actions allowed"
try gh api -X PUT "repos/$REPO/actions/permissions" -F enabled=true -f allowed_actions=selected -F sha_pinning_required=true
try gh api -X PUT "repos/$REPO/actions/permissions/fork-pr-contributor-approval" -f approval_policy=all_external_contributors

step "Milestones"
existing=$(gh api "repos/$REPO/milestones?state=all&per_page=100" --jq '.[].title')
create_ms() {
  if grep -Fxq "$1" <<<"$existing"; then echo "  exists: $1"
  else gh api "repos/$REPO/milestones" -f title="$1" -f description="$2" >/dev/null; echo "  created: $1"; fi
}
create_ms "v0.1.0" "MVP: read-only worktree dashboard (worktrees, working state, stashes, ahead/behind, graph, issues) with the security baseline. See docs/scope-mvp.md."
create_ms "v0.2.0" "Security and settings hardening, polish after MVP feedback. See docs/scope-mvp.md."
create_ms "later"  "Backlog parking lot for out-of-scope ideas (write operations, PR status, GHE, …). Not scheduled."

step "Labels"
scripts/github/sync-labels.sh --prune | sed 's/^/  /'

step "Ruleset: protect default branch"
ruleset=$(cat <<'JSON'
{
  "name": "main-protection",
  "target": "branch",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } },
  "bypass_actors": [],
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    { "type": "required_linear_history" },
    { "type": "pull_request",
      "parameters": {
        "required_approving_review_count": 0,
        "dismiss_stale_reviews_on_push": true,
        "require_code_owner_review": false,
        "require_last_push_approval": false,
        "required_review_thread_resolution": true,
        "allowed_merge_methods": ["squash"]
      } },
    { "type": "required_status_checks",
      "parameters": {
        "strict_required_status_checks_policy": true,
        "do_not_enforce_on_create": false,
        "required_status_checks": [
          { "context": "gitleaks" },
          { "context": "pr-policy" },
          { "context": "build-test" }
        ]
      } }
  ]
}
JSON
)
id=$(gh api "repos/$REPO/rulesets" --jq '.[] | select(.name=="main-protection") | .id')
if [[ -n "$id" ]]; then
  gh api -X PUT "repos/$REPO/rulesets/$id" --input - <<<"$ruleset" >/dev/null; echo "  updated ruleset $id"
else
  gh api -X POST "repos/$REPO/rulesets" --input - <<<"$ruleset" >/dev/null; echo "  created ruleset"
fi

echo; echo "Done. Review: https://github.com/$REPO/settings"
