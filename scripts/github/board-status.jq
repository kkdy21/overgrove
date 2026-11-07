# Board Status rule for one issue (ADR-0016, docs/process/development-workflow.md §2.1).
# Used by scripts/github/board-sync.sh and tested by scripts/github/board-sync-rules.test.sh.
#
# Input: the issue (id number state body assignees labels milestone closedByPullRequestsReferences).
# Args:  $total  number of issues under "## 의존성"
#        $done   true when every one of them is closed as completed by the owner (false if any is not)
#        $cur    current Status on the board ("" when the issue is not on it)
#        $owner  repository owner login
# Output: Backlog | Ready | In progress | In review | Done
(.labels.nodes | map(.name)) as $labels
| ([$labels[] | select(. == "status:triage" or . == "status:blocked" or . == "status:needs-decision")] | length > 0) as $blocked
| ([$labels[] | select(startswith("type:"))] | length > 0) as $typed
| ((.milestone.title // "") == "later") as $later
| (.assignees.nodes | map(.login)) as $as
| (.number | tostring) as $n
| [ (.closedByPullRequestsReferences.nodes // [])[]
    | select(.state == "OPEN")
    | select(.headRefName | test("^[a-z]+/" + $n + "-"))
    | select(($as | length) == 0 or (.author.login as $a | ($as | index($a)) != null) or .author.login == $owner) ] as $prs
| if .state == "CLOSED" then "Done"
  elif ($labels | index("type:epic")) then (if $cur == "" or $cur == "Done" then "Backlog" else $cur end)
  elif ($prs | map(select(.isDraft | not)) | length) > 0 then "In review"
  elif ($prs | length) > 0 or ($as | length) > 0 then "In progress"
  else
    ($typed and ($blocked | not) and ($later | not) and $done) as $ready
    | if ($cur == "In progress" or $cur == "In review" or $cur == "Ready") then (if $ready then "Ready" else "Backlog" end)
      elif ($ready and $total > 0) then "Ready"
      else "Backlog" end
  end
