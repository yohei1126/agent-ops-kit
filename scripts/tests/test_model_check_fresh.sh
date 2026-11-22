#!/usr/bin/env bash
# Tests for scripts/dev-loop-gate.sh --check model-check-fresh.
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
printf '%s\n' "$*" >"$FAKE_GH_ARGV"
cat "$FAKE_GH_JSON"
SH
chmod +x "$stub_bin/gh"

unset DEV_LOOP_PR DEV_LOOP_EXPECT_HEAD DEV_LOOP_NOW

checkout="$work_tmp/checkout"
mkdir -p "$checkout"
git -C "$checkout" init -q
printf '# Readme\n' >"$checkout/README.md"
git -C "$checkout" add README.md
git -C "$checkout" -c user.name=t -c user.email=t@example.invalid commit -q -m init
head_sha="abcdef1234567890abcdef1234567890abcdef12"
other_sha="1111111222222233333334444444555555566666"
short="${head_sha:0:7}"

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

gate_run() {
  local fixture_file="$1"
  shift
  out="$(PATH="$stub_bin:$PATH" FAKE_GH_JSON="$fixture_file" \
    FAKE_GH_ARGV="$work_tmp/gh.argv" "${BASH:-bash}" "$gate" "$@" 2>"$work_tmp/stderr")"
  status=$?
  err="$(cat "$work_tmp/stderr")"
}

mcf() {
  local fixture_file="$1"
  shift
  gate_run "$fixture_file" --check model-check-fresh --repo "$checkout" --pr 7 "$@"
}

expect_status() {
  if [ "$status" -eq "$2" ]; then
    ok "$1"
  else
    bad "$1" "expected exit $2, got $status; out: $out; err: $err"
  fi
}

expect_text() {
  case "$2" in
    *"$3"*) ok "$1" ;;
    *) bad "$1" "missing: $3 (got: $2)" ;;
  esac
}

# Build fixtures.
cat >"$work_tmp/match_gemini.json" <<EOF
{"headRefOid":"$head_sha","comments":[{"createdAt":"2026-11-22T10:00:00Z","body":"Model: Gemini 4 Argon (gemini-4-argon)\ngemini-batch-head: $head_sha\nFindings: none"}]}
EOF

cat >"$work_tmp/match_generic_prefix.json" <<EOF
{"headRefOid":"$head_sha","comments":[{"createdAt":"2026-11-22T12:00:00Z","body":"Model: Example\nmodel-check-head: ABCDEF1\nVerdict: PASS"}]}
EOF

cat >"$work_tmp/head_moved.json" <<EOF
{"headRefOid":"$head_sha","comments":[{"createdAt":"2026-11-22T10:00:00Z","body":"Model: Example\ngemini-batch-head: $other_sha\n"}]}
EOF

cat >"$work_tmp/prev_day.json" <<EOF
{"headRefOid":"$head_sha","comments":[{"createdAt":"2026-11-21T23:59:59Z","body":"Model: Example\ngemini-batch-head: $head_sha\n"}]}
EOF

cat >"$work_tmp/missing_result.json" <<EOF
{"headRefOid":"$head_sha","comments":[{"createdAt":"2026-11-22T10:00:00Z","body":"Just a regular comment."}]}
EOF

cat >"$work_tmp/empty_comments.json" <<EOF
{"headRefOid":"$head_sha","comments":[]}
EOF

cat >"$work_tmp/bad_ts.json" <<EOF
{"headRefOid":"$head_sha","comments":[{"createdAt":"not-a-timestamp","body":"Model: Example\ngemini-batch-head: $head_sha\n"}]}
EOF

cat >"$work_tmp/missing_ts.json" <<EOF
{"headRefOid":"$head_sha","comments":[{"createdAt":null,"body":"Model: Example\ngemini-batch-head: $head_sha\n"}]}
EOF

cat >"$work_tmp/missing_head_marker.json" <<EOF
{"headRefOid":"$head_sha","comments":[{"createdAt":"2026-11-22T10:00:00Z","body":"Model: Example\nNo head marker here.\n"}]}
EOF

cat >"$work_tmp/tz_cross_next.json" <<EOF
{"headRefOid":"$head_sha","comments":[{"createdAt":"2026-11-22T20:00:00-08:00","body":"Model: Example\nmodel-check-head: $head_sha\n"}]}
EOF

cat >"$work_tmp/tz_cross_prev.json" <<EOF
{"headRefOid":"$head_sha","comments":[{"createdAt":"2026-11-22T02:00:00+09:00","body":"Model: Example\nmodel-check-head: $head_sha\n"}]}
EOF

cat >"$work_tmp/latest_stale_over_pass.json" <<EOF
{"headRefOid":"$head_sha","comments":[
  {"createdAt":"2026-11-22T09:00:00Z","body":"Model: Example\ngemini-batch-head: $head_sha\n"},
  {"createdAt":"2026-11-22T11:00:00Z","body":"Model: Example\ngemini-batch-head: $other_sha\n"}
]}
EOF

printf 'not json\n' >"$work_tmp/garbage.json"

# 1. Matching head and day -> PASS (exit 0)
DEV_LOOP_NOW="2026-11-22T18:00:00Z" mcf "$work_tmp/match_gemini.json"
expect_status "1a: matching head and day exits 0" 0
expect_text "1a: summary row PASS" "$out" "model-check-fresh              PASS"
expect_text "1a: mentions short head and UTC date" "$out" "$short on 2026-11-22 UTC"
expect_text "1a: gh requested headRefOid,comments" "$(cat "$work_tmp/gh.argv")" "--json headRefOid,comments"

DEV_LOOP_NOW="2026-11-22T18:00:00Z" mcf "$work_tmp/match_generic_prefix.json" --expect-head "$short" --gh-repo owner/repo
expect_status "1b: generic marker prefix case-insensitive PASS" 0
expect_text "1b: gh received -R owner/repo" "$(cat "$work_tmp/gh.argv")" "-R owner/repo"

# 2. Head moved -> FAIL (exit 1 without --strict)
DEV_LOOP_NOW="2026-11-22T18:00:00Z" mcf "$work_tmp/head_moved.json"
expect_status "2a: head moved exits 1" 1
expect_text "2a: explains head moved" "$out" "head moved:"

DEV_LOOP_NOW="2026-11-22T18:00:00Z" mcf "$work_tmp/latest_stale_over_pass.json"
expect_status "2b: latest stale comment fails even if older passed" 1

DEV_LOOP_NOW="2026-11-22T18:00:00Z" mcf "$work_tmp/match_gemini.json" --expect-head "$other_sha"
expect_status "2c: --expect-head mismatch fails" 1
expect_text "2c: expect-head row fails" "$out" "expect-head"

# 3. Result from a previous day -> FAIL (exit 1)
DEV_LOOP_NOW="2026-11-22T18:00:00Z" mcf "$work_tmp/prev_day.json"
expect_status "3: previous day exits 1" 1
expect_text "3: shows both UTC dates" "$out" "2026-11-21 != today 2026-11-22 (UTC)"

# 4. Missing result -> FAIL (exit 1)
DEV_LOOP_NOW="2026-11-22T18:00:00Z" mcf "$work_tmp/missing_result.json"
expect_status "4: missing result exits 1" 1
expect_text "4: says missing result" "$out" "missing result"

# 5. Timestamp missing or unreadable -> FAIL (exit 1)
DEV_LOOP_NOW="2026-11-22T18:00:00Z" mcf "$work_tmp/bad_ts.json"
expect_status "5a: unreadable timestamp exits 1" 1
expect_text "5a: says timestamp missing or unreadable" "$out" "timestamp missing or unreadable"

DEV_LOOP_NOW="2026-11-22T18:00:00Z" mcf "$work_tmp/missing_ts.json"
expect_status "5b: missing timestamp exits 1" 1
expect_text "5b: says timestamp missing or unreadable" "$out" "timestamp missing or unreadable"

# 6. Head marker missing or unreadable in a Model: comment -> FAIL (exit 1)
DEV_LOOP_NOW="2026-11-22T18:00:00Z" mcf "$work_tmp/missing_head_marker.json"
expect_status "6: missing head marker exits 1" 1
expect_text "6: says head missing or unreadable" "$out" "head missing or unreadable"

# 7. --run record with matching head and day -> PASS; symlink checks -> exit 2
run_dir="$work_tmp/run_ok"
mkdir -p "$run_dir"
printf '# comment\n\nhead\t%s\ntime\t2026-11-22T14:00:00Z\n' "$head_sha" >"$run_dir/model-check.record"
DEV_LOOP_NOW="2026-11-22T18:00:00Z" mcf "$work_tmp/empty_comments.json" --run "$run_dir"
expect_status "7a: --run record passes with empty comments" 0
expect_text "7a: notes record source" "$out" "(record)"

# Newer passing record beats older stale comment
printf 'head\t%s\ntime\t2026-11-22T15:00:00Z\n' "$head_sha" >"$run_dir/model-check.record"
DEV_LOOP_NOW="2026-11-22T18:00:00Z" mcf "$work_tmp/head_moved.json" --run "$run_dir"
expect_status "7b: newer record beats older stale comment" 0

# Symlinked --run dir and symlinked record file exit 2
ln -s "$run_dir" "$work_tmp/run_symlink"
DEV_LOOP_NOW="2026-11-22T18:00:00Z" mcf "$work_tmp/empty_comments.json" --run "$work_tmp/run_symlink"
expect_status "7c: symlinked --run exits 2" 2

run_bad_rec="$work_tmp/run_bad_rec"
mkdir -p "$run_bad_rec"
ln -s "$run_dir/model-check.record" "$run_bad_rec/model-check.record"
DEV_LOOP_NOW="2026-11-22T18:00:00Z" mcf "$work_tmp/empty_comments.json" --run "$run_bad_rec"
expect_status "7d: symlinked record file exits 2" 2

# 8. ISO-8601 offset crossing UTC date boundary
# 2026-11-22T20:00:00-08:00 is 2026-11-23T04:00:00Z (UTC day 23)
DEV_LOOP_NOW="2026-11-23T05:00:00Z" mcf "$work_tmp/tz_cross_next.json"
expect_status "8a: -08:00 crossing UTC midnight forward matches 2026-11-23" 0

DEV_LOOP_NOW="2026-11-22T23:00:00Z" mcf "$work_tmp/tz_cross_next.json"
expect_status "8b: -08:00 crossing UTC midnight forward fails on 2026-11-22" 1

# 2026-11-22T02:00:00+09:00 is 2026-11-21T17:00:00Z (UTC day 21)
DEV_LOOP_NOW="2026-11-21T20:00:00Z" mcf "$work_tmp/tz_cross_prev.json"
expect_status "8c: +09:00 crossing UTC midnight backward matches 2026-11-21" 0

# 9. Usage errors and gh failures
gate_run "$work_tmp/match_gemini.json" --check model-check-fresh --repo "$checkout"
expect_status "9a: missing --pr exits 2" 2

gate_run "$work_tmp/match_gemini.json" --check line-cap --repo "$checkout" --run "$run_dir"
expect_status "9b: --run without model-check-fresh exits 2" 2

FAKE_GH_FAIL=1 mcf "$work_tmp/match_gemini.json"
expect_status "9c: gh failure exits 3" 3

mcf "$work_tmp/garbage.json"
expect_status "9d: unreadable gh JSON exits 3" 3

# 10. --help mentions UTC / same day and flag names
out="$("${BASH:-bash}" "$gate" --check model-check-fresh --help)"
status=$?
expect_status "10a: --check model-check-fresh --help exits 0" 0
expect_text "10b: help mentions UTC" "$out" "UTC"
expect_text "10c: help mentions Same day" "$out" "Same day"
expect_text "10d: help lists --pr" "$out" "--pr"
expect_text "10e: help lists --gh-repo" "$out" "--gh-repo"
expect_text "10f: help lists --repo" "$out" "--repo"
expect_text "10g: help lists --run" "$out" "--run"
expect_text "10h: help lists --expect-head" "$out" "--expect-head"
expect_text "10i: help lists DEV_LOOP_NOW" "$out" "DEV_LOOP_NOW"

# 11. DEV_LOOP_NOW pins today (and invalid DEV_LOOP_NOW exits 2)
DEV_LOOP_NOW="2026-11-23T00:00:00Z" mcf "$work_tmp/match_gemini.json"
expect_status "11a: DEV_LOOP_NOW pins today to next day -> FAIL" 1

DEV_LOOP_NOW="bad-now" mcf "$work_tmp/match_gemini.json"
expect_status "11b: invalid DEV_LOOP_NOW exits 2" 2

printf 'model-check-fresh tests: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
