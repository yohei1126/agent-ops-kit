#!/usr/bin/env bash
# Decision-table runner for policy/cases.
# No network. Bash 3.2 compatible.
set -u

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
policy_eval="$repo_root/scripts/policy-eval.sh"
cases_file="${POLICY_CASES:-$repo_root/policy/cases}"

pass=0
fail=0
work_tmp="$(mktemp -d)"
err_file="$work_tmp/stderr"
: > "$err_file"

out=""
err=""
status=0
tab="$(printf '\t')"

trap 'rm -rf "$work_tmp"' EXIT

ok() {
  pass=$((pass + 1))
  printf 'PASS %s\n' "$1"
}

bad() {
  fail=$((fail + 1))
  printf 'FAIL %s: %s\n' "$1" "$2"
}

if [ ! -r "$cases_file" ]; then
  printf 'test_policy_cases: cannot read %s\n' "$cases_file" >&2
  exit 2
fi

while IFS="$tab" read -r name action resource attrs expected rule_id || [ -n "$name" ]; do
  case "$name" in
    '' | '#'* | name) continue ;;
  esac

  args=()
  args[${#args[@]}]="--action"
  args[${#args[@]}]="$action"
  args[${#args[@]}]="--resource"
  args[${#args[@]}]="$resource"
  if [ "$attrs" != "-" ]; then
    old_ifs="$IFS"
    IFS=,
    set -f
    for attr in $attrs; do
      args[${#args[@]}]="--attr"
      args[${#args[@]}]="$attr"
    done
    set +f
    IFS="$old_ifs"
  fi

  case "$expected" in
    ALLOW) want_status=0 ;;
    DENY) want_status=1 ;;
    *)
      bad "$name" "unknown expected effect: $expected"
      continue
      ;;
  esac

  : > "$err_file"
  out="$(bash "$policy_eval" "${args[@]}" 2>"$err_file")"
  status=$?
  err="$(cat "$err_file")"

  if [ "$status" -ne "$want_status" ]; then
    bad "$name" "expected exit $want_status, got $status; stderr: $err"
    continue
  fi
  if [ "$out" = "$expected $rule_id" ]; then
    ok "$name"
  else
    bad "$name" "expected '$expected $rule_id', got '$out'"
  fi
done < "$cases_file"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -ne 0 ]; then
  exit 1
fi
exit 0
