#!/usr/bin/env bash
# Tests for the pr-state named check in scripts/dev-loop-gate.sh.
# Uses a fake gh on PATH. No network and no real repository.
set -u

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
gate="$repo_root/scripts/dev-loop-gate.sh"
fixtures="$repo_root/scripts/tests/fixtures/pr-state"

pass=0
fail=0
work_tmp="$(mktemp -d)"
home_tmp="$work_tmp/home"
fake_bin="$work_tmp/bin"
argv_file="$work_tmp/argv"
cwd_file="$work_tmp/cwd"
err_file="$work_tmp/stderr"

mkdir -p "$home_tmp" "$fake_bin"
: > "$err_file"
: > "$argv_file"
: > "$cwd_file"

trap 'rm -rf "$work_tmp"' EXIT

unset DEV_LOOP_PR DEV_LOOP_EXPECT_HEAD
unset PR_STATE_FIXTURE PR_STATE_GH_FAIL

head_full="9f1c2d3e4a5b6c7d8e9f0a1b2c3d4e5f60718293"
head_short="9f1c2d3"
fields="number,state,isDraft,headRefOid,mergeable,mergeStateStatus,statusCheckRollup,url"

cat > "$fake_bin/gh" <<'EOF'
#!/usr/bin/env bash
set -u
printf '%s\n' "$@" > "${PR_STATE_ARGV_FILE:-/dev/null}"
pwd > "${PR_STATE_CWD_FILE:-/dev/null}"
if [ "${PR_STATE_GH_FAIL:-0}" = 1 ]; then
  printf 'gh: boom, not logged in\n' >&2
  printf 'gh: see the log\n' >&2
  exit 1
fi
cat "$PR_STATE_FIXTURE_DIR/${PR_STATE_FIXTURE:-open-draft-green}.json"
EOF
chmod +x "$fake_bin/gh"

export PR_STATE_FIXTURE_DIR="$fixtures"
export PR_STATE_ARGV_FILE="$argv_file"
export PR_STATE_CWD_FILE="$cwd_file"

PATH="$fake_bin:$PATH"
export PATH

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

expect_regex() {
  if printf '%s\n' "$out" | grep -Eq "$2"; then
    ok "$1"
  else
    bad "$1" "stdout missing line matching: $2"
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

expect_no_quote() {
  if printf '%s\n' "$out" | grep -q '"'; then
    bad "$1" "stdout contains a double quote"
  else
    ok "$1"
  fi
}

expect_argv_line() {
  local actual
  actual="$(sed -n "${2}p" "$argv_file")"
  if [ "$actual" = "$3" ]; then
    ok "$1"
  else
    bad "$1" "argv line $2 is '$actual', expected '$3'"
  fi
}

expect_argv_count() {
  local actual
  actual="$(wc -l < "$argv_file" | tr -d ' ')"
  if [ "$actual" -eq "$2" ]; then
    ok "$1"
  else
    bad "$1" "argv has $actual lines, expected $2"
  fi
}

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

reset_argv() {
  : > "$argv_file"
  : > "$cwd_file"
}

run_gate() {
  local dir="$1"
  shift
  reset_argv
  : > "$err_file"
  out="$(cd "$dir" && env HOME="$home_tmp" "$@" 2>"$err_file")"
  status=$?
  err="$(cat "$err_file")"
}

printf '== rows per fixture ==\n'

run_gate "$repo_root" env PR_STATE_FIXTURE=open-draft-green \
  bash "$gate" --check pr-state --pr 46
expect_status "1: open draft green exits 0" 0
expect_regex "1: state row" "^PR +state +PASS +OPEN$"
expect_regex "1: draft row" "^PR +draft +PASS +true$"
expect_regex "1: head row uses a short SHA" "^PR +head +PASS +$head_short$"
expect_regex "1: mergeable row" "^PR +mergeable +PASS +MERGEABLE$"
expect_regex "1: checks row counts success" "^PR +checks +PASS +success 2$"
expect_regex "1: fetched row is UTC" \
  "^PR +fetched +PASS +[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"
expect_no_quote "1: rows carry no double quote"

printf '== gh argv ==\n'

expect_argv_count "2: plain call has five arguments" 5
expect_argv_line "2: plain call starts with pr view" 1 "pr"
expect_argv_line "2: plain call names the number" 3 "46"
expect_argv_line "2: plain call requests JSON" 4 "--json"
expect_argv_line "2: plain call asks for the exact fields" 5 "$fields"

run_gate "$repo_root" env PR_STATE_FIXTURE=open-draft-green \
  bash "$gate" --check pr-state --pr 46 --gh-repo example-org/example-repo
expect_status "2: --gh-repo exits 0" 0
expect_argv_count "2: -R call has seven arguments" 7
expect_argv_line "2: -R comes before --json" 4 "-R"
expect_argv_line "2: -R passes the slug" 5 "example-org/example-repo"
expect_argv_line "2: -R call still requests JSON" 6 "--json"
expect_argv_line "2: -R call asks for the exact fields" 7 "$fields"

stated_cwd="$(cat "$cwd_file")"
if [ "$stated_cwd" = "$repo_root" ]; then
  ok "2: gh runs inside the checkout"
else
  bad "2: gh runs inside the checkout" "cwd was $stated_cwd"
fi

printf '== expect-head ==\n'

run_gate "$repo_root" env PR_STATE_FIXTURE=open-draft-green \
  bash "$gate" --check pr-state --pr 46 --expect-head "$head_full"
expect_status "3: full head match exits 0" 0
expect_regex "3: full head match is PASS" "^PR +head +PASS +$head_short$"

run_gate "$repo_root" env PR_STATE_FIXTURE=open-draft-green \
  bash "$gate" --check pr-state --pr 46 --expect-head "$head_short"
expect_status "3: short head match exits 0" 0

run_gate "$repo_root" env PR_STATE_FIXTURE=open-draft-green \
  DEV_LOOP_EXPECT_HEAD="${head_full:0:12}" \
  bash "$gate" --check pr-state --pr 46
expect_status "3: DEV_LOOP_EXPECT_HEAD match exits 0" 0

run_gate "$repo_root" env PR_STATE_FIXTURE=open-draft-green \
  bash "$gate" --check pr-state --pr 46 --expect-head deadbeef
expect_status "3: head mismatch is advisory" 0
expect_regex "3: head mismatch row" \
  "^PR +head +FAIL +live head $head_short != expected deadbeef; re-read before reporting$"

run_gate "$repo_root" env PR_STATE_FIXTURE=open-draft-green \
  bash "$gate" --check pr-state --pr 46 --expect-head deadbeef --strict
expect_status "3: head mismatch is strict failure" 1

run_gate "$repo_root" env PR_STATE_FIXTURE=open-draft-green \
  bash "$gate" --check pr-state --pr 46 --expect-head abc12
expect_status "3: short expect-head exits 2" 2

printf '== fixture rows ==\n'

run_gate "$repo_root" env PR_STATE_FIXTURE=open-ready-failing \
  bash "$gate" --check pr-state --pr 46
expect_status "4: failing checks are advisory" 0
expect_regex "4: failing checks row" "^PR +checks +FAIL +failure 1$"
expect_regex "4: ready row never hides a failure" "^PR +draft +PASS +false$"

run_gate "$repo_root" env PR_STATE_FIXTURE=open-ready-failing \
  bash "$gate" --check pr-state --pr 46 --strict
expect_status "4: failing checks are strict failure" 1

run_gate "$repo_root" env PR_STATE_FIXTURE=merged \
  bash "$gate" --check pr-state --pr 46
expect_status "5: merged state exits 0" 0
expect_regex "5: merged state row" "^PR +state +PASS +MERGED$"
expect_regex "5: merged checks row" "^PR +checks +PASS +success 1$"

run_gate "$repo_root" env PR_STATE_FIXTURE=unknown-mergeable \
  bash "$gate" --check pr-state --pr 46
expect_status "6: unknown mergeable is advisory" 0
expect_regex "6: unknown mergeable stays PASS" \
  "^PR +mergeable +PASS +GitHub still computing; re-run later$"

run_gate "$repo_root" env PR_STATE_FIXTURE=pending-checks \
  bash "$gate" --check pr-state --pr 46
expect_status "7: pending checks exit 0" 0
expect_regex "7: pending checks row" "^PR +checks +PASS +pending 2$"

run_gate "$repo_root" env PR_STATE_FIXTURE=no-checks \
  bash "$gate" --check pr-state --pr 46
expect_status "8: no checks exits 0" 0
expect_regex "8: no checks row" "^PR +checks +PASS +no checks$"

printf '== usage errors ==\n'

run_gate "$repo_root" bash "$gate" --check pr-state
expect_status "9: missing pr exits 2" 2

run_gate "$repo_root" bash "$gate" --check pr-state --pr 46x
expect_status "9: non-numeric pr exits 2" 2

run_gate "$repo_root" bash "$gate" --pr 46
expect_status "10: --pr without --check pr-state exits 2" 2

run_gate "$repo_root" bash "$gate" --check line-cap --pr 46
expect_status "10: --pr with another check exits 2" 2

run_gate "$repo_root" bash "$gate" --check pr-state --pr 46 --gh-repo example
expect_status "10: --gh-repo without a slash exits 2" 2

run_gate "$repo_root" bash "$gate" --check pr-state --pr 46 --expect-head not-a-sha
expect_status "10: --expect-head with non-hex exits 2" 2

printf '== missing tools and gh failure ==\n'

make_tool_path "$work_tmp/no-gh" bash sh git date cat mktemp dirname
run_gate "$repo_root" env PATH="$work_tmp/no-gh" \
  DEV_LOOP_PR=46 PR_STATE_FIXTURE=open-draft-green \
  bash "$gate" --check pr-state
expect_status "11: missing gh exits 3" 3
expect_err "11: missing gh is named" "gh is required for pr-state"

make_tool_path "$work_tmp/no-jq" bash sh git date cat mktemp dirname
run_gate "$repo_root" env PATH="$fake_bin:$work_tmp/no-jq" \
  DEV_LOOP_PR=46 PR_STATE_FIXTURE=open-draft-green \
  bash "$gate" --check pr-state
expect_status "11: missing jq exits 3" 3
expect_err "11: missing jq is named" "jq is required for pr-state"

run_gate "$repo_root" env PR_STATE_GH_FAIL=1 PR_STATE_FIXTURE=open-draft-green \
  DEV_LOOP_PR=46 bash "$gate" --check pr-state
expect_status "12: gh failure exits 3" 3
expect_err "12: gh failure shows the first stderr line" \
  "dev-loop-gate: gh failed: gh: boom, not logged in"
expect_no_err "12: gh failure hides later stderr lines" "see the log"

printf '== env pr number ==\n'

run_gate "$repo_root" env DEV_LOOP_PR=46 PR_STATE_FIXTURE=merged \
  bash "$gate" --check pr-state
expect_status "13: DEV_LOOP_PR works" 0
expect_regex "13: DEV_LOOP_PR reaches gh" "^PR +state +PASS +MERGED$"
expect_argv_line "13: DEV_LOOP_PR is the number argument" 3 "46"

printf '== default table is unchanged ==\n'

old_gate="$work_tmp/dev-loop-gate-head.sh"
if git -C "$repo_root" show HEAD:scripts/dev-loop-gate.sh > "$old_gate" 2>/dev/null; then
  for combo in none ready two_jobs; do
    case "$combo" in
      none) env_pair="" ;;
      ready) env_pair="DEV_LOOP_PR_STATE=ready" ;;
      two_jobs) env_pair="DEV_LOOP_OPEN_JOBS=2" ;;
    esac
    if [ -n "$env_pair" ]; then
      run_gate "$repo_root" env "$env_pair" bash "$gate"
    else
      run_gate "$repo_root" bash "$gate"
    fi
    new_status="$status"
    new_out="$out"
    if [ -n "$env_pair" ]; then
      run_gate "$repo_root" env "$env_pair" bash "$old_gate"
    else
      run_gate "$repo_root" bash "$old_gate"
    fi
    if [ "$status" -eq "$new_status" ] && [ "$out" = "$new_out" ]; then
      ok "14: table matches HEAD for $combo"
    else
      bad "14: table matches HEAD for $combo" "output or status differs"
    fi
  done
else
  bad "14: table matches HEAD" "git show HEAD failed"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -ne 0 ]; then
  exit 1
fi
exit 0
