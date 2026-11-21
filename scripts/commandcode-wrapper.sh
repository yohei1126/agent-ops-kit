#!/usr/bin/env bash
# commandcode-wrapper.sh: Mac launcher for the Command Code (Pro plan)
# adapter under scripts/agents/goat/. It verifies the stored login with one
# status call, then execs the adapter with --auth login, so no API key is
# needed, passed, or printed. The wrapper never starts a model run: every
# start of the agent binary goes through cc_run, which always leads with
# --no-auto-update, and the model run belongs to the adapter.
#
# The script is symlinked into the workstation bin folder, so the real
# script path is resolved through symlinks and the repository root is the
# parent of the script directory.
#
# Interface:
#   commandcode-wrapper.sh --check
#   commandcode-wrapper.sh --mode patch|review|write --model <id> [--] <args>
#   commandcode-wrapper.sh --help
#
# Everything after -- (or the first plain positional) is passed to the
# adapter unchanged. An unknown flag, a missing --mode or --model, a model
# id outside the pinned list, or a non-digit timeout prints a one-line
# reason and exits 2 before anything starts.
#
# The login status output goes to a private temp file that an EXIT trap
# removes; its content is never printed, and nothing from the environment
# is printed.
{ set +x; } 2>/dev/null
unset BASH_XTRACEFD
export -n SHELLOPS 2>/dev/null || true
set -euo pipefail
umask 077

# Resolve the real script path through symlinks; the repository root is
# the parent of the script directory.
script_path="$0"
link_hops=0
while [ -L "$script_path" ]; do
  link_hops=$((link_hops + 1))
  if [ "$link_hops" -gt 40 ]; then
    printf 'commandcode-wrapper: too many symlink levels resolving %s\n' "$0" >&2
    exit 2
  fi
  link_target="$(readlink "$script_path")"
  case "$link_target" in
    /*) script_path="$link_target" ;;
    *) script_path="$(dirname "$script_path")/$link_target" ;;
  esac
done
script_dir="$(cd "$(dirname "$script_path")" && pwd -P)"
repo_root="$(cd "$script_dir/.." && pwd -P)"

usage() {
  cat <<'EOF'
Usage:
  scripts/commandcode-wrapper.sh --check
  scripts/commandcode-wrapper.sh --mode patch|review|write --model <id> [--] <args>
  scripts/commandcode-wrapper.sh --help

Modes:
  --check
      Verify the Command Code (Pro plan) login with one status call and
      print "commandcode login: authenticated". No model run starts.
  --mode <patch|review|write>
      Verify the login, then start the adapter with --auth login. The
      adapter positionals are passed through unchanged:
        patch    <worktree> <brief-file> [check-id ...]
        review   <worktree> <brief-file> <result-file>
        write    <worktree> <brief-file> <scope> [<scope> ...]
      Everything after -- is positional: a value that looks like a flag
      after -- stays a value.
  -h | --help
      Print this help and exit.

Models:
  --model <id> is required and must be one of the pinned ids, exact and
  case sensitive:
    moonshotai/kimi-k3.1-pro
    deepseek/deepseek-v4-pro
    deepseek/deepseek-v4.1-flash
    google/gemini-4-argon
  Any other id, or any flag not listed here, exits 2 and starts nothing.

Environment:
  GOAT_CMD
      Agent binary name or path (default: cmd). Passed through to the
      adapter unchanged.
  COMMANDCODE_STATUS_TIMEOUT
      Login status timeout in seconds, digits only (default: 30). A
      non-digit value exits 2.
  COMMAND_CODE_API_KEY
      Never required, never passed to a child process, never printed.

Exit codes:
  0    ok
  2    usage or validation (nothing is started)
  4    the login is not verified
  5    the login status check failed or timed out
  127  the agent binary or jq is missing

The login status output goes to a private temp file, is checked for the
authenticated flag only, and is never printed. No user name, email, or
token from the environment or the status output is ever printed.
EOF
}

die_usage() {
  printf 'commandcode-wrapper: %s\n' "$1" >&2
  printf 'Try --help.\n' >&2
  exit 2
}

check=0
mode=""
model=""
positionals=()
positional_count=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --check)
      check=1
      shift
      ;;
    --mode)
      [ "$#" -ge 2 ] || die_usage "missing value for --mode"
      mode="$2"
      shift 2
      ;;
    --model)
      [ "$#" -ge 2 ] || die_usage "missing value for --model"
      model="$2"
      shift 2
      ;;
    --)
      shift
      while [ "$#" -gt 0 ]; do
        positionals[positional_count]="$1"
        positional_count=$((positional_count + 1))
        shift
      done
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    -?*)
      die_usage "unknown flag: $1"
      ;;
    *)
      positionals[positional_count]="$1"
      positional_count=$((positional_count + 1))
      shift
      ;;
  esac
done

if [ "$check" = 1 ]; then
  if [ -n "$mode" ] || [ -n "$model" ] || [ "$positional_count" -gt 0 ]; then
    die_usage "--check takes no other arguments"
  fi
else
  case "$mode" in
    patch | review | write) ;;
    '') die_usage "missing --mode (or use --check)" ;;
    *) die_usage "unknown mode: $mode" ;;
  esac
  [ -n "$model" ] || die_usage "missing --model"
  case "$model" in
    moonshotai/kimi-k3.1-pro | deepseek/deepseek-v4-pro | deepseek/deepseek-v4.1-flash | google/gemini-4-argon) ;;
    *) die_usage "model id is not pinned: $model" ;;
  esac
fi

status_timeout="${COMMANDCODE_STATUS_TIMEOUT:-30}"
case "$status_timeout" in
  '' | *[!0-9]*) die_usage "COMMANDCODE_STATUS_TIMEOUT must be digits only" ;;
esac

goat_cmd="${GOAT_CMD:-cmd}"
if ! goat_bin="$(command -v "$goat_cmd" 2>/dev/null)"; then
  printf 'commandcode-wrapper: agent binary not found: %s\n' "$goat_cmd" >&2
  exit 127
fi
if ! command -v jq >/dev/null 2>&1; then
  printf 'commandcode-wrapper: jq is required\n' >&2
  exit 127
fi

timeout_cmd=""
if command -v timeout >/dev/null 2>&1; then
  timeout_cmd="$(command -v timeout)"
elif command -v gtimeout >/dev/null 2>&1; then
  timeout_cmd="$(command -v gtimeout)"
fi

status_out=""
# shellcheck disable=SC2317,SC2329 # invoked by the EXIT trap
cleanup() {
  if [ -n "$status_out" ]; then
    rm -f -- "$status_out"
  fi
}
trap cleanup EXIT
status_out="$(mktemp "${TMPDIR:-/tmp}/commandcode-status.XXXXXX")"

# cc_run is the only place this wrapper starts the agent binary, and
# --no-auto-update is always the first argument after the binary. The
# output goes to the status temp file and is never printed. The API key
# never reaches the child. The fallback polls and kills the child itself
# because not every workstation has timeout or gtimeout.
cc_run() {
  local cc_status=0
  local cc_pid=0
  local cc_waited=0
  if [ -n "$timeout_cmd" ]; then
    "$timeout_cmd" "$status_timeout" env -u COMMAND_CODE_API_KEY \
      "$goat_bin" --no-auto-update "$@" >"$status_out" 2>&1 || cc_status=$?
  else
    env -u COMMAND_CODE_API_KEY "$goat_bin" --no-auto-update "$@" \
      >"$status_out" 2>&1 &
    cc_pid=$!
    while :; do
      if ! kill -0 "$cc_pid" 2>/dev/null; then
        wait "$cc_pid" || cc_status=$?
        break
      fi
      if [ "$cc_waited" -ge "$status_timeout" ]; then
        kill "$cc_pid" 2>/dev/null || true
        wait "$cc_pid" 2>/dev/null || cc_status=$?
        break
      fi
      sleep 1
      cc_waited=$((cc_waited + 1))
    done
  fi
  return "$cc_status"
}

# login_check refuses unless the status output says authenticated is true.
# A failed, hung, or unparsable status call refuses too.
login_check() {
  if ! cc_run status --json; then
    printf 'commandcode-wrapper: the login status check failed or timed out\n' >&2
    exit 5
  fi
  if ! jq -e '.authenticated == true' "$status_out" >/dev/null 2>&1; then
    printf 'commandcode-wrapper: the Command Code (Pro plan) login is not verified; log in on this machine and re-run\n' >&2
    exit 4
  fi
}

if [ "$check" = 1 ]; then
  login_check
  printf 'commandcode login: authenticated\n'
  exit 0
fi

adapter="$repo_root/scripts/agents/goat/run"
if [ ! -f "$adapter" ]; then
  printf 'commandcode-wrapper: adapter not found: %s\n' "$adapter" >&2
  exit 127
fi

login_check
rm -f -- "$status_out"
status_out=""
if [ "$positional_count" -gt 0 ]; then
  set -- "${positionals[@]}"
else
  set --
fi
exec env -u COMMAND_CODE_API_KEY "$adapter" --auth login \
  --mode "$mode" --model "$model" -- "$@"
