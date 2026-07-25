#!/usr/bin/env bash
# Picker for the worktrunk herdr plugin. Picks a branch via fzf (fast), then opens a
# new tab and runs `wt switch` in THAT pane — so the worktree creation and any hook
# output happen in the pane you keep, not in this transient picker pane. The new tab
# runs your interactive shell, so its `wt` function cd's into the worktree and sticks.

create_base=""
create_base_label="default branch"
case ${1:-} in
  ""|--create-base=default)
    ;;
  --create-base=current)
    create_base="@"
    current_branch=$(git branch --show-current 2>/dev/null || true)
    if [[ -n $current_branch ]]; then
      create_base_label="current branch (${current_branch})"
    else
      current_commit=$(git rev-parse --short HEAD 2>/dev/null || true)
      if [[ -n $current_commit ]]; then
        create_base_label="current HEAD (${current_commit})"
      else
        create_base_label="current branch"
      fi
    fi
    ;;
  *)
    printf '\033[31m%s\033[0m\n' "unsupported picker option: $1" >&2
    exit 2
    ;;
esac

plugin_root=${HERDR_PLUGIN_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}
# shellcheck source=./config.sh
source "$plugin_root/config.sh"
# shellcheck source=./helpers.sh
source "$plugin_root/helpers.sh"

# Branch refs to offer alongside `wt list`: always local heads, plus
# remote-tracking branches unless disabled via show_remote_branches = false.
branch_refs=(refs/heads refs/remotes)
[[ $(worktrunk_show_remote_branches) == false ]] && branch_refs=(refs/heads)

# fzf over existing worktree branches; --print-query returns a typed-but-unmatched
# name so we can create it. Falls back to a plain read if fzf isn't on PATH.
if command -v fzf >/dev/null; then
  choice=$(
    {
      wt --config-set list.json-schema=1 list --format=json 2>/dev/null \
        | jq -r '.[] | select(.branch != null) | .branch'
      # Drop origin/HEAD: its short form is bare "origin", so filter on the full
      # refname (refs/remotes/origin/HEAD) instead, then emit the short name.
      git for-each-ref --format='%(refname) %(refname:short)' "${branch_refs[@]}" 2>/dev/null \
        | awk '$1 !~ /\/HEAD$/ {print $2}'
    } | LC_ALL=C sort -u \
      | fzf --print-query --reverse --info=inline --border=rounded --margin=20%,30% \
            --prompt='worktree ❯ ' \
            --header="↵ on a match → switch · type a new name + ↵ → create from ${create_base_label} · esc → cancel"
  )
  ret=$?
  [[ $ret -gt 1 ]] && exit 0      # 130 = esc/abort → cancel (0 = picked, 1 = typed-new)
  name=${choice##*$'\n'}          # last line: the selection if any, else the typed query
else
  printf 'Branch (existing → switch · new → create from %s): ' "$create_base_label"
  read -r name
fi
[[ -z $name ]] && exit 0

herdr=${HERDR_BIN_PATH:-herdr}
worktrunk_switch_or_create "$name" "$create_base"
