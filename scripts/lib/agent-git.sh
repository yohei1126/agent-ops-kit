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

# Each command needs end of line or a non-identifier character after its last
# word, so git additional and git committing are not hits. This is a portable
# POSIX ERE; do not use grep -P.
agent_git_add_re='(^|[^[:alnum:]_])git[[:space:]]+add([^[:alnum:]_]|$)'
agent_git_commit_re='(^|[^[:alnum:]_])git[[:space:]]+commit([^[:alnum:]_]|$)'
agent_git_push_re='(^|[^[:alnum:]_])git[[:space:]]+push([^[:alnum:]_]|$)'
agent_git_pr_re='(^|[^[:alnum:]_])gh[[:space:]]+pr[[:space:]]+create([^[:alnum:]_]|$)'

agent_git_hits=0

# agent_git_in_scope <path>
# True only for the narrow, explicit agent-facing paths. Caller collect and
# monthly-audit operator examples stay out of scope by omission.
agent_git_in_scope() {
  case "$1" in
    docs/workstation-handoffs.md | templates/agent-task-issue.md) return 0 ;;
    prompts/*.md) return 0 ;;
    templates/agent-task*.md) return 0 ;;
  esac
  return 1
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
    agent_git_scan "$path" "$agent_git_add_re" "git add"
    agent_git_scan "$path" "$agent_git_commit_re" "git commit"
    agent_git_scan "$path" "$agent_git_push_re" "git push"
    agent_git_scan "$path" "$agent_git_pr_re" "gh pr create"
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
