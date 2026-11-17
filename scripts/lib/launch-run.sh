#!/usr/bin/env bash
# Generic headless launch helper sourced by agent adapters. Also runnable as
# the child wrapper for an adapter (see launch_run_child_main).
#
# The adapter supplies the binary name, the auto-deny needle, a message tag for
# this helper, and an environment-variable prefix. The prefix names the
# child-mode, caffeinate, and stall-seconds variables, for example
# <PREFIX>_CHILD_MODE, <PREFIX>_USE_CAFFEINE, and <PREFIX>_STALL_SECONDS.
#
# Retry policy (one automatic relaunch for the whole run, any cause):
#   - empty stdout (0 bytes or missing; whitespace-only is non-empty)
#   - stderr contains the adapter's headless auto-deny notice
#   - conservative fallback: no growth on stdout and stderr for
#     <PREFIX>_STALL_SECONDS (default 900) while the child PID is alive.
#     Liveness is kill -0 only; never ps, ps -o args, pgrep, or equivalent.
#     Set the variable to 0 to disable the fallback.
# An auto-deny or stall retry appends a simpler-commands instruction to a new
# brief file. The original brief is never mutated. Settings, allow lists, and
# global agent configuration are never edited. Permissions are never widened,
# and --dangerously-skip-permissions is never passed.
#
# The adapter must set launch_run_binary, launch_run_auto_deny_needle,
# launch_run_child_tag, and launch_run_env_prefix before calling launch_run_run.
# It must also set the log, PID, and brief paths, and define
# launch_run_prepare_args (fills launch_run_args from launch_run_brief_used).
#
# Safe to source: source-time work is only recording this file's path.
# shellcheck shell=bash

if [ -z "${launch_run_self:-}" ]; then
  launch_run_self="${BASH_SOURCE[0]}"
fi

launch_run_simpler_commands='use simple commands one at a time; no pipes, no redirects, no regex special characters.'

# Adapter-assigned before launch_run_run. Initialized empty so lint of this
# file alone does not report unassigned references.
launch_run_tag="${launch_run_tag:-}"
launch_run_cwd="${launch_run_cwd:-}"
launch_run_stdout_log="${launch_run_stdout_log:-}"
launch_run_stderr_log="${launch_run_stderr_log:-}"
launch_run_pid_file="${launch_run_pid_file:-}"
launch_run_brief="${launch_run_brief:-}"
launch_run_retry_brief="${launch_run_retry_brief:-}"
launch_run_attempt1_out="${launch_run_attempt1_out:-}"
launch_run_attempt1_err="${launch_run_attempt1_err:-}"
launch_run_brief_used="${launch_run_brief_used:-}"
launch_run_caffeinate="${launch_run_caffeinate:-0}"
launch_run_binary="${launch_run_binary:-}"
launch_run_auto_deny_needle="${launch_run_auto_deny_needle:-}"
launch_run_child_tag="${launch_run_child_tag:-launch-run}"
launch_run_env_prefix="${launch_run_env_prefix:-LAUNCH_RUN}"
launch_run_args=()

# launch_run_env_value <name> <default>
# Reads a variable by name without namerefs (macOS bash 3.2).
launch_run_env_value() {
  local name="$1"
  local default="$2"
  case "$name" in
    '' | *[!A-Za-z0-9_]*)
      printf '%s\n' "$default"
      return 0
      ;;
  esac
  eval "printf '%s\n' \"\${$name-$default}\""
}

launch_run_use_caffeinate() {
  if [ "$(uname -s)" = Darwin ] && command -v caffeinate >/dev/null 2>&1; then
    printf '1\n'
  else
    printf '0\n'
  fi
}

# Print the operator-facing wrapper prefix, including a trailing space
# when the wrapper is active. Empty when caffeinate is not used.
launch_run_wrapper_prefix() {
  if [ "${launch_run_caffeinate:-0}" = 1 ]; then
    printf '%q ' caffeinate -i
  fi
}

launch_run_file_bytes() {
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

launch_run_combined_bytes() {
  printf '%s\n' "$(($(launch_run_file_bytes "$launch_run_stdout_log") + $(launch_run_file_bytes "$launch_run_stderr_log")))"
}

launch_run_stall_seconds() {
  local n
  n="$(launch_run_env_value "${launch_run_env_prefix}_STALL_SECONDS" 900)"
  case "$n" in
    '' | *[!0-9]*) n=900 ;;
  esac
  printf '%s\n' "$n"
}

launch_run_has_auto_deny() {
  local path="$launch_run_stderr_log"
  if [ -z "$launch_run_auto_deny_needle" ] || [ ! -f "$path" ]; then
    return 1
  fi
  grep -q -F -- "$launch_run_auto_deny_needle" "$path"
}

launch_run_stdout_empty() {
  [ ! -s "$launch_run_stdout_log" ]
}

# Write $launch_run_retry_brief as a copy of the original brief plus the
# simpler-commands instruction. The original file is not modified.
launch_run_write_retry_brief() {
  local dest="$launch_run_retry_brief"
  local src="$launch_run_brief"

  if [ -z "$dest" ] || [ -z "$src" ]; then
    printf '%s: missing brief path for approval-wait retry\n' "$launch_run_tag" >&2
    return 1
  fi
  if [ "$dest" = "$src" ]; then
    printf '%s: refusing to append a retry instruction onto the original brief\n' \
      "$launch_run_tag" >&2
    return 1
  fi
  if [ -L "$dest" ]; then
    printf '%s: refusing symlinked retry brief: %s\n' "$launch_run_tag" "$dest" >&2
    return 1
  fi
  if [ -L "$src" ]; then
    printf '%s: refusing symlinked brief: %s\n' "$launch_run_tag" "$src" >&2
    return 1
  fi
  cat -- "$src" >"$dest" || return 1
  printf '\n%s\n' "$launch_run_simpler_commands" >>"$dest"
}

launch_run_rotate_attempt1() {
  local attempt1_out="$launch_run_attempt1_out"
  local attempt1_err="$launch_run_attempt1_err"

  if [ -L "$attempt1_out" ]; then
    printf '%s: refusing symlinked write target: %s\n' "$launch_run_tag" "$attempt1_out" >&2
    return 1
  fi
  if [ -L "$attempt1_err" ]; then
    printf '%s: refusing symlinked write target: %s\n' "$launch_run_tag" "$attempt1_err" >&2
    return 1
  fi
  if [ -e "$launch_run_stdout_log" ]; then
    mv -f -- "$launch_run_stdout_log" "$attempt1_out" || return 1
  fi
  if [ -e "$launch_run_stderr_log" ]; then
    mv -f -- "$launch_run_stderr_log" "$attempt1_err" || return 1
  fi
  return 0
}

# Child wrapper. Holds an optional `caffeinate -i` idle-sleep assertion
# (no utility operand) for the lifetime of the adapter's binary, and waits on
# it so a stall SIGTERM can reach the CLI without reading process arguments.
# stdin/stdout/stderr are already redirected by the parent.
# launch_run_child_main <env-prefix> <child-tag> <binary> [args...]
launch_run_child_main() {
  set -u
  local env_prefix="$1"
  local child_tag="$2"
  local binary="$3"
  shift 3
  local cafe_pid=""
  local child=""
  local status=0
  local use_cafe

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

  use_cafe="$(launch_run_env_value "${env_prefix}_USE_CAFFEINE" 0)"
  if [ "$use_cafe" = 1 ]; then
    # Hold the assertion for this wrapper's lifetime (Apple caffeinate(8)
    # -w). Starting it before the child, and waiting until the process exists,
    # avoids a race where an instant exit SIGTERMs a still-starting
    # caffeinate. Monitor the waited PID with kill -0 only.
    printf '%s: holding idle-sleep assertion with caffeinate -i\n' "$child_tag" >&2
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
    # time to record argv before the child (which may exit immediately) returns.
    sleep 0.1
  fi

  "$binary" "$@" &
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
launch_run_wait_pid() {
  local pid="$1"
  local stall_limit last_bytes last_change now bytes

  stall_limit="$(launch_run_stall_seconds)"
  if [ "$stall_limit" = 0 ]; then
    wait "$pid" || true
    return 0
  fi

  last_bytes="$(launch_run_combined_bytes)"
  last_change="$(date +%s)"

  while kill -0 "$pid" 2>/dev/null; do
    sleep 1
    if ! kill -0 "$pid" 2>/dev/null; then
      break
    fi
    bytes="$(launch_run_combined_bytes)"
    now="$(date +%s)"
    if [ "$bytes" != "$last_bytes" ]; then
      last_bytes="$bytes"
      last_change="$now"
    elif [ $((now - last_change)) -ge "$stall_limit" ]; then
      printf '%s: no log growth for %s seconds while PID %s is alive; stopping the child\n' \
        "$launch_run_tag" "$stall_limit" "$pid" >&2
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 2
    fi
  done
  wait "$pid" || true
  return 0
}

# Start one child (via this file in child mode), record its PID, and wait.
# $1 = "print" prints caller metadata after the PID file is written.
# Sets launch_run_wait_status to 0 (exited) or 2 (stall).
launch_run_start_and_wait() {
  local saved="$PWD"
  local child_pid
  local use_cafe="${launch_run_caffeinate:-0}"

  if [ -L "$launch_run_stdout_log" ]; then
    printf '%s: refusing symlinked write target: %s\n' "$launch_run_tag" "$launch_run_stdout_log" >&2
    return 1
  fi
  if [ -L "$launch_run_stderr_log" ]; then
    printf '%s: refusing symlinked write target: %s\n' "$launch_run_tag" "$launch_run_stderr_log" >&2
    return 1
  fi
  if [ -L "$launch_run_pid_file" ]; then
    printf '%s: refusing symlinked write target: %s\n' "$launch_run_tag" "$launch_run_pid_file" >&2
    return 1
  fi

  if ! launch_run_prepare_args; then
    return 1
  fi

  if [ -n "${launch_run_cwd:-}" ]; then
    cd -- "$launch_run_cwd" || return 1
  fi

  env "${launch_run_env_prefix}_CHILD_MODE=1" \
    "${launch_run_env_prefix}_USE_CAFFEINE=$use_cafe" \
    bash "$launch_run_self" __launch_run_child \
    "$launch_run_env_prefix" "$launch_run_child_tag" "$launch_run_binary" \
    "${launch_run_args[@]}" \
    >"$launch_run_stdout_log" 2>"$launch_run_stderr_log" </dev/null &
  child_pid=$!
  printf '%s\n' "$child_pid" >"$launch_run_pid_file"

  if [ -n "${launch_run_cwd:-}" ]; then
    cd -- "$saved" || return 1
  fi

  if [ "${1:-}" = print ]; then
    if command -v launch_run_print_metadata >/dev/null 2>&1; then
      launch_run_print_metadata
    fi
  fi

  launch_run_wait_status=0
  launch_run_wait_pid "$child_pid" || launch_run_wait_status=$?
  if [ "$launch_run_wait_status" != 0 ] && [ "$launch_run_wait_status" != 2 ]; then
    launch_run_wait_status=0
  fi
  return 0
}

launch_run_fail_closed() {
  printf '%s: the automatic retry also failed (empty output, a headless auto-deny, or a stall).\n' \
    "$launch_run_tag" >&2
  printf '%s: stdout: %s\n' "$launch_run_tag" "$launch_run_stdout_log" >&2
  printf '%s: stderr: %s\n' "$launch_run_tag" "$launch_run_stderr_log" >&2
  printf '%s: ask the operator to inspect those logs and decide the next step. Do not add allow-rules or pass --dangerously-skip-permissions.\n' \
    "$launch_run_tag" >&2
}

# Inspect the just-finished attempt. Sets launch_run_need_retry (0/1) and
# launch_run_approval_retry (0/1). Prints a one-line reason when retrying.
launch_run_classify_attempt() {
  launch_run_need_retry=0
  launch_run_approval_retry=0

  if [ "${launch_run_wait_status:-0}" = 2 ]; then
    launch_run_need_retry=1
    launch_run_approval_retry=1
    printf '%s: run stalled waiting (no log growth); retrying once with a simpler-commands instruction\n' \
      "$launch_run_tag" >&2
    return 0
  fi
  if launch_run_has_auto_deny; then
    launch_run_need_retry=1
    launch_run_approval_retry=1
    printf '%s: headless auto-deny in stderr (%s); retrying once with a simpler-commands instruction\n' \
      "$launch_run_tag" "$launch_run_stderr_log" >&2
    return 0
  fi
  if launch_run_stdout_empty; then
    launch_run_need_retry=1
    printf '%s: empty stdout log (%s); retrying once\n' \
      "$launch_run_tag" "$launch_run_stdout_log" >&2
    return 0
  fi
  return 0
}

# Run at most two attempts under the shared retry budget and return 0 or 1.
# Callers must set launch_run_tag, the binary/notice/prefix fields, the
# log/pid/brief paths, and define launch_run_prepare_args.
launch_run_run() {
  launch_run_caffeinate="$(launch_run_use_caffeinate)"
  launch_run_brief_used="$launch_run_brief"
  launch_run_wait_status=0

  if [ -z "${launch_run_attempt1_out:-}" ]; then
    launch_run_attempt1_out="${launch_run_stdout_log}.attempt1"
  fi
  if [ -z "${launch_run_attempt1_err:-}" ]; then
    launch_run_attempt1_err="${launch_run_stderr_log}.attempt1"
  fi

  if ! launch_run_start_and_wait print; then
    printf '%s: failed to start %s\n' "$launch_run_tag" "$launch_run_binary" >&2
    return 1
  fi

  launch_run_classify_attempt
  if [ "$launch_run_need_retry" != 1 ]; then
    return 0
  fi

  if ! launch_run_rotate_attempt1; then
    return 1
  fi

  if [ "$launch_run_approval_retry" = 1 ]; then
    if ! launch_run_write_retry_brief; then
      return 1
    fi
    # Used by the caller-defined launch_run_prepare_args.
    # shellcheck disable=SC2034
    launch_run_brief_used="$launch_run_retry_brief"
  fi

  if ! launch_run_start_and_wait; then
    printf '%s: failed to start %s on retry\n' "$launch_run_tag" "$launch_run_binary" >&2
    return 1
  fi

  launch_run_need_retry=0
  launch_run_approval_retry=0
  if [ "${launch_run_wait_status:-0}" = 2 ] || launch_run_has_auto_deny || launch_run_stdout_empty; then
    launch_run_fail_closed
    return 1
  fi
  return 0
}

# Child mode started by launch_run_start_and_wait. The parent passes the
# environment prefix, the message tag, and the binary before the adapter args.
if [ "${1:-}" = "__launch_run_child" ] && [ "$#" -ge 4 ]; then
  launch_run_child_prefix="$2"
  launch_run_child_tag_arg="$3"
  launch_run_child_binary="$4"
  shift 4
  launch_run_child_main "$launch_run_child_prefix" "$launch_run_child_tag_arg" \
    "$launch_run_child_binary" "$@"
fi
