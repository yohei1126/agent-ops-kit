#!/usr/bin/env bash
# Compatibility wrapper, prefer scripts/agent-launch.sh.
#
# Launch a headless Antigravity CLI (agy -p) documentation worker through the
# agy adapter. The launcher logic lives in scripts/agents/agy/run.
#
# Usage:
#   scripts/agy-docs-launch.sh <repo> <brief-path> [log-stem] [model]
# Model default: gemini-3.8-flash-medium (override via 4th arg, else AGY_DOCS_MODEL, else AGY_MODEL).
#
# This wrapper keeps the former CLI, usage text, model default, and exit codes
# for one release cycle. It resolves the model and delegates to the adapter;
# the adapter keeps the former safety properties:
# - <repo> is a plain basename under $HOME/agy-work/<repo>.
# - <brief-path> resolves inside $HOME/agy-inbox/.
# - Per-run settings are generated from scripts/templates/, checked before
#   launch, and never written into the checkout.
# - Symlinked checkout, settings, PID, and log paths are refused.
# - --dangerously-skip-permissions is never passed and allow lists are never
#   widened.
# - Shared launch/retry logic lives in scripts/lib/launch-run.sh.
#
# Exit codes: 0 ok, 1 check or launch failure, 2 usage.

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd -P)"
adapter="$script_dir/agents/agy/run"

usage() {
  cat >&2 <<'EOF'
Usage: scripts/agy-docs-launch.sh <repo> <brief-path> [log-stem] [model]

Arguments:
  <repo>        Repository directory basename under $HOME/agy-work/<repo>
  <brief-path>  Readable brief file under $HOME/agy-inbox/
  [log-stem]    Optional log/PID filename stem (defaults to brief basename)
  [model]       Optional agy --model id (default gemini-3.8-flash-medium;
                else AGY_DOCS_MODEL, else AGY_MODEL)
EOF
}

if [[ $# -lt 2 || $# -gt 4 ]]; then
  usage
  exit 2
fi

repo="$1"
brief_input="$2"
stem_input="${3:-}"
model_input="${4:-}"

# Model: 4th argv > AGY_DOCS_MODEL > AGY_MODEL > gemini-3.8-flash-medium
if [[ -n "$model_input" ]]; then
  model="$model_input"
elif [[ -n "${AGY_DOCS_MODEL:-}" ]]; then
  model="$AGY_DOCS_MODEL"
elif [[ -n "${AGY_MODEL:-}" ]]; then
  model="$AGY_MODEL"
else
  model="gemini-3.8-flash-medium"
fi

exec "$adapter" --mode docs --model "$model" -- "$repo" "$brief_input" "$stem_input"
