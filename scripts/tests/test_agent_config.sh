#!/usr/bin/env bash
# Tests for scripts/lib/agent-config.sh: validation, listing, selection,
# field reads, and label building. Every invalid shape must fail closed.
set -u

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
lib="$repo_root/scripts/lib/agent-config.sh"
example="$repo_root/templates/agent-config.example.json"

pass=0
fail=0
work_tmp="$(mktemp -d)"
trap 'rm -rf "$work_tmp"' EXIT

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/agent-config.sh
. "$lib"

ok() {
  pass=$((pass + 1))
  printf 'PASS %s\n' "$1"
}

bad() {
  fail=$((fail + 1))
  printf 'FAIL %s: %s\n' "$1" "$2"
}

expect_status() {
  if [ "$status" -eq "$2" ]; then
    ok "$1"
  else
    bad "$1" "expected status $2, got $status; stderr: $err"
  fi
}

expect_eq() {
  if [ "$2" = "$3" ]; then
    ok "$1"
  else
    bad "$1" "expected [$3], got [$2]"
  fi
}

expect_err() {
  case "$err" in
    *"$2"*) ok "$1" ;;
    *) bad "$1" "stderr missing: $2; got: $err" ;;
  esac
}

# load <path>: load a config and capture status, stdout, stderr.
load() {
  err_file="$work_tmp/stderr"
  : >"$err_file"
  out=""
  # shellcheck disable=SC2119 # the path comes from AGENT_OPS_KIT_CONFIG
  AGENT_OPS_KIT_CONFIG="$1" agent_config_load 2>"$err_file"
  status=$?
  err="$(cat "$err_file")"
}

test_home="$work_tmp/home"
mkdir -p "$test_home"

base_config='{"schema_version":1,"agents":{"a":{"adapter":"stub","display":"Display A","provider":"Provider A","who_can_launch":"bot","provisioned":true}},"lanes":{"lane":{"entries":[{"agent":"a","model":"model-1","model_name":"Model One"}]}}}'

make_config() {
  local name="$1"
  local filter="$2"
  local path="$work_tmp/$name.json"
  printf '%s\n' "$base_config" | jq "$filter" >"$path"
  printf '%s\n' "$path"
}

printf '== config path ==\n'

out="$(unset AGENT_OPS_KIT_CONFIG; HOME="$test_home"; agent_config_path)"
expect_eq "1: default path lives under HOME" "$out" "$test_home/.config/agent-ops-kit/agents.json"
out="$(AGENT_OPS_KIT_CONFIG=/tmp/override.json agent_config_path)"
expect_eq "1: env var overrides the path" "$out" "/tmp/override.json"

printf '== the example config validates ==\n'

load "$example"
expect_status "2: example config loads" 0

out="$(agent_config_lanes | tr '\n' ' ')"
expect_eq "2: example lanes keep their order" "$out" "coding docs review security-review "
out="$(agent_config_agents | tr '\n' ' ')"
expect_eq "2: example agents are listed" "$out" "goat agy-subscription agy-api-key codex opencode-fireworks cursor "

out="$(agent_config_agent_field goat adapter)"
expect_eq "3: agent field reads adapter" "$out" "goat"
out="$(agent_config_agent_field agy-api-key provisioned)"
expect_eq "3: agent field reads a false boolean" "$out" "false"
out="$(agent_config_lane_entry_field coding 4 model_name)"
expect_eq "3: lane entry field reads model_name" "$out" "Composer 2.5"
out="$(agent_config_lane_entry_field coding 2 mode)"
expect_eq "3: an absent optional mode is empty" "$out" ""

out="$(agent_config_label opencode-fireworks "DeepSeek V4.1 Flash")"
expect_eq "4: label uses model (provider / display)" "$out" \
  "DeepSeek V4.1 Flash (Fireworks / OpenCode)"

printf '== selection and who_can_launch ==\n'

select_test() {
  local name="$1"
  local lane="$2"
  local caller="$3"
  local agent="$4"
  local want_status="$5"
  err_file="$work_tmp/stderr"
  : >"$err_file"
  if [ -n "$agent" ]; then
    out="$(agent_config_select "$lane" "$caller" "$agent" 2>"$err_file")"
  else
    out="$(agent_config_select "$lane" "$caller" 2>"$err_file")"
  fi
  status=$?
  err="$(cat "$err_file")"
  expect_status "$name status" "$want_status"
  if [ "$want_status" = 0 ]; then
    expect_eq "$name agent" "$out" "$agent"
  fi
}

# The fixture config from the example is loaded again for selection.
load "$example"
expect_status "5: reload example for selection" 0

out="$(agent_config_select coding maintainer)"
expect_eq "5: coding maintainer selects the first entry" "$out" "goat"
out="$(agent_config_select coding bot)"
expect_eq "5: coding bot selects the first bot entry" "$out" "goat"
# Lane orders as set by the ops lane on behalf of the maintainer: fixed-quota
# agents first, then prepaid credits, Cursor last (coding only).
out="$(jq -r '[.lanes.coding.entries[].agent] | join(" ")' "$example")"
expect_eq "5: coding lane order puts fixed-quota agents first" "$out" \
  "goat agy-subscription codex opencode-fireworks cursor"
out="$(jq -r '[.lanes.docs.entries[].agent] | join(" ")' "$example")"
expect_eq "5: docs lane order" "$out" "goat agy-subscription opencode-fireworks"
out="$(jq -r '[.lanes.review.entries[].agent] | join(" ")' "$example")"
expect_eq "5: review lane order" "$out" "agy-subscription goat agy-api-key opencode-fireworks"
out="$(jq -r '[.lanes["security-review"].entries[] | .agent + "/" + .model_name] | join(",")' "$example")"
expect_eq "5: security-review lane order" "$out" \
  "agy-subscription/Gemini 4 Carbon,agy-subscription/Claude Opus 5.5 High,agy-api-key/Gemini 4 Carbon,goat/Kimi K3.1 Pro,opencode-fireworks/Kimi K3.1 Pro"
out="$(jq -r '.lanes.coding.entries[1].mode' "$example")"
expect_eq "5: the coding agy entry is an issue hand-off" "$out" "issue"
out="$(jq -r '[.lanes[].entries[] | select(.model == null) | .model_name] | join(",")' "$example")"
expect_eq "5: only the unverified ids are null" "$out" \
  "Gemini 4 Hydrogen,GPT-6 Luna,Composer 2.5,Gemini 4 Hydrogen,Gemini 4 Hydrogen,Claude Opus 5.5 High"
# Ids with a run record, as corrected by the ops lane.
out="$(jq -r '[.lanes.docs.entries[] | select(.agent == "agy-subscription") | .model] | join(",")' "$example")"
expect_eq "5: the docs agy id is the one the launcher ran" "$out" "gemini-3.8-flash-medium"
out="$(jq -r '[.lanes["security-review"].entries[] | select(.model_name == "Gemini 4 Carbon") | .model] | join(",")' "$example")"
expect_eq "5: both security-review Carbon entries use the launcher id" "$out" "gemini-4-carbon-medium,gemini-4-carbon-medium"
out="$(jq -r '[.lanes[].entries[] | select(.agent == "opencode-fireworks" and .model_name == "Kimi K3.1 Pro") | .model] | unique | join(",")' "$example")"
expect_eq "5: every OpenCode Kimi entry uses the Fireworks id" "$out" "fireworks-ai/accounts/fireworks/models/kimi-k3p1-pro"
out="$(jq -r '[.lanes[].entries[] | select(.agent == "opencode-fireworks" and .model_name == "DeepSeek V4.1 Flash") | .model] | unique | join(",")' "$example")"
expect_eq "5: every OpenCode DeepSeek entry uses the Fireworks id" "$out" "fireworks-ai/accounts/fireworks/models/deepseek-v4p1-flash-1017"
out="$(jq -r '[.lanes[].entries[] | select(.model == null) | select((._comment // "") | test("TODO") | not)] | length' "$example")"
expect_eq "5: every null id carries a TODO comment" "$out" "0"
out="$(jq -r '[.. | strings | select(. == "gemini-4-hydrogen")] | length' "$example")"
expect_eq "5: the unrun Hydrogen id appears nowhere" "$out" "0"
out="$(jq -r '[.agents[] | .overages] | unique | join(",")' "$example")"
expect_eq "5: every example agent sets overages never" "$out" "never"
out="$(jq -r '[.. | strings | select(test("gpt-oss"; "i"))] | length' "$example")"
expect_eq "5: the example names no GPT-OSS model" "$out" "0"
out="$(jq -r '[.lanes.docs.entries[], .lanes.review.entries[], .lanes["security-review"].entries[] | .agent | select(. == "cursor" or . == "codex")] | length' "$example")"
expect_eq "5: docs and review lanes have no Cursor or Codex" "$out" "0"
: >"$work_tmp/stderr"
out="$(agent_config_select coding bot codex 2>"$work_tmp/stderr")"
status=$?
err="$(cat "$work_tmp/stderr")"
expect_status "5: codex refuses a bot caller" 4
expect_err "5: codex bot refusal names who_can_launch" "who_can_launch=maintainer"
: >"$work_tmp/stderr"
out="$(agent_config_select coding maintainer codex 2>"$work_tmp/stderr")"
status=$?
err="$(cat "$work_tmp/stderr")"
expect_status "5: codex without an adapter is not provisioned" 4
expect_err "5: codex maintainer refusal says not provisioned" "not provisioned"
out="$(agent_config_select docs bot)"
expect_eq "6: docs bot picks the bot entry" "$out" "goat"
out="$(agent_config_select docs maintainer)"
expect_eq "6: docs maintainer picks the first entry" "$out" "goat"
out="$(agent_config_select review bot)"
expect_eq "6: review bot skips maintainer-only" "$out" "goat"
out="$(agent_config_select security-review bot)"
expect_eq "7: security-review bot skips unprovisioned and maintainer entries" "$out" "goat"
out="$(agent_config_select security-review maintainer)"
expect_eq "7: security-review maintainer picks the first entry" "$out" "agy-subscription"

err_file="$work_tmp/stderr"
: >"$err_file"
out="$(agent_config_select review bot agy-api-key 2>"$err_file")"
status=$?
err="$(cat "$err_file")"
expect_status "8: requested unprovisioned agent is refused" 4
expect_err "8: refusal lists the provisioned reason" "not provisioned"

: >"$err_file"
out="$(agent_config_select coding maintainer cursor 2>"$err_file")"
status=$?
err="$(cat "$err_file")"
expect_status "8: requested agent picks its first eligible entry" 0
expect_eq "8: requested cursor is selected" "$out" "cursor"

: >"$err_file"
out="$(agent_config_select review bot agy-subscription 2>"$err_file")"
status=$?
err="$(cat "$err_file")"
expect_status "9: requested maintainer-only agent refuses a bot" 4
expect_err "9: refusal lists who_can_launch" "who_can_launch=maintainer"

# A maintainer-only entry in issue (hand-off) mode launches nothing, so a bot
# may select it to prepare the task Issue. The same agent in a launching mode
# stays refused (above).
: >"$err_file"
out="$(agent_config_select coding bot agy-subscription 2>"$err_file")"
status=$?
err="$(cat "$err_file")"
expect_status "9: a bot may select a maintainer-only hand-off entry" 0
expect_eq "9: the hand-off entry is the agy seat" "$out" "agy-subscription"
handoff_off="$(make_config handoff-off '.agents.a.who_can_launch="maintainer" | .agents.a.provisioned=false | .lanes.lane.entries[0].mode="issue"')"
load "$handoff_off"
: >"$err_file"
out="$(agent_config_select lane bot 2>"$err_file")"
status=$?
err="$(cat "$err_file")"
expect_status "9: an unprovisioned hand-off entry is still skipped" 4
expect_err "9: the hand-off skip says not provisioned" "not provisioned"
load "$example"

printf '== null model ids, overages ==\n'

null_model="$(make_config null-model '.lanes.lane.entries[0].model=null')"
load "$null_model"
expect_status "21: a null model id (unverified) loads" 0
out="$(agent_config_lane_entry_field lane 0 model)"
expect_eq "21: a null model id reads as empty" "$out" ""
missing_model="$(make_config missing-model 'del(.lanes.lane.entries[0].model)')"
load "$missing_model"
expect_status "21: a missing model key is refused" 3
expect_err "21: the missing-model refusal names the field" "model must be a non-empty string, or null"
empty_model="$(make_config empty-model '.lanes.lane.entries[0].model=""')"
load "$empty_model"
expect_status "21: an empty model id is refused" 3
number_model="$(make_config number-model '.lanes.lane.entries[0].model=5')"
load "$number_model"
expect_status "21: a non-string model id is refused" 3
overages_never="$(make_config overages-never '.agents.a.overages="never"')"
load "$overages_never"
expect_status "21: overages never loads" 0
for bad_value in '"allowed"' '"always"' 'true' 'null'; do
  overages_bad="$(make_config overages-bad '.agents.a.overages='"$bad_value")"
  load "$overages_bad"
  expect_status "21: overages $bad_value is refused" 3
  expect_err "21: overages $bad_value refusal names the rule" "overages must be never"
done
load "$example"

select_test "10: unknown lane" nope bot "" 3
select_test "10: unknown agent" coding bot nope 3
select_test "10: agent not in lane" docs bot codex 3

# An empty lane loads but selects nothing.
empty_lane="$(make_config empty-lane '.lanes.lane.entries=[]')"
load "$empty_lane"
expect_status "10: empty lane config loads" 0
err_file="$work_tmp/stderr"
: >"$err_file"
out="$(agent_config_select lane bot 2>"$err_file")"
status=$?
err="$(cat "$err_file")"
expect_status "10: empty lane has no eligible entry" 4
expect_err "10: empty lane is named" "has no entries"

printf '== invalid shapes fail closed ==\n'

invalid_shape() {
  local name="$1"
  local filter="$2"
  local path
  path="$(make_config "$name" "$filter")"
  load "$path"
  expect_status "11: $name exits 3" 3
  expect_caller_exits_2 "11: $name reaches the caller as exit 2" "$path"
}

# The library returns a distinct status; callers turn it into exit 2.
expect_caller_exits_2() {
  local label="$1"
  local path="$2"
  local caller_status=0
  /bin/bash "$repo_root/scripts/agent-launch.sh" --config "$path" --validate \
    >/dev/null 2>&1 || caller_status=$?
  if [ "$caller_status" -eq 2 ]; then
    ok "$label"
  else
    bad "$label" "expected caller exit 2, got $caller_status"
  fi
}

load "$work_tmp/does-not-exist.json"
expect_status "11: missing config exits 3" 3
expect_caller_exits_2 "11: missing config reaches the caller as exit 2" \
  "$work_tmp/does-not-exist.json"

printf '{not json\n' >"$work_tmp/bad-json.json"
load "$work_tmp/bad-json.json"
expect_status "11: invalid JSON exits 3" 3
expect_caller_exits_2 "11: invalid JSON reaches the caller as exit 2" \
  "$work_tmp/bad-json.json"

# Several top-level JSON values are one invalid config, not several
# configs validated one by one.
printf '%s\n%s\n' "$base_config" "$base_config" >"$work_tmp/multi-doc.json"
load "$work_tmp/multi-doc.json"
expect_status "11: two concatenated JSON documents exit 3" 3
expect_err "11: multi-document error names the rule" "exactly one JSON document"
expect_caller_exits_2 "11: multi-document config reaches the caller as exit 2" \
  "$work_tmp/multi-doc.json"
: >"$work_tmp/empty.json"
load "$work_tmp/empty.json"
expect_status "11: an empty file exits 3" 3

# A trailing newline must not slip past the token rule.
invalid_shape adapter-trailing-newline '.agents.a.adapter = "stub\n"'
invalid_shape mode-trailing-newline '.lanes.lane.entries[0].mode = "docs\n"'
invalid_shape adapter-leading-newline '.agents.a.adapter = "\nstub"'

invalid_shape schema-two '.schema_version = 2'
invalid_shape schema-string '.schema_version = "1"'
invalid_shape agents-not-object '.agents = []'
invalid_shape lanes-not-object '.lanes = []'
invalid_shape adapter-uppercase '.agents.a.adapter = "Agy"'
invalid_shape adapter-slash '.agents.a.adapter = "a/b"'
invalid_shape who-invalid '.agents.a.who_can_launch = "operator"'
invalid_shape provisioned-string '.agents.a.provisioned = "true"'
invalid_shape display-empty '.agents.a.display = ""'
invalid_shape provider-missing 'del(.agents.a.provider)'
invalid_shape agent-unknown-field '.agents.a.extra = 1'
invalid_shape lane-not-object '.lanes.lane = []'
invalid_shape entries-not-array '.lanes.lane.entries = {}'
invalid_shape undefined-agent '.lanes.lane.entries[0].agent = "missing"'
invalid_shape model-empty '.lanes.lane.entries[0].model = ""'
invalid_shape model-name-missing 'del(.lanes.lane.entries[0].model_name)'
invalid_shape mode-invalid '.lanes.lane.entries[0].mode = "Docs Mode"'
invalid_shape entry-unknown-field '.lanes.lane.entries[0].extra = 1'
invalid_shape top-level-unknown '.extra = 1'
invalid_shape lane-comment-number '.lanes.lane._comment = 1'

# Lane and agent names are tokens: a tab or newline in a name could shift
# the delimited rows agent-launch --validate reads.
invalid_shape lane-name-tab '.lanes = {"la\tne": .lanes.lane}'
invalid_shape lane-name-newline '.lanes = {"la\nne": .lanes.lane}'
invalid_shape lane-name-trailing-newline '.lanes = {"lane\n": .lanes.lane}'
invalid_shape lane-name-uppercase '.lanes = {"Lane": .lanes.lane}'
invalid_shape agent-name-tab '.agents = {"a\tb": .agents.a} | .lanes.lane.entries[0].agent = "a\tb"'
invalid_shape agent-name-newline '.agents = {"a\nb": .agents.a} | .lanes.lane.entries[0].agent = "a\nb"'

printf '== explicit empty path ==\n'

err_file="$work_tmp/stderr"
: >"$err_file"
AGENT_OPS_KIT_CONFIG="$example" agent_config_load "" 2>"$err_file"
status=$?
err="$(cat "$err_file")"
expect_status "13: an explicit empty path exits 3 even with the env var set" 3
expect_err "13: explicit empty path error is explicit" "config path is empty"

printf '== validation error output ==\n'

load "$(make_config bad-who '.agents.a.who_can_launch = "operator"')"
expect_status "12: invalid who_can_launch exits 3" 3
expect_err "12: error names the field" "who_can_launch must be maintainer or bot"

load "$(make_config bad-agent '.lanes.lane.entries[0].agent = "missing"')"
expect_err "12: undefined agent error is explicit" "is not a defined agent"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -ne 0 ]; then
  exit 1
fi
exit 0
