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
# The stub agent must never run in this test.
exit 99
SH
chmod +x "$fake_bin/agy"

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
resolved="$(PATH="$fake_bin:$PATH" command -v agy)"
if [ "$resolved" = "$fake_bin/agy" ]; then
  ok "0: command -v agy resolves to the stub"
else
  bad "0: command -v agy resolves to the stub" "got: $resolved"
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
      "adapter": "stub",
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
  out="$(AGENT_OPS_KIT_CONFIG="$TEST_CONFIG" HOME="$test_home" \
    PATH="$fake_bin:$PATH" STUB_ADAPTER_RECORD="$record" \
    STUB_ADAPTER_EXIT="${STUB_ADAPTER_EXIT:-0}" \
    bash "$kit/scripts/agent-launch.sh" "$@" 2>"$err_file")"
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

printf '== source hygiene ==\n'

clean_pattern='agy|opencode|goat|codex|cursor|gemini|deepseek|kimi|fireworks|argon|hydrogen'
for file in "$repo_root/scripts/agent-launch.sh" \
  "$repo_root/scripts/lib/agent-config.sh" \
  "$repo_root/scripts/lib/launch-run.sh"; do
  hits="$(grep -inE -- "$clean_pattern" "$file" || true)"
  leaked=0
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    line="${hit#*:}"
    trimmed="${line#"${line%%[![:space:]]*}"}"
    case "$trimmed" in
      *'.config/agent-ops-kit/agents.json') continue ;;
    esac
    leaked=$((leaked + 1))
    printf 'LEAK %s:%s\n' "${file#"$repo_root"/}" "$hit"
  done <<EOF
$hits
EOF
  if [ "$leaked" -eq 0 ]; then
    ok "15: ${file#"$repo_root"/} names no agent or model"
  else
    bad "15: ${file#"$repo_root"/} names no agent or model" "$leaked matching lines"
  fi
done

printf '== the shipped example validates through the real entry point ==\n'

err_file="$work_tmp/err-example"
out="$(AGENT_OPS_KIT_CONFIG="$repo_root/templates/agent-config.example.json" \
  HOME="$test_home" PATH="$fake_bin:$PATH" \
  bash "$launcher" --validate 2>"$err_file")"
status=$?
err="$(cat "$err_file")"
expect_status "16: example config validates through agent-launch" 0
expect_out "16: example validation reports VALID=1" "VALID=1"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -ne 0 ]; then
  exit 1
fi
exit 0
