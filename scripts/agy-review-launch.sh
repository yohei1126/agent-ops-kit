#!/usr/bin/env bash
# Compatibility wrapper, prefer scripts/agent-launch.sh.
#
# Launch a headless Antigravity CLI (agy) model-review session through the agy
# adapter. The launcher logic lives in scripts/agents/agy/run.
#
# Usage:
#   scripts/agy-review-launch.sh <run-name> <repo-checkout> <brief-path> [model]
#   scripts/agy-review-launch.sh --dry-run <run-name> <repo-checkout> <brief-path> [model]
#   scripts/agy-review-launch.sh --check-settings <settings.json> <run-dir>
# Model default: gemini-4-argon-medium (override via 4th arg, else AGY_REVIEW_MODEL).
#
# This wrapper keeps the former CLI, usage text, model default, and exit codes
# for one release cycle. It resolves the model and delegates to the adapter;
# the adapter keeps the former safety properties:
# - A fresh run folder under $HOME/agy-work/runs with settings generated from
#   scripts/templates/ and checked before every launch.
# - Refuses symlinked run folders, briefs, settings, PID files, and logs, and
#   refuses a run name that is not a plain token.
# - Never passes --dangerously-skip-permissions and never reads or writes
#   global agent settings.
# - Shared launch/retry logic lives in scripts/lib/launch-run.sh.
#
# Exit codes: 0 ok, 1 check or launch failure, 2 usage.

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd -P)"
adapter="$script_dir/agents/agy/run"
settings_lib="$script_dir/lib/agy-settings-check.sh"
launch_lib="$script_dir/lib/launch-run.sh"
default_model="gemini-4-argon-medium"

usage() {
  cat >&2 <<'EOF'
Usage: scripts/agy-review-launch.sh <run-name> <repo-checkout> <brief-path> [model]
       scripts/agy-review-launch.sh --dry-run <run-name> <repo-checkout> <brief-path> [model]
       scripts/agy-review-launch.sh --check-settings <settings.json> <run-dir>

Arguments:
  <run-name>       Plain token [A-Za-z0-9._-]+ under $HOME/agy-work/runs
  <repo-checkout>  Existing checkout directory inside $HOME/agy-work
  <brief-path>     Readable brief file; copied to <run>/BRIEF.md when needed
  [model]          Optional agy --model id (default gemini-4-argon-medium;
                   else AGY_REVIEW_MODEL)

Flags:
  --dry-run        Generate settings and run the check, then print the agy
                   command without starting it
  --check-settings Run only the pre-launch settings check on an existing file
EOF
}

dry_run=0
check_mode=0
check_settings=""
check_run=""
pos1=""
pos2=""
pos3=""
pos4=""
npos=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)
      dry_run=1
      shift
      ;;
    --check-settings)
      if [ "$#" -lt 3 ]; then
        usage
        exit 2
      fi
      check_mode=1
      check_settings="$2"
      check_run="$3"
      shift 3
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    --)
      shift
      while [ "$#" -gt 0 ]; do
        npos=$((npos + 1))
        case "$npos" in
          1) pos1="$1" ;;
          2) pos2="$1" ;;
          3) pos3="$1" ;;
          4) pos4="$1" ;;
        esac
        shift
      done
      ;;
    -*)
      printf 'agy-review-launch: unknown flag: %s\n' "$1" >&2
      usage
      exit 2
      ;;
    *)
      npos=$((npos + 1))
      case "$npos" in
        1) pos1="$1" ;;
        2) pos2="$1" ;;
        3) pos3="$1" ;;
        4) pos4="$1" ;;
      esac
      shift
      ;;
  esac
done

if [ ! -r "$settings_lib" ]; then
  printf 'agy-review-launch: missing library: %s\n' "$settings_lib" >&2
  exit 1
fi
if [ ! -r "$launch_lib" ]; then
  printf 'agy-review-launch: missing library: %s\n' "$launch_lib" >&2
  exit 1
fi

if [ -z "${HOME:-}" ]; then
  printf 'agy-review-launch: HOME is not set\n' >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  printf 'agy-review-launch: jq is required\n' >&2
  exit 1
fi

if [ "$check_mode" = 1 ]; then
  if [ "$npos" -ne 0 ]; then
    printf 'agy-review-launch: --check-settings takes no positional arguments\n' >&2
    usage
    exit 2
  fi
  exec "$adapter" --mode review --model "$default_model" \
    --check-settings "$check_settings" "$check_run" --
fi

if [ "$npos" -lt 3 ] || [ "$npos" -gt 4 ]; then
  usage
  exit 2
fi

# The former launcher validated the run name before the model, so an argv
# invalid in both reports the run name. Keep that order here.
case "$pos1" in
  '' | . | ..)
    printf 'agy-review-launch: invalid run name: %s\n' "$pos1" >&2
    usage
    exit 2
    ;;
  -* | *[!A-Za-z0-9._-]*)
    printf 'agy-review-launch: invalid run name %s (use [A-Za-z0-9._-]+, not starting with -)\n' \
      "$pos1" >&2
    exit 2
    ;;
esac

# Model: 4th argv > AGY_REVIEW_MODEL > gemini-4-argon-medium.
if [ -n "$pos4" ]; then
  model="$pos4"
elif [ -n "${AGY_REVIEW_MODEL:-}" ]; then
  model="$AGY_REVIEW_MODEL"
else
  model="$default_model"
fi
case "$model" in
  '' | -*)
    printf 'agy-review-launch: invalid model id: %s\n' "$model" >&2
    exit 2
    ;;
esac

adapter_flags=""
if [ "$dry_run" = 1 ]; then
  adapter_flags="--dry-run"
fi

if [ -n "$adapter_flags" ]; then
  exec "$adapter" --mode review --model "$model" "$adapter_flags" \
    -- "$pos1" "$pos2" "$pos3" "$pos4"
fi
exec "$adapter" --mode review --model "$model" \
  -- "$pos1" "$pos2" "$pos3" "$pos4"
