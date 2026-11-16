#!/usr/bin/env bash
# Deprecated compatibility shim. Removed after one release cycle.
#
# Keeps the former agy_launch_* variable and function contract working for
# callers that still source this file. New code should source
# scripts/lib/launch-run.sh through an adapter and use the launch_run_* names.
#
# Safe to source: source-time work is only loading the generic helper.
# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154,SC2317,SC2329,SC1091

agy_launch_shim_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=launch-run.sh
. "$agy_launch_shim_dir/launch-run.sh"

agy_launch_auto_deny_needle="${agy_launch_auto_deny_needle:-headless mode cannot prompt for}"
agy_launch_simpler_commands="${agy_launch_simpler_commands:-$launch_run_simpler_commands}"

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
agy_launch_wait_status="${agy_launch_wait_status:-0}"
agy_launch_need_retry="${agy_launch_need_retry:-0}"
agy_launch_approval_retry="${agy_launch_approval_retry:-0}"
agy_launch_self="$launch_run_self"
agy_launch_args=()

# Copy the former agy_launch_* state onto the generic launch_run_* names.
# Every forwarding function calls this first, so a legacy caller that sets
# only agy_launch_* variables (for example agy_launch_caffeinate=1) gets the
# same behaviour as before.
agy_launch_bridge_in() {
  launch_run_tag="$agy_launch_tag"
  launch_run_cwd="$agy_launch_cwd"
  launch_run_stdout_log="$agy_launch_stdout_log"
  launch_run_stderr_log="$agy_launch_stderr_log"
  launch_run_pid_file="$agy_launch_pid_file"
  launch_run_brief="$agy_launch_brief"
  launch_run_retry_brief="$agy_launch_retry_brief"
  launch_run_attempt1_out="$agy_launch_attempt1_out"
  launch_run_attempt1_err="$agy_launch_attempt1_err"
  launch_run_brief_used="$agy_launch_brief_used"
  launch_run_caffeinate="$agy_launch_caffeinate"
  launch_run_wait_status="$agy_launch_wait_status"
  launch_run_need_retry="$agy_launch_need_retry"
  launch_run_approval_retry="$agy_launch_approval_retry"
  launch_run_simpler_commands="$agy_launch_simpler_commands"
  launch_run_auto_deny_needle="$agy_launch_auto_deny_needle"
  launch_run_binary="agy"
  launch_run_child_tag="agy-launch-run"
  launch_run_env_prefix="AGY_LAUNCH"
  if [ "${#agy_launch_args[@]}" -gt 0 ]; then
    launch_run_args=("${agy_launch_args[@]}")
  else
    launch_run_args=()
  fi

  launch_run_prepare_args() {
    agy_launch_prepare_args
    if [ "${#agy_launch_args[@]}" -gt 0 ]; then
      launch_run_args=("${agy_launch_args[@]}")
    else
      launch_run_args=()
    fi
  }

  launch_run_print_metadata() {
    agy_launch_print_metadata
  }
}

# Copy the state the generic helper updated back onto the former names.
agy_launch_bridge_out() {
  agy_launch_brief_used="${launch_run_brief_used:-}"
  agy_launch_caffeinate="${launch_run_caffeinate:-0}"
  agy_launch_wait_status="${launch_run_wait_status:-0}"
  agy_launch_need_retry="${launch_run_need_retry:-0}"
  agy_launch_approval_retry="${launch_run_approval_retry:-0}"
  agy_launch_attempt1_out="${launch_run_attempt1_out:-}"
  agy_launch_attempt1_err="${launch_run_attempt1_err:-}"
  if [ "${#launch_run_args[@]}" -gt 0 ]; then
    agy_launch_args=("${launch_run_args[@]}")
  else
    agy_launch_args=()
  fi
}

# agy_launch_forward <generic-function> [args...]
agy_launch_forward() {
  local fn="$1"
  local status=0
  shift
  agy_launch_bridge_in
  "$fn" "$@" || status=$?
  agy_launch_bridge_out
  return "$status"
}

agy_launch_use_caffeinate() { agy_launch_forward launch_run_use_caffeinate "$@"; }
agy_launch_wrapper_prefix() { agy_launch_forward launch_run_wrapper_prefix "$@"; }
agy_launch_file_bytes() { agy_launch_forward launch_run_file_bytes "$@"; }
agy_launch_combined_bytes() { agy_launch_forward launch_run_combined_bytes "$@"; }
agy_launch_stall_seconds() { agy_launch_forward launch_run_stall_seconds "$@"; }
agy_launch_has_auto_deny() { agy_launch_forward launch_run_has_auto_deny "$@"; }
agy_launch_stdout_empty() { agy_launch_forward launch_run_stdout_empty "$@"; }
agy_launch_write_retry_brief() { agy_launch_forward launch_run_write_retry_brief "$@"; }
agy_launch_rotate_attempt1() { agy_launch_forward launch_run_rotate_attempt1 "$@"; }
agy_launch_wait_pid() { agy_launch_forward launch_run_wait_pid "$@"; }
agy_launch_start_and_wait() { agy_launch_forward launch_run_start_and_wait "$@"; }
agy_launch_fail_closed() { agy_launch_forward launch_run_fail_closed "$@"; }
agy_launch_classify_attempt() { agy_launch_forward launch_run_classify_attempt "$@"; }
agy_launch_child_main() { launch_run_child_main AGY_LAUNCH agy-launch-run agy "$@"; }
agy_launch_run() { agy_launch_forward launch_run_run "$@"; }

# Preserve the former child-mode entry point.
if [ "${AGY_LAUNCH_CHILD_MODE:-}" = 1 ]; then
  agy_launch_child_main "$@"
fi
