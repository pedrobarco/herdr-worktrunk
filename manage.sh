#!/usr/bin/env bash
# All-in-one picker for the worktrunk herdr plugin. One fzf list over existing
# worktrees and branches: ↵ switches to a match or creates a typed-new branch,
# ctrl-x removes the highlighted worktree (then reloads so you can delete more).
# The switch/create and remove logic lives in helpers.sh, shared with picker.sh
# and remove.sh so all three commands behave identically.

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

if ! command -v fzf >/dev/null; then
  printf '\033[31m%s\033[0m\n' "fzf not found on PATH"; sleep 2; exit 1
fi

plugin_root=${HERDR_PLUGIN_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}
# shellcheck source=./config.sh
source "$plugin_root/config.sh"
# shellcheck source=./helpers.sh
source "$plugin_root/helpers.sh"

herdr=${HERDR_BIN_PATH:-herdr}

# Branch refs to offer alongside `wt list`: always local heads, plus
# remote-tracking branches unless disabled via show_remote_branches = false.
branch_refs=(refs/heads refs/remotes)
[[ $(worktrunk_show_remote_branches) == false ]] && branch_refs=(refs/heads)

# Loop so ctrl-x deletes and returns to a refreshed list; ↵ acts and exits.
while true; do
  choice=$(
    {
      wt --config-set list.json-schema=1 list --format=json 2>/dev/null \
        | jq -r '.[] | select(.branch != null) | .branch'
      # Drop origin/HEAD: its short form is bare "origin", so filter on the full
      # refname (refs/remotes/origin/HEAD) instead, then emit the short name.
      git for-each-ref --format='%(refname) %(refname:short)' "${branch_refs[@]}" 2>/dev/null \
        | awk '$1 !~ /\/HEAD$/ {print $2}'
    } | LC_ALL=C sort -u \
      | fzf --print-query --expect=ctrl-x --reverse --info=inline \
            --border=rounded --margin=20%,30% \
            --prompt='worktree ❯ ' \
            --header="↵ switch · type + ↵ create from ${create_base_label} · ctrl-x remove · esc cancel"
  )
  # 130+ = esc/abort → cancel (0 = picked, 1 = typed-new with no match).
  (( $? > 1 )) && exit 0

  # With --print-query --expect the output is three lines: the typed query, the
  # pressed key (blank for enter), and the selection (absent for a typed-new name).
  # read line-by-line to stay bash 3.2 compatible (no mapfile).
  { IFS= read -r query; IFS= read -r key; IFS= read -r match; } <<< "$choice"

  if [[ $key == ctrl-x ]]; then
    # Delete needs a real, highlighted worktree branch, not a typed-only name.
    [[ -z $match ]] && continue
    worktrunk_remove "$match"
    continue   # reload the list
  fi

  name=${match:-$query}
  [[ -z $name ]] && exit 0
  worktrunk_switch_or_create "$name" "$create_base"
  break
done
