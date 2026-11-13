#!/usr/bin/env bash
# Tests the board Status rule (scripts/github/board-status.jq, ADR-0016) with synthetic issues. No network.
# Run: scripts/github/board-sync-rules.test.sh
set -euo pipefail
RULE="$(cd "$(dirname "$0")" && pwd)/board-status.jq"
OWNER=kkdy21
fail=0

# issue <number> <state> <assignees csv> <labels csv> <milestone> <prs: state:draft:branch:author;...>
issue() {
  jq -n --argjson n "$1" --arg state "$2" --arg as "$3" --arg labels "$4" --arg ms "$5" --arg prs "$6" '{
    id: "x", number: $n, state: $state, body: "",
    assignees: {nodes: ($as | split(",") | map(select(length > 0)) | map({login: .}))},
    labels: {nodes: ($labels | split(",") | map(select(length > 0)) | map({name: .}))},
    milestone: (if $ms == "" then null else {title: $ms} end),
    closedByPullRequestsReferences: {nodes: ($prs | split(";") | map(select(length > 0)) | map(split(":"))
      | map({state: .[0], isDraft: (.[1] == "draft"), headRefName: .[2], author: {login: .[3]}}))}
  }'
}

# check <name> <expected> <dependency count> <all done> <current status> <issue json>
check() {
  local got
  got=$(jq -r --argjson total "$3" --argjson done "$4" --arg cur "$5" --arg owner "$OWNER" -f "$RULE" <<<"$6")
  if [[ "$got" == "$2" ]]; then
    echo "ok   $1"
  else
    echo "FAIL $1: expected $2, got $got"
    fail=1
  fi
}

T=type:feature
check "closed issue is Done"                         "Done"        0 true  "In review"   "$(issue 1 CLOSED '' '' '' '')"
check "epic keeps its status"                        "In progress" 0 true  "In progress" "$(issue 2 OPEN '' type:epic '' '')"
check "new epic starts in Backlog"                   "Backlog"     0 true  ""            "$(issue 2 OPEN '' type:epic '' '')"
check "assignee means In progress"                   "In progress" 0 true  "Ready"       "$(issue 3 OPEN alice $T '' '')"
check "assignee's draft PR is In progress"           "In progress" 0 true  "Ready"       "$(issue 3 OPEN alice $T '' 'OPEN:draft:feat/3-x:alice')"
check "assignee's ready PR is In review"             "In review"   0 true  "In progress" "$(issue 3 OPEN alice $T '' 'OPEN:ready:feat/3-x:alice')"
check "first PR wins on an unassigned issue"         "In review"   0 true  "Ready"       "$(issue 4 OPEN '' $T '' 'OPEN:ready:feat/4-x:bob')"
check "owner's PR counts on someone's issue"         "In review"   0 true  "In progress" "$(issue 5 OPEN alice $T '' 'OPEN:ready:fix/5-y:kkdy21')"
check "PR from another issue's branch is ignored"    "Backlog"     0 true  ""            "$(issue 6 OPEN '' $T '' 'OPEN:ready:feat/99-x:mallory')"
check "non-assignee PR on a claimed issue is ignored" "In progress" 0 true  "Ready"      "$(issue 7 OPEN alice $T '' 'OPEN:ready:feat/7-x:mallory')"
check "merged or closed PR is ignored"               "Ready"       0 true  "In review"   "$(issue 8 OPEN '' $T '' 'MERGED:ready:feat/8-x:bob')"
check "released claim goes back to Ready"            "Ready"       0 true  "In progress" "$(issue 9 OPEN '' $T '' '')"
check "released claim with open dependency: Backlog" "Backlog"     1 false "In progress" "$(issue 9 OPEN '' $T '' '')"
check "dependencies done: Backlog -> Ready"          "Ready"       1 true  "Backlog"     "$(issue 10 OPEN '' $T '' '')"
check "new issue with done dependencies is Ready"    "Ready"       2 true  ""            "$(issue 10 OPEN '' $T '' '')"
check "no dependencies: Backlog stays (triage)"      "Backlog"     0 true  "Backlog"     "$(issue 11 OPEN '' $T '' '')"
check "triage keeps a Ready issue Ready"             "Ready"       0 true  "Ready"       "$(issue 11 OPEN '' $T '' '')"
check "open dependency demotes Ready"                "Backlog"     1 false "Ready"       "$(issue 12 OPEN '' $T '' '')"
check "issue without type:* label never auto-Ready"  "Backlog"     1 true  ""            "$(issue 13 OPEN '' '' '' '')"
check "status:triage blocks Ready"                   "Backlog"     1 true  "Backlog"     "$(issue 14 OPEN '' $T,status:triage '' '')"
check "status:blocked demotes Ready"                 "Backlog"     0 true  "Ready"       "$(issue 15 OPEN '' $T,status:blocked '' '')"
check "status:needs-decision blocks Ready"           "Backlog"     1 true  "Backlog"     "$(issue 16 OPEN '' $T,status:needs-decision '' '')"
check "later milestone never auto-Ready"             "Backlog"     1 true  "Backlog"     "$(issue 17 OPEN '' $T later '')"
check "reopened issue (Done) with done deps: Ready"  "Ready"       1 true  "Done"        "$(issue 18 OPEN '' $T '' '')"
check "reopened issue (Done) without deps: Backlog"  "Backlog"     0 true  "Done"        "$(issue 18 OPEN '' $T '' '')"
# A merge closes the issue and the PR at once (#595). Read after the merge, the issue is Done whatever its PR shows.
check "closed by a merged PR: Done despite assignee" "Done"        0 true  "In review"   "$(issue 19 CLOSED alice $T '' 'MERGED:ready:feat/19-x:alice')"
check "closed by a merged PR: Done, deps unfinished" "Done"        1 false "In review"   "$(issue 19 CLOSED alice $T '' 'MERGED:ready:feat/19-x:alice')"
# Read in the instant before GitHub closes it, the same issue falls back to its assignee. That would overwrite Done,
# so `board-sync.sh pr` reads an issue its merged PR closes once more when it still looks open.
check "race: merged PR, issue still read open"       "In progress" 0 true  "Done"        "$(issue 19 OPEN alice $T '' 'MERGED:ready:feat/19-x:alice')"

if ((fail)); then echo "board-sync rules: FAILED"; exit 1; fi
echo "board-sync rules: all passed"
