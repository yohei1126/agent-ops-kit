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
model_line_file="${model_line_file:-}"
recorded_id_file="${recorded_id_file:-}"

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

# model_ids_trim <text>: strip surrounding blanks only, never case.
model_ids_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# model_ids_has_token <line> <id>: true when id appears as a whole token,
# bounded by start, end, whitespace, parentheses, or backticks. Letter case must match.
model_ids_has_token() {
  awk -v text="$1" -v id="$2" 'BEGIN {
    if (id == "") exit 1
    start = 1
    while ((i = index(substr(text, start), id)) > 0) {
      pos = start + i - 1
      before = (pos == 1) ? "" : substr(text, pos - 1, 1)
      after = substr(text, pos + length(id), 1)
      if ((before == "" || before == " " || before == "\t" || before == "(" ||
           before == "`") &&
          (after == "" || after == " " || after == "\t" || after == ")" ||
           after == "`")) exit 0
      start = pos + 1
    }
    exit 1
  }'
}

# model_ids_model_lines <file>: print each Model line, leading blanks
# stripped, in file order.
model_ids_model_lines() {
  local file="$1"
  local line trimmed
  while IFS= read -r line || [ -n "$line" ]; do
    trimmed="${line#"${line%%[![:space:]]*}"}"
    case "$trimmed" in
      Model:* | Model/Authors:* | "Model /"*) printf '%s\n' "$trimmed" ;;
    esac
  done <"$file"
}

# model_ids_first_id <file>: the first non-empty, non-comment line, trimmed.
model_ids_first_id() {
  local file="$1"
  local line trimmed
  while IFS= read -r line || [ -n "$line" ]; do
    trimmed="$(model_ids_trim "$line")"
    case "$trimmed" in
      '' | '#'*) continue ;;
    esac
    printf '%s' "$trimmed"
    return 0
  done <"$file"
  return 1
}

# model_ids_configured_matches <line> <entries>: true when the line holds one
# configured non-null id as a whole token.
model_ids_configured_matches() {
  local text="$1"
  local entries="$2"
  local lane index agent model has_todo
  while IFS="$(printf '\t')" read -r lane index agent model has_todo; do
    [ -n "$lane" ] || continue
    case "$model" in
      NULL | NOT_A_STRING) continue ;;
    esac
    if model_ids_has_token "$text" "$model"; then
      return 0
    fi
  done <<EOF_CONFIGURED
$entries
EOF_CONFIGURED
  return 1
}

run_model_ids() {
  local config="$repo/$model_ids_config_rel"
  local list="$repo/$model_ids_list_rel"
  local entries lane index agent model has_todo where
  local checked=0 hits=0 state
  local model_lines model_line_seen expected_id mline

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

  if [ -n "$model_line_file" ]; then
    if [ ! -f "$model_line_file" ]; then
      printf 'dev-loop-gate: model-ids: model-line file not found: %s\n' "$model_line_file" >&2
      exit 2
    fi
    expected_id=""
    if [ -n "$recorded_id_file" ]; then
      if [ ! -f "$recorded_id_file" ]; then
        printf 'dev-loop-gate: model-ids: recorded-id file not found: %s\n' "$recorded_id_file" >&2
        exit 2
      fi
      if ! expected_id="$(model_ids_first_id "$recorded_id_file")"; then
        printf 'dev-loop-gate: model-ids: recorded-id file has no id line: %s\n' "$recorded_id_file" >&2
        exit 2
      fi
    fi
    model_lines="$(model_ids_model_lines "$model_line_file")"
    model_line_seen=0
    while IFS= read -r mline; do
      [ -n "$mline" ] || continue
      model_line_seen=$((model_line_seen + 1))
      if [ -n "$expected_id" ]; then
        if ! model_ids_has_token "$mline" "$expected_id"; then
          row MI "Model line" FAIL "Model line does not name the recorded id $expected_id; copy that id exactly, letter case included"
          hits=$((hits + 1))
        fi
      elif ! model_ids_configured_matches "$mline" "$entries"; then
        row MI "Model line" FAIL "Model line matches no configured model id; copy one from templates/agent-config.example.json exactly, letter case included"
        hits=$((hits + 1))
      fi
    done <<EOF_MODEL_LINES
$model_lines
EOF_MODEL_LINES
    if [ "$model_line_seen" -eq 0 ]; then
      if [ -n "$expected_id" ]; then
        row MI "Model line" FAIL "no Model line found; add a Model line naming $expected_id"
      else
        row MI "Model line" FAIL "no Model line found; add a Model line naming a configured model id"
      fi
      hits=$((hits + 1))
    fi
  fi

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
