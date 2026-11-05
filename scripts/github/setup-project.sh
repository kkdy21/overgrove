#!/usr/bin/env bash
# Creates the "Overgrove Roadmap" GitHub Projects (v2) board and links it to the repository. Idempotent.
# Requires: gh with the `project` scope  →  gh auth refresh -s project
#
# Fields: Status (Backlog, Ready, In progress, In review, Done), Phase, Area, Priority, Size.
# Not possible through the API (do these once in the web UI, see docs/process/github-settings.md):
#   - add a Board view grouped by Status
#   - enable the "Auto-add to project" workflow for kkdy21/overgrove issues
set -euo pipefail
OWNER="${OWNER:-kkdy21}"
REPO="${REPO:-kkdy21/overgrove}"
TITLE="Overgrove Roadmap"

num=$(gh project list --owner "$OWNER" --format json --jq ".projects[] | select(.title==\"$TITLE\") | .number")
if [[ -z "$num" ]]; then
  num=$(gh project create --owner "$OWNER" --title "$TITLE" --format json --jq .number)
  echo "created project #$num"
else
  echo "project exists: #$num"
fi
gh project link "$num" --owner "$OWNER" --repo "$REPO" >/dev/null 2>&1 || true
gh project edit "$num" --owner "$OWNER" --visibility PUBLIC \
  --description "Issue-driven roadmap for Overgrove (macOS worktree-first Git client)" \
  --readme "Every task is an issue in $REPO. Columns: Backlog → Ready → In progress → In review → Done. See docs/process/development-workflow.md." >/dev/null

fields=$(gh project field-list "$num" --owner "$OWNER" --format json --jq '.fields[].name')
add_field() {
  if grep -Fxq "$1" <<<"$fields"; then echo "field exists: $1"
  else gh project field-create "$num" --owner "$OWNER" --name "$1" --data-type SINGLE_SELECT --single-select-options "$2" >/dev/null; echo "field created: $1"; fi
}
add_field "Phase"    "Plan,Design,Dev,QA,Release"
add_field "Area"     "git-core,parser,ui,github,security,ci,docs"
add_field "Priority" "P0,P1,P2"
add_field "Size"     "S,M,L"

# Replace the default Status options (Todo/In Progress/Done) with the five columns.
project_id=$(gh project view "$num" --owner "$OWNER" --format json --jq .id)
status_id=$(gh project field-list "$num" --owner "$OWNER" --format json --jq '.fields[] | select(.name=="Status") | .id')
gh api graphql -f query='
mutation($field: ID!) {
  updateProjectV2Field(input: {
    fieldId: $field,
    singleSelectOptions: [
      {name: "Backlog",     color: GRAY,   description: "Triaged, not scheduled yet"},
      {name: "Ready",       color: BLUE,   description: "Acceptance criteria clear, dependencies done"},
      {name: "In progress", color: YELLOW, description: "Branch exists, work under way"},
      {name: "In review",   color: PURPLE, description: "PR open"},
      {name: "Done",        color: GREEN,  description: "Merged / closed"}
    ]
  }) { projectV2Field { ... on ProjectV2SingleSelectField { name options { name } } } }
}' -f field="$status_id" --jq '.data.updateProjectV2Field.projectV2Field.options | map(.name) | join(" → ")'

echo "project id: $project_id  url: https://github.com/users/$OWNER/projects/$num"
