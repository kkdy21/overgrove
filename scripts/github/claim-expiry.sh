#!/usr/bin/env bash
# Enforces the issue claim lease (ADR-0013). Run by .github/workflows/claim-expiry.yml every 30 minutes.
#   1. Releases a claim when LEASE_HOURS have passed since assignment and the assignee has no open PR
#      that closes the issue (`Closes #n`). Closing the PR without merge therefore also releases the claim.
#   2. For an unassigned issue that already has an open linked PR, tries to assign the author of the earliest
#      such PR (first PR wins). GitHub only allows assigning some users; failures are silent to avoid spam.
# The repository owner (maintainer) is exempt from expiry. Epics are ignored.
#
# Usage: scripts/github/claim-expiry.sh [--dry-run] [--input issues.json]
# Requires: gh, jq. Env: REPO (default kkdy21/overgrove), LEASE_HOURS (default 5).
set -euo pipefail
REPO="${REPO:-kkdy21/overgrove}"
LEASE_HOURS="${LEASE_HOURS:-5}"
OWNER="${REPO%%/*}"; NAME="${REPO##*/}"
DRY=0; INPUT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --input) INPUT="$2"; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

fetch_issues() {
  local cursor="" page
  while :; do
    page=$(gh api graphql -F owner="$OWNER" -F name="$NAME" ${cursor:+-F cursor="$cursor"} -f query='
      query($owner: String!, $name: String!, $cursor: String) {
        repository(owner: $owner, name: $name) {
          issues(states: OPEN, first: 50, after: $cursor) {
            pageInfo { hasNextPage endCursor }
            nodes {
              number
              labels(first: 20) { nodes { name } }
              assignees(first: 5) { nodes { login } }
              timelineItems(itemTypes: [ASSIGNED_EVENT], last: 20) {
                nodes { ... on AssignedEvent { createdAt assignee { ... on User { login } } } }
              }
              closedByPullRequestsReferences(first: 10, includeClosedPrs: false) {
                nodes { number state createdAt author { login } }
              }
            }
          }
        }
      }')
    jq -c '.data.repository.issues.nodes[]' <<<"$page"
    [[ $(jq -r '.data.repository.issues.pageInfo.hasNextPage' <<<"$page") == "true" ]] || break
    cursor=$(jq -r '.data.repository.issues.pageInfo.endCursor' <<<"$page")
  done
}

plan() {
  jq -r --arg owner "$OWNER" --argjson lease "$LEASE_HOURS" '
    select([.labels.nodes[].name] | index("type:epic") | not)
    | . as $i
    | ($i.assignees.nodes | map(.login)) as $as
    | ($i.closedByPullRequestsReferences.nodes | map(select(.state == "OPEN"))) as $prs
    | if ($as | length) > 0 then
        $as[] as $a
        | select($a != $owner)
        | select(($prs | map(.author.login) | index($a)) | not)
        | ([$i.timelineItems.nodes[] | select(.assignee.login == $a) | .createdAt] | last) as $t
        | select($t != null and ((now - ($t | fromdateiso8601)) > ($lease * 3600)))
        | "release\t\($i.number)\t\($a)\t\($t)"
      elif ($prs | length) > 0 then
        ($prs | sort_by(.createdAt) | .[0]) as $p
        | "assign\t\($i.number)\t\($p.author.login)\t\($p.number)"
      else empty end'
}

if [[ -n "$INPUT" ]]; then actions=$(jq -c '.[]' "$INPUT" | plan); else actions=$(fetch_issues | plan); fi
[[ -z "$actions" ]] && { echo "nothing to do"; exit 0; }

while IFS=$'\t' read -r kind issue login extra; do
  case "$kind" in
    release)
      echo "release #$issue from @$login (assigned $extra, no open PR after ${LEASE_HOURS}h)"
      [[ $DRY -eq 1 ]] && continue
      gh issue edit "$issue" --repo "$REPO" --remove-assignee "$login" >/dev/null
      gh issue comment "$issue" --repo "$REPO" --body "⏰ Claim by @$login expired: no open pull request with \`Closes #$issue\` within ${LEASE_HOURS} hours of claiming. The issue is open again — comment \`/claim\` to take it. (선점 만료: ${LEASE_HOURS}시간 안에 PR이 없어 해제되었습니다.)" >/dev/null
      ;;
    assign)
      echo "assign #$issue to @$login (first open linked PR #$extra)"
      [[ $DRY -eq 1 ]] && continue
      gh issue edit "$issue" --repo "$REPO" --add-assignee "$login" >/dev/null 2>&1 || true
      if gh api "repos/$REPO/issues/$issue" --jq '[.assignees[].login] | index("'"$login"'") != null' | grep -q true; then
        gh issue comment "$issue" --repo "$REPO" --body "🔗 Assigned to @$login: PR #$extra is the first open pull request for this issue (first PR wins). Other PRs for this issue will fail the \`pr-policy\` check. (PR 선착순으로 담당자를 지정했습니다.)" >/dev/null
      fi
      ;;
  esac
done <<<"$actions"
