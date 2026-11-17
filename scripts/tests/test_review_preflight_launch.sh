#!/usr/bin/env bash
# Tests for the review-ready preflight in scripts/agent-launch.sh and the
# evidence hand-off to the agy review adapter.
#
# A stub gh serves pull request JSON and a stub agy records any start. The
# adapter runs only in its own --dry-run mode, so no agent starts. Bash 3.2.
set -u

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
launcher="$repo_root/scripts/agent-launch.sh"

pass=0
fail=0
# Physical path: the launchers resolve symlinks (macOS /var is /private/var).
work_tmp="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$work_tmp"' EXIT

home="$work_tmp/home"
fake_bin="$work_tmp/bin"
tool_bin="$work_tmp/tool-bin"
agy_record="$work_tmp/agy-started"
mkdir -p "$home/agy-work" "$home/tmp" "$fake_bin" "$tool_bin"

cat >"$fake_bin/agy" <<SH
#!/bin/sh
printf 'agy started\n' >>"$agy_record"
exit 99
SH
cat >"$fake_bin/gh" <<'SH'
#!/bin/sh
# Serves the fixture JSON named by FAKE_GH_JSON for `gh pr view`.
cat "$FAKE_GH_JSON"
SH
chmod +x "$fake_bin/agy" "$fake_bin/gh"

ln -s "$BASH" "$tool_bin/bash"
for cmd in jq git tr mkdir kill cp mv cat uname mktemp sed wc rm ln awk \
  readlink realpath dirname basename chmod date head tail env nohup tee cut \
  sort uniq touch sleep grep find ls printf; do
  cmd_path="$(command -v "$cmd" 2>/dev/null)" || continue
  case "$cmd_path" in
    '' | */agy | */gh | */caffeinate | "$fake_bin"/*) continue ;;
    /*) ln -s "$cmd_path" "$tool_bin/$cmd" ;;
  esac
done
test_path="$fake_bin:$tool_bin"

# The reviewed checkout: a small git repo with one commit.
checkout="$home/agy-work/repo"
mkdir -p "$checkout"
git -C "$checkout" init -q
printf '# Readme\n\nShort.\n' >"$checkout/README.md"
git -C "$checkout" add README.md
git -C "$checkout" -c user.name=t -c user.email=t@example.invalid commit -q -m init
head_sha="$(git -C "$checkout" rev-parse HEAD)"
printf 'Review the change.\n' >"$home/agy-work/brief.md"
printf 'ok 1 - first\nok 2 - second\n' >"$work_tmp/test.log"

config="$work_tmp/agents.json"
cat >"$config" <<'JSON'
{
  "schema_version": 1,
  "agents": {
    "seat": {"adapter": "agy", "display": "agy", "provider": "Test",
             "who_can_launch": "maintainer", "provisioned": true, "overages": "never"}
  },
  "lanes": {
    "review": {
      "preflight": "review-ready",
      "entries": [{"agent": "seat", "model": "test-model", "model_name": "Test Model", "mode": "review"}]
    }
  }
}
JSON

green="$work_tmp/green.json"
red="$work_tmp/red.json"
printf '{"headRefOid":"%s","statusCheckRollup":[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}]}\n' \
  "$head_sha" >"$green"
printf '{"headRefOid":"%s","statusCheckRollup":[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"FAILURE"}]}\n' \
  "$head_sha" >"$red"

ok() {
  pass=$((pass + 1))
  printf 'PASS %s\n' "$1"
}

bad() {
  fail=$((fail + 1))
  printf 'FAIL %s: %s\n' "$1" "$2"
}

out=""
err=""
status=0

# launch <gh fixture> <agent-launch args...>
launch() {
  local fixture="$1"
  shift
  out="$(cd "$home" && env -i HOME="$home" PATH="$test_path" TMPDIR="$home/tmp" \
    FAKE_GH_JSON="$fixture" "$BASH" "$launcher" --config "$config" "$@" \
    2>"$work_tmp/stderr")"
  status=$?
  err="$(cat "$work_tmp/stderr")"
}

expect_status() {
  if [ "$status" -eq "$2" ]; then
    ok "$1"
  else
    bad "$1" "expected exit $2, got $status; stderr: $err"
  fi
}

expect_text() {
  case "$2" in
    *"$3"*) ok "$1" ;;
    *) bad "$1" "missing: $3" ;;
  esac
}

adapter_args=(-- --dry-run -- run-p "$checkout" "$home/agy-work/brief.md")

# 1. A preflight lane needs a pinned pull request and head.
launch "$green" --lane review --as maintainer "${adapter_args[@]}"
expect_status "1: preflight lane without --pr exits 2" 2
expect_text "1: refusal names the preflight" "$err" "has preflight review-ready"
launch "$green" --lane review --as maintainer --pr 7 "${adapter_args[@]}"
expect_status "1: preflight lane without --expect-head exits 2" 2

# 2. A red head refuses before the adapter starts.
launch "$red" --lane review --as maintainer --pr 7 --expect-head "$head_sha" \
  --checkout "$checkout" "${adapter_args[@]}"
expect_status "2: failing CI exits 1" 1
expect_text "2: says no agent started" "$err" "no agent started"
if [ -e "$home/agy-work/runs/run-p" ]; then
  bad "2: no run folder on a red head" "run folder exists"
else
  ok "2: no run folder on a red head"
fi

# 3. A moved head refuses too.
launch "$green" --lane review --as maintainer --pr 7 --expect-head 0000000 \
  --checkout "$checkout" "${adapter_args[@]}"
expect_status "3: head mismatch exits 1" 1

# 4. Green: the entry point's dry-run reports the preflight and evidence.
launch "$green" --lane review --as maintainer --dry-run --pr 7 \
  --expect-head "$head_sha" --checkout "$checkout" --test-log "$work_tmp/test.log" \
  "${adapter_args[@]}"
expect_status "4: green dry-run exits 0" 0
expect_text "4: prints the preflight result" "$out" "PREFLIGHT=review-ready PASS"
evidence="$(printf '%s\n' "$out" | sed -n 's/^EVIDENCE=//p')"
if [ -n "$evidence" ] && [ -f "$evidence" ]; then
  ok "4: evidence file exists"
  expect_text "4: evidence has the header" "$(cat "$evidence")" "## Machine evidence"
  expect_text "4: evidence has the head" "$(cat "$evidence")" "$head_sha"
  expect_text "4: evidence has the test log tail" "$(cat "$evidence")" "ok 2 - second"
else
  bad "4: evidence file exists" "EVIDENCE=$evidence"
fi

# 5. Green: the adapter appends the evidence to the run brief once.
launch "$green" --lane review --as maintainer --pr 7 --expect-head "$head_sha" \
  --checkout "$checkout" "${adapter_args[@]}"
expect_status "5: green launch reaches the adapter dry-run" 0
brief_copy="$home/agy-work/runs/run-p/BRIEF.md"
if [ -f "$brief_copy" ]; then
  expect_text "5: run brief keeps the original text" "$(cat "$brief_copy")" "Review the change."
  n="$(grep -c '^## Machine evidence' "$brief_copy")"
  if [ "$n" -eq 1 ]; then
    ok "5: evidence appended exactly once"
  else
    bad "5: evidence appended exactly once" "found $n"
  fi
else
  bad "5: run brief exists" "missing $brief_copy"
fi
expect_text "5: adapter prompt carries the evidence" "$out" "Machine"

# 6. A preflight value other than review-ready is a config error.
bad_config="$work_tmp/bad.json"
jq '.lanes.review.preflight = "other"' "$config" >"$bad_config"
out="$(env -i HOME="$home" PATH="$test_path" "$BASH" "$launcher" --validate --config "$bad_config" 2>&1)"
status=$?
expect_status "6: unknown preflight value fails validation" 2
expect_text "6: names the field" "$out" "preflight must be"

if [ -e "$agy_record" ]; then
  bad "no agent started" "the stub agy was called"
else
  ok "no agent started"
fi

printf 'review-preflight-launch tests: %s passed, %s failed\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
  exit 1
fi
exit 0
