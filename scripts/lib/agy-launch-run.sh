#!/usr/bin/env bash
# Shared headless agy launch helper sourced by scripts/agy-review-launch.sh
# and scripts/agy-docs-launch.sh. Also runnable as the child wrapper when
# AGY_LAUNCH_CHILD_MODE=1 (see agy_launch_child_main).
#
# Retry policy (one automatic relaunch for the whole run, any cause):
#   - empty stdout (0 bytes or missing; whitespace-only is non-empty)
#   - stderr contains the official headless auto-deny notice
#     ("headless mode cannot prompt for")
#   - conservative fallback: no growth on stdout and stderr for
#     AGY_LAUNCH_STALL_SECONDS (default 900) while the child PID is
#     alive. Liveness is kill -0 only; never ps, ps -o args, pgrep, or
#     equivalent. Set the variable to 0 to disable the fallback.
# An auto-deny or stall retry appends a simpler-commands instruction to a
# new brief file. The original brief is never mutated. Settings, allow
# lists, and global agy configuration are never edited. Permissions are
# never widened, and --dangerously-skip-permissions is never passed.
#
# Safe to source: source-time work is only recording this file's path.
# shellcheck shell=bash

agy_launch_auto_deny_needle='headless mode cannot prompt for'
agy_launch_simpler_commands='use simple commands one at a time; no pipes, no redirects, no regex special characters.'

if [ -z "${agy_launch_self:-}" ]; then
  agy_launch_self="${BASH_SOURCE[0]}"
fi

# Caller-assigned before agy_launch_run. Initialized empty so lint of
# this file alone does not report unassigned references.
agy_launch_tag="${agy_launch_tag:-}"
agy_launch_cwd="${agy_launch_cwd:-}"
agy_launch_stdout_log="${agy_launch_stdout_log:-}"
agy_launch_stderr_log="${agy_launch_stderr_log:-}"
agy_launch_pid_file="${agy_launch_pid_file:-}"
agy_launch_brief="${agy_launch_brief:-}"
agy_launch_retry_brief="${agy_launch_retry_brief:-}"
agy_launch_attempt1_out="${agy_launch_attempt1_out:-}"
agy_launch_attempt1_err="${agy_launch_attempt1_err:-}"
agy_launch_brief_used="${agy_launch_brief_used:-}"
agy_launch_caffeinate="${agy_launch_caffeinate:-0}"
agy_launch_args=()

agy_launch_use_caffeinate() {
  if [ "$(uname -s)" = Darwin ] && command -v caffeinate >/dev/null 2>&1; then
    printf '1\n'
  else
    printf '0\n'
  fi
}

# Print the operator-facing wrapper prefix, including a trailing space
# when the wrapper is active. Empty when caffeinate is not used.
agy_launch_wrapper_prefix() {
  if [ "${agy_launch_caffeinate:-0}" = 1 ]; then
    printf '%q ' caffeinate -i
  fi
}

agy_launch_file_bytes() {
  local path="$1"
  local n
  if [ ! -f "$path" ]; then
    printf '0\n'
    return 0
  fi
  n="$(wc -c <"$path" | tr -d '[:space:]')"
  case "$n" in
    '' | *[!0-9]*) n=0 ;;
  esac
  printf '%s\n' "$n"
}

agy_launch_combined_bytes() {
  printf '%s\n' "$(($(agy_launch_file_bytes "$agy_launch_stdout_log") + $(agy_launch_file_bytes "$agy_launch_stderr_log")))"
}

agy_launch_stall_seconds() {
  local n="${AGY_LAUNCH_STALL_SECONDS:-900}"
  case "$n" in
    '' | *[!0-9]*) n=900 ;;
  esac
  printf '%s\n' "$n"
}

agy_launch_has_auto_deny() {
  local path="$agy_launch_stderr_log"
  if [ ! -f "$path" ]; then
    return 1
  fi
  grep -q -F -- "$agy_launch_auto_deny_needle" "$path"
}

agy_launch_stdout_empty() {
  [ ! -s "$agy_launch_stdout_log" ]
}

# Write $agy_launch_retry_brief as a copy of the original brief plus the
# simpler-commands instruction. The original file is not modified.
agy_launch_write_retry_brief() {
  local dest="$agy_launch_retry_brief"
  local src="$agy_launch_brief"

  if [ -z "$dest" ] || [ -z "$src" ]; then
    printf '%s: missing brief path for approval-wait retry\n' "$agy_launch_tag" >&2
    return 1
  fi
  if [ "$dest" = "$src" ]; then
    printf '%s: refusing to append a retry instruction onto the original brief\n' \
      "$agy_launch_tag" >&2
    return 1
  fi
  if [ -L "$dest" ]; then
    printf '%s: refusing symlinked retry brief: %s\n' "$agy_launch_tag" "$dest" >&2
    return 1
  fi
  if [ -L "$src" ]; then
    printf '%s: refusing symlinked brief: %s\n' "$agy_launch_tag" "$src" >&2
    return 1
  fi
  cat -- "$src" >"$dest" || return 1
  printf '\n%s\n' "$agy_launch_simpler_commands" >>"$dest"
}

agy_launch_rotate_attempt1() {
  local attempt1_out="$agy_launch_attempt1_out"
  local attempt1_err="$agy_launch_attempt1_err"

  if [ -L "$attempt1_out" ]; then
    printf '%s: refusing symlinked write target: %s\n' "$agy_launch_tag" "$attempt1_out" >&2
    return 1
  fi
  if [ -L "$attempt1_err" ]; then
    printf '%s: refusing symlinked write target: %s\n' "$agy_launch_tag" "$attempt1_err" >&2
    return 1
  fi
  if [ -e "$agy_launch_stdout_log" ]; then
    mv -f -- "$agy_launch_stdout_log" "$attempt1_out" || return 1
  fi
  if [ -e "$agy_launch_stderr_log" ]; then
    mv -f -- "$agy_launch_stderr_log" "$attempt1_err" || return 1
  fi
  return 0
}

# Child wrapper. Holds an optional `caffeinate -i` idle-sleep assertion
# (no utility operand) for the lifetime of `agy`, and waits on `agy` so a
# stall SIGTERM can reach the CLI without reading process arguments.
# stdin/stdout/stderr are already redirected by the parent.
agy_launch_child_main() {
  set -u
  local cafe_pid=""
  local child=""
  local status=0

  # invoked from trap (TERM/INT/HUP and EXIT)
  # shellcheck disable=SC2317,SC2329
  cleanup() {
    if [ -n "${child:-}" ]; then
      kill "$child" 2>/dev/null || true
      wait "$child" 2>/dev/null || true
    fi
    if [ -n "${cafe_pid:-}" ]; then
      kill "$cafe_pid" 2>/dev/null || true
      wait "$cafe_pid" 2>/dev/null || true
    fi
  }

  trap cleanup EXIT
  trap 'cleanup; exit 143' TERM INT HUP

  if [ "${AGY_LAUNCH_USE_CAFFEINE:-0}" = 1 ]; then
    # Hold the assertion for this wrapper's lifetime (Apple caffeinate(8)
    # -w). Starting it before agy, and waiting until the process exists,
    # avoids a race where an instant agy exit SIGTERMs a still-starting
    # caffeinate. Monitor the waited PID with kill -0 only.
    printf 'agy-launch-run: holding idle-sleep assertion with caffeinate -i\n' >&2
    caffeinate -i -w $$ </dev/null >/dev/null 2>&1 &
    cafe_pid=$!
    waited=0
    while ! kill -0 "$cafe_pid" 2>/dev/null; do
      sleep 0.1
      waited=$((waited + 1))
      if [ "$waited" -ge 50 ]; then
        break
      fi
    done
    # Fraction is accepted by macOS and GNU sleep; gives a bash test stub
    # time to record argv before agy (which may exit immediately) returns.
    sleep 0.1
  fi

  agy "$@" &
  child=$!
  wait "$child"
  status=$?

  trap - EXIT TERM INT HUP
  if [ -n "$cafe_pid" ]; then
    kill "$cafe_pid" 2>/dev/null || true
    wait "$cafe_pid" 2>/dev/null || true
  fi
  exit "$status"
}

# Wait for $1. Return 0 when the child exits on its own (any status),
# 2 when the stall fallback fired and the child was signaled.
agy_launch_wait_pid() {
  local pid="$1"
  local stall_limit last_bytes last_change now bytes

  stall_limit="$(agy_launch_stall_seconds)"
  if [ "$stall_limit" = 0 ]; then
    wait "$pid" || true
    return 0
  fi

  last_bytes="$(agy_launch_combined_bytes)"
  last_change="$(date +%s)"

  while kill -0 "$pid" 2>/dev/null; do
    sleep 1
    if ! kill -0 "$pid" 2>/dev/null; then
      break
    fi
    bytes="$(agy_launch_combined_bytes)"
    now="$(date +%s)"
    if [ "$bytes" != "$last_bytes" ]; then
      last_bytes="$bytes"
      last_change="$now"
    elif [ $((now - last_change)) -ge "$stall_limit" ]; then
      printf '%s: no log growth for %s seconds while PID %s is alive; stopping the child\n' \
        "$agy_launch_tag" "$stall_limit" "$pid" >&2
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 2
    fi
  done
  wait "$pid" || true
  return 0
}

# Start one agy child (via this file in child mode), record its PID, and
# wait. $1 = "print" prints caller metadata after the PID file is written.
# Sets agy_launch_wait_status to 0 (exited) or 2 (stall).
agy_launch_start_and_wait() {
  local saved="$PWD"
  local child_pid
  local use_cafe="${agy_launch_caffeinate:-0}"

  if [ -L "$agy_launch_stdout_log" ]; then
    printf '%s: refusing symlinked write target: %s\n' "$agy_launch_tag" "$agy_launch_stdout_log" >&2
    return 1
  fi
  if [ -L "$agy_launch_stderr_log" ]; then
    printf '%s: refusing symlinked write target: %s\n' "$agy_launch_tag" "$agy_launch_stderr_log" >&2
    return 1
  fi
  if [ -L "$agy_launch_pid_file" ]; then
    printf '%s: refusing symlinked write target: %s\n' "$agy_launch_tag" "$agy_launch_pid_file" >&2
    return 1
  fi

  if ! agy_launch_prepare_args; then
    return 1
  fi

  if [ -n "${agy_launch_cwd:-}" ]; then
    cd -- "$agy_launch_cwd" || return 1
  fi

  AGY_LAUNCH_CHILD_MODE=1 AGY_LAUNCH_USE_CAFFEINE="$use_cafe" \
    bash "$agy_launch_self" "${agy_launch_args[@]}" \
    >"$agy_launch_stdout_log" 2>"$agy_launch_stderr_log" </dev/null &
  child_pid=$!
  printf '%s\n' "$child_pid" >"$agy_launch_pid_file"

  if [ -n "${agy_launch_cwd:-}" ]; then
    cd -- "$saved" || return 1
  fi

  if [ "${1:-}" = print ]; then
    if command -v agy_launch_print_metadata >/dev/null 2>&1; then
      agy_launch_print_metadata
    fi
  fi

  agy_launch_wait_status=0
  agy_launch_wait_pid "$child_pid" || agy_launch_wait_status=$?
  if [ "$agy_launch_wait_status" != 0 ] && [ "$agy_launch_wait_status" != 2 ]; then
    agy_launch_wait_status=0
  fi
  return 0
}

agy_launch_fail_closed() {
  printf '%s: the automatic retry also failed (empty output, a headless auto-deny, or a stall).\n' \
    "$agy_launch_tag" >&2
  printf '%s: stdout: %s\n' "$agy_launch_tag" "$agy_launch_stdout_log" >&2
  printf '%s: stderr: %s\n' "$agy_launch_tag" "$agy_launch_stderr_log" >&2
  printf '%s: ask the operator to inspect those logs and decide the next step. Do not add allow-rules or pass --dangerously-skip-permissions.\n' \
    "$agy_launch_tag" >&2
}

# Inspect the just-finished attempt. Sets agy_launch_need_retry (0/1) and
# agy_launch_approval_retry (0/1). Prints a one-line reason when retrying.
agy_launch_classify_attempt() {
  agy_launch_need_retry=0
  agy_launch_approval_retry=0

  if [ "${agy_launch_wait_status:-0}" = 2 ]; then
    agy_launch_need_retry=1
    agy_launch_approval_retry=1
    printf '%s: run stalled waiting (no log growth); retrying once with a simpler-commands instruction\n' \
      "$agy_launch_tag" >&2
    return 0
  fi
  if agy_launch_has_auto_deny; then
    agy_launch_need_retry=1
    agy_launch_approval_retry=1
    printf '%s: headless auto-deny in stderr (%s); retrying once with a simpler-commands instruction\n' \
      "$agy_launch_tag" "$agy_launch_stderr_log" >&2
    return 0
  fi
  if agy_launch_stdout_empty; then
    agy_launch_need_retry=1
    printf '%s: empty stdout log (%s); retrying once\n' \
      "$agy_launch_tag" "$agy_launch_stdout_log" >&2
    return 0
  fi
  return 0
}

# Run at most two attempts under the shared retry budget and return 0 or 1.
# Callers must set agy_launch_tag, log/pid/brief paths, and define
# agy_launch_prepare_args (fills agy_launch_args from agy_launch_brief_used).
agy_launch_run() {
  agy_launch_caffeinate="$(agy_launch_use_caffeinate)"
  agy_launch_brief_used="$agy_launch_brief"
  agy_launch_wait_status=0

  if [ -z "${agy_launch_attempt1_out:-}" ]; then
    agy_launch_attempt1_out="${agy_launch_stdout_log}.attempt1"
  fi
  if [ -z "${agy_launch_attempt1_err:-}" ]; then
    agy_launch_attempt1_err="${agy_launch_stderr_log}.attempt1"
  fi

  if ! agy_launch_start_and_wait print; then
    printf '%s: failed to start agy\n' "$agy_launch_tag" >&2
    return 1
  fi

  agy_launch_classify_attempt
  if [ "$agy_launch_need_retry" != 1 ]; then
    return 0
  fi

  if ! agy_launch_rotate_attempt1; then
    return 1
  fi

  if [ "$agy_launch_approval_retry" = 1 ]; then
    if ! agy_launch_write_retry_brief; then
      return 1
    fi
    # Used by the caller-defined agy_launch_prepare_args.
    # shellcheck disable=SC2034
    agy_launch_brief_used="$agy_launch_retry_brief"
  fi

  if ! agy_launch_start_and_wait; then
    printf '%s: failed to start agy on retry\n' "$agy_launch_tag" >&2
    return 1
  fi

  agy_launch_need_retry=0
  agy_launch_approval_retry=0
  if [ "${agy_launch_wait_status:-0}" = 2 ] || agy_launch_has_auto_deny || agy_launch_stdout_empty; then
    agy_launch_fail_closed
    return 1
  fi
  return 0
}

if [ "${AGY_LAUNCH_CHILD_MODE:-}" = 1 ]; then
  agy_launch_child_main "$@"
fi
