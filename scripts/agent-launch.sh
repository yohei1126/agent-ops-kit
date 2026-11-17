#!/usr/bin/env bash
# Config-driven agent launcher. Selects one lane entry that the caller may
# launch, then execs the adapter for that entry.
#
# Usage:
#   scripts/agent-launch.sh --lane <lane> --as <bot|maintainer>
#       [--agent <name>] [--config <path>] [--dry-run] -- <adapter args>
#   scripts/agent-launch.sh --validate [--config <path>]
#   scripts/agent-launch.sh --list [--config <path>]
#   scripts/agent-launch.sh --help
#
# The config path is $AGENT_OPS_KIT_CONFIG when set, otherwise
# $HOME/.config/agent-ops-kit/agents.json.
#
# There is no default lane and no default model. Policy refusals, usage
# errors, and config errors exit 2 before any adapter starts.
#
# A lane entry with mode `issue` is a hand-off: it never starts the agent or
# its adapter. --dry-run prints the scripts/agent-task-issue.sh command for
# the task Issue (arguments after `--` go to that script; --agent and --model
# come from the config). Without --dry-run a bot is refused (exit 2) and the
# maintainer runs the command. A null model id (unverified) exits 2, except
# for a hand-off entry, which passes the model name marked "id unverified".
#
# A lane with "preflight": "review-ready" needs --pr and --expect-head and
# starts nothing unless scripts/dev-loop-gate.sh --check review-ready passes.
#
# Exit codes: 0 ok, 1 adapter or preflight failure, 2 usage, config, or
# policy refusal.
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd -P)"
config_lib="$script_dir/lib/agent-config.sh"
adapters_root="$script_dir/agents"

# One flag table drives both help text and value requirements.
flag_specs() {
  cat <<'EOF'
lane <lane>|Lane to select an entry from (required for launch)
as <bot|maintainer>|Caller identity used for who_can_launch (required for launch)
agent <name>|Pick the first eligible lane entry for this configured agent
config <path>|Config file, non-empty (overrides AGENT_OPS_KIT_CONFIG)
pr <number>|Pull request under review; required when the lane has a preflight
expect-head <sha>|Head SHA under review (7+ hex); required when the lane has a preflight
checkout <dir>|Checkout of that head for the preflight (default: the current directory)
test-log <path>|Test log whose tail goes into the preflight evidence
gh-repo <owner/repo>|Repository of that pull request for the preflight (default: gh infers it from the checkout)
dry-run|Print the selection and the exact command instead of launching; for an issue hand-off entry, the agent-task-issue.sh command
validate|Validate the config, including entry modes against installed adapters, and exit
list|List lane and agent names from the config
help|Print this help
EOF
}

# flag_spec_find <flag>
# Prints the value placeholder for the flag (empty when it takes no value).
# Returns 1 for an unknown flag.
flag_spec_find() {
  local flag="$1"
  local line spec
  while IFS= read -r line; do
    spec="${line%%|*}"
    case "$spec" in
      "$flag "*) printf '%s\n' "${spec#* }"; return 0 ;;
      "$flag") printf '\n'; return 0 ;;
    esac
  done <<EOF
$(flag_specs)
EOF
  return 1
}

usage() {
  cat <<'EOF'
Usage:
  scripts/agent-launch.sh --lane <lane> --as <bot|maintainer> [--agent <name>] [--config <path>] [--dry-run] -- <adapter args>
  scripts/agent-launch.sh --validate [--config <path>]
  scripts/agent-launch.sh --list [--config <path>]
  scripts/agent-launch.sh --help

Options:
EOF
  local line spec desc
  while IFS= read -r line; do
    spec="${line%%|*}"
    desc="${line#*|}"
    printf '  --%s\n        %s\n' "$spec" "$desc"
  done <<EOF
$(flag_specs)
EOF
  cat <<EOF

Entry mode $agent_config_handoff_mode (hand-off):
  Never starts the agent or its adapter. With --dry-run, prints the
  scripts/agent-task-issue.sh command for the task Issue; arguments after --
  go to that script, and --agent and --model come from the config. Without
  --dry-run, a bot is refused (exit 2); the maintainer runs the command and
  then runs the agent from the Issue.

A lane entry whose model id is null (unverified) exits 2 when selected,
except in hand-off mode, which executes no model: there the Issue gets the
model name marked "id unverified".
EOF
}

usage_error() {
  printf 'agent-launch: %s\n' "$1" >&2
  usage >&2
  exit 2
}

# adapter_mode_check <adapter> <mode> <where>
# An adapter that takes --mode lists its modes, one per line, in
# scripts/agents/<adapter>/modes. Such an adapter needs an entry mode from that
# list; an adapter without the file takes no mode. Call only for an installed
# adapter. Prints the refusal and returns 1 on a mismatch.
adapter_mode_check() {
  local adapter="$1"
  local mode="$2"
  local where="$3"
  local modes_file="$adapters_root/$adapter/modes"
  local line listed=""

  if [ ! -f "$modes_file" ]; then
    if [ -n "$mode" ]; then
      printf 'agent-launch: %s sets mode %s, but adapter %s takes no mode (no %s)\n' \
        "$where" "$mode" "$adapter" "$modes_file" >&2
      return 1
    fi
    return 0
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '' | '#'*) continue ;;
    esac
    listed="$listed $line"
    if [ -n "$mode" ] && [ "$line" = "$mode" ]; then
      return 0
    fi
  done <"$modes_file"
  if [ -z "$mode" ]; then
    printf 'agent-launch: %s has no mode, but adapter %s needs one of:%s\n' \
      "$where" "$adapter" "$listed" >&2
  else
    printf 'agent-launch: %s sets mode %s, but adapter %s supports only:%s\n' \
      "$where" "$mode" "$adapter" "$listed" >&2
  fi
  return 1
}

# validate_entry_modes: check every lane entry whose adapter is installed.
# An adapter that is not installed yet is refused at launch time instead.
# agent_config_load has already restricted lane names, adapters, and modes to
# [a-z0-9-]+, so no field can hold the tab or newline used as delimiters here.
# The row count is still checked against the entry count so a malformed row
# fails closed instead of being skipped.
validate_entry_modes() {
  local lane index adapter mode entries expected seen=0 status=0
  local tab
  tab="$(printf '\t')"
  expected="$(jq -r '[.lanes[].entries | length] | add // 0' \
    "$(agent_config_loaded_path)")" || return 1
  entries="$(jq -r '. as $root | .lanes | to_entries[] | .key as $lane |
    .value.entries | to_entries[] |
    [$lane, ((.key + 1) | tostring), $root.agents[.value.agent].adapter, (.value.mode // "-")] | join("\t")' \
    "$(agent_config_loaded_path)")" || return 1
  while IFS="$tab" read -r lane index adapter mode; do
    [ -n "$lane" ] || continue
    seen=$((seen + 1))
    case "$lane:$index:$adapter:$mode" in
      *[!a-z0-9:-]*)
        printf 'agent-launch: malformed lane entry row: %s\n' "$lane" >&2
        status=1
        continue
        ;;
    esac
    [ "$mode" != "-" ] || mode=""
    if [ -d "$adapters_root/$adapter" ]; then
      if ! adapter_mode_check "$adapter" "$mode" "lane $lane entry $index"; then
        status=1
      fi
    fi
  done <<LIST
$entries
LIST
  if [ "$seen" != "$expected" ]; then
    printf 'agent-launch: checked %s lane entries, expected %s\n' "$seen" "$expected" >&2
    status=1
  fi
  return "$status"
}

if [ ! -r "$config_lib" ]; then
  printf 'agent-launch: missing library: %s\n' "$config_lib" >&2
  exit 1
fi
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/agent-config.sh
. "$config_lib"

lane=""
as_caller=""
requested_agent=""
config_path=""
config_set=0
dry_run=0
review_pr=""
review_head=""
review_checkout=""
review_test_log=""
review_gh_repo=""
do_validate=0
do_list=0
do_help=0
adapter_args=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --)
      shift
      while [ "$#" -gt 0 ]; do
        adapter_args[${#adapter_args[@]}]="$1"
        shift
      done
      ;;
    --help)
      do_help=1
      shift
      ;;
    --*)
      flag="${1#--}"
      if ! value_spec="$(flag_spec_find "$flag")"; then
        usage_error "unknown flag: --$flag"
      fi
      if [ -n "$value_spec" ]; then
        if [ "$#" -lt 2 ]; then
          usage_error "missing value for --$flag"
        fi
        value="$2"
        shift 2
      else
        value=""
        shift
      fi
      case "$flag" in
        lane) lane="$value" ;;
        as) as_caller="$value" ;;
        agent) requested_agent="$value" ;;
        config)
          if [ -z "$value" ]; then
            usage_error "--config needs a non-empty path"
          fi
          config_path="$value"
          config_set=1
          ;;
        pr) review_pr="$value" ;;
        expect-head) review_head="$value" ;;
        checkout) review_checkout="$value" ;;
        test-log) review_test_log="$value" ;;
        gh-repo) review_gh_repo="$value" ;;
        dry-run) dry_run=1 ;;
        validate) do_validate=1 ;;
        list) do_list=1 ;;
        help) do_help=1 ;;
        *) usage_error "unknown flag: --$flag" ;;
      esac
      ;;
    -?*)
      usage_error "unknown flag: $1"
      ;;
    *)
      usage_error "unexpected argument: $1"
      ;;
  esac
done

# load_config: an explicit --config path, otherwise the library default.
load_config() {
  if [ "$config_set" = 1 ]; then
    agent_config_load "$config_path"
  else
    agent_config_load
  fi
}

# Only a launch passes arguments after `--` to an adapter.
reject_adapter_args() {
  if [ "${#adapter_args[@]}" -gt 0 ]; then
    usage_error "$1 takes no arguments after --"
  fi
}

if [ "$do_help" = 1 ]; then
  reject_adapter_args "--help"
  usage
  if load_config >/dev/null 2>&1; then
    printf '\nLanes from %s:\n' "$(agent_config_loaded_path)"
    agent_config_lanes
    printf '\nAgents from %s:\n' "$(agent_config_loaded_path)"
    agent_config_agents
  fi
  exit 0
fi

if [ "$do_validate" = 1 ]; then
  if [ "$do_list" = 1 ] || [ -n "$lane" ] || [ -n "$as_caller" ] ||
    [ -n "$requested_agent" ] || [ "$dry_run" = 1 ]; then
    usage_error "--validate cannot be combined with launch or --list flags"
  fi
  reject_adapter_args "--validate"
  if ! load_config; then
    exit 2
  fi
  if ! validate_entry_modes; then
    exit 2
  fi
  printf 'CONFIG=%s\n' "$(agent_config_loaded_path)"
  printf 'VALID=1\n'
  exit 0
fi

if [ "$do_list" = 1 ]; then
  if [ -n "$lane" ] || [ -n "$as_caller" ] || [ -n "$requested_agent" ] ||
    [ "$dry_run" = 1 ]; then
    usage_error "--list cannot be combined with launch flags"
  fi
  reject_adapter_args "--list"
  if ! load_config; then
    exit 2
  fi
  printf 'LANES\n'
  agent_config_lanes
  printf 'AGENTS\n'
  agent_config_agents
  exit 0
fi

if [ -z "$lane" ]; then
  usage_error "missing --lane (there is no default lane)"
fi
if [ -z "$as_caller" ]; then
  usage_error "missing --as (there is no default caller)"
fi
case "$as_caller" in
  bot | maintainer) ;;
  *) usage_error "invalid --as value: $as_caller (use bot or maintainer)" ;;
esac

if ! load_config; then
  exit 2
fi

if ! selected_agent="$(agent_config_select "$lane" "$as_caller" "$requested_agent")"; then
  exit 2
fi
if [ -z "$selected_agent" ]; then
  printf 'agent-launch: no eligible entry in lane %s\n' "$lane" >&2
  exit 2
fi

entry_index="$(agent_config_first_entry_index "$lane" "$selected_agent")"
if [ -z "$entry_index" ]; then
  printf 'agent-launch: could not resolve lane entry for %s\n' "$selected_agent" >&2
  exit 2
fi

adapter="$(agent_config_agent_field "$selected_agent" adapter)"
model="$(agent_config_lane_entry_field "$lane" "$entry_index" model)"
model_name="$(agent_config_lane_entry_field "$lane" "$entry_index" model_name)"
mode="$(agent_config_lane_entry_field "$lane" "$entry_index" mode)"

# A null model id is unverified. Only a hand-off entry may carry one, because
# it executes no model; the Issue then says the id is unverified.
if [ -z "$model" ] && [ "$mode" != "$agent_config_handoff_mode" ]; then
  printf 'agent-launch: lane %s entry for %s has a null model id (unverified); the maintainer must confirm the id locally and set it in the config before this entry can run\n' \
    "$lane" "$selected_agent" >&2
  exit 2
fi
if [ -z "$model_name" ]; then
  printf 'agent-launch: lane %s entry for %s has no model name\n' \
    "$lane" "$selected_agent" >&2
  exit 2
fi

adapter_run="$adapters_root/$adapter/run"
if [ ! -d "$adapters_root/$adapter" ]; then
  printf 'agent-launch: adapter %s is not installed at %s\n' \
    "$adapter" "$adapters_root/$adapter" >&2
  exit 2
fi
if [ ! -f "$adapter_run" ] || [ ! -x "$adapter_run" ]; then
  printf 'agent-launch: adapter %s has no executable run at %s\n' \
    "$adapter" "$adapter_run" >&2
  exit 2
fi

if ! adapter_mode_check "$adapter" "$mode" "lane $lane entry $((entry_index + 1)) ($selected_agent)"; then
  exit 2
fi

label="$(agent_config_label "$selected_agent" "$model_name")"

# A hand-off entry never starts the agent or its adapter. It turns into an
# agent-task Issue command; the maintainer runs the agent from that Issue.
if [ "$mode" = "$agent_config_handoff_mode" ]; then
  task_issue="$script_dir/agent-task-issue.sh"
  if [ "${#adapter_args[@]}" -gt 0 ]; then
    for arg in "${adapter_args[@]}"; do
      case "$arg" in
        --agent | --agent=* | --model | --model=*)
          usage_error "$arg comes from the config for a hand-off entry; do not pass it after --"
          ;;
      esac
    done
  fi
  if [ -n "$model" ]; then
    model_text="$model_name ($model)"
  else
    model_text="$model_name (id unverified)"
  fi
  command_args=("$task_issue" --agent "$adapter" --model "$model_text")
  if [ "${#adapter_args[@]}" -gt 0 ]; then
    for arg in "${adapter_args[@]}"; do
      command_args[${#command_args[@]}]="$arg"
    done
  fi
  if [ "$dry_run" = 1 ]; then
    printf 'AGENT=%s\n' "$selected_agent"
    printf 'ADAPTER=%s\n' "$adapter"
    printf 'MODEL=%s\n' "${model:-null}"
    printf 'LABEL=%s\n' "$label"
    printf 'MODE=%s\n' "$mode"
    printf 'HANDOFF=issue\n'
    printf 'COMMAND='
    printf '%q ' "${command_args[@]}"
    printf '\n'
    exit 0
  fi
  if [ "$as_caller" != maintainer ]; then
    printf 'agent-launch: lane %s entry %s (%s) is an issue hand-off: a bot never runs it. Re-run with --dry-run to print the agent-task-issue.sh command, create the Issue with it, and the maintainer runs the agent from the Issue.\n' \
      "$lane" "$((entry_index + 1))" "$selected_agent" >&2
    exit 2
  fi
  if [ ! -f "$task_issue" ] || [ ! -x "$task_issue" ]; then
    printf 'agent-launch: missing executable %s\n' "$task_issue" >&2
    exit 1
  fi
  exec "${command_args[@]}"
fi

# A lane with a preflight (review lanes) is fail-closed: the adapter starts,
# or prints its command, only when CI and the named checks are green for the
# exact head under review. The evidence file reaches the adapter through
# AGENT_LAUNCH_EVIDENCE so the brief carries the machine results. On PASS the
# evidence folder stays in TMPDIR after the launch, as a record of what the
# review was told; the launcher execs the adapter and cannot clean it up.
preflight="$(agent_config_lane_preflight "$lane")"
if [ -n "$preflight" ]; then
  if [ -z "$review_pr" ] || [ -z "$review_head" ]; then
    usage_error "lane $lane has preflight $preflight: pass --pr <number> and --expect-head <sha> so the review is pinned to one head"
  fi
  gate="$script_dir/dev-loop-gate.sh"
  evidence_dir="$(mktemp -d "${TMPDIR:-/tmp}/agent-launch-evidence.XXXXXX")"
  evidence_file="$evidence_dir/evidence.md"
  set -- --check "$preflight" --pr "$review_pr" --expect-head "$review_head" \
    --repo "${review_checkout:-$PWD}" --evidence-out "$evidence_file"
  if [ -n "$review_test_log" ]; then
    set -- "$@" --test-log "$review_test_log"
  fi
  if [ -n "$review_gh_repo" ]; then
    set -- "$@" --gh-repo "$review_gh_repo"
  fi
  preflight_status=0
  "$gate" "$@" >&2 || preflight_status=$?
  if [ "$preflight_status" -ne 0 ]; then
    rm -rf "$evidence_dir"
    printf 'agent-launch: preflight %s failed (exit %s); no agent started. Fix the FAIL rows above, then re-run.\n' \
      "$preflight" "$preflight_status" >&2
    exit 1
  fi
  export AGENT_LAUNCH_EVIDENCE="$evidence_file"
fi

command_args=("$adapter_run")
if [ -n "$mode" ]; then
  command_args[${#command_args[@]}]="--mode"
  command_args[${#command_args[@]}]="$mode"
fi
command_args[${#command_args[@]}]="--model"
command_args[${#command_args[@]}]="$model"
command_args[${#command_args[@]}]="--"
if [ "${#adapter_args[@]}" -gt 0 ]; then
  for arg in "${adapter_args[@]}"; do
    command_args[${#command_args[@]}]="$arg"
  done
fi

if [ "$dry_run" = 1 ]; then
  printf 'AGENT=%s\n' "$selected_agent"
  printf 'ADAPTER=%s\n' "$adapter"
  printf 'MODEL=%s\n' "$model"
  printf 'LABEL=%s\n' "$label"
  if [ -n "$preflight" ]; then
    printf 'PREFLIGHT=%s PASS\n' "$preflight"
    printf 'EVIDENCE=%s\n' "$AGENT_LAUNCH_EVIDENCE"
  fi
  printf 'COMMAND='
  printf '%q ' "${command_args[@]}"
  printf '\n'
  exit 0
fi

exec "${command_args[@]}"
