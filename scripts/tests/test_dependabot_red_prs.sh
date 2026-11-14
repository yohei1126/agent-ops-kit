#!/usr/bin/env bash
# Tests for scripts/dependabot-red-prs.sh.
# Uses a fake gh on PATH. No network and no real repository.
set -u

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
check="$repo_root/scripts/dependabot-red-prs.sh"
fixtures="$repo_root/scripts/tests/fixtures/dependabot-red-prs"

pass=0
fail=0
work_tmp="$(mktemp -d)"
home_tmp="$work_tmp/home"
fake_bin="$work_tmp/bin"
argv_file="$work_tmp/argv"
err_file="$work_tmp/stderr"

mkdir -p "$home_tmp" "$fake_bin"
: > "$argv_file"
: > "$err_file"

trap 'rm -rf "$work_tmp"' EXIT

unset DEPENDABOT_RED_NOW DEPENDABOT_RED_FIXTURE DEPENDABOT_RED_GH_FAIL

# Fixed clock: 2026-01-10T00:00:00Z. The fixtures use fixed ISO8601
# timestamps, so 2026-01-09 is 1 day old and 2026-01-01 is 9 days old.
now_epoch=1768003200

cat > "$fake_bin/gh" <<'EOF'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${DEPENDABOT_RED_ARGV_FILE:-/dev/null}"
if [ "${DEPENDABOT_RED_GH_FAIL:-0}" = 1 ]; then
  printf 'gh: boom, not logged in\n' >&2
  printf 'gh: see the log\n' >&2
  exit 1
fi
cat "$DEPENDABOT_RED_FIXTURE_DIR/${DEPENDABOT_RED_FIXTURE:-no-prs}.json"
EOF
chmod +x "$fake_bin/gh"

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

expect_line() {
  if printf '%s\n' "$out" | grep -Fxq -- "$2"; then
    ok "$1"
  else
    bad "$1" "stdout missing exact line: $2"
  fi
}

expect_out_eq() {
  if [ "$out" = "$2" ]; then
    ok "$1"
  else
    bad "$1" "stdout is '$out'"
  fi
}

expect_last_line() {
  local last
  last="$(printf '%s\n' "$out" | tail -n 1)"
  if [ "$last" = "$2" ]; then
    ok "$1"
  else
    bad "$1" "last line is '$last', expected '$2'"
  fi
}

expect_err() {
  case "$err" in
    *"$2"*) ok "$1" ;;
    *) bad "$1" "stderr missing: $2" ;;
  esac
}

expect_no_err() {
  case "$err" in
    *"$2"*) bad "$1" "stderr should not contain: $2" ;;
    *) ok "$1" ;;
  esac
}

expect_empty_err() {
  if [ -z "$err" ]; then
    ok "$1"
  else
    bad "$1" "stderr should be empty: $err"
  fi
}

expect_argv_has() {
  if grep -Fq -- "$2" "$argv_file"; then
    ok "$1"
  else
    bad "$1" "argv missing: $2"
  fi
}

expect_argv_never() {
  if grep -Eq -- '(^| )(close|comment|merge|edit)( |$)' "$argv_file"; then
    bad "$1" "argv contains a write verb"
  else
    ok "$1"
  fi
}

expect_argv_calls() {
  local actual
  actual="$(wc -l < "$argv_file" | tr -d ' ')"
  if [ "$actual" -eq "$2" ]; then
    ok "$1"
  else
    bad "$1" "argv has $actual calls, expected $2"
  fi
}

fixture=no-prs
gh_fail=0

# The PATH the check runs with. Tests that hide a tool replace it.
check_path="$fake_bin:$PATH"

run_check() {
  : > "$argv_file"
  : > "$err_file"
  out="$(env HOME="$home_tmp" \
    DEPENDABOT_RED_NOW="$now_epoch" \
    DEPENDABOT_RED_FIXTURE_DIR="$fixtures" \
    DEPENDABOT_RED_FIXTURE="$fixture" \
    DEPENDABOT_RED_GH_FAIL="$gh_fail" \
    DEPENDABOT_RED_ARGV_FILE="$argv_file" \
    PATH="$check_path" \
    bash "$check" "$@" 2>"$err_file")"
  status=$?
  err="$(cat "$err_file")"
}

# Link only the named commands into a fresh directory, following
# scripts/tests/test_pr_state.sh. A PATH built from that directory alone keeps
# the real gh or jq out of reach.
make_tool_path() {
  local dir="$1"
  shift
  local tool found

  mkdir -p "$dir"
  for tool in "$@"; do
    found="$(command -v "$tool" 2>/dev/null || true)"
    if [ -n "$found" ]; then
      ln -s "$found" "$dir/$tool"
    fi
  done
}

expect_no_tab() {
  if printf '%s\n' "$out" | grep -q $'\t'; then
    bad "$1" "stdout contains a literal tab"
  else
    ok "$1"
  fi
}

printf '== no pull requests ==\n'

fixture=no-prs
gh_fail=0
run_check --repo example-org/example-repo
expect_status "1: no pull requests exits 0" 0
expect_out_eq "1: prints only the summary" \
  "summary: 0 open dependabot PRs, 0 flagged"
expect_empty_err "1: no pull requests prints no stderr"
expect_argv_calls "1: no pull requests calls gh once" 1

printf '== one green young pull request ==\n'

fixture=green-young
gh_fail=0
run_check --repo example-org/example-repo
expect_status "2: green young exits 0" 0
expect_line "2: green young is ok" \
  "ok  example-org/example-repo#101  green  1d  https://example.com/pulls/101  Bump example-package from 1.0.0 to 1.0.1"
expect_last_line "2: summary comes last" \
  "summary: 1 open dependabot PRs, 0 flagged"

printf '== one red young pull request ==\n'

fixture=red-young
gh_fail=0
run_check --repo example-org/example-repo
expect_status "3: red young exits 1" 1
expect_line "3: red young is flagged" \
  "FLAG  example-org/example-repo#102  red  1d  https://example.com/pulls/102  Bump example-package from 1.0.0 to 1.0.1"
expect_last_line "3: summary counts the flag" \
  "summary: 1 open dependabot PRs, 1 flagged"

printf '== pending pull request older than the default ==\n'

fixture=pending-old
gh_fail=0
run_check --repo example-org/example-repo
expect_status "4: a stale pending pull request exits 1" 1
expect_line "4: a stale pending pull request is flagged" \
  "FLAG  example-org/example-repo#103  pending  9d  https://example.com/pulls/103  Bump example-package from 1.0.0 to 1.0.1"
expect_last_line "4: summary counts the stale flag" \
  "summary: 1 open dependabot PRs, 1 flagged"

fixture=pending-old
gh_fail=0
run_check --repo example-org/example-repo --days 10
expect_status "5: --days 10 accepts a 9 day old pending pull request" 0
expect_line "5: --days 10 reports it as ok" \
  "ok  example-org/example-repo#103  pending  9d  https://example.com/pulls/103  Bump example-package from 1.0.0 to 1.0.1"
expect_last_line "5: --days 10 summary has no flag" \
  "summary: 1 open dependabot PRs, 0 flagged"

printf '== status contexts ==\n'

fixture="status-error"
gh_fail=0
run_check --repo example-org/example-repo
expect_status "6: StatusContext ERROR exits 1" 1
expect_line "6: StatusContext ERROR counts as red" \
  "FLAG  example-org/example-repo#104  red  1d  https://example.com/pulls/104  Bump example-package from 1.0.0 to 1.0.1"

fixture=no-checks
gh_fail=0
run_check --repo example-org/example-repo
expect_status "7: no checks exits 0" 0
expect_line "7: no checks reports none" \
  "ok  example-org/example-repo#105  none  1d  https://example.com/pulls/105  Bump example-package from 1.0.0 to 1.0.1"

printf '== two repositories ==\n'

fixture=two-prs
gh_fail=0
run_check --repo example-org/example-repo --repo example-org/second-repo
expect_status "8: two repositories exit 1" 1
expect_line "8: first repository red pull request" \
  "FLAG  example-org/example-repo#106  red  1d  https://example.com/pulls/106  Bump example-package from 1.0.0 to 1.0.1"
expect_line "8: second repository red pull request" \
  "FLAG  example-org/second-repo#106  red  1d  https://example.com/pulls/106  Bump example-package from 1.0.0 to 1.0.1"
expect_line "8: second repository green pull request" \
  "ok  example-org/second-repo#107  green  1d  https://example.com/pulls/107  Bump example-package from 1.0.0 to 1.0.1"
expect_last_line "8: summary aggregates both repositories" \
  "summary: 4 open dependabot PRs, 2 flagged"
expect_argv_calls "8: one gh call per repository" 2
expect_argv_has "8: second repository reaches gh" \
  "-R example-org/second-repo"

printf '== gh failure ==\n'

fixture=green-young
gh_fail=1
run_check --repo example-org/example-repo
expect_status "9: gh failure exits 2" 2
expect_err "9: gh failure names the repository" \
  "gh failed for example-org/example-repo"
expect_err "9: gh failure shows the first stderr line" \
  "gh: boom, not logged in"
expect_no_err "9: gh failure hides later stderr lines" "see the log"
expect_out_eq "9: gh failure prints no report" ""

printf '== invalid JSON ==\n'

fixture=invalid
gh_fail=0
run_check --repo example-org/example-repo
expect_status "10: invalid JSON exits 2" 2
expect_err "10: invalid JSON names the repository" \
  "could not read the gh JSON for example-org/example-repo"
expect_out_eq "10: invalid JSON prints no report" ""

printf '== usage errors ==\n'

fixture=no-prs
gh_fail=0
for value in abc -1 "" 3.5; do
  run_check --repo example-org/example-repo --days "$value"
  expect_status "11: --days '$value' exits 2" 2
  expect_err "11: --days '$value' names the rule" \
    "must be a non-negative integer"
  expect_argv_calls "11: --days '$value' never calls gh" 0
done

run_check --days 3
expect_status "12: missing --repo exits 2" 2
expect_err "12: missing --repo names the flag" "--repo is required"
expect_argv_calls "12: missing --repo never calls gh" 0

run_check --repo example-org/example-repo --bogus
expect_status "12: unknown argument exits 2" 2
expect_err "12: unknown argument is named" "unknown argument: --bogus"

run_check --repo example-org/example-repo --repo
expect_status "12: --repo without a value exits 2" 2
expect_err "12: --repo without a value names the flag" \
  "--repo needs an owner/repo value"

run_check --repo not-a-slug
expect_status "12: a malformed --repo exits 2" 2
expect_err "12: a malformed --repo names the shape" \
  "--repo must be owner/repo"

printf '== help ==\n'

run_check --help
expect_status "13: --help exits 0" 0
if printf '%s\n' "$out" | grep -Fq "Usage: scripts/dependabot-red-prs.sh"; then
  ok "13: --help prints usage"
else
  bad "13: --help prints usage" "stdout missing the usage line"
fi
expect_argv_calls "13: --help never calls gh" 0

printf '== gh argv stays read-only ==\n'

fixture=green-young
gh_fail=0
run_check --repo example-org/example-repo
expected_argv="pr list -R example-org/example-repo --author app/dependabot --state open --limit 100 --json number,title,url,createdAt,headRefOid,statusCheckRollup"
actual_argv="$(sed -n '1p' "$argv_file")"
if [ "$actual_argv" = "$expected_argv" ]; then
  ok "14: gh receives the exact read-only argv"
else
  bad "14: gh receives the exact read-only argv" \
    "argv was '$actual_argv'"
fi
expect_argv_has "14: argv contains pr list" "pr list"
expect_argv_has "14: argv filters to Dependabot" "--author app/dependabot"
expect_argv_has "14: argv filters to open pull requests" "--state open"
expect_argv_never "14: argv never uses a write verb"

printf '== title sanitizing ==\n'

fixture=title-tab
gh_fail=0
run_check --repo example-org/example-repo
expect_status "15: a tab in the title exits 0" 0
expect_line "15: a backslash stays and a tab becomes a space" \
  'ok  example-org/example-repo#109  green  1d  https://example.com/pulls/109  Bump example-package from 1.0.0 to 1.0.1 \ paste here'
expect_no_tab "15: no literal tab reaches the report"
expect_last_line "15: a sanitized title keeps the summary" \
  "summary: 1 open dependabot PRs, 0 flagged"

printf '== age equals --days ==\n'

fixture=pending-old
gh_fail=0
run_check --repo example-org/example-repo --days 9
expect_status "16: age equal to --days exits 0" 0
expect_line "16: age equal to --days reports ok" \
  "ok  example-org/example-repo#103  pending  9d  https://example.com/pulls/103  Bump example-package from 1.0.0 to 1.0.1"
expect_last_line "16: age equal to --days flags nothing" \
  "summary: 1 open dependabot PRs, 0 flagged"

run_check --repo example-org/example-repo --days 8
expect_status "16: one day under the age exits 1" 1
expect_line "16: a 9 day old pending pull request is flagged at --days 8" \
  "FLAG  example-org/example-repo#103  pending  9d  https://example.com/pulls/103  Bump example-package from 1.0.0 to 1.0.1"

printf '== --repo= and --days= forms ==\n'

fixture=green-young
gh_fail=0
run_check --repo=example-org/example-repo
expect_status "17: --repo=OWNER/REPO exits 0" 0
expect_line "17: --repo= reports the pull request" \
  "ok  example-org/example-repo#101  green  1d  https://example.com/pulls/101  Bump example-package from 1.0.0 to 1.0.1"
expect_argv_has "17: --repo= passes the slug to gh" \
  "-R example-org/example-repo"

fixture=pending-old
run_check --repo=example-org/example-repo --days=10
expect_status "17: --days=10 exits 0" 0
expect_line "17: --days=10 reports the pull request as ok" \
  "ok  example-org/example-repo#103  pending  9d  https://example.com/pulls/103  Bump example-package from 1.0.0 to 1.0.1"

run_check --repo=example-org/example-repo --days=9
expect_status "17: --days=9 at the boundary exits 0" 0

run_check --repo=example-org/example-repo --days=abc
expect_status "17: --days=abc exits 2" 2
expect_err "17: --days=abc names the rule" \
  "must be a non-negative integer"
expect_argv_calls "17: --days=abc never calls gh" 0

fixture=two-prs
run_check --repo=example-org/example-repo --repo=example-org/second-repo
expect_status "17: two --repo= values exit 1" 1
expect_line "17: the second --repo= value reaches the report" \
  "ok  example-org/second-repo#107  green  1d  https://example.com/pulls/107  Bump example-package from 1.0.0 to 1.0.1"
expect_argv_calls "17: two --repo= values call gh twice" 2

printf '== missing tools ==\n'

fixture=green-young
gh_fail=0

# A PATH built from one directory keeps the real gh and jq out of reach.
make_tool_path "$work_tmp/no-gh" bash sh cat date mktemp rm jq
check_path="$work_tmp/no-gh"
run_check --repo example-org/example-repo
expect_status "18: missing gh exits 2" 2
expect_err "18: missing gh is named" "gh is required"
expect_argv_calls "18: missing gh never calls gh" 0

make_tool_path "$work_tmp/no-jq" bash sh cat date mktemp rm
ln -s "$fake_bin/gh" "$work_tmp/no-jq/gh"
check_path="$work_tmp/no-jq"
run_check --repo example-org/example-repo
expect_status "18: missing jq exits 2" 2
expect_err "18: missing jq is named" "jq is required"
expect_argv_calls "18: missing jq never calls gh" 0

check_path="$fake_bin:$PATH"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -ne 0 ]; then
  exit 1
fi
exit 0
