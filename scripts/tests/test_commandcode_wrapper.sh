#!/usr/bin/env bash
# Tests for scripts/commandcode-wrapper.sh with a stub agent binary only.
# No test starts a real session or touches the network: the stub sits at
# an absolute path and GOAT_CMD points at it. Every waiting test is
# bounded, so a hang cannot wedge the suite. Bash 3.2 compatible.
# shellcheck disable=SC2016 # awk programs and grep patterns in single quotes
set -u

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
wrapper="$repo_root/scripts/commandcode-wrapper.sh"
adapter="$repo_root/scripts/agents/goat/run"

pass=0
fail=0
work_tmp="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$work_tmp"' EXIT

ok() {
  pass=$((pass + 1))
  printf 'PASS %s\n' "$1"
}

bad() {
  fail=$((fail + 1))
  printf 'FAIL %s: %s\n' "$1" "$2"
}

# The wrapper and the adapter run the agent under a narrowed environment,
# so the stub cannot read test variables. Its logs and control files live
# at fixed paths baked in here. One line per invocation goes to the
# invocations log: the full argv joined by a unit separator, with newlines
# inside an argument encoded as record separators so one invocation stays
# one line. One line per invocation goes to the env log: the child
# environment names in the same order.
ctl="$work_tmp/ctl"
invlog="$work_tmp/ctl/invocations"
envlog="$work_tmp/ctl/env-names"
mkdir -p "$ctl" "$work_tmp/bin"
us="$(printf '\037')"
cat >"$work_tmp/bin/cmd" <<SH
#!/bin/sh
sep='$us'
line="\$0"
for a in "\$@"; do
  enc=\$(printf '%s' "\$a" | tr '\n' '\036')
  line="\$line\$sep\$enc"
done
printf '%s\n' "\$line" >>"$invlog"
env | sed 's/=.*//' | LC_ALL=C sort | tr '\n' "\$sep" >>"$envlog"
printf '\n' >>"$envlog"
if [ "\${1:-}" = "--no-auto-update" ] && [ "\${2:-}" = "status" ]; then
  if [ -f "$ctl/status-hang" ]; then
    sleep 15
    exit 0
  fi
  if [ -f "$ctl/status-fail" ]; then
    printf 'stub status failure\n' >&2
    exit 3
  fi
  if [ -f "$ctl/status-badjson" ]; then
    printf 'this is not json\n'
    exit 0
  fi
  if [ -f "$ctl/status-unauth" ]; then
    printf '{"authenticated":false,"version":"x","user":"stub-user","model":"m","context_window":1}\n'
  else
    printf '{"authenticated":true,"version":"x","user":"stub-user","model":"m","context_window":1}\n'
  fi
  exit 0
fi
if [ "\${1:-}" = "-p" ]; then
  if [ -f "$ctl/run-out" ]; then
    cat "$ctl/run-out"
  fi
  exit 0
fi
exit 0
SH
chmod +x "$work_tmp/bin/cmd"
stub="$work_tmp/bin/cmd"
secret="fake-wrapper-key-456"
pinned="moonshotai/kimi-k3.1-pro"

# run_bounded <seconds> <command...>: runs one wrapper invocation with a
# wall-clock bound, so a hung wrapper or agent cannot wedge the suite.
run_bounded() {
  bound=$1
  shift
  out=""
  err=""
  status=0
  bounded_killed=0
  "$@" >"$work_tmp/out" 2>"$work_tmp/err" &
  bounded_pid=$!
  bounded_waited=0
  while kill -0 "$bounded_pid" 2>/dev/null; do
    if [ "$bounded_waited" -ge "$bound" ]; then
      kill "$bounded_pid" 2>/dev/null || true
      bounded_killed=1
      break
    fi
    sleep 1
    bounded_waited=$((bounded_waited + 1))
  done
  wait "$bounded_pid" 2>/dev/null || status=$?
  out="$(cat "$work_tmp/out")"
  err="$(cat "$work_tmp/err")"
}

expect_status() {
  if [ "$status" -eq "$2" ]; then
    ok "$1"
  else
    bad "$1" "expected exit $2, got $status${bounded_killed:+ (killed by the test bound)}; out: $out err: $err"
  fi
}

expect_text() {
  case "$2" in
    *"$3"*) ok "$1" ;;
    *) bad "$1" "missing: $3" ;;
  esac
}

expect_no_text() {
  case "$2" in
    *"$3"*) bad "$1" "unexpected: $3" ;;
    *) ok "$1" ;;
  esac
}

expect_eq() {
  if [ "$2" = "$3" ]; then
    ok "$1"
  else
    bad "$1" "expected: $2; got: $3"
  fi
}

# The invocation log is one line per invocation with fields split by the
# unit separator (byte 31), so awk can assert on every argument of every
# invocation.
invocation_count() {
  if [ -f "$invlog" ]; then
    awk 'END { print NR }' "$invlog"
  else
    printf '0\n'
  fi
}

run_invocation_count() {
  if [ -f "$invlog" ]; then
    awk 'BEGIN { FS = sprintf("%c", 31) }
      $2 == "-p" { n = n + 1 }
      END { print n + 0 }' "$invlog"
  else
    printf '0\n'
  fi
}

status_invocation_count() {
  if [ -f "$invlog" ]; then
    awk 'BEGIN { FS = sprintf("%c", 31) }
      $2 == "--no-auto-update" && $3 == "status" { n = n + 1 }
      END { print n + 0 }' "$invlog"
  else
    printf '0\n'
  fi
}

run_model_id() {
  if [ -f "$invlog" ]; then
    awk 'BEGIN { FS = sprintf("%c", 31) }
      $2 == "-p" {
        for (i = 2; i < NF; i++)
          if ($i == "--model") { print $(i + 1); exit }
      }' "$invlog"
  fi
}

git_c() {
  git -c user.name=t -c user.email=t@example.invalid "$@"
}

main_repo="$work_tmp/main"
mkdir -p "$main_repo/docs"
git -C "$main_repo" init -q -b main 2>/dev/null || {
  git -C "$main_repo" init -q
  git -C "$main_repo" symbolic-ref HEAD refs/heads/main
}
printf 'one\ntwo\nthree\n' >"$main_repo/docs/a.md"
git -C "$main_repo" add .
git_c -C "$main_repo" commit -q -m init
wt="$work_tmp/wt"
git -C "$main_repo" worktree add -q -b feat/topic "$wt"
brief="$work_tmp/brief.md"
printf 'Review the change.\n' >"$brief"
review_text="$work_tmp/review-text.md"
printf 'VERDICT: PASS\n' >"$review_text"
result="$work_tmp/review.md"

printf '== missing tools and usage ==\n'
run_bounded 15 env GOAT_CMD="$work_tmp/no-such-agent" "$wrapper" --check
expect_status "4: a missing agent binary exits 127" 127
expect_text "4: names the missing binary" "$err" "agent binary not found"
nojq_bin="$work_tmp/nojq-bin"
mkdir -p "$nojq_bin"
ln -s "$(command -v bash)" "$nojq_bin/bash"
# dirname is needed before the jq check: the wrapper resolves its own
# script path first.
ln -s "$(command -v dirname)" "$nojq_bin/dirname"
run_bounded 15 env PATH="$nojq_bin" GOAT_CMD="$stub" "$wrapper" --check
expect_status "4: a missing jq exits 127" 127
expect_text "4: names jq" "$err" "jq is required"

run_bounded 15 env GOAT_CMD="$stub" "$wrapper"
expect_status "5: no arguments exits 2" 2
expect_text "5: suggests the help" "$err" "Try --help."
run_bounded 15 env GOAT_CMD="$stub" "$wrapper" -- "$wt" "$brief" "$result"
expect_status "5: a missing --mode exits 2" 2
run_bounded 15 env GOAT_CMD="$stub" "$wrapper" --mode review -- "$wt" "$brief" "$result"
expect_status "5: a missing --model exits 2" 2
run_bounded 15 env GOAT_CMD="$stub" "$wrapper" --mode shell --model "$pinned" -- "$wt" "$brief" "$result"
expect_status "5: an unknown mode exits 2" 2
run_bounded 15 env GOAT_CMD="$stub" "$wrapper" --mode review --model "$pinned" --bogus -- "$wt" "$brief" "$result"
expect_status "5: an unknown flag exits 2" 2
run_bounded 15 env GOAT_CMD="$stub" "$wrapper" --mode review --model "$pinned" --auth login -- "$wt" "$brief" "$result"
expect_status "5: --auth is refused" 2
run_bounded 15 env GOAT_CMD="$stub" "$wrapper" --mode review --model "$pinned" --yolo -- "$wt" "$brief" "$result"
expect_status "5: --yolo is refused" 2
run_bounded 15 env GOAT_CMD="$stub" "$wrapper" --mode review --model "$pinned" --cmd /bin/sh -- "$wt" "$brief" "$result"
expect_status "5: --cmd is refused" 2
run_bounded 15 env GOAT_CMD="$stub" "$wrapper" --check --mode review
expect_status "5: --check takes no other arguments" 2
run_bounded 15 env GOAT_CMD="$stub" "$wrapper" --mode review --model example/model-x -- "$wt" "$brief" "$result"
expect_status "5: an unpinned model exits 2" 2
run_bounded 15 env GOAT_CMD="$stub" "$wrapper" --mode review --model "Moonshotai/Kimi-K3.1-Pro" -- "$wt" "$brief" "$result"
expect_status "5: a wrong-case model id exits 2" 2
run_bounded 15 env COMMANDCODE_STATUS_TIMEOUT=x GOAT_CMD="$stub" "$wrapper" --check
expect_status "5: a non-digit timeout exits 2 on --check" 2
run_bounded 15 env COMMANDCODE_STATUS_TIMEOUT=x GOAT_CMD="$stub" \
  "$wrapper" --mode review --model "$pinned" -- "$wt" "$brief" "$result"
expect_status "5: a non-digit timeout exits 2 on the run form" 2
for pinned_id in moonshotai/kimi-k3.1-pro deepseek/deepseek-v4-pro deepseek/deepseek-v4.1-flash google/gemini-4-argon; do
  run_bounded 15 env GOAT_CMD="$work_tmp/no-such-agent" "$wrapper" \
    --mode review --model "$pinned_id" -- "$wt" "$brief" "$result"
  expect_status "5: the pinned id $pinned_id passes validation" 127
done
expect_eq "5: no usage or validation error starts the agent" "0" "$(invocation_count)"

printf '== login check ==\n'
run_bounded 15 env GOAT_CMD="$stub" COMMAND_CODE_API_KEY="$secret" "$wrapper" --check
expect_status "1: --check with an authenticated login exits 0" 0
expect_eq "1: --check prints exactly the ok line" "commandcode login: authenticated" "$out"
expect_eq "1: --check prints nothing on stderr" "" "$err"
expect_eq "1: --check starts one status call" "1" "$(invocation_count)"
expect_eq "1: --check starts no model run" "0" "$(run_invocation_count)"

printf '== status refusals ==\n'
touch "$ctl/status-unauth"
run_bounded 15 env GOAT_CMD="$stub" COMMAND_CODE_API_KEY="$secret" "$wrapper" --check
expect_status "2: an unauthenticated status exits 4" 4
expect_text "2: says the login is not verified" "$err" "not verified"
expect_no_text "2: no status content is printed" "$out$err" "stub-user"
expect_eq "2: no model run is started" "0" "$(run_invocation_count)"
rm -f "$ctl/status-unauth"

touch "$ctl/status-fail"
run_bounded 15 env GOAT_CMD="$stub" COMMAND_CODE_API_KEY="$secret" "$wrapper" --check
expect_status "3: a failing status command exits 5" 5
expect_text "3: says the status check failed" "$err" "failed or timed out"
expect_no_text "3: the stub stderr stays in the temp file" "$out$err" "stub status failure"
rm -f "$ctl/status-fail"

touch "$ctl/status-hang"
run_bounded 15 env COMMANDCODE_STATUS_TIMEOUT=2 GOAT_CMD="$stub" \
  COMMAND_CODE_API_KEY="$secret" "$wrapper" --check
expect_status "3: a hanging status command exits 5" 5
expect_eq "3: the wrapper bounds the hang itself" "0" "$bounded_killed"
rm -f "$ctl/status-hang"

touch "$ctl/status-badjson"
run_bounded 15 env GOAT_CMD="$stub" COMMAND_CODE_API_KEY="$secret" "$wrapper" --check
expect_status "3: unparsable status output exits 4" 4
expect_no_text "3: the unparsable text is not printed" "$out$err" "this is not json"
rm -f "$ctl/status-badjson"

printf '== run form ==\n'
{
  jq -cn --arg m "$pinned" '{type: "event", event: {type: "model_request_start", model: $m}}'
  jq -cn --arg m "$pinned" '{type: "event", event: {type: "model_request_end", model: $m}}'
  jq -cn --rawfile t "$review_text" '{type: "result", finalText: $t}'
} >"$ctl/run-out"
before_status="$(status_invocation_count)"
run_bounded 60 env GOAT_CMD="$stub" COMMAND_CODE_API_KEY="$secret" \
  "$wrapper" --mode review --model "$pinned" -- "$wt" "$brief" "$result"
expect_status "6: the run form exits 0" 0
after_status="$(status_invocation_count)"
status_delta=$((after_status - before_status))
if [ "$status_delta" -ge 2 ]; then
  ok "6: the wrapper check and the adapter login verification both ran"
else
  bad "6: the wrapper check and the adapter login verification both ran" \
    "status calls added: $status_delta"
fi
if [ -f "$result" ]; then
  ok "6: the adapter wrote the result file"
else
  bad "6: the adapter wrote the result file" "missing: $result"
fi
case "$(head -n 1 "$result" 2>/dev/null)" in
  'Model: '*) ok "6: the result starts with a Model line" ;;
  *) bad "6: the result starts with a Model line" "first line: $(head -n 1 "$result" 2>/dev/null)" ;;
esac
expect_eq "6: the model run used the pinned model" "$pinned" "$(run_model_id)"
expect_eq "6: exactly one model run started" "1" "$(run_invocation_count)"
if [ -f "$envlog" ] && grep -q 'COMMAND_CODE_API_KEY' "$envlog"; then
  bad "6: the stub never sees COMMAND_CODE_API_KEY" "the key reached a child"
else
  ok "6: the stub never sees COMMAND_CODE_API_KEY"
fi

result2="$work_tmp/review-unauth.md"
touch "$ctl/status-unauth"
before_runs="$(run_invocation_count)"
run_bounded 15 env GOAT_CMD="$stub" COMMAND_CODE_API_KEY="$secret" \
  "$wrapper" --mode review --model "$pinned" -- "$wt" "$brief" "$result2"
expect_status "6: an unauthenticated run form exits 4" 4
expect_no_text "6: the refused run prints no status content" "$out$err" "stub-user"
if [ -f "$result2" ]; then
  bad "6: the refused run writes nothing" "result exists"
else
  ok "6: the refused run writes nothing"
fi
expect_eq "6: the refused run starts no model" "$before_runs" "$(run_invocation_count)"
rm -f "$ctl/status-unauth"

printf '== enforcement ==\n'
if [ -f "$invlog" ]; then
  presence_hits="$(awk 'BEGIN { FS = sprintf("%c", 31) }
    {
      has_nau = 0
      is_run = ($2 == "-p")
      for (i = 2; i <= NF; i++)
        if ($i == "--no-auto-update") has_nau = 1
      if (!has_nau) print NR ": an invocation lacks --no-auto-update"
      if (is_run) {
        has_model = 0
        for (i = 2; i < NF; i++)
          if ($i == "--model" && $(i + 1) == want) has_model = 1
        if (!has_model) print NR ": the model run lacks --model " want
      }
    }' want="$pinned" "$invlog")"
  if [ -z "$presence_hits" ]; then
    ok "7: every recorded invocation carries --no-auto-update"
  else
    bad "7: every recorded invocation carries --no-auto-update" "$presence_hits"
  fi
  lead_hits="$(awk 'BEGIN { FS = sprintf("%c", 31) }
    {
      is_status = 0
      for (i = 2; i <= NF; i++)
        if ($i == "status") is_status = 1
      if (is_status && $2 != "--no-auto-update")
        print NR ": a status call does not lead with --no-auto-update"
    }' "$invlog")"
  if [ -z "$lead_hits" ]; then
    ok "7: every status call leads with --no-auto-update"
  else
    bad "7: every status call leads with --no-auto-update" "$lead_hits"
  fi
else
  bad "7: every recorded invocation carries --no-auto-update" "no stub log"
fi

printf '== static launch-site gate ==\n'
gate_pattern='GOAT_CMD|COMMAND_CODE_API_KEY|(^|[^A-Za-z0-9_])cmd (-p|--|status|whoami)'
found_hits="$(grep -rlE -e "$gate_pattern" --exclude-dir=tests --exclude='*.md' \
  "$repo_root/scripts" 2>/dev/null | LC_ALL=C sort)"
expected_hits="$adapter
$wrapper"
if [ "$found_hits" = "$(printf '%s\n' "$expected_hits" | LC_ALL=C sort)" ]; then
  ok "8: only the adapter and the wrapper can start the agent binary"
else
  bad "8: only the adapter and the wrapper can start the agent binary" "found: $found_hits"
fi
for gate_file in "$adapter" "$wrapper"; do
  if grep -q -- '--no-auto-update' "$gate_file"; then
    ok "8: $(basename "$gate_file") always passes --no-auto-update"
  else
    bad "8: $(basename "$gate_file") always passes --no-auto-update" "no --no-auto-update in the file"
  fi
done

printf '== wrapper source ==\n'
if grep -q -- '--yolo' "$wrapper"; then
  bad "9: the wrapper source never holds --yolo" "found in scripts/commandcode-wrapper.sh"
else
  ok "9: the wrapper source never holds --yolo"
fi
if grep -qE '(^|[[:space:];|&(])(echo|printf|cat)[[:space:]].*"[$]status_out"' "$wrapper"; then
  bad "9: the wrapper never prints the status temp file" "a print command reads the status temp file"
else
  ok "9: the wrapper never prints the status temp file"
fi
if grep -q 'exec env -u COMMAND_CODE_API_KEY' "$wrapper"; then
  ok "9: the exec drops COMMAND_CODE_API_KEY from the adapter environment"
else
  bad "9: the exec drops COMMAND_CODE_API_KEY from the adapter environment" "the exec line does not use env -u"
fi

printf 'commandcode wrapper tests: %s passed, %s failed\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
  exit 1
fi
exit 0
