#!/usr/bin/env bash
# agent-git named check for scripts/dev-loop-gate.sh.
# Sourced by the gate script, never run on its own. It expects row(), repo,
# and strict from the caller.
#
# Fails when an agent-facing kit doc tells a worker to run a mutating git
# command or to open a pull request. The scope is an explicit path list, not
# every tracked Markdown file. CI fails so a leftover instruction cannot slip
# through review.
set -u

repo="${repo:-}"
strict="${strict:-0}"

agent_git_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
agent_git_hits=0
agent_git_policy_loaded=0

agent_git_load_policy() {
  if [ "$agent_git_policy_loaded" = 1 ]; then
    return 0
  fi
  # shellcheck source-path=SCRIPTDIR
  # shellcheck source=policy-eval.sh
  . "$agent_git_lib_dir/policy-eval.sh"
  agent_git_policy_loaded=1
}

# agent_git_in_scope <path>
# True when the evaluator allows an agent-git.scan decision for the path.
agent_git_in_scope() {
  agent_git_load_policy
  policy_eval_attrs=""
  policy_eval_decide agent-git.scan "$1"
}

# agent_git_scan <path> <regex> <label>
# Prints one FAIL row per matching line and counts the hit.
agent_git_scan() {
  local path="$1"
  local regex="$2"
  local label="$3"
  local hit lineno

  while IFS= read -r hit; do
    lineno="${hit%%:*}"
    [ -n "$lineno" ] || continue
    row AG "$path:$lineno" FAIL "found $label; keep git and pull request steps in the caller"
    agent_git_hits=$((agent_git_hits + 1))
  done < <(grep -nE -- "$regex" "$repo/$path" 2>/dev/null)
}

run_agent_git() {
  local checked=0
  local path state action
  local agent_git_tab forbid_id forbid_ere forbid_label

  agent_git_tab="$(printf '\t')"
  agent_git_hits=0

  row Gate Name Status Action
  row ---- ------------------------------ ------ ------

  while IFS= read -r -d '' path; do
    if ! agent_git_in_scope "$path"; then
      continue
    fi
    if [ ! -f "$repo/$path" ]; then
      continue
    fi
    checked=$((checked + 1))
    while IFS="$agent_git_tab" read -r forbid_id forbid_ere forbid_label; do
      [ -n "$forbid_id" ] || continue
      agent_git_scan "$path" "$forbid_ere" "$forbid_label"
    done < <(policy_eval_list_forbids agent-git.instruct)
  done < <(git -C "$repo" ls-files -z)

  if [ "$agent_git_hits" -gt 0 ]; then
    state=FAIL
  else
    state=PASS
  fi
  action="$checked files, $agent_git_hits hits"
  row AG agent-git "$state" "$action"

  if [ "$agent_git_hits" -gt 0 ] && [ "$strict" = 1 ]; then
    return 1
  fi
  return 0
}
