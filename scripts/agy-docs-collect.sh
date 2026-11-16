#!/usr/bin/env bash
# Compatibility wrapper, prefer scripts/agent-launch.sh.
#
# Collect status, git state, open pull requests, and recent log tails for a
# headless agy documentation run. The implementation lives in
# scripts/agents/agy/collect.
#
# Usage:
#   scripts/agy-docs-collect.sh <repo> [log-stem]
#
# Safety properties:
# - Read-only inspection only (process table, git status/log, gh pr list, log
#   tails).
# - Rejects <repo> values that are not a single directory basename under
#   $HOME/agy-work/<repo>.
# - Never mutates git state, GitHub state, or agent settings.

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd -P)"
adapter="$script_dir/agents/agy/collect"

usage() {
  cat >&2 <<'EOF'
Usage: scripts/agy-docs-collect.sh <repo> [log-stem]

Arguments:
  <repo>      Repository directory basename under $HOME/agy-work/<repo>
  [log-stem]  Optional log/PID stem under $HOME/agy-inbox/ (defaults to newest .pid)
EOF
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage
  exit 2
fi

exec "$adapter" "$@"
