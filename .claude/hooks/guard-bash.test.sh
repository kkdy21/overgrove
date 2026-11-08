#!/usr/bin/env bash
# Tests .claude/hooks/guard-bash.sh with synthetic PreToolUse inputs (#301). No network; throwaway git repositories
# give the hook a branch to look at (`cwd`).
# Run: .claude/hooks/guard-bash.test.sh
set -euo pipefail
HOOK="$(cd "$(dirname "$0")" && pwd)/guard-bash.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail=0

on_branch="$work/branch"
on_main="$work/main"
for repo in "$on_branch" "$on_main"; do
  git init -q -b main "$repo"
done
git -C "$on_branch" checkout -q -b feat/1-x

# check <name> <expected exit 0|2> <cwd> <command>
check() {
  local got=0
  jq -n --arg command "$4" --arg cwd "$3" '{tool_input: {command: $command}, cwd: $cwd}' |
    "$HOOK" >/dev/null 2>&1 || got=$?
  if [[ "$got" == "$2" ]]; then
    echo "ok   $1"
  else
    echo "FAIL $1: expected exit $2, got $got"
    fail=1
  fi
}

B=$on_branch
M=$on_main

# #301: `main` elsewhere in a compound command is not a push to main.
check "push then pr create --base main"     0 "$B" 'git push -u origin feat/1-x && gh pr create --base main --title x'
check "push; pr create --base main"         0 "$B" 'git push origin feat/1-x; gh pr create --base main'
check "push, newline, base main"            0 "$B" $'git push origin feat/1-x\ngh pr create --base main'
check "push then pr create --base=main"     0 "$B" 'git push origin feat/1-x && gh pr create --base=main'
check "push then pr create -B main"         0 "$B" 'git push origin feat/1-x && gh pr create -B main --draft'
check "push then pr edit --base main"       0 "$B" 'git push origin feat/1-x && gh pr edit 5 --base main'
check "push then quoted base main"          0 "$B" 'git push origin feat/1-x && gh pr create --base "main" --title x'
# Conservative on purpose: a bare `main` anywhere else next to a push still blocks (security review of #301).
check "push | grep main (conservative)"     2 "$B" 'git push origin feat/1-x 2>&1 | grep -v main'
check "push || echo main (conservative)"    2 "$B" 'git push origin feat/1-x || echo main'
check "plain push of the branch"            0 "$B" 'git push -q -u origin feat/1-x'
check "branch named like main-ish"          0 "$B" 'git push origin feat/maintenance'

# Pushes to main stay blocked, alone or inside a compound command.
check "push origin main"                    2 "$B" 'git push origin main'
check "push origin HEAD:main"               2 "$B" 'git push origin HEAD:main'
check "push origin HEAD:refs/heads/main"    2 "$B" 'git push origin HEAD:refs/heads/main'
check "push origin +main"                   2 "$B" 'git push origin +main'
check "push origin quoted main"             2 "$B" 'git push origin "main"'
check "push main after cd"                  2 "$B" 'cd /tmp && git push origin main'
check "push main before pr create"          2 "$B" 'git push origin main && gh pr create --base main'
check "push main with git -C"               2 "$B" 'git -C /tmp/x push origin main'
check "push main, second segment"           2 "$B" 'git fetch origin; git push origin feat/1-x:main'
check "push main in command substitution"   2 "$B" 'echo $(git push origin main)'
check "push main in backticks"              2 "$B" 'echo `git push origin main`'
check "push main with -c option"            2 "$B" 'git -c core.x=y push origin HEAD:main'
check "force-with-lease to main in subst"   2 "$B" 'x=$(git push --force-with-lease origin main)'
# Bypasses found in the security review of #301's first version (splitting the command): all must block.
check "continued line, force"               2 "$B" $'git push \\\n  --force origin feat/1-x'
check "continued line, main"                2 "$B" $'git push origin \\\n  main'
check "quoted ; before main"                2 "$B" "git push -o 'a;b' origin main"
check "quoted | before main"                2 "$B" 'git push --push-option="x|y" origin main'
check "quoted && before -f"                 2 "$B" "git push origin feat/1-x -o 'a&&' -f"
check "quoted || before --force"            2 "$B" 'git push -o "a||b" --force origin feat/1-x'
check "quoted newline before main"          2 "$B" $'git push -o "a\n" origin main'
check "absolute path to git, main"          2 "$B" '/usr/bin/git push origin main'
check "absolute path to git, force"         2 "$B" '/opt/homebrew/bin/git push --force origin feat/1-x'
check "absolute path, bare push on main"    2 "$M" '/usr/bin/git push'
check "xargs main"                          2 "$B" 'echo main | xargs git push origin'
check "xargs force"                         2 "$B" 'echo --force | xargs git push origin feat/1-x'
check "base main does not hide a push"      2 "$B" 'gh pr create --base main; git push origin main'
check "pr create then push main"            2 "$B" 'gh pr create --base main && git push origin HEAD:main'
# The base-branch exemption cannot hide a refspec (re-review of #301): `-o` takes the next word as its value.
check "strip: -o --base main in subshell"   2 "$B" 'gh pr create $(git push origin -o --base main )'
check "strip: -o -B main in quoted subst"   2 "$B" 'gh pr create --title "$(git push -o -B main origin x)"'
check "strip: gh pr create as -o value"     2 "$B" 'git push origin -o "gh pr create" -o --base main'
check "strip: gh pr edit as -o value"       2 "$B" "git push -o 'gh pr edit' -o -B main origin feat/1-x"
check "strip: backtick subst"               2 "$B" 'gh pr create `git push origin -o --base main `'
check "title with parentheses, base main"   0 "$B" 'git push origin feat/1-x && gh pr create --title "fix(ui): x" --base main'
check "bare push on main"                   2 "$M" 'git push'
check "push origin only on main"            2 "$M" 'git push origin'
check "bare push on main after cd"          2 "$M" 'echo hi && git push -u'
check "push branch from main checkout"      0 "$M" 'git push origin feat/1-x'

# #342: push forms both the old and the #301 hook let through.
check "push --all"                          2 "$B" 'git push --all'
check "push origin --all"                   2 "$B" 'git push origin --all'
check "push --mirror"                       2 "$B" 'git push --mirror origin'
check "push --mirror=x"                     2 "$B" 'git push --mirror=origin'
check "force via + refspec"                 2 "$B" 'git push origin +feat/1-x'
check "force via quoted + refspec"          2 "$B" "git push origin '+feat/1-x'"
check "force via +HEAD refspec"             2 "$B" 'git push origin +HEAD:feat/1-x'
check "force bundled -uf"                   2 "$B" 'git push -uf origin feat/1-x'
check "force bundled -fu"                   2 "$B" 'git push -fu origin feat/1-x'
check "force bundled -qf"                   2 "$B" 'git push -qf origin feat/1-x'
check "push origin HEAD on main"            2 "$M" 'git push origin HEAD'
check "push origin @ on main"               2 "$M" 'git push origin @'
check "push -u origin HEAD on main"         2 "$M" 'git push -u origin HEAD'
check "push main, single &"                 2 "$B" 'git push origin main&'
check "push main, single & then more"       2 "$B" 'git push origin main& echo done'
check "push heads/main"                     2 "$B" 'git push origin heads/main'
check "push HEAD:heads/main"                2 "$B" 'git push origin HEAD:heads/main'
check "push main; in braces"                2 "$B" '{ git push origin main; }'
check "push main} in braces"                2 "$B" '{ git push origin main;}'
check "git -C main checkout, bare push"     2 "$B" "git -C $M push"
check "git -C main checkout, HEAD"          2 "$B" "git -C $M push origin HEAD"
check "git -C quoted main checkout"         2 "$B" "git -C \"$M\" push -u"
check "cd main checkout, bare push"         2 "$B" "cd $M && git push"
# Not pushes, or pushes of a branch: allowed.
check "push branch then date +%s"           0 "$B" 'git push origin feat/1-x && date +%s'
check "date +%s alone"                      0 "$B" 'date +%s'
check "push origin HEAD on a branch"        0 "$B" 'git push -u origin HEAD'
check "git -C branch checkout, bare push"   0 "$M" "git -C $B push"
check "cd branch checkout, push HEAD"       0 "$M" "cd $B && git push -u origin HEAD"
check "push branch named feat/main-menu"    0 "$B" 'git push origin feat/main-menu'
check "push branch named feat/x-main"       0 "$B" 'git push origin feat/x-main'
check "push -uq (not a bundled force)"      0 "$B" 'git push -uq origin feat/1-x'
check "push then rm -rf build"              0 "$B" 'git push origin feat/1-x && rm -rf build'
check "log --all without push"              0 "$B" 'git log --all --oneline'

# Force pushes stay blocked.
check "force push"                          2 "$B" 'git push --force origin feat/1-x'
check "force push -f"                       2 "$B" 'git push -f'
check "force push in second segment"        2 "$B" 'git status && git push -f origin feat/1-x'
check "force-with-lease to main"            2 "$B" 'git push --force-with-lease origin main'

# The other rules are unchanged.
check "no-verify"                           2 "$B" 'git commit --no-verify -m x'
check "commit -n"                           2 "$B" 'git commit -n -m x'
check "hooksPath change"                    2 "$B" 'git config core.hooksPath /dev/null'
check "main override variable"              2 "$B" 'OVERGROVE_ALLOW_MAIN_PUSH=1 git push origin feat/1-x'
check "commit on main"                      2 "$M" 'git commit -m x'
check "commit on a branch"                  0 "$B" 'git commit -m x'
check "repo delete"                         2 "$B" 'gh repo delete kkdy21/overgrove'
check "visibility change"                   2 "$B" 'gh repo edit --visibility public'
check "secrets"                             2 "$B" 'gh secret list'
check "auth token"                          2 "$B" 'gh auth token'
check "api DELETE"                          2 "$B" 'gh api -X DELETE repos/x/y'
check "pr checkout"                         2 "$B" 'gh pr checkout 12'
check "pr ref fetch without hooksPath"      2 "$B" 'git fetch origin pull/12/head:refs/remotes/pr/12'
check "pr ref fetch with hooksPath"         0 "$B" 'git -c core.hooksPath=/dev/null fetch origin pull/12/head:refs/remotes/pr/12'
check "rm -rf home"                         2 "$B" 'rm -rf ~'
check "rm -rf .git"                         2 "$B" 'rm -rf .git'
check "pr create alone"                     0 "$B" 'gh pr create --base main --title x'

exit $fail
