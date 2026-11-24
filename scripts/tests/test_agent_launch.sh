#!/usr/bin/env bash
# Tests for scripts/agent-launch.sh: usage and config errors, who_can_launch
# for both callers, provisioned refusal, --agent selection, lane order,
# --dry-run output, missing adapters, and source hygiene.
#
# A copied scripts tree gives the test stub adapters. A stub `agy` is first on
# PATH and the test asserts it resolves before any launch; no real agent runs.
set -u

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
launcher="$repo_root/scripts/agent-launch.sh"

pass=0
fail=0
work_tmp="$(mktemp -d)"
trap 'rm -rf "$work_tmp"' EXIT

test_home="$work_tmp/home"
mkdir -p "$test_home"

fake_bin="$work_tmp/bin"
mkdir -p "$fake_bin"
cat >"$fake_bin/agy" <<'SH'
#!/bin/sh
# The stub agent must never run in this test; it records any start.
if [ -n "${FAKE_AGY_RECORD:-}" ]; then
  printf 'agy started\n' >>"$FAKE_AGY_RECORD"
fi
exit 99
SH
chmod +x "$fake_bin/agy"

# Closed PATH: the stub directory plus a private directory of symlinks to the
# utilities the entry point and adapters need, never agy or caffeinate. Every
# entry-point invocation below uses exactly this PATH.
tool_bin="$work_tmp/tool-bin"
mkdir -p "$tool_bin"
for cmd in bash jq tr mkdir kill cp mv cat uname mktemp sed wc rm ln \
  readlink realpath dirname basename chmod date head env nohup tee cut \
  sort uniq touch sleep grep find ls; do
  cmd_path="$(command -v "$cmd" 2>/dev/null)" || continue
  case "$cmd_path" in
    '' | */agy | */caffeinate | "$fake_bin"/*) continue ;;
    /*) ;;
    *) continue ;;
  esac
  ln -s "$cmd_path" "$tool_bin/$cmd"
done
test_path="$fake_bin:$tool_bin"

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
    bad "$1" "expected exit $2, got $status; stderr: $err"
  fi
}

expect_out() {
  case "$out" in
    *"$2"*) ok "$1" ;;
    *) bad "$1" "stdout missing: $2" ;;
  esac
}

expect_no_out() {
  case "$out" in
    *"$2"*) bad "$1" "stdout should not contain: $2" ;;
    *) ok "$1" ;;
  esac
}

expect_err() {
  case "$err" in
    *"$2"*) ok "$1" ;;
    *) bad "$1" "stderr missing: $2; got: $err" ;;
  esac
}

expect_record_line() {
  if grep -qxF -- "$2" "$record" 2>/dev/null; then
    ok "$1"
  else
    bad "$1" "adapter argv missing: $2"
  fi
}

expect_record_empty() {
  if [ -s "$record" ]; then
    bad "$1" "stub adapter was invoked"
  else
    ok "$1"
  fi
}

# The only agy on the test PATH must be the stub.
resolved="$(PATH="$test_path" command -v agy)"
if [ "$resolved" = "$fake_bin/agy" ]; then
  ok "0: command -v agy resolves to the stub"
else
  bad "0: command -v agy resolves to the stub" "got: $resolved"
fi

case "$(PATH="$test_path" command -v jq)" in
  "$tool_bin"/*) ok "0: the closed PATH resolves tools from the controlled directory" ;;
  *) bad "0: the closed PATH resolves tools from the controlled directory" "jq not in $tool_bin" ;;
esac
if PATH="$test_path" command -v caffeinate >/dev/null 2>&1; then
  bad "0: caffeinate is not on the closed PATH" "found"
else
  ok "0: caffeinate is not on the closed PATH"
fi

# Copied scripts tree with stub adapters.
kit="$work_tmp/kit"
mkdir -p "$kit/scripts/lib" "$kit/scripts/agents/stub" \
  "$kit/scripts/agents/broken" "$kit/scripts/agents/noexec"
cp "$launcher" "$kit/scripts/agent-launch.sh"
cp "$repo_root/scripts/lib/agent-config.sh" "$kit/scripts/lib/"

cat >"$kit/scripts/agents/stub/run" <<'SH'
#!/usr/bin/env bash
set -u
if [ -n "${STUB_ADAPTER_RECORD:-}" ]; then
  {
    printf 'ARGV_START\n'
    for arg in "$@"; do
      printf '%s\n' "$arg"
    done
    printf 'ARGV_END\n'
  } >>"$STUB_ADAPTER_RECORD"
fi
printf 'ADAPTER_STDOUT\n'
exit "${STUB_ADAPTER_EXIT:-0}"
SH
chmod +x "$kit/scripts/agents/stub/run"

# stubmode: the same stub, but it declares the modes it accepts.
mkdir -p "$kit/scripts/agents/stubmode"
cp "$kit/scripts/agents/stub/run" "$kit/scripts/agents/stubmode/run"
chmod +x "$kit/scripts/agents/stubmode/run"
printf '# test modes\ndocs\nreview\n' >"$kit/scripts/agents/stubmode/modes"

# broken: directory without run. noexec: run without the executable bit.
printf '#!/usr/bin/env bash\nexit 0\n' >"$kit/scripts/agents/noexec/run"
chmod -x "$kit/scripts/agents/noexec/run"

valid_config="$work_tmp/agents.json"
cat >"$valid_config" <<'JSON'
{
  "schema_version": 1,
  "agents": {
    "bot-agent": {
      "adapter": "stub",
      "display": "Stub",
      "provider": "Provider X",
      "who_can_launch": "bot",
      "provisioned": true
    },
    "human-agent": {
      "adapter": "stubmode",
      "display": "Human",
      "provider": "Provider X",
      "who_can_launch": "maintainer",
      "provisioned": true
    },
    "unready-agent": {
      "adapter": "stub",
      "display": "Unready",
      "provider": "Provider X",
      "who_can_launch": "bot",
      "provisioned": false
    },
    "missing-agent": {
      "adapter": "absent",
      "display": "Absent",
      "provider": "Provider X",
      "who_can_launch": "bot",
      "provisioned": true
    },
    "broken-agent": {
      "adapter": "broken",
      "display": "Broken",
      "provider": "Provider X",
      "who_can_launch": "bot",
      "provisioned": true
    },
    "noexec-agent": {
      "adapter": "noexec",
      "display": "Noexec",
      "provider": "Provider X",
      "who_can_launch": "bot",
      "provisioned": true
    }
  },
  "lanes": {
    "mix": {
      "entries": [
        {"agent": "human-agent", "model": "human-model", "model_name": "Human One", "mode": "docs"},
        {"agent": "bot-agent", "model": "bot-model", "model_name": "Bot One"},
        {"agent": "unready-agent", "model": "unready-model", "model_name": "Unready One"}
      ]
    },
    "botonly": {
      "entries": [
        {"agent": "bot-agent", "model": "bot-model", "model_name": "Bot One"}
      ]
    },
    "humanonly": {
      "entries": [
        {"agent": "human-agent", "model": "human-model", "model_name": "Human One", "mode": "docs"}
      ]
    },
    "unready": {
      "entries": [
        {"agent": "unready-agent", "model": "unready-model", "model_name": "Unready One"}
      ]
    },
    "empty": {
      "entries": []
    },
    "missing": {
      "entries": [
        {"agent": "missing-agent", "model": "missing-model", "model_name": "Missing One"}
      ]
    },
    "broken": {
      "entries": [
        {"agent": "broken-agent", "model": "broken-model", "model_name": "Broken One"}
      ]
    },
    "noexec": {
      "entries": [
        {"agent": "noexec-agent", "model": "noexec-model", "model_name": "Noexec One"}
      ]
    },
    "ordered": {
      "entries": [
        {"agent": "bot-agent", "model": "first-model", "model_name": "First One"},
        {"agent": "bot-agent", "model": "second-model", "model_name": "Second One"}
      ]
    }
  }
}
JSON

bad_json="$work_tmp/bad-json.json"
printf '{not json\n' >"$bad_json"
schema_two="$work_tmp/schema-two.json"
jq '.schema_version = 2' "$valid_config" >"$schema_two"
missing_model="$work_tmp/missing-model.json"
jq '.lanes.botonly.entries[0].model = ""' "$valid_config" >"$missing_model"
missing_config="$work_tmp/missing.json"

TEST_CONFIG="$valid_config"
out=""
err=""
status=0
record="$work_tmp/record-none"
: >"$record"

run_launch() {
  local tag="$1"
  shift
  err_file="$work_tmp/err-$tag"
  record="$work_tmp/record-$tag"
  : >"$record"
  rm -f "$record.task"
  out="$(AGENT_OPS_KIT_CONFIG="$TEST_CONFIG" HOME="$test_home" \
    PATH="$test_path" STUB_ADAPTER_RECORD="$record" \
    STUB_ADAPTER_EXIT="${STUB_ADAPTER_EXIT:-0}" FAKE_AGY_RECORD="$record" \
    STUB_TASK_RECORD="$record.task" \
    /bin/bash "$kit/scripts/agent-launch.sh" "$@" 2>"$err_file")"
  status=$?
  err="$(cat "$err_file")"
}

printf '== help, validate, and list ==\n'

run_launch help --help
expect_status "1: --help exits 0" 0
expect_out "1: help prints usage" "Usage:"
expect_out "1: help is generated from the flag table" "--lane <lane>"
expect_out "1: help appends lane names from the config" "mix"
expect_out "1: help appends agent names from the config" "bot-agent"
expect_out "1: help lists --pr for the preflight" "--pr <number>"
expect_out "1: help lists --expect-head for the preflight" "--expect-head <sha>"
expect_out "1: help describes the review-ready preflight" "preflight"

TEST_CONFIG="$valid_config"
run_launch help-config --config "$valid_config" --help
expect_status "1: --help with an explicit config exits 0" 0
expect_out "1: explicit config help lists lanes" "ordered"

TEST_CONFIG="$missing_config"
run_launch help-noconfig --help
expect_status "1: --help without a config still exits 0" 0
expect_out "1: help still prints usage" "Usage:"
expect_no_out "1: no config, no lane listing" "bot-agent"

run_launch validate --config "$valid_config" --validate
expect_status "2: --validate accepts a valid config" 0
expect_out "2: --validate prints the config path" "CONFIG=$valid_config"
expect_out "2: --validate prints VALID=1" "VALID=1"

run_launch validate-bad --config "$bad_json" --validate
expect_status "2: --validate rejects invalid JSON" 2

multi_doc="$work_tmp/multi-doc.json"
cat "$valid_config" "$valid_config" >"$multi_doc"
run_launch validate-multi --config "$multi_doc" --validate
expect_status "2: --validate rejects two concatenated JSON documents" 2
expect_no_out "2: a multi-document config never prints VALID=1" "VALID=1"

run_launch validate-schema --config "$schema_two" --validate
expect_status "2: --validate rejects an unknown schema version" 2

run_launch list --config "$valid_config" --list
expect_status "3: --list exits 0" 0
expect_out "3: --list prints LANES" "LANES"
expect_out "3: --list prints AGENTS" "AGENTS"
expect_out "3: --list prints a lane" "botonly"
expect_out "3: --list prints an agent" "human-agent"

run_launch validate-combined --validate --lane mix
expect_status "3: --validate rejects launch flags" 2

# --config overrides AGENT_OPS_KIT_CONFIG.
TEST_CONFIG="$missing_config"
run_launch config-override --config "$valid_config" --lane botonly --as bot --dry-run --
expect_status "4: --config overrides the environment path" 0
expect_out "4: config override selects the entry" "AGENT=bot-agent"

printf '== usage and config errors ==\n'

TEST_CONFIG="$missing_config"
run_launch missing --lane mix --as bot
expect_status "5: missing config exits 2" 2
expect_err "5: missing config is named" "config file not found"

TEST_CONFIG="$bad_json"
run_launch badjson --lane mix --as bot
expect_status "5: invalid JSON exits 2" 2
expect_err "5: invalid JSON is named" "not valid JSON"

TEST_CONFIG="$schema_two"
run_launch schema --lane mix --as bot
expect_status "5: unknown schema exits 2" 2
expect_err "5: schema error is named" "schema_version must be 1"

run_launch missing-model --config "$missing_model" --lane botonly --as bot
expect_status "5: a missing model exits 2" 2
expect_err "5: missing model is named" "model must be a non-empty string"

TEST_CONFIG="$valid_config"
run_launch no-lane --as bot
expect_status "6: missing --lane exits 2" 2
expect_err "6: missing --lane is explained" "missing --lane"

run_launch no-as --lane mix
expect_status "6: missing --as exits 2" 2
expect_err "6: missing --as is explained" "missing --as"

run_launch bad-as --lane mix --as everyone
expect_status "6: invalid --as exits 2" 2

run_launch unknown-flag --lane mix --as bot --nope
expect_status "6: unknown flag exits 2" 2

run_launch missing-value --lane
expect_status "6: missing flag value exits 2" 2
expect_err "6: missing value is explained" "missing value for --lane"

run_launch positional mix bot
expect_status "6: positional arguments exit 2" 2

run_launch unknown-lane --lane nope --as bot
expect_status "7: unknown lane exits 2" 2
expect_err "7: unknown lane is named" "unknown lane"

run_launch unknown-agent --lane mix --as bot --agent nope
expect_status "7: unknown agent exits 2" 2
expect_err "7: unknown agent is named" "unknown agent"

run_launch agent-not-in-lane --lane botonly --as bot --agent human-agent
expect_status "7: agent outside the lane exits 2" 2
expect_err "7: agent outside the lane is named" "is not in lane"

printf '== who_can_launch and provisioned ==\n'

run_launch humanonly-bot --lane humanonly --as bot --dry-run --
expect_status "8: maintainer-only agent refuses a bot" 2
expect_err "8: refusal lists who_can_launch" "who_can_launch=maintainer"

run_launch unready-bot --lane unready --as bot --dry-run --
expect_status "8: unprovisioned agent is refused" 2
expect_err "8: refusal lists the provisioned reason" "not provisioned"

run_launch empty-lane --lane empty --as bot --dry-run --
expect_status "8: an empty lane refuses" 2
expect_err "8: empty lane is named" "has no entries"

run_launch botonly-bot --lane botonly --as bot --dry-run --
expect_status "9: a bot agent allows a bot" 0
expect_out "9: bot caller selects the bot agent" "AGENT=bot-agent"

run_launch botonly-maintainer --lane botonly --as maintainer --dry-run --
expect_status "9: a bot agent allows the maintainer" 0
expect_out "9: maintainer selects the bot agent" "AGENT=bot-agent"
expect_record_empty "9: maintainer dry-run starts no adapter"

run_launch humanonly-maintainer --lane humanonly --as maintainer --dry-run --
expect_status "9: a maintainer agent allows the maintainer" 0
expect_out "9: maintainer selects the maintainer agent" "AGENT=human-agent"

printf '== lane order and --agent ==\n'

run_launch mix-bot --lane mix --as bot --dry-run --
expect_status "10: bot skips the maintainer entry" 0
expect_out "10: bot takes the first eligible entry" "AGENT=bot-agent"

run_launch mix-maintainer --lane mix --as maintainer --dry-run --
expect_status "10: maintainer takes the first entry" 0
expect_out "10: maintainer keeps lane order" "AGENT=human-agent"

run_launch mix-agent --lane mix --as maintainer --agent bot-agent --dry-run --
expect_status "10: --agent picks a later entry" 0
expect_out "10: --agent selection wins over lane order" "AGENT=bot-agent"

run_launch ordered-first --lane ordered --as bot --dry-run --
expect_status "11: lane order picks the first entry" 0
expect_out "11: first entry model is selected" "MODEL=first-model"

run_launch ordered-agent --lane ordered --as bot --agent bot-agent --dry-run --
expect_status "11: --agent picks the first entry for that agent" 0
expect_out "11: first entry for the agent is selected" "MODEL=first-model"

printf '== dry-run output ==\n'

run_launch dry --lane botonly --as bot --dry-run -- repo brief
expect_status "12: --dry-run exits 0" 0
expect_out "12: dry-run prints AGENT" "AGENT=bot-agent"
expect_out "12: dry-run prints ADAPTER" "ADAPTER=stub"
expect_out "12: dry-run prints MODEL" "MODEL=bot-model"
expect_out "12: dry-run prints the label" "LABEL=Bot One (Provider X / Stub)"
expect_out "12: dry-run prints the exact command" "COMMAND="
expect_out "12: command names the adapter run script" "$kit/scripts/agents/stub/run"
expect_record_empty "12: dry-run does not start the adapter"

case "$out" in
  *"COMMAND="*"--mode"*) ok "12: no mode means no --mode flag" ;;
  *) bad "12: no mode means no --mode flag" "stdout: $out" ;;
esac

run_launch dry-mode --lane humanonly --as maintainer --dry-run -- repo brief
expect_status "12: mode dry-run exits 0" 0
expect_out "12: mode is passed to the adapter" "--mode docs"

printf '== adapter launch and failures ==\n'

run_launch launch-bot --lane botonly --as bot -- repo brief
expect_status "13: adapter launch exits 0" 0
expect_out "13: adapter stdout passes through" "ADAPTER_STDOUT"
expect_record_line "13: adapter receives --model" "--model"
expect_record_line "13: adapter receives the model id" "bot-model"
expect_record_line "13: adapter receives the separator" "--"
expect_record_line "13: adapter receives the first launcher arg" "repo"
expect_record_line "13: adapter receives the second launcher arg" "brief"

run_launch launch-mode --lane humanonly --as maintainer -- repo brief
expect_status "13: adapter launch with a mode exits 0" 0
expect_record_line "13: mode is forwarded" "--mode"
expect_record_line "13: mode value is forwarded" "docs"

STUB_ADAPTER_EXIT=7
run_launch launch-fail --lane botonly --as bot -- repo brief
STUB_ADAPTER_EXIT=0
expect_status "14: adapter failure status passes through" 7

run_launch missing-adapter --lane missing --as bot --dry-run --
expect_status "14: a missing adapter directory exits 2" 2
expect_err "14: missing adapter is named" "is not installed"

run_launch broken-adapter --lane broken --as bot --dry-run --
expect_status "14: an adapter without run exits 2" 2
expect_err "14: missing run is named" "has no executable run"

run_launch noexec-adapter --lane noexec --as bot --dry-run --
expect_status "14: a non-executable run exits 2" 2
expect_err "14: non-executable run is named" "has no executable run"

printf '== entry modes must match the adapter ==\n'

# Each case is a config the library accepts, but the selected adapter would
# refuse; agent-launch must refuse it with exit 2 before the adapter starts.
mode_cases="$work_tmp/mode-cases"
mkdir -p "$mode_cases"
jq '.lanes.humanonly.entries[0].mode = "coding"' "$valid_config" >"$mode_cases/unlisted.json"
jq 'del(.lanes.humanonly.entries[0].mode)' "$valid_config" >"$mode_cases/missing.json"
jq '.lanes.botonly.entries[0].mode = "docs"' "$valid_config" >"$mode_cases/unexpected.json"

TEST_CONFIG="$mode_cases/unlisted.json"
run_launch mode-unlisted --lane humanonly --as maintainer -- repo brief
expect_status "17: a mode the adapter does not list exits 2" 2
expect_err "17: unlisted mode refusal names the supported modes" "supports only: docs review"
expect_record_empty "17: unlisted mode never starts the adapter"
run_launch mode-unlisted-validate --validate
expect_status "17: --validate rejects an unlisted mode" 2

TEST_CONFIG="$mode_cases/missing.json"
run_launch mode-missing --lane humanonly --as maintainer -- repo brief
expect_status "17: a missing mode for a moded adapter exits 2" 2
expect_err "17: missing mode refusal says one is needed" "needs one of: docs review"
expect_record_empty "17: missing mode never starts the adapter"
run_launch mode-missing-validate --validate
expect_status "17: --validate rejects a missing mode" 2

TEST_CONFIG="$mode_cases/unexpected.json"
run_launch mode-unexpected --lane botonly --as bot --dry-run -- repo brief
expect_status "17: a mode for an adapter without modes exits 2" 2
expect_err "17: unexpected mode refusal says the adapter takes none" "takes no mode"
run_launch mode-unexpected-validate --validate
expect_status "17: --validate rejects a mode for an adapter without modes" 2
TEST_CONFIG="$valid_config"

printf '== lane names cannot shift --validate rows ==\n'

# A lane name holding a tab or newline once shifted the delimited rows, so an
# invalid mode for an installed adapter was skipped and VALID=1 printed.
shift_cases="$work_tmp/shift-cases"
mkdir -p "$shift_cases"
jq '.lanes = {"x\thumanonly": {"entries": [{"agent": "human-agent", "model": "m", "model_name": "M", "mode": "coding"}]}}' \
  "$valid_config" >"$shift_cases/tab.json"
jq '.lanes = {"x\nhumanonly": {"entries": [{"agent": "human-agent", "model": "m", "model_name": "M", "mode": "coding"}]}}' \
  "$valid_config" >"$shift_cases/newline.json"
for case_name in tab newline; do
  TEST_CONFIG="$shift_cases/$case_name.json"
  run_launch "shift-$case_name" --validate
  expect_status "18: a lane name with a $case_name fails --validate" 2
  expect_no_out "18: a lane name with a $case_name never prints VALID=1" "VALID=1"
  expect_err "18: the $case_name lane name refusal names the rule" "must match [a-z0-9-]+"
done
TEST_CONFIG="$valid_config"

printf '== explicit empty --config and extra arguments ==\n'

# AGENT_OPS_KIT_CONFIG points at a valid config, so a fallback would succeed.
TEST_CONFIG="$valid_config"
run_launch config-empty-validate --config "" --validate
expect_status "19: --config \"\" --validate exits 2" 2
expect_no_out "19: --config \"\" never validates the env config" "VALID=1"
expect_err "19: --config \"\" refusal is explicit" "non-empty path"
run_launch config-empty-list --config "" --list
expect_status "19: --config \"\" --list exits 2" 2
run_launch config-empty-help --config "" --help
expect_status "19: --config \"\" --help exits 2" 2
run_launch config-empty-launch --config "" --lane botonly --as bot -- repo brief
expect_status "19: --config \"\" launch exits 2" 2
expect_record_empty "19: --config \"\" launch never starts the adapter"

run_launch validate-extra --validate -- extra
expect_status "20: --validate rejects arguments after --" 2
expect_no_out "20: --validate with extra arguments never prints VALID=1" "VALID=1"
expect_err "20: --validate extra-argument refusal is explicit" "takes no arguments after --"
run_launch list-extra --list -- extra
expect_status "20: --list rejects arguments after --" 2
expect_no_out "20: --list with extra arguments prints no listing" "LANES"
run_launch help-extra --help -- extra
expect_status "20: --help rejects arguments after --" 2
run_launch validate-bare-sep --validate --
expect_status "20: --validate with a bare -- still exits 0" 0

printf '== issue hand-off entries ==\n'

# An issue-mode entry never runs its adapter or the agent. It becomes an
# agent-task-issue.sh command; the stub below records what would be created.
mkdir -p "$kit/scripts/agents/stubissue"
cp "$kit/scripts/agents/stub/run" "$kit/scripts/agents/stubissue/run"
chmod +x "$kit/scripts/agents/stubissue/run"
printf '# test modes\nreview\nissue\n' >"$kit/scripts/agents/stubissue/modes"
cat >"$kit/scripts/agent-task-issue.sh" <<'SH'
#!/usr/bin/env bash
set -u
{
  printf 'TASK_START\n'
  for arg in "$@"; do
    printf '%s\n' "$arg"
  done
  printf 'TASK_END\n'
} >>"${STUB_TASK_RECORD:-/dev/null}"
printf 'TASK_STDOUT\n'
SH
chmod +x "$kit/scripts/agent-task-issue.sh"
handoff_config="$work_tmp/handoff.json"
jq '.agents["handoff-agent"] = {"adapter": "stubissue", "display": "Handoff", "provider": "Provider X", "who_can_launch": "maintainer", "provisioned": true, "overages": "never"}
  | .agents["handoff-off"] = {"adapter": "stubissue", "display": "Handoff", "provider": "Provider X", "who_can_launch": "maintainer", "provisioned": false}
  | .lanes.handoff = {"entries": [
      {"agent": "handoff-agent", "model": "handoff-model", "model_name": "Handoff One", "mode": "issue"},
      {"agent": "bot-agent", "model": "bot-model", "model_name": "Bot One"}]}
  | .lanes.handoffreview = {"entries": [
      {"agent": "handoff-agent", "model": "handoff-model", "model_name": "Handoff One", "mode": "review"}]}
  | .lanes.handoffoff = {"entries": [
      {"agent": "handoff-off", "model": "handoff-model", "model_name": "Handoff One", "mode": "issue"}]}
  | .lanes.handoffnull = {"entries": [
      {"agent": "handoff-agent", "model": null, "model_name": "Handoff One", "mode": "issue"}]}
  | .lanes.reviewnull = {"entries": [
      {"agent": "handoff-agent", "model": null, "model_name": "Handoff One", "mode": "review"}]}
  | .lanes.nullmodel = {"entries": [
      {"agent": "bot-agent", "model": null, "model_name": "Unverified One"},
      {"agent": "unready-agent", "model": "unready-model", "model_name": "Unready One"}]}' \
  "$valid_config" >"$handoff_config"
TEST_CONFIG="$handoff_config"

expect_task_empty() {
  if [ -s "$record.task" ]; then
    bad "$1" "agent-task-issue.sh was run"
  else
    ok "$1"
  fi
}

run_launch handoff-validate --validate
expect_status "22: a config with an issue hand-off entry validates" 0
expect_out "22: hand-off validation reports VALID=1" "VALID=1"

run_launch handoff-bot-dry --lane handoff --as bot --dry-run -- --title "Task" --file brief.md
expect_status "22: bot --dry-run on a hand-off entry exits 0" 0
expect_out "22: hand-off dry-run selects the maintainer-only hand-off entry" "AGENT=handoff-agent"
expect_out "22: hand-off dry-run reports issue mode" "HANDOFF=issue"
expect_out "22: hand-off dry-run prints the agent-task-issue.sh command" 'agent-task-issue.sh --agent stubissue --model Handoff\ One\ \(handoff-model\) --title Task --file brief.md'
expect_record_empty "22: hand-off dry-run never runs the adapter or the agent"
expect_task_empty "22: hand-off dry-run does not run agent-task-issue.sh"

run_launch handoff-bot-run --lane handoff --as bot -- --title "Task" --file brief.md
expect_status "22: a bot without --dry-run is refused on a hand-off entry" 2
expect_err "22: the bot refusal names the hand-off" "is an issue hand-off: a bot never runs it"
expect_err "22: the bot refusal points at --dry-run" "Re-run with --dry-run"
expect_record_empty "22: the bot refusal never runs the adapter or the agent"
expect_task_empty "22: the bot refusal does not run agent-task-issue.sh"

run_launch handoff-maint-run --lane handoff --as maintainer -- --title "Task" --file brief.md
expect_status "22: the maintainer runs the hand-off command" 0
expect_out "22: the maintainer run reaches agent-task-issue.sh" "TASK_STDOUT"
expect_record_empty "22: the maintainer run never runs the adapter or the agent"
for want in --agent stubissue --model "Handoff One (handoff-model)" --title Task --file brief.md; do
  if grep -qxF -- "$want" "$record.task" 2>/dev/null; then
    ok "22: agent-task-issue.sh receives $want"
  else
    bad "22: agent-task-issue.sh receives $want" "$(cat "$record.task" 2>/dev/null)"
  fi
done

for config_flag in --agent --agent=x --model --model=x; do
  run_launch "handoff-flag$config_flag" --lane handoff --as bot --dry-run -- "$config_flag" other
  expect_status "22: $config_flag after -- is refused for a hand-off entry" 2
  expect_err "22: the $config_flag refusal says it comes from the config" "comes from the config"
done

run_launch handoff-review --lane handoffreview --as bot --dry-run -- run repo brief
expect_status "22: the same maintainer-only agent in review mode refuses a bot" 2
expect_err "22: the review-mode refusal names who_can_launch" "who_can_launch=maintainer"
expect_record_empty "22: the review-mode refusal runs nothing"

run_launch handoff-off --lane handoffoff --as bot --dry-run -- --title Task
expect_status "22: an unprovisioned hand-off entry is skipped" 2
expect_err "22: the unprovisioned hand-off skip says not provisioned" "not provisioned"

printf '%s\n' '{"schema_version":1,"agents":{"a":{"adapter":"stub","display":"A","provider":"P","who_can_launch":"maintainer","provisioned":true}},"lanes":{"l":{"entries":[{"agent":"a","model":"m","model_name":"M","mode":"issue"}]}}}' \
  >"$work_tmp/handoff-nomodes.json"
TEST_CONFIG="$work_tmp/handoff-nomodes.json"
run_launch handoff-nomodes --validate
expect_status "22: issue mode on an adapter that does not list it fails --validate" 2
expect_err "22: the unlisted issue mode is named" "takes no mode"
TEST_CONFIG="$handoff_config"

printf '== null model ids fail closed ==\n'

# A hand-off entry executes no model, so a null id is allowed there and the
# Issue gets the model name marked "id unverified".
run_launch handoffnull-dry --lane handoffnull --as bot --dry-run -- --title Task
expect_status "23: a null-id hand-off entry dry-runs" 0
expect_out "23: the null-id hand-off reports MODEL=null" "MODEL=null"
expect_out "23: the null-id hand-off marks the id unverified" 'agent-task-issue.sh --agent stubissue --model Handoff\ One\ \(id\ unverified\) --title Task'
expect_record_empty "23: the null-id hand-off dry-run runs nothing"
run_launch handoffnull-run --lane handoffnull --as maintainer -- --title Task
expect_status "23: the maintainer runs a null-id hand-off" 0
if grep -qxF -- "Handoff One (id unverified)" "$record.task" 2>/dev/null; then
  ok "23: agent-task-issue.sh receives the id-unverified model text"
else
  bad "23: agent-task-issue.sh receives the id-unverified model text" "$(cat "$record.task" 2>/dev/null)"
fi
expect_record_empty "23: the null-id hand-off never runs the adapter or the agent"
run_launch handoffnull-bot --lane handoffnull --as bot -- --title Task
expect_status "23: a bot without --dry-run is still refused on a null-id hand-off" 2
expect_err "23: the null-id bot refusal names the hand-off" "issue hand-off"
# Any other mode still fails closed on a null id.
run_launch reviewnull-dry --lane reviewnull --as maintainer --dry-run -- run repo brief
expect_status "23: a null id in review mode exits 2" 2
expect_err "23: the review-mode null refusal says unverified" "null model id (unverified)"
expect_record_empty "23: the review-mode null id runs nothing"

run_launch nullmodel-validate --validate
expect_status "23: --validate accepts a null model id" 0
run_launch nullmodel-dry --lane nullmodel --as bot --dry-run -- repo brief
expect_status "23: selecting a null model id exits 2" 2
expect_err "23: the null-model refusal says the id is unverified" "null model id (unverified)"
expect_no_out "23: a null model id prints no command" "COMMAND="
run_launch nullmodel-run --lane nullmodel --as bot -- repo brief
expect_status "23: launching a null model id exits 2" 2
expect_record_empty "23: a null model id never runs the adapter"
TEST_CONFIG="$valid_config"

printf '== source hygiene ==\n'

# The denylist is the static agent and model words plus every agent name,
# adapter, model id, and model name in the shipped example config, so a newly
# configured id cannot leak into shared code unnoticed.
example_config="$repo_root/templates/agent-config.example.json"
deny_file="$work_tmp/denylist"
{
  printf '%s\n' agy opencode goat codex cursor gemini deepseek kimi fireworks \
    argon hydrogen composer
  # A null model id is unverified and has no text to deny.
  jq -r '(.agents | keys[]), (.agents[].adapter), (.lanes[].entries[] | (.model // empty), .model_name)' \
    "$example_config"
} | sort -u >"$deny_file"
if grep -qxF -- 'deepseek/deepseek-v4.1-flash' "$deny_file" && grep -qxF -- 'GPT-6 Luna' "$deny_file" &&
  grep -qxF -- 'gemini-4-carbon-medium' "$deny_file" && grep -qxF -- 'gemini-3.8-flash-medium' "$deny_file" &&
  grep -qxF -- 'fireworks-ai/accounts/fireworks/models/kimi-k3p1-pro' "$deny_file" &&
  grep -qxF -- 'Gemini 4 Hydrogen' "$deny_file"; then
  ok "15: the denylist includes model ids and names from the example config"
else
  bad "15: the denylist includes model ids and names from the example config" "$(tr '\n' ' ' <"$deny_file")"
fi
if grep -qxiF -- 'null' "$deny_file"; then
  bad "15: a null model id adds no denylist word" "null is in the denylist"
else
  ok "15: a null model id adds no denylist word"
fi

# hygiene_leaks <file>: prints the number of lines naming a denied word.
# Only the allowed config-path text is removed before matching, so a line that
# holds the path and a model id still counts as a leak.
allowed_path_text='.config/agent-ops-kit/agents.json'
hygiene_leaks() {
  local file="$1"
  local hits hit line stripped leaked=0
  hits="$(grep -inF -f "$deny_file" -- "$file" || true)"
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    line="${hit#*:}"
    stripped="${line//"$allowed_path_text"/}"
    if ! printf '%s\n' "$stripped" | grep -qiF -f "$deny_file"; then
      continue
    fi
    leaked=$((leaked + 1))
    printf 'LEAK %s:%s\n' "${file#"$repo_root"/}" "$hit" >&2
  done <<HITS
$hits
HITS
  printf '%s\n' "$leaked"
}

leak_fixture="$work_tmp/leaked-source.sh"
printf '#!/usr/bin/env bash\nmodel="deepseek/deepseek-v4.1-flash"\n' >"$leak_fixture"
if [ "$(hygiene_leaks "$leak_fixture" 2>/dev/null)" -gt 0 ]; then
  ok "15: the hygiene check catches a leaked example model id"
else
  bad "15: the hygiene check catches a leaked example model id" "model id not detected"
fi

# A line holding both the allowed config path and a model id is a leak.
combined_fixture="$work_tmp/leaked-path-and-model.sh"
printf '#!/usr/bin/env bash\nmodel="gemini-4-argon-medium" # ~/.config/agent-ops-kit/agents.json\n' >"$combined_fixture"
if [ "$(hygiene_leaks "$combined_fixture" 2>/dev/null)" -gt 0 ]; then
  ok "15: the hygiene check catches a model id on a config-path line"
else
  bad "15: the hygiene check catches a model id on a config-path line" "path exception hid the model id"
fi
# The config path alone is allowed.
path_fixture="$work_tmp/path-only.sh"
printf '#!/usr/bin/env bash\n# default: ~/.config/agent-ops-kit/agents.json\n' >"$path_fixture"
if [ "$(hygiene_leaks "$path_fixture" 2>/dev/null)" -eq 0 ]; then
  ok "15: the config path alone is not a leak"
else
  bad "15: the config path alone is not a leak" "path-only line reported"
fi

# The example config's hand-off entry, through the real kit tree: --dry-run
# prints the agent-task-issue.sh command and nothing starts.
example_record="$work_tmp/record-example-handoff"
: >"$example_record"
out="$(AGENT_OPS_KIT_CONFIG="$example_config" HOME="$test_home" PATH="$test_path" \
  FAKE_AGY_RECORD="$example_record" \
  /bin/bash "$launcher" --lane coding --as bot --agent agy-subscription --dry-run -- \
  --title "Example task" --file brief.md 2>"$work_tmp/err-example-handoff")"
status=$?
err="$(cat "$work_tmp/err-example-handoff")"
expect_status "24: the example agy coding entry dry-runs as a hand-off for a bot" 0
expect_out "24: the example hand-off reports issue mode" "HANDOFF=issue"
expect_out "24: the example hand-off prints agent-task-issue.sh for agy" 'scripts/agent-task-issue.sh --agent agy --model Gemini\ 4\ Hydrogen\ \(id\ unverified\)'
out="$(AGENT_OPS_KIT_CONFIG="$example_config" HOME="$test_home" PATH="$test_path" \
  FAKE_AGY_RECORD="$example_record" \
  /bin/bash "$launcher" --lane coding --as bot --agent agy-subscription -- \
  --title "Example task" --file brief.md 2>"$work_tmp/err-example-handoff")"
status=$?
err="$(cat "$work_tmp/err-example-handoff")"
expect_status "24: the example hand-off without --dry-run refuses a bot" 2
expect_err "24: the example bot refusal names the hand-off" "issue hand-off"
out="$(AGENT_OPS_KIT_CONFIG="$example_config" HOME="$test_home" PATH="$test_path" \
  /bin/bash "$launcher" --lane coding --as bot --agent cursor --dry-run -- x 2>"$work_tmp/err-example-null")"
status=$?
err="$(cat "$work_tmp/err-example-null")"
expect_status "24: the example Cursor coding entry (null id) cannot run" 2
expect_err "24: the example Cursor refusal says unverified" "null model id (unverified)"
out="$(AGENT_OPS_KIT_CONFIG="$example_config" HOME="$test_home" PATH="$test_path" \
  FAKE_AGY_RECORD="$example_record" \
  /bin/bash "$launcher" --lane review --as maintainer --dry-run -- run repo brief 2>"$work_tmp/err-example-null")"
status=$?
err="$(cat "$work_tmp/err-example-null")"
expect_status "24: the example review lane (null Hydrogen id) exits 2" 2
expect_err "24: the example Cursor refusal says the id is unverified" "null model id (unverified)"
out="$(AGENT_OPS_KIT_CONFIG="$example_config" HOME="$test_home" PATH="$test_path" \
  /bin/bash "$launcher" --lane review --as bot --agent agy-api-key --dry-run -- x 2>"$work_tmp/err-example-off")"
status=$?
err="$(cat "$work_tmp/err-example-off")"
expect_status "24: the disabled API-key agy entry is skipped" 2
expect_err "24: the disabled API-key agy skip says not provisioned" "not provisioned"
if [ -s "$example_record" ]; then
  bad "24: no example run starts agy" "agy was started"
else
  ok "24: no example run starts agy"
fi

printf '== the lane.launch policy fails closed ==\n'

# The lane.launch decision loads the policy evaluator and the kit policy. A
# policy that cannot load stops the launch with the failure named, before
# any adapter starts.
bad_policy="$work_tmp/bad-policy-rules"
printf 'this file is not a policy record\n' >"$bad_policy"
out="$(AGENT_OPS_KIT_CONFIG="$example_config" HOME="$test_home" PATH="$test_path" \
  POLICY_RULES="$bad_policy" \
  /bin/bash "$launcher" --lane coding --as bot --dry-run -- x 2>"$work_tmp/err-policy-load")"
status=$?
err="$(cat "$work_tmp/err-policy-load")"
expect_status "25: an unloadable lane.launch policy exits 2" 2
expect_err "25: the refusal names the lane.launch policy" "lane.launch policy"
expect_no_out "25: an unloadable policy prints no command" "COMMAND="

for file in "$repo_root/scripts/agent-launch.sh" \
  "$repo_root/scripts/lib/agent-config.sh" \
  "$repo_root/scripts/lib/launch-run.sh"; do
  leaked="$(hygiene_leaks "$file")"
  if [ "$leaked" -eq 0 ]; then
    ok "15: ${file#"$repo_root"/} names no agent or model"
  else
    bad "15: ${file#"$repo_root"/} names no agent or model" "$leaked matching lines"
  fi
done

printf '== the shipped example validates through the real entry point ==\n'

err_file="$work_tmp/err-example"
out="$(AGENT_OPS_KIT_CONFIG="$repo_root/templates/agent-config.example.json" \
  HOME="$test_home" PATH="$test_path" \
  /bin/bash "$launcher" --validate 2>"$err_file")"
status=$?
err="$(cat "$err_file")"
expect_status "16: example config validates through agent-launch" 0
expect_out "16: example validation reports VALID=1" "VALID=1"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -ne 0 ]; then
  exit 1
fi
exit 0
