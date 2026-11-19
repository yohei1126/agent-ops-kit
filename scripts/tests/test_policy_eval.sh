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

printf '== sourced decision after a failed load ==\n'

cat > "$work_tmp/truncated" <<'POL'
id=allow.docs
effect=permit
action=skip-model-check
resource=docs/*.md
principal=*

this line is not key=value
POL

run_sourced_decide() {
  (
    # shellcheck source-path=SCRIPTDIR
    # shellcheck source=../lib/policy-eval.sh
    . "$repo_root/scripts/lib/policy-eval.sh"
    if [ -n "$2" ]; then
      export POLICY_RULES="$2"
    else
      unset POLICY_RULES
    fi
    load_status=0
    if [ "$1" != "-" ]; then
      policy_eval_load "$1" 2>/dev/null || load_status=$?
    fi
    decide_status=0
    policy_eval_decide "$3" "$4" 2>/dev/null || decide_status=$?
    printf '%s|%s|%s|%s|%s\n' "$load_status" "$decide_status" \
      "$policy_eval_effect" "$policy_eval_rule" "$policy_eval_loaded"
  )
}

sourced_result="$(run_sourced_decide "$work_tmp/truncated" "" skip-model-check docs/guide.md)"
IFS='|' read -r sourced_load sourced_decide sourced_effect sourced_rule sourced_loaded <<EOF
$sourced_result
EOF

if [ "$sourced_load" -ne 0 ]; then
  ok "truncated policy load fails"
else
  bad "truncated policy load fails" "expected a non-zero load exit, got $sourced_load"
fi
status="$sourced_decide"
expect_status "truncated policy decide exits 3" 3
out="$sourced_effect"
expect_line "truncated policy effect is DENY" "DENY"
out="$sourced_rule"
expect_line "truncated policy rule is default.deny" "default.deny"
out="$sourced_loaded"
expect_line "truncated policy is not left loaded" "0"

sourced_result="$(run_sourced_decide "-" "$work_tmp/no-such-policy" skip-model-check docs/guide.md)"
IFS='|' read -r sourced_load sourced_decide sourced_effect sourced_rule sourced_loaded <<EOF
$sourced_result
EOF

status="$sourced_decide"
expect_status "sourced missing policy decide exits 3" 3
out="$sourced_effect"
expect_line "sourced missing policy effect is DENY" "DENY"
out="$sourced_rule"
expect_line "sourced missing policy rule is default.deny" "default.deny"

printf '== empty policy ==\n'

: > "$work_tmp/empty-policy"
run_eval --policy "$work_tmp/empty-policy" --action skip-model-check --resource docs/guide.md
expect_status "empty policy file exits 3" 3
expect_err "empty policy file has no rules" "no rules"

printf '# only a comment\n' > "$work_tmp/comments-policy"
run_eval --policy "$work_tmp/comments-policy" --action skip-model-check --resource docs/guide.md
expect_status "comments-only policy file exits 3" 3
expect_err "comments-only policy file has no rules" "no rules"

printf '== invalid policy values ==\n'

cat > "$work_tmp/bad-case" <<'POL'
id=forbid.token
effect=forbid
action=skip-model-check
resource=*token*
match=glob
case=lowercase

id=allow.docs
effect=permit
action=skip-model-check
resource=docs/*.md
principal=*
POL
run_eval --policy "$work_tmp/bad-case" --action skip-model-check --resource docs/TOKEN-notes.md
expect_status "lowercase case exits 3" 3
expect_err "lowercase case is named" "invalid case"

cat > "$work_tmp/bad-match" <<'POL'
id=bad.match
effect=permit
action=skip-model-check
resource=docs/*.md
match=exact
POL
run_eval --policy "$work_tmp/bad-match" --action skip-model-check --resource docs/guide.md
expect_status "bad match exits 3" 3
expect_err "bad match is named" "invalid match"

cat > "$work_tmp/bad-principal" <<'POL'
id=bad.principal
effect=permit
action=skip-model-check
resource=docs/*.md
principal=bot
POL
run_eval --policy "$work_tmp/bad-principal" --action skip-model-check --resource docs/guide.md
expect_status "bad principal exits 3" 3
expect_err "bad principal is named" "invalid principal"

cat > "$work_tmp/bad-key" <<'POL'
id=bad.key
effect=permit
action=skip-model-check
resource=docs/*.md
foo=bar
POL
run_eval --policy "$work_tmp/bad-key" --action skip-model-check --resource docs/guide.md
expect_status "unknown key exits 3" 3
expect_err "unknown key is named" "unknown key"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -ne 0 ]; then
  exit 1
fi
exit 0
