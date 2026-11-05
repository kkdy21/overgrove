#!/usr/bin/env bash
# Enforces the issue claim lease (ADR-0013). Run by .github/workflows/claim-expiry.yml every 30 minutes.
#
# A PR "counts" for an issue only if it is open, closes the issue (`Closes #n`), comes from a branch named
# <type>/<n>-<slug>, and was updated within STALE_HOURS. This stops one PR that lists many issues from
# holding all of them.
#   1. Release: LEASE_HOURS after assignment, an assignee without a counting PR is unassigned.
#      This covers "no PR yet", "PR closed without merge", and "PR stale for STALE_HOURS".
#   2. First PR wins: an unassigned, claimable issue with a counting PR gets the earliest PR's author as
#      assignee, unless that author already holds MAX_CLAIMS issues. Failures are silent to avoid spam.
# The repository owner (maintainer) is exempt. Epics and blocked/undecided/untriaged issues are not assigned.
#
# Usage: scripts/github/claim-expiry.sh [--dry-run] [--input issues.json]
# Requires: gh, jq. Env: REPO, LEASE_HOURS (5), STALE_HOURS (72), MAX_CLAIMS (2).
set -uo pipefail
REPO="${REPO:-kkdy21/overgrove}"
LEASE_HOURS="${LEASE_HOURS:-5}"
STALE_HOURS="${STALE_HOURS:-72}"
MAX_CLAIMS="${MAX_CLAIMS:-2}"
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
              closedByPullRequestsReferences(first: 20, includeClosedPrs: false) {
                nodes { number state createdAt updatedAt headRefName author { login } }
              }
            }
          }
        }
      }') || { echo "::error::GraphQL query failed" >&2; exit 1; }
    jq -c '.data.repository.issues.nodes[]' <<<"$page"
    [[ $(jq -r '.data.repository.issues.pageInfo.hasNextPage' <<<"$page") == "true" ]] || break
    cursor=$(jq -r '.data.repository.issues.pageInfo.endCursor' <<<"$page")
  done
}

plan() {
  jq -r --arg owner "$OWNER" --argjson lease "$LEASE_HOURS" --argjson stale "$STALE_HOURS" '
    select([.labels.nodes[].name] | index("type:epic") | not)
    | . as $i
    | ([$i.labels.nodes[].name] | any(. == "status:blocked" or . == "status:needs-decision" or . == "status:triage")) as $unclaimable
    | ($i.assignees.nodes | map(.login)) as $as
    | [ $i.closedByPullRequestsReferences.nodes[]
        | select(.state == "OPEN")
        | select(.headRefName | test("^[a-z]+/" + ($i.number | tostring) + "-"))
        | select((now - (.updatedAt | fromdateiso8601)) < ($stale * 3600)) ] as $prs
    | if ($as | length) > 0 then
        $as[] as $a
        | select($a != $owner)
        | select(($prs | map(.author.login) | index($a)) | not)
        | ([$i.timelineItems.nodes[] | select(.assignee.login == $a) | .createdAt] | last) as $t
        | select($t != null and ((now - ($t | fromdateiso8601)) > ($lease * 3600)))
        | "release\t\($i.number)\t\($a)\t\($t)"
      elif ($prs | length) > 0 and ($unclaimable | not) then
        ($prs | sort_by(.createdAt) | .[0]) as $p
        | "assign\t\($i.number)\t\($p.author.login)\t\($p.number)"
      else empty end'
}

open_claims() {
  gh api --paginate "repos/$REPO/issues?state=open&assignee=$1&per_page=100" --jq '.[] | select(.pull_request | not) | .number' | wc -l | tr -d ' '
}

if [[ -n "$INPUT" ]]; then actions=$(jq -c '.[]' "$INPUT" | plan); else actions=$(fetch_issues | plan); fi
[[ -z "$actions" ]] && { echo "nothing to do"; exit 0; }

status=0
while IFS=$'\t' read -r kind issue login extra; do
  case "$kind" in
    release)
      echo "release #$issue from @$login (assigned $extra; no open, fresh PR from <type>/$issue-* after ${LEASE_HOURS}h)"
      [[ $DRY -eq 1 ]] && continue
      if ! gh api -X DELETE "repos/$REPO/issues/$issue/assignees" -f "assignees[]=$login" >/dev/null; then
        echo "::warning::could not unassign @$login from #$issue"; status=1; continue
      fi
      gh issue comment "$issue" --repo "$REPO" --body "⏰ Claim by @$login expired: no open pull request from a \`<type>/$issue-<slug>\` branch with \`Closes #$issue\` (updated within ${STALE_HOURS}h) ${LEASE_HOURS} hours after claiming. The issue is open again — comment \`/claim\` to take it. (선점 만료: 기한 안에 유효한 PR이 없어 해제되었습니다.)
<!-- claim-expired:$login -->" >/dev/null || { echo "::warning::could not comment on #$issue"; status=1; }
      ;;
    assign)
      if [[ "$login" != "$OWNER" ]] && (( $(open_claims "$login") >= MAX_CLAIMS )); then
        echo "skip #$issue: @$login already holds $MAX_CLAIMS claims"; continue
      fi
      echo "assign #$issue to @$login (first open linked PR #$extra)"
      [[ $DRY -eq 1 ]] && continue
      gh api -X POST "repos/$REPO/issues/$issue/assignees" -f "assignees[]=$login" >/dev/null 2>&1 || true
      if gh api "repos/$REPO/issues/$issue" | jq -e --arg l "$login" '[.assignees[].login] | index($l) != null' >/dev/null; then
        gh issue comment "$issue" --repo "$REPO" --body "🔗 Assigned to @$login: PR #$extra is the first open pull request for this issue (first PR wins). Other PRs for this issue will fail the \`pr-policy\` check. (PR 선착순으로 담당자를 지정했습니다.)" >/dev/null || true
      fi
      ;;
  esac
done <<<"$actions"
exit $status
