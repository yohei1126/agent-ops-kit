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
expect_eq "2: example agents are listed" "$out" "agy-subscription agy-api-key goat opencode-fireworks codex cursor "

out="$(agent_config_agent_field goat adapter)"
expect_eq "3: agent field reads adapter" "$out" "goat"
out="$(agent_config_agent_field agy-api-key provisioned)"
expect_eq "3: agent field reads a false boolean" "$out" "false"
out="$(agent_config_lane_entry_field coding 4 model_name)"
expect_eq "3: lane entry field reads model_name" "$out" "Composer 2.5"
out="$(agent_config_lane_entry_field coding 1 mode)"
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
expect_eq "5: coding maintainer selects the first entry" "$out" "agy-subscription"
out="$(agent_config_select coding bot)"
expect_eq "5: coding bot skips the maintainer-only entry" "$out" "goat"
out="$(agent_config_select docs bot)"
expect_eq "6: docs bot picks the bot entry" "$out" "goat"
out="$(agent_config_select docs maintainer)"
expect_eq "6: docs maintainer picks the first entry" "$out" "agy-subscription"
out="$(agent_config_select review bot)"
expect_eq "6: review bot skips maintainer-only" "$out" "goat"
out="$(agent_config_select security-review bot)"
expect_eq "7: security-review bot skips unprovisioned and maintainer entries" "$out" "opencode-fireworks"
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
out="$(agent_config_select coding bot cursor 2>"$err_file")"
status=$?
err="$(cat "$err_file")"
expect_status "9: requested maintainer-only agent refuses a bot" 4
expect_err "9: refusal lists who_can_launch" "who_can_launch=maintainer"

select_test "10: unknown lane" nope bot "" 3
select_test "10: unknown agent" coding bot nope 3
select_test "10: agent not in lane" coding bot codex 3

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
