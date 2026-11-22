#!/usr/bin/env bash
# Tests for scripts/dev-loop-gate.sh --check model-ids.
# Local temp git repos only, no network. Bash 3.2 compatible.
# shellcheck disable=SC2016 # literal backticks in the sample Model lines
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

# 12. A PR body Model line is compared with the recorded id.
r="$(new_repo modelline "$good_config" "$list_text")"
printf 'model-a\n' >"$work_tmp/recorded-a"
printf 'Model: model-z (Command Code / GOAT)\n' >"$work_tmp/body-mismatch"
run_gate --strict --check model-ids --repo "$r" \
  --model-line-file "$work_tmp/body-mismatch" --recorded-id-file "$work_tmp/recorded-a"
expect_status "12: a Model line that differs from the recorded id fails --strict" 1
expect_out "12: the FAIL row names the recorded id" "recorded id model-a"
expect_out "12: the FAIL row is educational" "copy that id exactly"

run_gate --check model-ids --repo "$r" \
  --model-line-file "$work_tmp/body-mismatch" --recorded-id-file "$work_tmp/recorded-a"
expect_status "12: a Model line that differs from the recorded id fails without --strict" 1
expect_out "12: the FAIL row shows without --strict" "FAIL"

printf 'Model: Name (model-a) (Command Code / GOAT)\n' >"$work_tmp/body-ok"
run_gate --strict --check model-ids --repo "$r" \
  --model-line-file "$work_tmp/body-ok" --recorded-id-file "$work_tmp/recorded-a"
expect_status "12: a Model line with the recorded id passes --strict" 0

printf 'moonshotai/Kimi-K3.1-Pro\n' >"$work_tmp/recorded-mixed"
printf 'Model: Name (moonshotai/Kimi-K3.1-Pro) (Command Code / GOAT)\n' >"$work_tmp/body-mixed"
run_gate --strict --check model-ids --repo "$r" \
  --model-line-file "$work_tmp/body-mixed" --recorded-id-file "$work_tmp/recorded-mixed"
expect_status "12: a mixed-case recorded id passes exactly" 0

printf 'Model: Name (moonshotai/kimi-k3.1-pro) (Command Code / GOAT)\n' >"$work_tmp/body-lower"
run_gate --strict --check model-ids --repo "$r" \
  --model-line-file "$work_tmp/body-lower" --recorded-id-file "$work_tmp/recorded-mixed"
expect_status "12: a case-only mismatch fails" 1

printf 'Model: Name (moonshotai/Kimi-K3) (Command Code / GOAT)\n' >"$work_tmp/body-prefix"
run_gate --strict --check model-ids --repo "$r" \
  --model-line-file "$work_tmp/body-prefix" --recorded-id-file "$work_tmp/recorded-mixed"
expect_status "12: a prefix of the recorded id does not match" 1

# 13. Without a recorded id, a Model line must name a configured id.
printf 'Model: Name (model-a) (Command Code / GOAT)\n' >"$work_tmp/body-fallback-ok"
run_gate --strict --check model-ids --repo "$r" \
  --model-line-file "$work_tmp/body-fallback-ok"
expect_status "13: a configured id in the Model line passes --strict" 0

printf 'Model: Name (model-z) (Command Code / GOAT)\n' >"$work_tmp/body-fallback-bad"
run_gate --strict --check model-ids --repo "$r" \
  --model-line-file "$work_tmp/body-fallback-bad"
expect_status "13: a Model line matching no configured id fails --strict" 1

# 14. A body with no Model line fails closed.
printf 'No Model line here.\n' >"$work_tmp/body-noline"
run_gate --strict --check model-ids --repo "$r" \
  --model-line-file "$work_tmp/body-noline" --recorded-id-file "$work_tmp/recorded-a"
expect_status "14: a body with no Model line fails --strict" 1
expect_out "14: says no Model line was found" "no Model line"

# 15. Flag use and missing files.
run_gate --check model-ids --repo "$r" --recorded-id-file "$work_tmp/recorded-a"
expect_status "15: --recorded-id-file without --model-line-file exits 2" 2
run_gate --model-line-file "$work_tmp/body-ok" --repo "$r"
expect_status "15: --model-line-file without --check model-ids exits 2" 2
run_gate --model-line-file "$work_tmp/body-ok" --check line-cap --repo "$r"
expect_status "15: the flags with another check exit 2" 2
run_gate --check model-ids --repo "$r" \
  --model-line-file "$work_tmp/missing-body" --recorded-id-file "$work_tmp/recorded-a"
expect_status "15: a missing model-line file exits 2" 2
expect_err "15: names the missing model-line file" "model-line file not found"

# 16. A "Model / Authors:" line (spaces around the slash) is a Model line.
printf 'Model / Authors: Name (`moonshotai/Kimi-K3.1-Pro`) (Command Code / GOAT).\n' >"$work_tmp/body-slash-ok"
run_gate --strict --check model-ids --repo "$r" \
  --model-line-file "$work_tmp/body-slash-ok" --recorded-id-file "$work_tmp/recorded-mixed"
expect_status "16: a Model / Authors line with the recorded id passes --strict" 0

printf 'Model / Authors: Name (`moonshotai/kimi-k3.1-pro`) (Command Code / GOAT).\n' >"$work_tmp/body-slash-lower"
run_gate --strict --check model-ids --repo "$r" \
  --model-line-file "$work_tmp/body-slash-lower" --recorded-id-file "$work_tmp/recorded-mixed"
expect_status "16: a Model / Authors line with a case-only mismatch fails --strict" 1

printf 'Model / Authors: Name (`moonshotai/Kimi-K2.5`) (Command Code / GOAT).\n' >"$work_tmp/body-slash-other"
run_gate --strict --check model-ids --repo "$r" \
  --model-line-file "$work_tmp/body-slash-other" --recorded-id-file "$work_tmp/recorded-mixed"
expect_status "16: a Model / Authors line with another id fails --strict" 1
expect_out "16: the FAIL row names the recorded id" "recorded id moonshotai/Kimi-K3.1-Pro"

# 17. A policy/rules in the repo under test adds the lane.verified and
# lane.use consistency checks from the decision table.
policy_config='{"lanes":{"coding":{"entries":[{"agent":"one","model":"model-a"}]}}}'

# write_policy <repo-dir>: writes the heredoc to <repo-dir>/policy/rules.
write_policy() {
  local dir="$1"
  mkdir -p "$dir/policy"
  cat >"$dir/policy/rules"
}

r="$(new_repo policypass "$policy_config" "$list_text")"
write_policy "$r" <<'EOF'
id=lane.verified.model-a
effect=permit
principal=*
action=lane.verified
resource=model-a

id=lane.use.coding.model-a
effect=permit
principal=*
action=lane.use
resource=model-a
when=lane=coding
EOF
run_gate --strict --check model-ids --repo "$r"
expect_status "17: a policy that verifies the id passes with --strict" 0
expect_out "17: the policy pass counts the entry" "1 entries, 0 hits"

# 18. The id is verified but the lane is not allowed.
r="$(new_repo policylane "$policy_config" "$list_text")"
write_policy "$r" <<'EOF'
id=lane.verified.model-a
effect=permit
principal=*
action=lane.verified
resource=model-a

id=lane.use.docs.model-a
effect=permit
principal=*
action=lane.use
resource=model-a
when=lane=docs
EOF
run_gate --strict --check model-ids --repo "$r"
expect_status "18: an id in a lane the policy does not allow fails --strict" 1
expect_out "18: the FAIL row names the lane" "not allowed in lane coding"

# 19. The id is not verified by the policy.
r="$(new_repo policyverified "$policy_config" "$list_text")"
write_policy "$r" <<'EOF'
id=lane.verified.model-b
effect=permit
principal=*
action=lane.verified
resource=model-b
EOF
run_gate --strict --check model-ids --repo "$r"
expect_status "19: an id the policy does not verify fails --strict" 1
expect_out "19: the FAIL row names the policy rule" "not verified by policy/rules rule default.deny"

# 20. A policy/rules that cannot be loaded fails closed.
r="$(new_repo policybad "$policy_config" "$list_text")"
write_policy "$r" <<'EOF'
this line is not a key=value record
EOF
run_gate --check model-ids --repo "$r"
expect_status "20: an unloadable policy exits 2" 2
expect_err "20: the load failure names the policy rules" "cannot load policy rules"

# 21. A list-rejected id keeps the unverified row even with a policy present.
r="$(new_repo policylist '{"lanes":{"coding":{"entries":[{"agent":"one","model":"model-z"}]}}}' "$list_text")"
write_policy "$r" <<'EOF'
id=lane.verified.model-a
effect=permit
principal=*
action=lane.verified
resource=model-a
EOF
run_gate --strict --check model-ids --repo "$r"
expect_status "21: a list-rejected id keeps its FAIL" 1
expect_out "21: the unverified row is unchanged" "unverified id model-z; add it to templates/agent-config.verified-model-ids.txt"
expect_no_out "21: no policy row duplicates the unverified row" "not verified by policy/rules"

# 22. Consumer-provided paths via flags (--agent-config and --verified-ids)
# work without kit templates/agent-config.example.json or verified-model-ids.txt.
r="$(new_repo consumerflags "" "")"
mkdir -p "$r/config"
printf '%s\n' "$good_config" >"$r/config/agents.json"
printf '%s\n' "$list_text" >"$r/config/verified.txt"
run_gate --strict --check model-ids --repo "$r" \
  --agent-config config/agents.json --verified-ids config/verified.txt
expect_status "22: consumer flags pass without kit example files" 0
expect_out "22: summary counts consumer entries" "3 entries, 0 hits"

# 23. Consumer-provided paths via gate.config.json work without kit example files.
consumer_gate_cfg="$work_tmp/consumer-gate.json"
cat >"$consumer_gate_cfg" <<'JSON'
{
  "model_ids": {
    "config": "config/agents.json",
    "verified_ids": "config/verified.txt"
  }
}
JSON
run_gate --strict --check model-ids --repo "$r" --config "$consumer_gate_cfg"
expect_status "23: consumer gate.config.json passes without kit example files" 0
expect_out "23: summary counts consumer entries from config" "3 entries, 0 hits"

# 24. With no consumer paths and no kit example files, model-ids exits 2.
r_empty="$(new_repo consumermissing "" "")"
run_gate --strict --check model-ids --repo "$r_empty"
expect_status "24: missing consumer and kit files exits 2" 2
expect_err "24: names missing config" "config not found"

# 25. Flag validation and path safety (fail closed).
run_gate --check model-ids --repo "$r" --agent-config /etc/passwd --verified-ids config/verified.txt
expect_status "25: absolute --agent-config exits 2" 2
run_gate --check model-ids --repo "$r" --agent-config ../agents.json --verified-ids config/verified.txt
expect_status "25: traversal --agent-config exits 2" 2
run_gate --check line-cap --repo "$r" --agent-config config/agents.json
expect_status "25: --agent-config with wrong check exits 2" 2

printf 'model-ids tests: %s passed, %s failed\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
  exit 1
fi
exit 0
