#!/usr/bin/env bash

# True when NAME is a token worktrunk resolves itself — a branch shortcut
# (^ default, - previous) or `:` syntax (pr:N, mr:N, or a PR/MR URL). Git branch
# names can't be these bare symbols or contain `:`, so these must be passed to
# `wt switch` as-is, never with --create. `@` (current) is omitted: switching to
# the current worktree is a no-op, and its only real use is as a --base.
worktrunk_is_shortcut() {
  case $1 in
    '^'|'-'|*:*) return 0 ;;
    *) return 1 ;;
  esac
}

# True when NAME is an existing local branch or remote-tracking branch. Such refs
# are checked out directly by `wt switch NAME` (worktrunk creates the worktree if
# one doesn't exist yet), so they must never be passed with --create.
worktrunk_ref_exists() {
  git show-ref --quiet --verify "refs/heads/$1" \
    || git show-ref --quiet --verify "refs/remotes/$1"
}

# Switch to the worktree for NAME, or create it. CREATE_BASE (optional) is the ref
# new branches are based on (empty = worktrunk's default). Shared by picker.sh and
# manage.sh so switch/create behaves identically wherever it's invoked. Requires
# $herdr to be set by the caller.
worktrunk_switch_or_create() {
  local name=$1 create_base=${2:-} open_mode is_create result wtpath root_ws
  local -a wtargs
  open_mode=$(worktrunk_open_mode)

  # Existing local/remote ref or a worktrunk shortcut (^ - pr:N …) → switch as-is
  # (wt creates the worktree if needed); anything else → create a new branch.
  if worktrunk_is_shortcut "$name" || worktrunk_ref_exists "$name"; then
    wtargs=(switch "$name")
    is_create=false
  else
    wtargs=(switch --create "$name")
    [[ -n $create_base ]] && wtargs+=(--base "$create_base")
    is_create=true
  fi

  if [[ $open_mode == tab ]]; then
    # Run wt in a new tab's interactive shell so shell integration can cd into the
    # worktree and keep the user there.
    local quoted_name wtcmd newpane
    printf -v quoted_name '%q' "$name"
    if [[ $is_create == true ]]; then
      if [[ -n $create_base ]]; then
        local quoted_base
        printf -v quoted_base '%q' "$create_base"
        wtcmd="wt switch --create $quoted_name --base $quoted_base"
      else
        wtcmd="wt switch --create $quoted_name"
      fi
    else
      wtcmd="wt switch $quoted_name"
    fi
    newpane=$("$herdr" tab create --workspace "$HERDR_WORKSPACE_ID" --cwd "$PWD" --label "$name" --focus \
      | jq -r '.result.root_pane.pane_id')
    [[ -z $newpane ]] && { printf '\033[31m%s\033[0m\n' "failed to open worktree tab"; sleep 2; return 1; }
    "$herdr" pane run "$newpane" "$wtcmd"
    return 0
  fi

  # Native workspace mode: let worktrunk create/switch (running hooks), then
  # register the resulting checkout through herdr's worktree API.
  if ! result=$(wt "${wtargs[@]}" --no-cd --format=json); then
    printf '\n\033[31m%s\033[0m press any key to close' "wt switch failed (see above)."; read -n1
    return 1
  fi
  wtpath=$(printf '%s\n' "$result" | jq -r '.path // empty' 2>/dev/null)
  if [[ -z $wtpath ]]; then
    wtpath=$(wt --config-set list.json-schema=1 list --format=json 2>/dev/null \
      | jq -r --arg b "$name" '.[] | select(.branch == $b and .kind == "worktree") | .path' \
      | head -n1)
  fi
  if [[ -z $wtpath ]]; then
    printf '\033[31m%s\033[0m\n' "worktrunk returned no worktree path for: $name"; sleep 2
    return 1
  fi
  # Register under the repo's ROOT workspace: when invoked from inside a worktree
  # workspace, $HERDR_WORKSPACE_ID is a linked-worktree workspace that `worktree
  # open` rejects. herdr resolves the root from any checkout cwd; fall back to the
  # pane's workspace if it can't.
  root_ws=$("$herdr" worktree list --cwd "$PWD" --json 2>/dev/null \
    | jq -r '.result.source.source_workspace_id // empty')
  [[ -z $root_ws ]] && root_ws=$HERDR_WORKSPACE_ID
  "$herdr" worktree open --workspace "$root_ws" --path "$wtpath" --label "$name" --focus --json
}

# Remove the worktree for branch NAME via `wt remove` (worktrunk owns the checkout,
# branch, hooks, and safety gates), then close the grouped herdr workspace and
# refocus the repo parent. Closing a workspace makes herdr re-pick focus, so the
# refocus is explicit; it's safe because we refuse to remove the caller's own
# workspace (below), so `workspace close` never tears down this pane. Resolved from
# one `herdr worktree list`. Shared by remove.sh and manage.sh; needs $herdr set.
worktrunk_remove() {
  local name=$1 wtlist wsid parent_ws
  wtlist=$("$herdr" worktree list --cwd "$PWD" --json 2>/dev/null)
  wsid=$(printf '%s' "$wtlist" | jq -r --arg b "$name" \
    '.result.worktrees[]? | select(.branch == $b) | .open_workspace_id // empty' | head -n1)

  # Refuse to remove the worktree whose workspace the caller is running in: closing
  # it would tear down this very pane. Switch to the parent first.
  if [[ -n $wsid && $wsid == "${HERDR_WORKSPACE_ID:-}" ]]; then
    printf '\033[33m%s\033[0m\n' "Can't remove the worktree you're in ($name)."
    printf '%s\n' "Switch to the parent (or another worktree) first, then remove it."
    sleep 2
    return 0
  fi

  # wt remove prompts for approval itself, refuses unmerged branches without -D, and
  # refuses worktrees with untracked files without -f — so run it interactively and
  # let worktrunk gate the destructive bits. --foreground keeps the pane until done.
  if ! wt remove --foreground "$name"; then
    printf '\n\033[31m%s\033[0m press any key to continue' "wt remove failed (see above)."; read -n1
    return 0
  fi

  # Close the now-empty grouped workspace, then restore focus to the repo parent
  # (herdr would otherwise jump to an arbitrary workspace). Tab mode / older
  # checkouts have no workspace; clean up their panes instead.
  if [[ -n $wsid ]]; then
    parent_ws=$(printf '%s' "$wtlist" | jq -r '.result.source.source_workspace_id // empty')
    "$herdr" workspace close "$wsid" >/dev/null 2>&1
    [[ -n $parent_ws ]] && "$herdr" workspace focus "$parent_ws" >/dev/null 2>&1
  else
    local wtpath
    wtpath=$(printf '%s' "$wtlist" | jq -r --arg b "$name" \
      '.result.worktrees[]? | select(.branch == $b) | .path' | head -n1)
    [[ -n $wtpath && $wtpath != "/" ]] && "$herdr" pane list 2>/dev/null \
      | jq -r --arg p "$wtpath" --arg self "${HERDR_PANE_ID:-}" \
          '.result.panes[] | select(.pane_id != $self)
           | select(.cwd == $p or (.cwd | startswith($p + "/"))) | .pane_id' \
      | while read -r pid; do "$herdr" pane close "$pid"; done
  fi
}
