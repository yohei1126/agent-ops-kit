#!/usr/bin/env bash
# Launch a headless Antigravity CLI (agy) model-review session in a fresh run
# folder with a generated, per-run settings.json.
#
# Usage:
#   scripts/agy-review-launch.sh <run-name> <repo-checkout> <brief-path> [model]
#   scripts/agy-review-launch.sh --dry-run <run-name> <repo-checkout> <brief-path> [model]
#   scripts/agy-review-launch.sh --check-settings <settings.json> <run-dir>
# Model default: gemini-4-argon-medium (override via 4th arg, else AGY_REVIEW_MODEL).
#
# Safety properties:
# - Generates <run>/settings.json from scripts/templates/agy-review-settings.json
#   on every launch. It never reads or copies settings from another run folder.
# - The template's only variable is @RUN_DIR@, replaced with the resolved
#   physical run folder path.
# - Runs scripts/lib/agy-settings-check.sh before launch and exits 1 when any
#   path-bearing allow entry resolves outside the run folder.
# - Refuses a symlinked run folder, brief, or settings file, and refuses a run
#   name that is not a plain token.
# - Never passes --dangerously-skip-permissions and never writes outside the
#   run folder (except creating the runs root).
# - Never reads, writes, or migrates global Antigravity/agy settings; --settings
#   stays session-only.
#
# Exit codes: 0 ok, 1 check or launch failure, 2 usage.

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd -P)"
settings_lib="$script_dir/lib/agy-settings-check.sh"
settings_template="$script_dir/templates/agy-review-settings.json"
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
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/agy-settings-check.sh
. "$settings_lib"

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
  if agy_settings_check "$check_settings" "$check_run"; then
    printf 'agy-review-launch: settings OK: %s\n' "$check_settings"
    exit 0
  fi
  exit 1
fi

if [ "$npos" -lt 3 ] || [ "$npos" -gt 4 ]; then
  usage
  exit 2
fi

run_name="$pos1"
repo_input="$pos2"
brief_input="$pos3"
model_input="$pos4"

case "$run_name" in
  '' | . | ..)
    printf 'agy-review-launch: invalid run name: %s\n' "$run_name" >&2
    usage
    exit 2
    ;;
  -* | *[!A-Za-z0-9._-]*)
    printf 'agy-review-launch: invalid run name %s (use [A-Za-z0-9._-]+, not starting with -)\n' \
      "$run_name" >&2
    exit 2
    ;;
esac

# Model: 4th argv > AGY_REVIEW_MODEL > gemini-4-argon-medium.
if [ -n "$model_input" ]; then
  model="$model_input"
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

work_root="$HOME/agy-work"
runs_root="$work_root/runs"
mkdir -p -- "$runs_root"
work_root_real="$(agy_physical_path "$work_root")"
runs_root_real="$(agy_physical_path "$runs_root")"

# Repository checkout must be an existing directory inside $HOME/agy-work.
if [ ! -d "$repo_input" ]; then
  printf 'agy-review-launch: repo checkout is not a directory: %s\n' "$repo_input" >&2
  exit 1
fi
repo_real="$(agy_physical_path "$repo_input")"
if [ "$repo_real" = "$work_root_real" ] || ! agy_path_inside "$repo_real" "$work_root_real"; then
  printf 'agy-review-launch: repo checkout %s resolves to %s outside %s\n' \
    "$repo_input" "$repo_real" "$work_root_real" >&2
  exit 1
fi

# Brief must be a readable file; it is copied into the run folder below.
if [ ! -f "$brief_input" ] || [ ! -r "$brief_input" ]; then
  printf 'agy-review-launch: brief file missing or unreadable: %s\n' "$brief_input" >&2
  exit 1
fi
brief_real="$(agy_physical_path "$brief_input")"

run_dir="$runs_root/$run_name"

if [ -L "$run_dir" ]; then
  printf 'agy-review-launch: refusing run folder symlink: %s\n' "$run_dir" >&2
  exit 1
fi
if [ -e "$run_dir" ] && [ ! -d "$run_dir" ]; then
  printf 'agy-review-launch: run path exists and is not a directory: %s\n' "$run_dir" >&2
  exit 1
fi
mkdir -p -- "$run_dir"

run_real="$(agy_physical_path "$run_dir")"
if [ "$run_real" = "$runs_root_real" ] || ! agy_path_inside "$run_real" "$runs_root_real"; then
  printf 'agy-review-launch: run folder %s resolves to %s outside %s\n' \
    "$run_dir" "$run_real" "$runs_root_real" >&2
  exit 1
fi

settings_file="$run_real/settings.json"
if [ -L "$settings_file" ]; then
  printf 'agy-review-launch: refusing symlinked settings file: %s\n' "$settings_file" >&2
  exit 1
fi
if [ -L "$run_real/BRIEF.md" ]; then
  printf 'agy-review-launch: refusing symlinked brief: %s\n' "$run_real/BRIEF.md" >&2
  exit 1
fi

if [ "$brief_real" != "$run_real/BRIEF.md" ]; then
  cp -f -- "$brief_real" "$run_real/BRIEF.md"
fi

# Generate settings.json from the template, substituting the physical run path.
if [ ! -r "$settings_template" ]; then
  printf 'agy-review-launch: missing settings template: %s\n' "$settings_template" >&2
  exit 1
fi
escaped_run="$(printf '%s' "$run_real" | sed 's/[\\&|]/\\&/g')"
settings_tmp="$run_real/.agy-review-settings.$$"
if ! sed "s|@RUN_DIR@|$escaped_run|g" "$settings_template" >"$settings_tmp"; then
  rm -f -- "$settings_tmp"
  printf 'agy-review-launch: failed to generate %s\n' "$settings_file" >&2
  exit 1
fi
if ! jq -e . "$settings_tmp" >/dev/null 2>&1; then
  rm -f -- "$settings_tmp"
  printf 'agy-review-launch: generated settings is not valid JSON: %s\n' "$settings_file" >&2
  exit 1
fi
mv -f -- "$settings_tmp" "$settings_file"

if ! agy_settings_check "$settings_file" "$run_real"; then
  printf 'agy-review-launch: settings check failed; not launching\n' >&2
  exit 1
fi

# Model resolved above so usage errors leave the runs root untouched.
stdout_log="$run_real/agy.log"
stderr_log="$run_real/agy.stderr.log"
pid_file="$run_real/agy.pid"

if [ -f "$pid_file" ]; then
  existing_pid="$(tr -d '[:space:]' <"$pid_file" || true)"
  case "$existing_pid" in
    '' | *[!0-9]*) ;;
    *)
      if kill -0 "$existing_pid" 2>/dev/null; then
        printf 'agy-review-launch: existing agy process (PID %s) from %s is still running\n' \
          "$existing_pid" "$pid_file" >&2
        exit 1
      fi
      ;;
  esac
fi

print_command() {
  printf 'AGY_COMMAND='
  printf '%q ' agy \
    --project "$run_real" \
    --model "$model" \
    --settings "$settings_file" \
    --add-dir "$run_real" \
    --add-dir "$repo_real" \
    --mode accept-edits \
    --print "$(cat "$run_real/BRIEF.md")"
  printf '\n'
}

if [ "$dry_run" = 1 ]; then
  printf 'RUN_DIR=%s\n' "$run_real"
  printf 'SETTINGS=%s\n' "$settings_file"
  printf 'MODEL=%s\n' "$model"
  printf 'STDOUT_LOG=%s\n' "$stdout_log"
  printf 'STDERR_LOG=%s\n' "$stderr_log"
  printf 'PID_FILE=%s\n' "$pid_file"
  print_command
  exit 0
fi

if ! command -v agy >/dev/null 2>&1; then
  printf "agy-review-launch: 'agy' binary not found on PATH\n" >&2
  exit 1
fi

(
  cd -- "$run_real" || exit 1
  nohup agy --project "$run_real" --model "$model" --settings "$settings_file" \
    --add-dir "$run_real" --add-dir "$repo_real" --mode accept-edits \
    --print "$(cat "$run_real/BRIEF.md")" >"$stdout_log" 2>"$stderr_log" </dev/null &
  printf '%s\n' "$!" >"$pid_file"
) || {
  printf 'agy-review-launch: failed to start agy in %s\n' "$run_real" >&2
  exit 1
}

agy_pid="$(tr -d '[:space:]' <"$pid_file")"

printf 'AGY_PID=%s\n' "$agy_pid"
printf 'RUN_DIR=%s\n' "$run_real"
printf 'SETTINGS=%s\n' "$settings_file"
printf 'MODEL=%s\n' "$model"
printf 'STDOUT_LOG=%s\n' "$stdout_log"
printf 'STDERR_LOG=%s\n' "$stderr_log"
printf 'PID_FILE=%s\n' "$pid_file"
