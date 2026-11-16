#!/usr/bin/env bash
# Deprecated compatibility shim. Removed after one release cycle.
#
# Keeps the former agy_launch_* variable and function contract working for
# callers that still source this file. New code should source
# scripts/lib/launch-run.sh through an adapter and use the launch_run_* names.
#
# Safe to source: source-time work is only loading the generic helper.
# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154,SC2329,SC1091

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

agy_launch_use_caffeinate() {
  launch_run_use_caffeinate
}

agy_launch_wrapper_prefix() {
  launch_run_wrapper_prefix
}

# Run the shared budget with the former agy_launch_* names bridged onto the
# generic launch_run_* names.
agy_launch_run() {
  local status=0

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
  launch_run_binary="agy"
  launch_run_auto_deny_needle="$agy_launch_auto_deny_needle"
  launch_run_child_tag="agy-launch-run"
  launch_run_env_prefix="AGY_LAUNCH"

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

  launch_run_run
  status=$?

  agy_launch_brief_used="$launch_run_brief_used"
  agy_launch_caffeinate="$launch_run_caffeinate"
  agy_launch_wait_status="${launch_run_wait_status:-0}"
  agy_launch_need_retry="${launch_run_need_retry:-0}"
  agy_launch_approval_retry="${launch_run_approval_retry:-0}"
  if [ "${#launch_run_args[@]}" -gt 0 ]; then
    agy_launch_args=("${launch_run_args[@]}")
  else
    agy_launch_args=()
  fi
  return "$status"
}

# Preserve the former child-mode entry point.
if [ "${AGY_LAUNCH_CHILD_MODE:-}" = 1 ]; then
  launch_run_child_main AGY_LAUNCH agy-launch-run agy "$@"
fi
