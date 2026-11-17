#!/usr/bin/env bash
# Tests for scripts/dev-loop-gate.sh --check review-ready.
# A stub gh serves fixture JSON; temp git repos only, no network. Bash 3.2.
set -u

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
gate="$repo_root/scripts/dev-loop-gate.sh"

pass=0
fail=0
work_tmp="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$work_tmp"' EXIT

stub_bin="$work_tmp/bin"
mkdir -p "$stub_bin"
cat >"$stub_bin/gh" <<'SH'
#!/bin/sh
if [ -n "${FAKE_GH_FAIL:-}" ]; then
  printf 'HTTP 404: not found\n' >&2
  exit 1
fi
printf '%s\n' "$*" >>"$FAKE_GH_ARGV"
cat "$FAKE_GH_JSON"
SH
chmod +x "$stub_bin/gh"

unset DEV_LOOP_PR DEV_LOOP_EXPECT_HEAD DEV_LOOP_REVIEW_READY_CHECKS

checkout="$work_tmp/checkout"
mkdir -p "$checkout"
git -C "$checkout" init -q
printf '# Readme\n\nShort.\n' >"$checkout/README.md"
git -C "$checkout" add README.md
git -C "$checkout" -c user.name=t -c user.email=t@example.invalid commit -q -m init
head_sha="$(git -C "$checkout" rev-parse HEAD)"
short="${head_sha:0:7}"
printf 'ok 1 - alpha\nok 2 - omega\n' >"$work_tmp/test.log"

fixture() {
  # fixture <name> <rollup json array> [head]
  printf '{"headRefOid":"%s","statusCheckRollup":%s}\n' "${3:-$head_sha}" "$2" >"$work_tmp/$1.json"
}
run_ok='{"__typename":"CheckRun","name":"lint","status":"COMPLETED","conclusion":"SUCCESS"}'
fixture green "[$run_ok]"
fixture none "[]"
fixture pending "[$run_ok,{\"__typename\":\"CheckRun\",\"name\":\"macos\",\"status\":\"IN_PROGRESS\",\"conclusion\":null}]"
fixture failing "[$run_ok,{\"__typename\":\"CheckRun\",\"name\":\"tests\",\"status\":\"COMPLETED\",\"conclusion\":\"FAILURE\"}]"
fixture stale "[{\"__typename\":\"CheckRun\",\"name\":\"old\",\"status\":\"COMPLETED\",\"conclusion\":\"STALE\"}]"
fixture neutral "[$run_ok,{\"__typename\":\"CheckRun\",\"name\":\"n\",\"status\":\"COMPLETED\",\"conclusion\":\"NEUTRAL\"},{\"__typename\":\"CheckRun\",\"name\":\"s\",\"status\":\"COMPLETED\",\"conclusion\":\"SKIPPED\"}]"
fixture ctx_ok "[{\"__typename\":\"StatusContext\",\"context\":\"ext\",\"state\":\"SUCCESS\"}]"
fixture ctx_pending "[{\"__typename\":\"StatusContext\",\"context\":\"ext\",\"state\":\"PENDING\"}]"
fixture moved "[$run_ok]" "1111111111111111111111111111111111111111"
printf 'not json\n' >"$work_tmp/garbage.json"

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

# gate_run <fixture> <args...>
gate_run() {
  local fixture_name="$1"
  shift
  out="$(PATH="$stub_bin:$PATH" FAKE_GH_JSON="$work_tmp/$fixture_name.json" \
    FAKE_GH_ARGV="$work_tmp/gh.argv" "$BASH" "$gate" "$@" 2>"$work_tmp/stderr")"
  status=$?
  err="$(cat "$work_tmp/stderr")"
}

expect_status() {
  if [ "$status" -eq "$2" ]; then
    ok "$1"
  else
    bad "$1" "expected exit $2, got $status; out: $out err: $err"
  fi
}

expect_text() {
  case "$2" in
    *"$3"*) ok "$1" ;;
    *) bad "$1" "missing: $3" ;;
  esac
}

rr() {
  local fixture_name="$1"
  shift
  gate_run "$fixture_name" --check review-ready --repo "$checkout" --pr 7 "$@"
}

# 1. Green head, green checkout, named checks pass.
rr green --expect-head "$short"
expect_status "1: green exits 0" 0
expect_text "1: ci row passes" "$out" "1 checks green"
expect_text "1: line-cap runs" "$out" "line-cap"
expect_text "1: summary passes" "$out" "review-ready                   PASS"
expect_text "1: gh asked for the head and checks" "$(cat "$work_tmp/gh.argv")" "--json headRefOid,statusCheckRollup"

# 2. FAIL exits 1 even without --strict.
rr moved --expect-head "$short"
expect_status "2: moved head exits 1 without --strict" 1
expect_text "2: head row explains" "$out" "re-read the PR and pass the current head"

# 3. Checkout not at the head.
fixture other "[$run_ok]" "2222222222222222222222222222222222222222"
rr other --expect-head 2222222
expect_status "3: checkout elsewhere exits 1" 1
expect_text "3: checkout row explains" "$out" "check out the PR head before review"

# 4. CI states.
rr none --expect-head "$short"
expect_status "4: no checks exits 1" 1
expect_text "4: no checks text" "$out" "no checks reported; wait for CI before review"
rr pending --expect-head "$short"
expect_status "4: pending exits 1" 1
expect_text "4: pending names the check" "$out" "1 pending: macos"
rr failing --expect-head "$short"
expect_status "4: failing exits 1" 1
expect_text "4: failing names the check" "$out" "1 failing: tests; fix CI before review"
rr stale --expect-head "$short"
expect_status "4: stale counts as failing" 1
rr neutral --expect-head "$short"
expect_status "4: neutral and skipped pass" 0
rr ctx_ok --expect-head "$short"
expect_status "4: status context success passes" 0
rr ctx_pending --expect-head "$short"
expect_status "4: status context pending fails" 1

# 5. A failing named check fails the preflight; an unknown id is SKIP.
awk 'BEGIN { for (i = 0; i < 600; i++) print "line" }' >"$checkout/LONG.md"
git -C "$checkout" add LONG.md
git -C "$checkout" -c user.name=t -c user.email=t@example.invalid commit -q -m long
long_sha="$(git -C "$checkout" rev-parse HEAD)"
fixture long "[$run_ok]" "$long_sha"
rr long --expect-head "${long_sha:0:7}"
expect_status "5: line-cap failure exits 1" 1
expect_text "5: names the failing check" "$out" "line-cap failed; run scripts/dev-loop-gate.sh --strict --check line-cap"
git -C "$checkout" -c user.name=t -c user.email=t@example.invalid rm -q LONG.md
git -C "$checkout" -c user.name=t -c user.email=t@example.invalid commit -q -m short
head_sha="$(git -C "$checkout" rev-parse HEAD)"
short="${head_sha:0:7}"
fixture green "[$run_ok]"
out="$(DEV_LOOP_REVIEW_READY_CHECKS="line-cap no-such-check" PATH="$stub_bin:$PATH" \
  FAKE_GH_JSON="$work_tmp/green.json" FAKE_GH_ARGV="$work_tmp/gh.argv" \
  "$BASH" "$gate" --check review-ready --repo "$checkout" --pr 7 --expect-head "$short" 2>/dev/null)"
status=$?
expect_status "5: an unknown id set by the caller fails" 1
expect_text "5: names the unknown id" "$out" "no-such-check failed"
out="$(PATH="$stub_bin:$PATH" FAKE_GH_JSON="$work_tmp/green.json" FAKE_GH_ARGV="$work_tmp/gh.argv" \
  "$BASH" "$gate" --check review-ready --repo "$checkout" --pr 7 --expect-head "$short" 2>/dev/null)"
status=$?
expect_status "5: default ids not in this kit do not fail" 0
expect_text "5: a missing default id is SKIP" "$out" "not in this kit version"

# 5b. Uncommitted edits to tracked files fail the checkout row.
printf 'edited\n' >>"$checkout/README.md"
rr green --expect-head "$short"
expect_status "5b: a dirty checkout exits 1" 1
expect_text "5b: says why" "$out" "uncommitted changes to tracked files"
git -C "$checkout" checkout -q -- README.md
upper="$(printf '%s' "$short" | tr 'a-f' 'A-F')"
rr green --expect-head "$upper"
expect_status "5b: an uppercase head matches" 0

# 6. Evidence on PASS only.
evidence="$work_tmp/evidence.md"
rr green --expect-head "$short" --test-log "$work_tmp/test.log" --evidence-out "$evidence"
expect_status "6: green with evidence exits 0" 0
if [ -f "$evidence" ]; then
  ok "6: evidence written"
  expect_text "6: evidence header" "$(cat "$evidence")" "## Machine evidence (settled; do not re-check)"
  expect_text "6: evidence head" "$(cat "$evidence")" "Head: $head_sha"
  expect_text "6: evidence CI list" "$(cat "$evidence")" "lint=SUCCESS"
  expect_text "6: evidence rows" "$(cat "$evidence")" "RR   ci"
  expect_text "6: evidence log tail" "$(cat "$evidence")" "ok 2 - omega"
else
  bad "6: evidence written" "missing"
fi
rm -f "$evidence"
rr failing --expect-head "$short" --evidence-out "$evidence"
if [ -e "$evidence" ]; then
  bad "6: no evidence on FAIL" "file exists"
else
  ok "6: no evidence on FAIL"
fi
ln -s "$work_tmp/elsewhere" "$work_tmp/link.md"
rr green --expect-head "$short" --evidence-out "$work_tmp/link.md"
expect_status "6: symlinked evidence path exits 2" 2

# 7. Usage.
gate_run green --check review-ready --repo "$checkout" --expect-head "$short"
expect_status "7: missing --pr exits 2" 2
expect_text "7: says both are required" "$err" "needs --pr and --expect-head"
gate_run green --check review-ready --repo "$checkout" --pr 7
expect_status "7: missing --expect-head exits 2" 2
rr green --expect-head "$short" --test-log "$work_tmp/missing.log"
expect_status "7: unreadable --test-log exits 2" 2
gate_run green --check line-cap --repo "$checkout" --test-log "$work_tmp/test.log"
expect_status "7: --test-log without review-ready exits 2" 2
gate_run green --check line-cap --repo "$checkout" --evidence-out "$work_tmp/e.md"
expect_status "7: --evidence-out without review-ready exits 2" 2
gate_run green --check line-cap --repo "$checkout" --comment "$work_tmp/test.log"
expect_status "7: --comment without review-citations exits 2" 2

# 8. gh failures exit 3.
out="$(FAKE_GH_FAIL=1 PATH="$stub_bin:$PATH" FAKE_GH_JSON="$work_tmp/green.json" \
  FAKE_GH_ARGV="$work_tmp/gh.argv" "$BASH" "$gate" --check review-ready --repo "$checkout" \
  --pr 7 --expect-head "$short" 2>"$work_tmp/stderr")"
status=$?
err="$(cat "$work_tmp/stderr")"
expect_status "8: gh failure exits 3" 3
expect_text "8: gh error is shown" "$err" "gh failed: HTTP 404"
rr garbage --expect-head "$short"
expect_status "8: unreadable gh output exits 3" 3

# 9. --help lists both review gates.
out="$("$BASH" "$gate" --help)"
expect_text "9: --help lists review-ready" "$out" "--check review-ready"
expect_text "9: --help lists review-citations" "$out" "--check review-citations"

printf 'review-ready tests: %s passed, %s failed\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
  exit 1
fi
exit 0
