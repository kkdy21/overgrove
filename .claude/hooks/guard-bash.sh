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
# The whole command line is checked, so line continuations, quoted separators, and `xargs` cannot hide a target. Only
# the base branch of `gh pr create`/`gh pr edit` (`--base main`, `--base=main`, `-B main`) is taken out first: it names
# the pull request's target, not a push (#301). Only where `gh pr create|edit` starts a command (line start or after
# `;`, `&`, `|`), so `gh pr create` quoted inside a `git push -o` value does not count; and the span stops at `;`, `&`,
# `|`, `$`, a backtick, and the end of the line, so a `-o --base main` inside `$(git push …)` is never taken out.
scan=$(printf '%s' "$cmd" | sed -E -e ':a' \
  -e 's/(^|[;&|][[:space:]]*)(gh[[:space:]]+pr[[:space:]]+(create|edit)[^;&|$`]*[[:space:]])(--base[[:space:]=]+|-B[[:space:]]+)["'\'']?main["'\'']?([[:space:]]|$)/\1\2--base=PR-BASE\5/' \
  -e 'ta')
scan_has() { printf '%s' "$scan" | grep -Eq -- "$1"; }
# `git push`, also with global options (`-C <dir>`, `-c <key=value>`, quoted values with spaces), a path to git, or
# inside `$(…)` or backticks.
q="'"
arg="(\"[^\"]*\"|$q[^$q]*$q|[^[:space:]]+)"
pushre="git([[:space:]]+(-[Cc][[:space:]]+$arg|-[^[:space:]]+))*[[:space:]]+push"
if scan_has "$pushre"; then
  # What may end a word: space, `)`, a backtick, `;`, `&`, `|`, `}`, a redirect, `#`, or the end of the line (#342).
  end='([[:space:])`;&|}<>#]|$)'
  # `--force`, `-f`, and `-f` bundled with other short options (`-uf`, `-fu`, `-uff`, `-foci.skip`), quoted too (#342).
  scan_has "[[:space:]][\"']?(--force[\"']?$end|-[46dnquv]*f)" && block "Force push is not allowed. Use a new commit (we squash-merge anyway)."
  # A `+` refspec forces too (`+feat/x`, `'+HEAD:x'`, `+$ref`). `date +%s` is not a refspec: `%` starts no ref name.
  scan_has '[[:space:]]["'\'']?[+]["'\'']?[A-Za-z0-9_@./$-]' && block "Force push ('+' refspec) is not allowed. Use a new commit (we squash-merge anyway)."
  # `--all` (and its alias `--branches`) pushes every branch, main included; `--mirror` also force-pushes and deletes.
  # git accepts any unambiguous prefix of a long option (`--mirr`, `--al`), so the prefixes count too (#342).
  scan_has "[[:space:]]--(al|all|b|br|bra|bran|branc|branch|branche|branches|m|mi|mir|mirr|mirro|mirror)([=]|$end)" &&
    block "'git push --all', '--branches', and '--mirror' include main. Push your branch by name."
  scan_has '--force-with-lease' && scan_has "(^|[[:space:]:/+\"'])main[\"']?$end" && block "Force push to main is not allowed."
  # `main`, `+main`, `"main"`, `HEAD:main`, `refs/heads/main`, `heads/main` as a push target.
  scan_has "([[:space:]:]|(refs/)?heads/)[+]?[\"']?main[\"']?$end" && block "Direct push to main is not allowed. Push your branch and open a PR."

  # A push with no refspec, or with `HEAD`/`@`, pushes the branch of the checkout it runs in (#342). That checkout is
  # `cwd`, changed by each `cd <dir>` before the push that is not inside `( … )` or `$( … )`, then by the push's own
  # `git -C <dir>`. Relative targets resolve against the folder so far; `~` is the home folder; `cd -` is ignored.
  resolve() {
    local d=$1
    d="${d#\"}"; d="${d%\"}"; d="${d#"$q"}"; d="${d%"$q"}"
    [[ "$d" == "~"* ]] && d="$HOME${d#\~}"
    [[ "$d" != /* ]] && d="$2/$d"
    printf '%s' "$d"
  }
  # A `cd` starts a command (line start, newline, `;`, `&`, `|`, `{`, `(`); its unquoted target stops at `;&|)`.
  nl=$'\n'
  cdre="(^|[;&|{($nl][[:space:]]*)cd[[:space:]]+(--[[:space:]]+)?(\"[^\"]*\"|$q[^$q]*$q|[^[:space:];&|)]+)"
  cre="-C[[:space:]]+$arg"
  rest=$scan
  before=""
  while [[ $rest =~ $pushre ]]; do
    m=${BASH_REMATCH[0]}
    before+=${rest%%"$m"*}
    rest=${rest#*"$m"}
    top=$before
    while [[ $top =~ \([^\(\)]*\) ]]; do top=${top/"${BASH_REMATCH[0]}"/}; done
    dir=$cwd
    while [[ $top =~ $cdre ]]; do
      target=${BASH_REMATCH[3]}
      top=${top#*"${BASH_REMATCH[0]}"}
      [[ "$target" == "-" ]] && continue
      [[ -z "$dir" && "$target" != [/~\"$q]* ]] && continue
      # A `cd` that would fail leaves the shell where it was, and a following `;` push runs there.
      next=$(resolve "$target" "$dir")
      [[ -d "$next" ]] && dir=$next
    done
    t=$m
    while [[ $t =~ $cre ]]; do
      dir=$(resolve "${BASH_REMATCH[1]}" "${dir:-/}")
      t=${t#*"${BASH_REMATCH[0]}"}
    done
    before+=$m
    [[ -n "$dir" ]] || continue
    cur=$(git -C "$dir" symbolic-ref --short -q HEAD 2>/dev/null || true)
    [[ "$cur" == "main" ]] || continue
    # The push's words up to the next separator: count the remote and refspecs, skipping options, `-o <value>`, and
    # redirects (`2>/dev/null`, `> log`).
    read -ra words <<<"${rest%%[;&|]*}"
    positional=()
    skip=0
    # `${a[@]+…}`: bash 3.2 (macOS) treats an empty array as unset under `set -u`.
    for w in ${words[@]+"${words[@]}"}; do
      if ((skip)); then skip=0; continue; fi
      case "$w" in
        '#'*) break ;; # a comment: the rest is not part of the push
        -o | --push-option | --repo | --receive-pack | --exec) skip=1 ;;
        [0-9]'>' | [0-9]'>>' | '>' | '>>' | '<' | '&>') skip=1 ;;
        -* | [0-9]'>'* | '>'* | '<'* | '&>'*) ;;
        *) w="${w%%[\`\)\}]*}"; w="${w#[\"\']}"; w="${w%[\"\']}"; positional+=("$w") ;;
      esac
    done
    names_head=0
    for w in ${positional[@]+"${positional[@]:1}"}; do [[ "$w" == "HEAD" || "$w" == "@" ]] && names_head=1; done
    if ((${#positional[@]} < 2 || names_head)); then
      block "The push runs on main ($dir); it would push main. Switch to your issue branch."
    fi
  done
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

# 5) Never check out untrusted PR code: .githooks is a relative hooksPath, so a PR's own hooks would run here.
has 'gh[[:space:]]+pr[[:space:]]+checkout' && block "Do not check out PRs locally (their .githooks/.claude hooks would run). Use: git -c core.hooksPath=/dev/null fetch origin pull/<n>/head:refs/remotes/pr/<n> and read with git diff/git show."
has 'git[^;&|]*fetch[^;&|]*pull/[0-9]+/head' && ! has 'core\.hooksPath=/dev/null' && block "Fetch PR refs with: git -c core.hooksPath=/dev/null fetch origin pull/<n>/head:refs/remotes/pr/<n>"

# 6) Obvious foot-guns.
has 'rm[[:space:]]+-[a-zA-Z]*r[a-zA-Z]*f?[[:space:]]+(/|~|\$HOME)([[:space:]]|$)' && block "Refusing to delete a root or home directory."
has 'rm[[:space:]]+-[a-zA-Z]*r[^;&|]*[[:space:]]\.git([[:space:]/]|$)' && block "Refusing to delete .git."

exit 0
