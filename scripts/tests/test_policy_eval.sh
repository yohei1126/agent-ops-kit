#!/usr/bin/env bash
# Tests for scripts/policy-eval.sh.
# No network. Bash 3.2 compatible.
set -u

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
policy_eval="$repo_root/scripts/policy-eval.sh"

pass=0
fail=0
work_tmp="$(mktemp -d)"
err_file="$work_tmp/stderr"
: > "$err_file"

out=""
err=""
status=0

trap 'rm -rf "$work_tmp"' EXIT

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

expect_err() {
  case "$err" in
    *"$2"*) ok "$1" ;;
    *) bad "$1" "stderr missing: $2" ;;
  esac
}

expect_line() {
  if [ "$out" = "$2" ]; then
    ok "$1"
  else
    bad "$1" "expected '$2', got '$out'"
  fi
}

run_eval() {
  : > "$err_file"
  out="$(bash "$policy_eval" "$@" 2>"$err_file")"
  status=$?
  err="$(cat "$err_file")"
}

printf '== help ==\n'

run_eval --help
expect_status "help exits 0" 0
expect_out "help names the default deny" "default"
expect_out "help names forbid precedence" "forbid"
expect_out "help shows ALLOW" "ALLOW <rule-id>"
expect_out "help shows DENY" "DENY <rule-id>"
expect_out "help shows exit codes" "Exit codes"

printf '== usage ==\n'

run_eval --resource docs/guide.md
expect_status "missing action exits 2" 2

run_eval --action skip-model-check
expect_status "missing resource exits 2" 2

run_eval --policy "" --action skip-model-check --resource docs/guide.md
expect_status "empty policy exits 2" 2

printf '== policy errors ==\n'

run_eval --policy "$work_tmp/missing" --action skip-model-check --resource docs/guide.md
expect_status "missing policy exits 3" 3
expect_err "missing policy is named" "cannot read policy file"

cat > "$work_tmp/dup" <<'POL'
id=dup.rule
effect=permit
action=skip-model-check
resource=*

id=dup.rule
effect=permit
action=skip-model-check
resource=*
POL
run_eval --policy "$work_tmp/dup" --action skip-model-check --resource docs/guide.md
expect_status "duplicate id exits 3" 3
expect_err "duplicate id is named" "duplicate policy rule id"

cat > "$work_tmp/bad-effect" <<'POL'
id=bad.effect
effect=maybe
action=skip-model-check
resource=*
POL
run_eval --policy "$work_tmp/bad-effect" --action skip-model-check --resource docs/guide.md
expect_status "bad effect exits 3" 3
expect_err "bad effect is named" "invalid effect"

printf '== mcr meta ==\n'

expected_meta='Line cap: 150
Deny list: .github/* *auth* *secret* *token* *credential* *permission* *launch* *settings* *security* .env* */.env* scripts/agents/* scripts/templates/* scripts/quota/* scripts/dev-loop-gate.sh scripts/lib/* scripts/tests/test_model_check_required.sh scripts/tests/test_dev_loop_gate.sh templates/dev-loop/* prompts/* *agent-config* *model-ids*
Allow list: docs/*.md README.md scripts/README.md'

run_eval --print-mcr-meta
expect_status "meta exits 0" 0
expect_line "meta matches the three exact lines" "$expected_meta"

printf '== decisions ==\n'

run_eval --action skip-model-check --resource docs/guide.md
expect_status "docs path exits 0" 0
expect_line "docs path allows" "ALLOW mcr.allow.docs"

run_eval --action skip-model-check --resource docs/TOKEN-notes.md
expect_status "token path exits 1" 1
expect_line "token path denies" "DENY mcr.deny.token"

run_eval --action skip-model-check --resource src/app.js
expect_status "unknown path exits 1" 1
expect_line "unknown path uses default deny" "DENY default.deny"

run_eval --action skip-model-check --resource docs/guide.md --attr changed_lines=150
expect_status "cap equal exits 0" 0
expect_line "cap equal allows" "ALLOW mcr.allow.docs"

run_eval --action skip-model-check --resource docs/guide.md --attr changed_lines=151
expect_status "cap over exits 1" 1
expect_line "cap over denies" "DENY mcr.line-cap"

run_eval --action agent-git.scan --resource docs/workstation-handoffs.md
expect_status "in-scope scan exits 0" 0
expect_line "in-scope scan allows" "ALLOW agent-git.scope.handoffs"

run_eval --action agent-git.scan --resource docs/launch-approvals-and-collection.md
expect_status "out-of-scope scan exits 1" 1
expect_line "out-of-scope scan uses default deny" "DENY default.deny"

run_eval --action agent-git.instruct --resource templates/agent-task-issue.md \
  --attr "text=Run git add ."
expect_status "git add text exits 1" 1
expect_line "git add text hits the rule" "DENY agent-git.forbid.git-add"

run_eval --action agent-git.instruct --resource prompts/prefix.md \
  --attr "text=This git additional note is harmless."
expect_status "git additional text exits 1" 1
expect_line "git additional text is not a hit" "DENY default.deny"

run_eval --list-forbids --action agent-git.instruct
expect_status "list-forbids exits 0" 0
expect_out "list-forbids names git add" "agent-git.forbid.git-add"
expect_out "list-forbids carries the label" "git add"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -ne 0 ]; then
  exit 1
fi
exit 0
