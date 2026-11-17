#!/usr/bin/env bash
# model-ids named check for scripts/dev-loop-gate.sh.
# Sourced by the gate script, never run on its own. It expects row(), repo,
# and strict from the caller.
#
# Every non-null lane model id in the example agent config must be listed in
# the verified-ids file, and every null id must carry a TODO in the entry's
# _comment. Both files are read from the work tree under --repo.
set -u

repo="${repo:-}"
strict="${strict:-0}"

model_ids_config_rel="templates/agent-config.example.json"
model_ids_list_rel="templates/agent-config.verified-model-ids.txt"

# model_ids_known <list> <id>: true when the id is a whole line of the list,
# ignoring blank lines, # comments, and surrounding blanks.
model_ids_known() {
  local list="$1"
  local id="$2"
  local line trimmed

  while IFS= read -r line || [ -n "$line" ]; do
    trimmed="${line#"${line%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    case "$trimmed" in
      '' | '#'*) continue ;;
    esac
    if [ "$trimmed" = "$id" ]; then
      return 0
    fi
  done <"$list"
  return 1
}

run_model_ids() {
  local config="$repo/$model_ids_config_rel"
  local list="$repo/$model_ids_list_rel"
  local entries lane index agent model has_todo where
  local checked=0 hits=0 state

  if ! command -v jq >/dev/null 2>&1; then
    printf 'dev-loop-gate: jq is required for model-ids\n' >&2
    exit 3
  fi
  if [ ! -f "$config" ]; then
    printf 'dev-loop-gate: model-ids: config not found: %s\n' "$model_ids_config_rel" >&2
    exit 2
  fi
  if [ ! -f "$list" ]; then
    printf 'dev-loop-gate: model-ids: verified-ids list not found: %s\n' "$model_ids_list_rel" >&2
    exit 2
  fi

  # One tab-separated record per lane entry: lane, index, agent, model or
  # the literal NULL, and whether _comment mentions TODO.
  if ! entries="$(jq -r '
      .lanes | to_entries[] | .key as $lane
      | .value.entries | to_entries[]
      | [$lane, (.key | tostring), (.value.agent // "?"),
         (if .value.model == null then "NULL"
          elif .value.model == "" then "NOT_A_STRING"
          elif (.value.model | type) == "string" then .value.model
          else "NOT_A_STRING" end),
         (if ((.value._comment // "") | type) != "string" then "no"
          elif ((.value._comment // "") | test("TODO")) then "yes"
          else "no" end)]
      | join("\t")' "$config" 2>/dev/null)"; then
    printf 'dev-loop-gate: model-ids: cannot read lanes from %s\n' "$model_ids_config_rel" >&2
    exit 2
  fi

  row Gate Name Status Action
  row ---- ------------------------------ ------ ------

  while IFS="$(printf '\t')" read -r lane index agent model has_todo; do
    [ -n "$lane" ] || continue
    checked=$((checked + 1))
    where="${lane}[${index}] ${agent}"
    case "$model" in
      NULL)
        if [ "$has_todo" != yes ]; then
          row MI "$where" FAIL "null model id without a TODO; add a _comment with TODO saying who confirms the id"
          hits=$((hits + 1))
        fi
        ;;
      NOT_A_STRING)
        row MI "$where" FAIL "model must be an id string or null; use null plus a TODO until the id is confirmed"
        hits=$((hits + 1))
        ;;
      *)
        if ! model_ids_known "$list" "$model"; then
          row MI "$where" FAIL "unverified id $model; add it to $model_ids_list_rel only after a run record or the vendor's model list confirms it, else use null plus a TODO"
          hits=$((hits + 1))
        fi
        ;;
    esac
  done <<EOF_ENTRIES
$entries
EOF_ENTRIES

  if [ "$hits" -gt 0 ]; then
    state=FAIL
  else
    state=PASS
  fi
  row MI model-ids "$state" "$checked entries, $hits hits"

  if [ "$hits" -gt 0 ] && [ "$strict" = 1 ]; then
    return 1
  fi
  return 0
}
