#!/usr/bin/env bash
# Remover for the worktrunk herdr plugin — fzf over removable worktrees, then hand
# off to the shared worktrunk_remove (native herdr removal + hooks + branch delete).

if ! command -v fzf >/dev/null; then
  printf '\033[31m%s\033[0m\n' "fzf not found on PATH"; sleep 2; exit 1
fi

plugin_root=${HERDR_PLUGIN_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}
# shellcheck source=./config.sh
source "$plugin_root/config.sh"
# shellcheck source=./helpers.sh
source "$plugin_root/helpers.sh"

herdr=${HERDR_BIN_PATH:-herdr}

# Removable = any real worktree except the main one (the primary checkout can't be
# removed). Pin worktrunk's JSON to schema 1 (worktrunk warns it will default to 2).
cands=$(wt --config-set list.json-schema=1 list --format=json 2>/dev/null \
  | jq -r '.[] | select(.branch != null and .is_main != true) | .branch')
if [[ -z $cands ]]; then
  printf '\033[33m%s\033[0m\n' "No removable worktrees (only the main worktree exists)."; sleep 2; exit 0
fi

name=$(printf '%s\n' "$cands" \
  | fzf --reverse --info=inline --border=rounded --margin=20%,30% \
        --prompt='remove worktree ❯ ' \
        --header='↵ to remove · esc to cancel')
[[ -z $name ]] && exit 0      # esc / no selection → cancel

worktrunk_remove "$name"
