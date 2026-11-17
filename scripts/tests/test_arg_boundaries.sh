#!/usr/bin/env bash
# Table-driven argument-boundary test for the launchers that have --dry-run.
#
# Each row runs a launcher in dry-run mode with arguments that are easy to
# drop, split, or reinterpret: literal values after `--`, paths with spaces,
# empty strings, leading-dash values, and shell metacharacters. The test reads
# the printed command line (COMMAND= or AGY_COMMAND=, quoted with printf %q),
# parses it back into argv, and asserts the arguments arrived literally.
#
# No agent runs: PATH holds only a stub `agy` that records any start and a
# private directory of system utilities. Bash 3.2 compatible.
set -u

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
scripts="$repo_root/scripts"
example_config="$repo_root/templates/agent-config.example.json"

pass=0
fail=0
# Physical path: launchers resolve symlinks (macOS /var is /private/var).
work_tmp="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$work_tmp"' EXIT

home="$work_tmp/home"
agy_record="$work_tmp/agy-started"
fake_bin="$work_tmp/bin"
tool_bin="$work_tmp/tool-bin"
mkdir -p "$home/agy-work/repo two" "$fake_bin" "$tool_bin"

cat >"$fake_bin/agy" <<SH
#!/bin/sh
printf 'agy started\n' >>"$agy_record"
exit 99
SH
chmod +x "$fake_bin/agy"

# The launchers run under the same bash as this test (macOS CI uses
# /bin/bash 3.2), including scripts they start through `bash` on PATH.
ln -s "$BASH" "$tool_bin/bash"
for cmd in jq tr mkdir kill cp mv cat uname mktemp sed wc rm ln \
  readlink realpath dirname basename chmod date head env nohup tee cut \
  sort uniq touch sleep grep find ls printf; do
  cmd_path="$(command -v "$cmd" 2>/dev/null)" || continue
  case "$cmd_path" in
    '' | */agy | */caffeinate | "$fake_bin"/*) continue ;;
    /*) ln -s "$cmd_path" "$tool_bin/$cmd" ;;
  esac
done
test_path="$fake_bin:$tool_bin"

# The brief text itself carries a leading dash, a metacharacter, a glob, and a
# double space, so a word-split or evaluated prompt shows up as a mismatch.
# shellcheck disable=SC2016
brief_text='-x $(printf PWNED) * two  spaces'
printf '%s\n' "$brief_text" >"$home/agy-work/-brief one.md"
# A brief whose file name looks like a review flag, in the working directory.
printf '%s\n' "$brief_text" >"$home/--check-settings"

ok() {
  pass=$((pass + 1))
  printf 'PASS %s\n' "$1"
}

bad() {
  fail=$((fail + 1))
  printf 'FAIL %s: %s\n' "$1" "$2"
}

out=""
status=0
parsed=()

# run_case <cmd...>: runs one launcher with the closed PATH from $home.
run_case() {
  out="$(cd "$home" && HOME="$home" PATH="$test_path" "$@" 2>&1)"
  status=$?
}

# parse_field <NAME>: parses the NAME= line of $out into the parsed array.
# The launchers print it with printf %q, so eval only removes the quoting; a
# launcher that stopped quoting would run the metacharacter payload, which
# changes the value and fails the comparison.
parse_field() {
  local line
  line="$(printf '%s\n' "$out" | grep -m1 "^$1=")" || return 1
  line="${line#"$1"=}"
  set -f
  eval "parsed=($line)"
  set +f
}

# expect_tail <label> <expected...>: the last N parsed words equal expected.
expect_tail() {
  local label="$1"
  shift
  local n=$# total=${#parsed[@]} i=0 want got
  if [ "$total" -lt "$n" ]; then
    bad "$label" "only $total words, wanted the last $n"
    return
  fi
  for want in "$@"; do
    got="${parsed[$((total - n + i))]}"
    if [ "$got" != "$want" ]; then
      bad "$label" "word $((total - n + i)) is [$got], wanted [$want]"
      return
    fi
    i=$((i + 1))
  done
  ok "$label"
}

# expect_seq <label> <expected...>: the expected words appear contiguously.
expect_seq() {
  local label="$1"
  shift
  local n=$# total=${#parsed[@]} start=0 i match want
  while [ $((start + n)) -le "$total" ]; do
    match=1
    i=0
    for want in "$@"; do
      if [ "${parsed[$((start + i))]}" != "$want" ]; then
        match=0
        break
      fi
      i=$((i + 1))
    done
    if [ "$match" = 1 ]; then
      ok "$label"
      return
    fi
    start=$((start + 1))
  done
  bad "$label" "sequence not found: $*"
}

expect_status() {
  if [ "$status" -eq "$2" ]; then
    ok "$1"
  else
    bad "$1" "expected exit $2, got $status; output: $out"
  fi
}

# Literal values that must survive the hand-off unchanged.
# shellcheck disable=SC2016
literal_args=(--title 'a b' '' -x -- '$(printf PWNED)' '*' "tab	in")

# Rows: one function per launcher surface. Each sets up its own command.
row_issue_bot() {
  run_case "$BASH" "$scripts/agent-launch.sh" --config "$example_config" \
    --lane coding --as bot --agent agy-subscription --dry-run -- "${literal_args[@]}"
  expect_status "issue hand-off (bot): dry-run exits 0" 0
  if parse_field COMMAND; then
    expect_tail "issue hand-off (bot): args after -- arrive literally" "${literal_args[@]}"
  else
    bad "issue hand-off (bot)" "no COMMAND= line"
  fi
}

row_issue_maintainer() {
  run_case "$BASH" "$scripts/agent-launch.sh" --config "$example_config" \
    --lane coding --as maintainer --agent agy-subscription --dry-run -- "${literal_args[@]}"
  expect_status "issue hand-off (maintainer): dry-run exits 0" 0
  if parse_field COMMAND; then
    expect_tail "issue hand-off (maintainer): args after -- arrive literally" "${literal_args[@]}"
  else
    bad "issue hand-off (maintainer)" "no COMMAND= line"
  fi
}

row_adapter_entry() {
  run_case "$BASH" "$scripts/agent-launch.sh" --config "$example_config" \
    --lane security-review --as maintainer --agent agy-subscription --dry-run -- \
    run-a "$home/agy-work/repo two" "$home/agy-work/-brief one.md"
  expect_status "entry point (adapter): dry-run exits 0" 0
  if parse_field COMMAND; then
    expect_tail "entry point (adapter): positionals keep spaces and the dash" \
      -- run-a "$home/agy-work/repo two" "$home/agy-work/-brief one.md"
  else
    bad "entry point (adapter)" "no COMMAND= line"
  fi
}

row_review_wrapper() {
  run_case "$BASH" "$scripts/agy-review-launch.sh" --dry-run -- \
    run-b "$home/agy-work/repo two" "$home/agy-work/-brief one.md"
  expect_status "review wrapper: dry-run exits 0" 0
  if parse_field AGY_COMMAND; then
    expect_seq "review wrapper: repo path with a space is one word" \
      --add-dir "$home/agy-work/repo two"
    expect_tail "review wrapper: brief text is one literal prompt" --print "$brief_text"
  else
    bad "review wrapper" "no AGY_COMMAND= line"
  fi
}

row_adapter_flag_like_brief() {
  run_case "$BASH" "$scripts/agents/agy/run" --mode review --model test-model -- \
    --dry-run -- run-c "$home/agy-work/repo two" --check-settings
  expect_status "adapter: dry-run with a flag-like brief name exits 0" 0
  if parse_field AGY_COMMAND; then
    expect_tail "adapter: a positional after the second -- is a path, not a flag" \
      --print "$brief_text"
  else
    bad "adapter flag-like brief" "no AGY_COMMAND= line"
  fi
}

row_review_empty_brief() {
  run_case "$BASH" "$scripts/agy-review-launch.sh" --dry-run -- \
    run-d "$home/agy-work/repo two" ''
  if [ "$status" -ne 0 ]; then
    ok "review wrapper: an empty brief argument is refused, not dropped"
  else
    bad "review wrapper: empty brief" "exit 0; output: $out"
  fi
}

# Self-test: a launcher that word-splits its arguments must fail the
# comparison, so a regression cannot pass by accident.
row_broken_stub() {
  local broken="$work_tmp/broken-launcher"
  local before_pass=$pass before_fail=$fail
  cat >"$broken" <<'SH'
#!/bin/sh
# Drops the quoting, as a careless launcher would.
echo "COMMAND=tool $*"
SH
  chmod +x "$broken"
  run_case "$broken" "${literal_args[@]}"
  parse_field COMMAND
  expect_tail "self-test probe" "${literal_args[@]}" >/dev/null
  if [ "$fail" -gt "$before_fail" ]; then
    pass=$before_pass
    fail=$before_fail
    ok "self-test: a word-splitting launcher fails the comparison"
  else
    pass=$before_pass
    fail=$before_fail
    bad "self-test" "a word-splitting launcher passed"
  fi
}

row_issue_bot
row_issue_maintainer
row_adapter_entry
row_review_wrapper
row_adapter_flag_like_brief
row_review_empty_brief
row_broken_stub

if [ -e "$agy_record" ]; then
  bad "no agent started" "the stub agy was called"
else
  ok "no agent started"
fi

printf 'arg-boundary tests: %s passed, %s failed\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
  exit 1
fi
exit 0
