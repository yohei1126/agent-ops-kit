#!/usr/bin/env bash
# Load, validate, and query the agent config. Source this file; sourcing has
# no side effects beyond defining functions.
#
# Config path: $AGENT_OPS_KIT_CONFIG when set, otherwise
# $HOME/.config/agent-ops-kit/agents.json. Pass an explicit path to
# agent_config_load to override both.
#
# Status codes:
#   0  success
#   3  config missing, unreadable, invalid, or an unknown lane/agent
#   4  policy refusal (no eligible lane entry)
# Callers turn a non-zero status into their own usage or config exit (2).
# This file must not name an agent or a model; those live in the config.
# shellcheck shell=bash

agent_config_path() {
  if [ -n "${AGENT_OPS_KIT_CONFIG:-}" ]; then
    printf '%s\n' "$AGENT_OPS_KIT_CONFIG"
  else
    printf '%s\n' "${HOME:-}/.config/agent-ops-kit/agents.json"
  fi
}

# shellcheck disable=SC2016 # the jq program is intentionally single-quoted
agent_config_validation_program='
def nonempty: (type == "string") and (length > 0);
# \A and \z are absolute anchors; `$` would also accept a trailing newline.
def token: (type == "string") and (test("\\A[a-z0-9-]+\\z"));
def known_agent_fields: ["adapter", "display", "provider", "who_can_launch", "provisioned", "overages", "_comment"];
def known_entry_fields: ["agent", "model", "model_name", "mode", "_comment"];
. as $root |
if (type != "object") then
  "config root must be an object"
else
  [
    (if $root.schema_version != 1 then "schema_version must be 1" else empty end),
    (if ($root.agents | type) != "object" then "agents must be an object" else empty end),
    (if ($root.lanes | type) != "object" then "lanes must be an object" else empty end),
    (if ($root | has("_comment")) and (($root._comment | type) != "string") then "_comment must be a string" else empty end),
    (if ([$root | keys[] | select(. != "schema_version" and . != "agents" and . != "lanes" and . != "_comment")] | length) > 0 then
       "config has an unknown top-level field" else empty end),
    (if ($root.agents | type) == "object" then
       $root.agents | to_entries[] | .key as $name | .value as $a |
       (if ($name | token | not) then "agents: agent name \($name | @json) must match [a-z0-9-]+" else empty end),
       (if ($a | type) != "object" then
          "agents.\($name) must be an object"
        else
          (if ($a.adapter | token | not) then "agents.\($name).adapter must match [a-z0-9-]+" else empty end),
          (if ($a.display | nonempty | not) then "agents.\($name).display must be a non-empty string" else empty end),
          (if ($a.provider | nonempty | not) then "agents.\($name).provider must be a non-empty string" else empty end),
          (if ($a.who_can_launch != "maintainer" and $a.who_can_launch != "bot") then
             "agents.\($name).who_can_launch must be maintainer or bot" else empty end),
          (if ($a.provisioned | type) != "boolean" then "agents.\($name).provisioned must be a boolean" else empty end),
          (if ($a | has("overages")) and ($a.overages != "never") then
             "agents.\($name).overages must be never (paid overages are not allowed)" else empty end),
          (if ($a | has("_comment")) and (($a._comment | type) != "string") then
             "agents.\($name)._comment must be a string" else empty end),
          (if ([$a | keys[] | select(. as $k | known_agent_fields | index($k) | not)] | length) > 0 then
             "agents.\($name) has an unknown field" else empty end)
        end)
     else empty end),
    (if ($root.lanes | type) == "object" then
       $root.lanes | to_entries[] | .key as $lane | .value as $l |
       (if ($lane | token | not) then "lanes: lane name \($lane | @json) must match [a-z0-9-]+" else empty end),
       (if ($l | type) != "object" then
          "lanes.\($lane) must be an object"
        else
          (if ($l | has("_comment")) and (($l._comment | type) != "string") then
             "lanes.\($lane)._comment must be a string" else empty end),
          (if ([$l | keys[] | select(. != "entries" and . != "_comment")] | length) > 0 then
             "lanes.\($lane) has an unknown field" else empty end),
          (if ($l.entries | type) != "array" then
             "lanes.\($lane).entries must be an array"
           else
             $l.entries | to_entries[] | .key as $i | .value as $e |
             (if ($e | type) != "object" then
                "lanes.\($lane)[\($i)] must be an object"
              else
                (if ($e.agent | nonempty | not) then
                   "lanes.\($lane)[\($i)].agent must be a non-empty string"
                 elif ($root.agents[$e.agent] == null) then
                   "lanes.\($lane)[\($i)].agent is not a defined agent"
                 else empty end),
                (if ($e | has("model") | not) or (($e.model != null) and ($e.model | nonempty | not)) then
                   "lanes.\($lane)[\($i)].model must be a non-empty string, or null while the id is unverified" else empty end),
                (if ($e.model_name | nonempty | not) then
                   "lanes.\($lane)[\($i)].model_name must be a non-empty string" else empty end),
                (if ($e | has("mode")) and (($e.mode | token) | not) then
                   "lanes.\($lane)[\($i)].mode must match [a-z0-9-]+" else empty end),
                (if ($e | has("_comment")) and (($e._comment | type) != "string") then
                   "lanes.\($lane)[\($i)]._comment must be a string" else empty end),
                (if ([$e | keys[] | select(. as $k | known_entry_fields | index($k) | not)] | length) > 0 then
                   "lanes.\($lane)[\($i)] has an unknown field" else empty end)
              end)
           end)
        end)
     else empty end)
  ] | .[]
end
'

# agent_config_load [path]
# Validates the whole config and records the path for later queries. With no
# argument the path comes from agent_config_path; an explicit empty argument
# is an error, never a fallback to the environment or the default file.
agent_config_load() {
  local path
  local errors
  local line

  if [ "$#" -ge 1 ]; then
    path="$1"
  else
    path="$(agent_config_path)"
  fi
  case "$path" in
    '')
      printf 'agent-config: config path is empty\n' >&2
      return 3
      ;;
  esac
  if [ ! -f "$path" ]; then
    printf 'agent-config: config file not found: %s\n' "$path" >&2
    return 3
  fi
  if [ ! -r "$path" ]; then
    printf 'agent-config: config file is not readable: %s\n' "$path" >&2
    return 3
  fi
  if ! command -v jq >/dev/null 2>&1; then
    printf 'agent-config: jq is required\n' >&2
    return 3
  fi
  # Slurp so a file holding several top-level JSON values is rejected: the
  # config must be exactly one document, and that document is validated.
  if ! jq -e -s 'length == 1' "$path" >/dev/null 2>&1; then
    printf 'agent-config: config is not valid JSON (exactly one JSON document required): %s\n' "$path" >&2
    return 3
  fi
  if ! errors="$(jq -r -s ".[0] | $agent_config_validation_program" "$path" 2>/dev/null)"; then
    printf 'agent-config: could not validate config: %s\n' "$path" >&2
    return 3
  fi
  if [ -n "$errors" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      printf 'agent-config: %s: %s\n' "$path" "$line" >&2
    done <<EOF
$errors
EOF
    return 3
  fi
  agent_config_loaded_file="$path"
  return 0
}

agent_config_loaded_path() {
  printf '%s\n' "${agent_config_loaded_file:-}"
}

agent_config_lanes() {
  jq -r '.lanes | keys_unsorted[]' "$agent_config_loaded_file"
}

agent_config_agents() {
  jq -r '.agents | keys_unsorted[]' "$agent_config_loaded_file"
}

agent_config_lane_exists() {
  jq -e --arg lane "$1" '.lanes[$lane] != null' "$agent_config_loaded_file" >/dev/null
}

agent_config_agent_exists() {
  jq -e --arg agent "$1" '.agents[$agent] != null' "$agent_config_loaded_file" >/dev/null
}

agent_config_agent_in_lane() {
  jq -e --arg lane "$1" --arg agent "$2" \
    '[.lanes[$lane].entries[] | select(.agent == $agent)] | length > 0' \
    "$agent_config_loaded_file" >/dev/null
}

agent_config_agent_field() {
  jq -r --arg agent "$1" --arg field "$2" '.agents[$agent][$field]' \
    "$agent_config_loaded_file"
}

agent_config_lane_entry_count() {
  jq -r --arg lane "$1" '.lanes[$lane].entries | length' "$agent_config_loaded_file"
}

# shellcheck disable=SC2034 # field is consumed by the jq --arg
agent_config_lane_entry_field() {
  local lane="$1"
  local index="$2"
  local field="$3"
  jq -r --arg lane "$lane" --argjson index "$index" --arg field "$field" \
    '.lanes[$lane].entries[$index][$field] // empty' "$agent_config_loaded_file"
}

# agent_config_first_entry_index <lane> <agent>
# Prints the index of the first lane entry for the agent.
agent_config_first_entry_index() {
  jq -r --arg lane "$1" --arg agent "$2" \
    '[.lanes[$lane].entries | to_entries[] | select(.value.agent == $agent) | .key][0] // empty' \
    "$agent_config_loaded_file"
}

# agent_config_label <agent> <model-name>
# Prints `<model-name> (<provider> / <display>)`.
agent_config_label() {
  local agent="$1"
  local model_name="$2"
  local provider display
  provider="$(agent_config_agent_field "$agent" provider)"
  display="$(agent_config_agent_field "$agent" display)"
  printf '%s (%s / %s)\n' "$model_name" "$provider" "$display"
}

# A lane entry with this mode is a hand-off: the caller prepares a task Issue
# and the maintainer runs the agent from it. Nothing is launched for it.
agent_config_handoff_mode="issue"

# agent_config_select <lane> <caller> [agent]
# Walks lane entries in order and prints the first eligible agent name.
# The caller is `bot` or `maintainer`. An entry is eligible when the caller
# may launch it (`bot` allows both; `maintainer` allows only the maintainer)
# and the entry is provisioned. A hand-off entry launches nothing, so a bot
# may select a maintainer-only hand-off entry to prepare its Issue; the
# launcher still refuses to run the hand-off for a bot without --dry-run.
# Skip reasons go to stderr.
agent_config_select() {
  local lane="$1"
  local caller="$2"
  local requested="${3:-}"
  local count index name who provisioned mode reason skipped

  if ! agent_config_lane_exists "$lane"; then
    printf 'agent-config: unknown lane: %s\n' "$lane" >&2
    return 3
  fi
  if [ -n "$requested" ]; then
    if ! agent_config_agent_exists "$requested"; then
      printf 'agent-config: unknown agent: %s\n' "$requested" >&2
      return 3
    fi
    if ! agent_config_agent_in_lane "$lane" "$requested"; then
      printf 'agent-config: agent %s is not in lane %s\n' "$requested" "$lane" >&2
      return 3
    fi
  fi

  count="$(agent_config_lane_entry_count "$lane")"
  if [ "$count" = 0 ]; then
    printf 'agent-config: lane %s has no entries\n' "$lane" >&2
    return 4
  fi

  skipped=""
  index=0
  while [ "$index" -lt "$count" ]; do
    name="$(agent_config_lane_entry_field "$lane" "$index" agent)"
    index=$((index + 1))
    if [ -n "$requested" ] && [ "$name" != "$requested" ]; then
      continue
    fi
    who="$(agent_config_agent_field "$name" who_can_launch)"
    provisioned="$(agent_config_agent_field "$name" provisioned)"
    mode="$(agent_config_lane_entry_field "$lane" "$((index - 1))" mode)"

    reason=""
    if [ "$who" = "maintainer" ] && [ "$caller" != "maintainer" ] &&
      [ "$mode" != "$agent_config_handoff_mode" ]; then
      reason="who_can_launch=maintainer refuses caller $caller"
    elif [ "$provisioned" != "true" ]; then
      reason="not provisioned"
    fi

    if [ -z "$reason" ]; then
      printf '%s\n' "$name"
      return 0
    fi
    skipped="${skipped}lane $lane entry $index ($name) skipped: $reason
"
  done

  if [ -n "$requested" ]; then
    printf 'agent-config: no eligible entry for agent %s in lane %s\n' \
      "$requested" "$lane" >&2
  else
    printf 'agent-config: no eligible entry in lane %s\n' "$lane" >&2
  fi
  printf '%s' "$skipped" >&2
  return 4
}
