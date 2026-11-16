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
# Exit codes: 0 ok, 1 adapter failure, 2 usage, config, or policy refusal.
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
config <path>|Config file (overrides AGENT_OPS_KIT_CONFIG)
dry-run|Print the selection and the exact command instead of launching
validate|Validate the config and exit
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
}

usage_error() {
  printf 'agent-launch: %s\n' "$1" >&2
  usage >&2
  exit 2
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
dry_run=0
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
        config) config_path="$value" ;;
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

if [ "$do_help" = 1 ]; then
  usage
  if agent_config_load "$config_path" >/dev/null 2>&1; then
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
  if ! agent_config_load "$config_path"; then
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
  if ! agent_config_load "$config_path"; then
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

if ! agent_config_load "$config_path"; then
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

if [ -z "$model" ] || [ -z "$model_name" ]; then
  printf 'agent-launch: lane %s entry for %s has no model\n' \
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

label="$(agent_config_label "$selected_agent" "$model_name")"

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
  printf 'COMMAND='
  printf '%q ' "${command_args[@]}"
  printf '\n'
  exit 0
fi

exec "${command_args[@]}"
