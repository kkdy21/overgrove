#!/usr/bin/env bash
# Keeps the "Overgrove Roadmap" board Status in step with issues, pull requests, and claims (ADR-0016).
#
# Usage:
#   scripts/github/board-sync.sh issue <n>        recompute one issue (and, if it is closed, the issues that depend on it)
#   scripts/github/board-sync.sh pr <n>           recompute the issue that pull request <n> works on
#   scripts/github/board-sync.sh dependents <n>   recompute open issues that list #<n> under "## 의존성"
#   scripts/github/board-sync.sh reconcile        recompute every issue (open issues, and every issue on the board)
#   add --dry-run to print the changes without making them (dry runs never write to the board)
#
# Every issue it looks at gets one log line: what it read, the status it computed, and whether it changed it (#595),
# so a run's log alone explains the board.
#
# Env:
#   GH_TOKEN        token with the `project` scope (CI: secrets.PROJECT_TOKEN). Locally gh's own login is used.
#   REPO            owner/name (default kkdy21/overgrove). The project belongs to the repository owner (a user).
#   PROJECT_NUMBER  default 4
#   RECHECK_SECONDS how long `pr` waits before reading again an issue its merged PR closes but that still reads open
#                   (default 5, #595)
#
# Rules (docs/process/development-workflow.md §2.1). The first match wins:
#   closed                                    → Done
#   type:epic                                 → unchanged (new epics start in Backlog)
#   a counted pull request that is not a draft → In review
#   a counted draft pull request, or assignee → In progress
#   otherwise it is "ready" when it has a type:* label, no status:triage/blocked/needs-decision label, its milestone
#   is not `later`, and every issue under "## 의존성" is done (closed as completed by the owner, like pr-policy):
#     In progress / In review / Ready              → Ready if ready, else Backlog
#     Backlog / not on the board / Done (reopened) → Ready if ready and it has dependencies, else Backlog
#   Backlog issues without dependencies stay where triage put them.
#
# A pull request is counted for issue #n only when it is open, comes from a `<type>/<n>-<slug>` branch, and its author
# is an assignee, the owner, or nobody is assigned yet (first PR wins). This is the claim rule of claim-expiry.sh, so a
# PR that says "Closes #1 #2 #3" cannot move issues its author does not hold.
#
# Security: reads issue and PR data through the API only. Bodies are scanned for issue numbers and never evaluated.
set -euo pipefail

REPO="${REPO:-kkdy21/overgrove}"
OWNER="${REPO%%/*}"
NAME="${REPO##*/}"
PROJECT_NUMBER="${PROJECT_NUMBER:-4}"

DRY_RUN=0
POSITIONAL=()
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    *) POSITIONAL+=("$arg") ;;
  esac
done
MODE="${POSITIONAL[0]:-}"
TARGET="${POSITIONAL[1]:-}"
RECHECK_SECONDS="${RECHECK_SECONDS:-5}"
[[ "$RECHECK_SECONDS" =~ ^[0-9]{1,2}$ ]] || { echo "RECHECK_SECONDS must be 0-99" >&2; exit 2; }

case "$MODE" in
  issue | pr | dependents)
    [[ "$TARGET" =~ ^[0-9]{1,9}$ ]] || { echo "usage: $0 $MODE <number> [--dry-run]" >&2; exit 2; } ;;
  reconcile) ;;
  *) echo "usage: $0 {issue <n>|pr <n>|dependents <n>|reconcile} [--dry-run]" >&2; exit 2 ;;
esac

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Keep in sync with .github/workflows/pr-policy.yml and dependency-closed.yml.
dependency_section() { tr -d '\r' | awk '/^#+[ \t]*(의존성|Dependencies)/ {f=1; next} /^#+[ \t]/ {f=0} f' | grep -Eo '#[0-9]{1,9}' | tr -d '#' | awk '{print $1+0}' || true; }

# ---- project metadata -------------------------------------------------------
PROJECT_JSON=$(gh api graphql -F owner="$OWNER" -F number="$PROJECT_NUMBER" -f query='
  query($owner: String!, $number: Int!) {
    user(login: $owner) {
      projectV2(number: $number) {
        id
        field(name: "Status") { ... on ProjectV2SingleSelectField { id options { id name } } }
      }
    }
  }' --jq '.data.user.projectV2')
PROJECT_ID=$(jq -r '.id' <<<"$PROJECT_JSON")
FIELD_ID=$(jq -r '.field.id' <<<"$PROJECT_JSON")
[[ -n "$PROJECT_ID" && "$PROJECT_ID" != null && -n "$FIELD_ID" && "$FIELD_ID" != null ]] || { echo "project $OWNER/$PROJECT_NUMBER or its Status field not found" >&2; exit 1; }
option_id() { jq -r --arg n "$1" '.field.options[] | select(.name == $n) | .id' <<<"$PROJECT_JSON"; }

# ---- dependencies: done = closed as completed by the owner, not a pull request (same as pr-policy) ----
MAX_DEPS=20 # same limit as pr-policy; more dependencies means "not ready" without looking any up

# Returns 0 when dependency $1 is done, 1 when it is not (or does not exist), 2 when it could not be read.
# One REST call per distinct dependency, cached for the run. Errors other than 404 are not cached as "missing",
# so rate limiting cannot demote a Ready issue.
dep_done() {
  local d=$1 f="$WORK/dep-$1" out state reason is_pr closer
  if [[ ! -f "$f" ]]; then
    if out=$(gh api "repos/$REPO/issues/$d" --jq '[.state, (.state_reason // "none"), (has("pull_request") | tostring), (.closed_by.login // "none")] | join(" ")' 2>"$WORK/dep.err"); then
      printf '%s\n' "$out" >"$f"
    elif grep -q 'HTTP 404' "$WORK/dep.err"; then
      echo "missing none false none" >"$f"
    else
      echo "could not read dependency #$d" >&2
      return 2
    fi
  fi
  read -r state reason is_pr closer <"$f"
  [[ "$state" == closed && "$reason" == completed && "$is_pr" == false && "$closer" == "$OWNER" ]] && return 0
  return 1
}

# stdin: issue body; $1 = 1 to look the dependencies up, 0 to count them only.
# Prints "<count> <all_done>". With lookups off (or more than MAX_DEPS), all_done is false unless there are none.
deps_summary() {
  local lookup=$1 deps count all=true d rc
  deps=$(dependency_section | sort -un)
  count=$(printf '%s\n' "$deps" | grep -c . || true)
  if ((count == 0)); then echo "0 true"; return 0; fi
  if ((count > MAX_DEPS || lookup == 0)); then echo "$count false"; return 0; fi
  for d in $deps; do
    rc=0
    dep_done "$d" || rc=$?
    case $rc in 0) ;; 1) all=false ;; *) return 1 ;; esac
  done
  echo "$count $all"
}

# ---- desired status ---------------------------------------------------------
# stdin: issue JSON (ISSUE_FIELDS); args: dependency count, all done, current status ("" if not on the board)
desired_status() {
  jq -r --argjson total "$1" --argjson done "$2" --arg cur "$3" --arg owner "$OWNER" -f "$SCRIPT_DIR/board-status.jq"
}

ISSUE_FIELDS='
  id number state body
  assignees(first: 10) { nodes { login } }
  labels(first: 50) { nodes { name } }
  milestone { title }
  closedByPullRequestsReferences(first: 10, includeClosedPrs: false) { nodes { state isDraft headRefName author { login } } }'

fetch_issue() {
  gh api graphql -F owner="$OWNER" -F name="$NAME" -F n="$1" -f query="
    query(\$owner: String!, \$name: String!, \$n: Int!) {
      repository(owner: \$owner, name: \$name) { issue(number: \$n) { $ISSUE_FIELDS } }
    }" --jq '.data.repository.issue'
}

# Prints "<item id or -> <status or ->" (spaces in the status replaced by "_") for an issue's item on this board.
# Live runs use addProjectV2ItemById, which returns the existing item (or adds the issue), so the item is found even
# when the issue also sits on many other people's public projects. Dry runs never write and scan the first 100 items.
board_item() {
  local content_id=$1 item status
  if ((DRY_RUN)); then
    gh api graphql -f id="$content_id" -f query='
      query($id: ID!) {
        node(id: $id) { ... on Issue { projectItems(first: 100) { nodes { id project { id } fieldValueByName(name: "Status") { ... on ProjectV2ItemFieldSingleSelectValue { name } } } } } }
      }' | jq -r --arg p "$PROJECT_ID" '[.data.node.projectItems.nodes[] | select(.project.id == $p)] | .[0] | "\(.id // "-") \(.fieldValueByName.name // "-" | gsub(" "; "_"))"'
    return
  fi
  item=$(gh api graphql -f project="$PROJECT_ID" -f content="$content_id" -f query='
    mutation($project: ID!, $content: ID!) { addProjectV2ItemById(input: {projectId: $project, contentId: $content}) { item { id } } }' \
    --jq '.data.addProjectV2ItemById.item.id') || return 1
  [[ -n "$item" && "$item" != null ]] || return 1
  status=$(gh api graphql -f id="$item" -f query='
    query($id: ID!) { node(id: $id) { ... on ProjectV2Item { fieldValueByName(name: "Status") { ... on ProjectV2ItemFieldSingleSelectValue { name } } } } }' \
    --jq '.data.node.fieldValueByName.name // "-"') || return 1
  echo "$item ${status// /_}"
}

CHANGED=0
CHECKED=0
set_status() { # number item current want inputs
  local number=$1 item=$2 cur=$3 want=$4 inputs=$5
  CHECKED=$((CHECKED + 1))
  if [[ "$cur" == "$want" ]]; then
    echo "#$number: $inputs -> $want (unchanged)"
    return 0
  fi
  echo "#$number: $inputs -> $want (was ${cur:-not on board})"
  CHANGED=$((CHANGED + 1))
  ((DRY_RUN)) && return 0
  gh api graphql -f project="$PROJECT_ID" -f item="$item" -f field="$FIELD_ID" -f opt="$(option_id "$want")" -f query='
    mutation($project: ID!, $item: ID!, $field: ID!, $opt: String!) {
      updateProjectV2ItemFieldValue(input: {projectId: $project, itemId: $item, fieldId: $field, value: {singleSelectOptionId: $opt}}) { projectV2Item { id } }
    }' >/dev/null
}

# issue JSON, item id ("-" if not on the board), current status ("" if none) → apply the desired status
sync_with() {
  local json=$1 item=$2 cur=$3 body summary total want if_done if_not inputs
  body=$(jq -r '.body // ""' <<<"$json")
  summary=$(deps_summary 0 <<<"$body") || return 1
  total=${summary% *}
  if ((total > 0 && total <= MAX_DEPS)); then
    # Look the dependencies up only when the result depends on them (an assigned or closed issue does not).
    if_done=$(desired_status "$total" true "$cur" <<<"$json")
    if_not=$(desired_status "$total" false "$cur" <<<"$json")
    if [[ "$if_done" == "$if_not" ]]; then
      want=$if_done
    else
      summary=$(deps_summary 1 <<<"$body") || return 1
      want=$(desired_status "$total" "${summary#* }" "$cur" <<<"$json")
    fi
  else
    want=$(desired_status "$total" "${summary#* }" "$cur" <<<"$json")
  fi
  # What the rule saw: state, assignees, open PRs (draft or ready, by branch), dependencies (count, done or not looked up).
  # Any open PR that names the issue is listed, counted or not, so its branch name is quoted: a fork's branch cannot
  # pass for extra entries.
  inputs=$(jq -r --arg deps "$total:${summary#* }" '
    "state=\(.state) assignees=\([.assignees.nodes[].login] | join(",") | if . == "" then "-" else . end)"
    + " prs=\([(.closedByPullRequestsReferences.nodes // [])[] | select(.state == "OPEN")
        | "\(.headRefName | @json)(\(if .isDraft then "draft" else "ready" end))"] | join(",") | if . == "" then "-" else . end)"
    + " deps=\($deps)"' <<<"$json")
  if [[ "$item" == "-" ]] && ! ((DRY_RUN)); then
    item=$(gh api graphql -f project="$PROJECT_ID" -f content="$(jq -r '.id' <<<"$json")" -f query='
      mutation($project: ID!, $content: ID!) { addProjectV2ItemById(input: {projectId: $project, contentId: $content}) { item { id } } }' \
      --jq '.data.addProjectV2ItemById.item.id') || return 1
  fi
  set_status "$(jq -r '.number' <<<"$json")" "$item" "$cur" "$want" "$inputs"
}

# $1 issue number; $2 (optional) the merged pull request that closes it: an issue that still reads open is read once
# more after RECHECK_SECONDS. The merge closes both at once, and a run that saw the issue open in between would put
# it back to its assignee's "In progress" after the issue's own run set Done (#595).
sync_issue() {
  local json found item cur
  json=$(fetch_issue "$1") || { echo "could not read issue #$1" >&2; return 1; }
  [[ -n "$json" && "$json" != null ]] || { echo "issue #$1 not found" >&2; return 1; }
  if [[ -n "${2:-}" && "$(jq -r '.state' <<<"$json")" == OPEN ]]; then
    echo "#$1: still open after PR #$2 merged; reading it again in $RECHECK_SECONDS s"
    sleep "$RECHECK_SECONDS"
    json=$(fetch_issue "$1") || { echo "could not read issue #$1" >&2; return 1; }
  fi
  found=$(board_item "$(jq -r '.id' <<<"$json")") || { echo "could not read the board item of #$1" >&2; return 1; }
  item=${found%% *}
  cur=${found#* }
  cur=${cur//_/ }
  [[ "$cur" == "-" ]] && cur=""
  sync_with "$json" "$item" "$cur"
}

sync_dependents() {
  local target=$1 row json
  gh api --paginate "repos/$REPO/issues?state=open&per_page=100" \
    --jq '.[] | select(.pull_request | not) | {number, body: (.body // "")} | @base64' >"$WORK/open.b64"
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    json=$(printf '%s' "$row" | base64 -d)
    if jq -r '.body' <<<"$json" | dependency_section | grep -qx "$target"; then sync_issue "$(jq -r '.number' <<<"$json")"; fi
  done <"$WORK/open.b64"
}

case "$MODE" in
  issue)
    sync_issue "$TARGET"
    # State-based rather than event-based, so a later event that replaces a queued "closed" run still does this.
    if [[ "$(gh api "repos/$REPO/issues/$TARGET" --jq .state)" == closed ]]; then sync_dependents "$TARGET"; fi
    ;;
  pr)
    # The issue whose number is in the branch name and that the PR closes, in this repository only.
    pr_json=$(gh api graphql -F owner="$OWNER" -F name="$NAME" -F n="$TARGET" -f query='
      query($owner: String!, $name: String!, $n: Int!) {
        repository(owner: $owner, name: $name) {
          pullRequest(number: $n) { merged headRefName closingIssuesReferences(first: 20) { nodes { number repository { nameWithOwner } } } }
        }
      }')
    for n in $(jq -r --arg repo "$REPO" '.data.repository.pullRequest as $p
        | $p.closingIssuesReferences.nodes[]?
        | select(.repository.nameWithOwner == $repo)
        | . as $i
        | select($p.headRefName | test("^[a-z]+/" + ($i.number | tostring) + "-"))
        | $i.number' <<<"$pr_json"); do
      if [[ "$(jq -r '.data.repository.pullRequest.merged' <<<"$pr_json")" == true ]]; then
        sync_issue "$n" "$TARGET"
      else
        sync_issue "$n"
      fi
    done
    ;;
  dependents)
    sync_dependents "$TARGET"
    ;;
  reconcile)
    # Every issue of this repository on the board (item and status come with it), then open issues not on it yet.
    gh api graphql --paginate -F owner="$OWNER" -F number="$PROJECT_NUMBER" -f query="
      query(\$owner: String!, \$number: Int!, \$endCursor: String) {
        user(login: \$owner) {
          projectV2(number: \$number) {
            items(first: 50, after: \$endCursor) {
              pageInfo { hasNextPage endCursor }
              nodes {
                id
                fieldValueByName(name: \"Status\") { ... on ProjectV2ItemFieldSingleSelectValue { name } }
                content { ... on Issue { repository { nameWithOwner } $ISSUE_FIELDS } }
              }
            }
          }
        }
      }" | jq -r --arg repo "$REPO" '.data.user.projectV2.items.nodes[]
        | select(.content.number != null and .content.repository.nameWithOwner == $repo)
        | {item: .id, status: (.fieldValueByName.name // ""), issue: (.content | del(.repository))} | @base64' >"$WORK/board.b64"
    on_board=" "
    while IFS= read -r row; do
      [[ -n "$row" ]] || continue
      entry=$(printf '%s' "$row" | base64 -d)
      json=$(jq -c '.issue' <<<"$entry")
      on_board+="$(jq -r '.number' <<<"$json") "
      sync_with "$json" "$(jq -r '.item' <<<"$entry")" "$(jq -r '.status' <<<"$entry")"
    done <"$WORK/board.b64"
    for n in $(gh api --paginate "repos/$REPO/issues?state=open&per_page=100" --jq '.[] | select(.pull_request | not) | .number'); do
      [[ "$on_board" == *" $n "* ]] || sync_issue "$n"
    done
    ;;
esac
suffix=""
((DRY_RUN)) && suffix=" (dry run)"
echo "board-sync $MODE${TARGET:+ $TARGET}: checked $CHECKED issue(s), $CHANGED change(s)$suffix"
