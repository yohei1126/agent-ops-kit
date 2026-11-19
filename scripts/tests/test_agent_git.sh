#!/usr/bin/env bash
# Tests for scripts/dev-loop-gate.sh --check agent-git.
# Local temp git repos only, no network.
set -u

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
gate="$repo_root/scripts/dev-loop-gate.sh"

pass=0
fail=0
work_tmp="$(mktemp -d)"
err_file="$work_tmp/stderr"
: > "$err_file"

out=""
err=""
status=0

trap 'rm -rf "$work_tmp"' EXIT

unset DEV_LOOP_NAME_LIST
unset DEV_LOOP_BRANCH DEV_LOOP_ALIAS DEV_LOOP_REQUIRED_PATH \
  DEV_LOOP_SOFT_DENY_COUNT DEV_LOOP_MODEL_LANE DEV_LOOP_DIFF_KIND \
  DEV_LOOP_PR_STATE DEV_LOOP_OPERATOR_READY DEV_LOOP_VULN_SILENT \
  DEV_LOOP_RETRO_MARKER DEV_LOOP_OPEN_JOBS DEV_LOOP_OPEN_PRS

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

expect_regex() {
  if printf '%s\n' "$out" | grep -Eq "$2"; then
    ok "$1"
  else
    bad "$1" "stdout missing line matching: $2"
  fi
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
    *) bad "$1" "stderr missing: $2" ;;
  esac
}

expect_no_quote() {
  if printf '%s\n' "$out" | grep -q '"'; then
    bad "$1" "stdout contains a double quote"
  else
    ok "$1"
  fi
}

make_repo() {
  local dir
  dir="$(mktemp -d "$work_tmp/repo.XXXXXX")/repo"
  mkdir -p "$dir/docs"
  git -C "$dir" init -q
  printf '%s\n' "$dir"
}

track() {
  local dir="$1"
  shift
  git -C "$dir" add "$@"
}

run_gate() {
  local dir="$1"
  shift
  : > "$err_file"
  out="$(cd "$dir" && "$@" 2>"$err_file")"
  status=$?
  err="$(cat "$err_file")"
}

printf '== scope hits ==\n'

hit_repo="$(make_repo)"
mkdir -p "$hit_repo/templates"
cat > "$hit_repo/templates/agent-task-issue.md" <<'MD'
# Task
Run git add .
Run git commit -m change.
Run git push origin HEAD.
Run gh pr create --draft.
MD
track "$hit_repo" templates/agent-task-issue.md

run_gate "$repo_root" bash "$gate" --repo "$hit_repo" --check agent-git
expect_status "A1: in-scope hits are advisory" 0
expect_regex "A1: git add row" "^AG +templates/agent-task-issue\.md:2 +FAIL +found git add; "
expect_regex "A1: git commit row" "^AG +templates/agent-task-issue\.md:3 +FAIL +found git commit; "
expect_regex "A1: git push row" "^AG +templates/agent-task-issue\.md:4 +FAIL +found git push; "
expect_regex "A1: gh pr create row" "^AG +templates/agent-task-issue\.md:5 +FAIL +found gh pr create; "
expect_out "A1: summary counts four hits" "1 files, 4 hits"
expect_no_quote "A1: rows have no double quote"

run_gate "$repo_root" bash "$gate" --repo "$hit_repo" --check agent-git --strict
expect_status "A2: in-scope hits fail under strict" 1

printf '== out of scope ==\n'

caller_repo="$(make_repo)"
mkdir -p "$caller_repo/prompts"
printf '# Clean\nRun the tests and report.\n' > "$caller_repo/prompts/clean.md"
printf 'Create the pull request with gh pr create --draft in the collect step.\n' > "$caller_repo/docs/launch-approvals-and-collection.md"
printf 'Operator release example: git push origin main.\n' > "$caller_repo/docs/monthly-audit.md"
track "$caller_repo" prompts/clean.md docs/launch-approvals-and-collection.md docs/monthly-audit.md

run_gate "$repo_root" bash "$gate" --repo "$caller_repo" --check agent-git --strict
expect_status "A3: caller and audit examples pass under strict" 0
expect_regex "A3: only the clean in-scope file is counted" "^AG +agent-git +PASS +1 files, 0 hits$"
expect_no_out "A3: collect doc is not reported" "launch-approvals-and-collection.md"
expect_no_out "A3: audit doc is not reported" "monthly-audit.md"

printf '== clean and untracked ==\n'

clean_repo="$(make_repo)"
printf '# Handoffs\nRun the tests and report the branch.\n' > "$clean_repo/docs/workstation-handoffs.md"
track "$clean_repo" docs/workstation-handoffs.md

run_gate "$repo_root" bash "$gate" --repo "$clean_repo" --check agent-git --strict
expect_status "A4: clean in-scope file passes under strict" 0
expect_regex "A4: clean summary passes" "^AG +agent-git +PASS +1 files, 0 hits$"

untracked_repo="$(make_repo)"
mkdir -p "$untracked_repo/prompts"
printf '# Clean\n' > "$untracked_repo/prompts/clean.md"
printf 'Run git push origin HEAD.\n' > "$untracked_repo/prompts/draft.md"
track "$untracked_repo" prompts/clean.md

run_gate "$repo_root" bash "$gate" --repo "$untracked_repo" --check agent-git --strict
expect_status "A5: untracked in-scope file is ignored" 0
expect_no_out "A5: untracked path is not reported" "prompts/draft.md"
expect_out "A5: only the tracked file is counted" "1 files, 0 hits"

printf '== allowed commands ==\n'

allowed_repo="$(make_repo)"
mkdir -p "$allowed_repo/prompts"
cat > "$allowed_repo/prompts/allowed.md" <<'MD'
# Allowed
Run git status and git diff before reporting.
Operators may git tag and use gh release create.
MD
track "$allowed_repo" prompts/allowed.md

run_gate "$repo_root" bash "$gate" --repo "$allowed_repo" --check agent-git --strict
expect_status "A6: status and diff are not hits" 0
expect_out "A6: allowed commands produce no hits" "1 files, 0 hits"

printf '== prefix guard ==\n'

prefix_repo="$(make_repo)"
mkdir -p "$prefix_repo/prompts"
cat > "$prefix_repo/prompts/prefix.md" <<'MD'
# Prefix
This git additional note is harmless.
This git committing note is harmless.
MD
track "$prefix_repo" prompts/prefix.md

run_gate "$repo_root" bash "$gate" --repo "$prefix_repo" --check agent-git --strict
expect_status "A7: prefix words are not hits" 0
expect_out "A7: prefix words produce no hits" "1 files, 0 hits"

printf '== kit self-check ==\n'

run_gate "$repo_root" bash "$gate" --repo "$repo_root" --strict --check agent-git
expect_status "A8: kit passes strict agent-git" 0
expect_regex "A8: kit summary passes" "^AG +agent-git +PASS +[0-9]+ files, 0 hits$"

printf '== missing and malformed policy ==\n'

policy_repo="$(make_repo)"
printf '# Handoffs\nRun the tests and report the branch.\n' > "$policy_repo/docs/workstation-handoffs.md"
track "$policy_repo" docs/workstation-handoffs.md

run_gate "$repo_root" env POLICY_RULES="$work_tmp/no-such-policy" bash "$gate" \
  --repo "$policy_repo" --check agent-git
expect_status "P1: missing policy fails closed without strict" 3
expect_err "P1: missing policy error is clear" "cannot load the agent-git policy"
expect_no_out "P1: missing policy does not print PASS" "PASS"

cat > "$work_tmp/malformed-policy" <<'POL'
id=allow.docs
effect=permit
action=agent-git.scan
resource=docs/*.md
principal=*

this line is not key=value
POL

run_gate "$repo_root" env POLICY_RULES="$work_tmp/malformed-policy" bash "$gate" \
  --repo "$policy_repo" --check agent-git
expect_status "P2: malformed policy fails closed without strict" 3
expect_err "P2: malformed policy error is clear" "cannot load the agent-git policy"
expect_no_out "P2: malformed policy does not print PASS" "PASS"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -ne 0 ]; then
  exit 1
fi
exit 0
