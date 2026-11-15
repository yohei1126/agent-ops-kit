#!/usr/bin/env bash
# Launch a headless Antigravity CLI (agy -p) documentation worker in the
# background under the fixed $HOME/agy-work/<repo> checkout root.
#
# Usage:
#   scripts/agy-docs-launch.sh <repo> <brief-path> [log-stem] [model]
# Model default: gemini-3.8-flash-medium (override via 4th arg, else AGY_DOCS_MODEL, else AGY_MODEL).
#
# Safety properties:
# - Requires <repo> to be a single directory basename (no slashes or '..').
# - Requires $HOME/agy-work/<repo> to exist already and resolve inside the
#   realpath of $HOME/agy-work.
# - Requires <brief-path> to exist and resolve inside the realpath of
#   $HOME/agy-inbox/.
# - Writes logs and a PID file under $HOME/agy-inbox/.
# - Generates $HOME/agy-inbox/<stem>.settings.json on every launch from
#   scripts/templates/agy-docs-settings.json, replacing @RUN_DIR@ with the
#   resolved checkout path, and passes it as agy --settings (session-only). It
#   never reads settings from another run and never writes into the checkout.
# - Runs the shared check in scripts/lib/agy-settings-check.sh before launch
#   and exits 1 when an allow entry is empty, malformed, a wildcard, or
#   resolves outside the checkout (including .. and symlink escapes).
# - Refuses a symlinked checkout, settings file, settings temp file, PID file,
#   or log file.
# - Never passes --dangerously-skip-permissions, never reads or writes global
#   Antigravity settings, and never widens an allow list.
# - Shared launch/retry logic lives in scripts/lib/agy-launch-run.sh (also
#   sourced by scripts/agy-review-launch.sh).
# - On Darwin, when caffeinate is on PATH, holds an idle-sleep assertion
#   with `caffeinate -i` for the lifetime of agy. On Linux, or when
#   caffeinate is missing, starts agy unwrapped. Missing caffeinate is not
#   an error.
# - Waits for the run to finish. Retries exactly once, in total, if stdout
#   is empty (0 bytes or missing), if stderr contains the official headless
#   auto-deny notice, or if both logs stop growing for
#   AGY_LAUNCH_STALL_SECONDS (default 900) while the child PID is still
#   alive. A second failure of any of those kinds exits 1 (fail closed)
#   and asks the operator to inspect the logs. An auto-deny or stall retry
#   appends a simpler-commands instruction to a new brief file under the
#   inbox; the original brief is not mutated. Settings and allow lists are
#   never edited. Operators who need a detached session can run the
#   launcher itself under a terminal multiplexer or nohup.
#
# Exit codes: 0 ok, 1 check or launch failure, 2 usage.

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd -P)"
settings_lib="$script_dir/lib/agy-settings-check.sh"
launch_lib="$script_dir/lib/agy-launch-run.sh"
settings_template="$script_dir/templates/agy-docs-settings.json"

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

# Physical absolute path; every symlink component is resolved by the shared
# library, so the result does not depend on realpath being installed.
resolve_path() {
  agy_physical_path "$1"
}

validate_token() {
  local label="$1"
  local value="$2"
  if [[ -z "$value" || "$value" == "." || "$value" == ".." || "$value" == *"/"* || "$value" == *".."* || "$value" == -* || "$value" != "$(basename -- "$value")" ]]; then
    printf 'Error: invalid %s %q (must be a plain basename without slashes or "..").\n' "$label" "$value" >&2
    exit 2
  fi
}

if [[ $# -lt 2 || $# -gt 4 ]]; then
  usage
  exit 2
fi

repo="$1"
brief_input="$2"
stem_input="${3:-}"
model_input="${4:-}"

validate_token "repository name" "$repo"

if [[ ! -r "$settings_lib" ]]; then
  printf 'Error: missing library: %s\n' "$settings_lib" >&2
  exit 1
fi
if [[ ! -r "$launch_lib" ]]; then
  printf 'Error: missing library: %s\n' "$launch_lib" >&2
  exit 1
fi
# Library messages name this launcher.
# shellcheck disable=SC2034
agy_settings_tag="agy-docs-launch"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/agy-settings-check.sh
. "$settings_lib"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/agy-launch-run.sh
. "$launch_lib"

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: 'jq' is required to generate and check settings." >&2
  exit 1
fi

if ! command -v agy >/dev/null 2>&1; then
  echo "Error: 'agy' binary not found on PATH." >&2
  exit 1
fi

work_root="$HOME/agy-work"
inbox_root="$HOME/agy-inbox"
mkdir -p "$work_root" "$inbox_root"

work_root_real="$(resolve_path "$work_root")"
inbox_root_real="$(resolve_path "$inbox_root")"

checkout_dir="$work_root/$repo"
if [[ -L "$checkout_dir" ]]; then
  printf 'Error: refusing symlinked checkout %s; use the real directory under %s.\n' "$checkout_dir" "$work_root" >&2
  exit 1
fi
if [[ ! -d "$checkout_dir" ]]; then
  printf 'Error: checkout directory missing at %s. Clone the repository under %s first.\n' "$checkout_dir" "$checkout_dir" >&2
  exit 1
fi

checkout_real="$(resolve_path "$checkout_dir")"
case "$checkout_real" in
  "$work_root_real"/*) ;;
  *)
    printf 'Error: checkout path %s resolves outside %s.\n' "$checkout_real" "$work_root_real" >&2
    exit 1
    ;;
esac

if [[ ! -f "$brief_input" || ! -r "$brief_input" ]]; then
  printf 'Error: brief file missing or unreadable: %s\n' "$brief_input" >&2
  exit 1
fi

brief_real="$(resolve_path "$brief_input")"
case "$brief_real" in
  "$inbox_root_real"/*) ;;
  *)
    printf 'Error: brief path %s resolves outside %s/.\n' "$brief_real" "$inbox_root_real" >&2
    exit 1
    ;;
esac

if [[ -n "$stem_input" ]]; then
  stem="$stem_input"
else
  brief_base="$(basename -- "$brief_real")"
  stem="${brief_base%.*}"
  if [[ -z "$stem" ]]; then
    stem="$brief_base"
  fi
fi

validate_token "log stem" "$stem"

pid_file="$inbox_root/$stem.pid"
stdout_log="$inbox_root/$stem-stdout.log"
stderr_log="$inbox_root/$stem-stderr.log"

# A symlinked log or PID file could redirect a write outside the inbox.
for write_target in "$pid_file" "$stdout_log" "$stderr_log"; do
  if [[ -L "$write_target" ]]; then
    printf 'Error: refusing symlinked %s: %s\n' "${write_target##*/}" "$write_target" >&2
    exit 1
  fi
done

if [[ -f "$pid_file" ]]; then
  existing_pid="$(tr -d '[:space:]' <"$pid_file" || true)"
  if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
    printf 'Error: existing agy process (PID %s) from %s is still running.\n' "$existing_pid" "$pid_file" >&2
    exit 1
  fi
fi

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

# Per-run settings: the checkout is the only write root.
settings_file="$inbox_root_real/$stem.settings.json"
if ! agy_settings_generate "$settings_template" "$settings_file" "$checkout_real"; then
  exit 1
fi
if ! agy_settings_check "$settings_file" "$checkout_real"; then
  printf 'Error: settings check failed; not launching.\n' >&2
  exit 1
fi

# shellcheck disable=SC2034,SC2154 # assigned here, consumed by agy-launch-run.sh
agy_launch_tag="agy-docs-launch"
agy_launch_cwd=""
agy_launch_stdout_log="$stdout_log"
agy_launch_stderr_log="$stderr_log"
agy_launch_pid_file="$pid_file"
agy_launch_brief="$brief_real"
agy_launch_retry_brief="$inbox_root_real/$stem.retry-brief.txt"
agy_launch_attempt1_out="$stdout_log.attempt1"
agy_launch_attempt1_err="$stderr_log.attempt1"
agy_launch_caffeinate="$(agy_launch_use_caffeinate)"

agy_launch_prepare_args() {
  agy_launch_args=(
    --project "$HOME/agy-work/$repo"
    --model "$model"
    --settings "$settings_file"
    -p "$(cat "$agy_launch_brief_used")"
  )
}

agy_launch_print_metadata() {
  printf 'AGY_PID=%s\n' "$(tr -d '[:space:]' <"$pid_file")"
  printf 'PID_FILE=%s\n' "$pid_file"
  printf 'MODEL=%s\n' "$model"
  printf 'SETTINGS=%s\n' "$settings_file"
  printf 'STDOUT_LOG=%s\n' "$stdout_log"
  printf 'STDERR_LOG=%s\n' "$stderr_log"
}

if ! agy_launch_run; then
  exit 1
fi
