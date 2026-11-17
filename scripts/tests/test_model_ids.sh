#!/usr/bin/env bash
# Tests for scripts/dev-loop-gate.sh --check model-ids.
# Local temp git repos only, no network. Bash 3.2 compatible.
set -u

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
gate="$repo_root/scripts/dev-loop-gate.sh"

pass=0
fail=0
work_tmp="$(mktemp -d)"
trap 'rm -rf "$work_tmp"' EXIT

out=""
err=""
status=0

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
    *"$2"*) bad "$1" "stdout has: $2" ;;
    *) ok "$1" ;;
  esac
}

expect_err() {
  case "$err" in
    *"$2"*) ok "$1" ;;
    *) bad "$1" "stderr missing: $2" ;;
  esac
}

# new_repo <name> <config json> <list text>: a git work tree with the two
# files under templates/. An empty argument leaves that file out.
new_repo() {
  local dir="$work_tmp/$1"
  mkdir -p "$dir/templates"
  git -C "$dir" init -q
  if [ -n "$2" ]; then
    printf '%s\n' "$2" >"$dir/templates/agent-config.example.json"
  fi
  if [ -n "$3" ]; then
    printf '%s\n' "$3" >"$dir/templates/agent-config.verified-model-ids.txt"
  fi
  printf '%s' "$dir"
}

run_gate() {
  local err_file="$work_tmp/stderr"
  out="$("$gate" "$@" 2>"$err_file")"
  status=$?
  err="$(cat "$err_file")"
}

list_text='# verified ids
  model-a  

model-b'

good_config='{"lanes":{
  "coding":{"entries":[
    {"agent":"one","model":"model-a"},
    {"agent":"two","model":null,"_comment":"TODO: confirm the id locally."}]},
  "review":{"entries":[{"agent":"one","model":"model-b"}]}}}'

# 1. Every id verified and the null id has a TODO.
r="$(new_repo good "$good_config" "$list_text")"
run_gate --strict --check model-ids --repo "$r"
expect_status "1: clean config passes with --strict" 0
expect_out "1: summary counts entries" "3 entries, 0 hits"
expect_out "1: summary PASS" "PASS"

# 2. An id missing from the list.
r="$(new_repo unknown '{"lanes":{"review":{"entries":[{"agent":"one","model":"model-z"}]}}}' "$list_text")"
run_gate --check model-ids --repo "$r"
expect_status "2: advisory FAIL exits 0 without --strict" 0
expect_out "2: names lane, index, and agent" "review[0] one"
expect_out "2: educational text" "unverified id model-z; add it to templates/agent-config.verified-model-ids.txt only after a run record"
expect_out "2: suggests null plus TODO" "else use null plus a TODO"
run_gate --strict --check model-ids --repo "$r"
expect_status "2: --strict exits 1" 1

# 3. A null id without a TODO comment.
r="$(new_repo notodo '{"lanes":{"coding":{"entries":[{"agent":"two","model":null,"_comment":"unverified"}]}}}' "$list_text")"
run_gate --strict --check model-ids --repo "$r"
expect_status "3: null without TODO fails with --strict" 1
expect_out "3: TODO hint" "null model id without a TODO"

# 4. A null id with no comment at all.
r="$(new_repo nocomment '{"lanes":{"coding":{"entries":[{"agent":"two","model":null}]}}}' "$list_text")"
run_gate --strict --check model-ids --repo "$r"
expect_status "4: null without comment fails" 1

# 5. Comments and blank lines in the list are not ids, and blanks are trimmed.
r="$(new_repo comments '{"lanes":{"coding":{"entries":[{"agent":"one","model":"# verified ids"}]}}}' "$list_text")"
run_gate --strict --check model-ids --repo "$r"
expect_status "5: a comment line is not a verified id" 1
r="$(new_repo trimmed '{"lanes":{"coding":{"entries":[{"agent":"one","model":"model-a"}]}}}' "$list_text")"
run_gate --strict --check model-ids --repo "$r"
expect_status "5: surrounding blanks in the list are trimmed" 0

# 6. A prefix of a verified id is not verified.
r="$(new_repo prefix '{"lanes":{"coding":{"entries":[{"agent":"one","model":"model"}]}}}' "$list_text")"
run_gate --strict --check model-ids --repo "$r"
expect_status "6: a prefix of a verified id fails" 1

# 7. Empty string and non-string ids.
r="$(new_repo empty '{"lanes":{"coding":{"entries":[{"agent":"one","model":""},{"agent":"two","model":7}]}}}' "$list_text")"
run_gate --strict --check model-ids --repo "$r"
expect_status "7: empty or non-string ids fail" 1
expect_out "7: id string hint" "model must be an id string or null"
expect_out "7: summary counts both hits" "2 entries, 2 hits"

# 7b. A non-string _comment on a null entry is a FAIL row, not a jq error.
r="$(new_repo numcomment '{"lanes":{"coding":{"entries":[{"agent":"two","model":null,"_comment":7}]}}}' "$list_text")"
run_gate --strict --check model-ids --repo "$r"
expect_status "7b: non-string comment fails the entry" 1
expect_out "7b: reported as a missing TODO" "null model id without a TODO"

# 8. Missing files exit 2.
r="$(new_repo nolist "$good_config" "")"
run_gate --check model-ids --repo "$r"
expect_status "8: missing list exits 2" 2
expect_err "8: names the list" "verified-ids list not found"
r="$(new_repo noconfig "" "$list_text")"
run_gate --check model-ids --repo "$r"
expect_status "8: missing config exits 2" 2
expect_err "8: names the config" "config not found"

# 9. Invalid JSON exits 2.
r="$(new_repo badjson '{"lanes":' "$list_text")"
run_gate --check model-ids --repo "$r"
expect_status "9: invalid config exits 2" 2

# 10. The kit itself passes.
run_gate --strict --check model-ids --repo "$repo_root"
expect_status "10: kit example config passes with --strict" 0
expect_no_out "10: no FAIL rows on the kit" "FAIL"

# 11. --help lists the check.
run_gate --help
expect_out "11: --help lists model-ids" "model-ids"

printf 'model-ids tests: %s passed, %s failed\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
  exit 1
fi
exit 0
