#!/usr/bin/env bash
# Tests for scripts/dev-loop-gate.sh. Local git repos only, no network.
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

expect_no_quote() {
  if printf '%s\n' "$out" | grep -q '"'; then
    bad "$1" "stdout contains a double quote"
  else
    ok "$1"
  fi
}

make_dir() {
  mktemp -d "$work_tmp/dir.XXXXXX"
}

make_repo() {
  local dir
  dir="$(make_dir)/repo"
  mkdir -p "$dir/docs"
  git -C "$dir" init -q
  printf '%s\n' "$dir"
}

write_md() {
  local file="$1"
  local count="$2"
  local i=1
  : > "$file"
  while [ "$i" -le "$count" ]; do
    printf 'line %s\n' "$i" >> "$file"
    i=$((i + 1))
  done
}

run_gate() {
  local dir="$1"
  shift
  : > "$err_file"
  out="$(cd "$dir" && "$@" 2>"$err_file")"
  status=$?
  err="$(cat "$err_file")"
}

printf '== default table ==\n'

run_gate "$repo_root" bash "$gate"
expect_status "1: no args exits 0" 0
for id in G1 G2 G3 G4 G5 G6 G7; do
  if printf '%s\n' "$out" | grep -q "^$id "; then
    ok "1: table has $id row"
  else
    bad "1: table has $id row" "no $id row in stdout"
  fi
done
expect_out "1: header row" "Gate Name"

run_gate "$repo_root" env DEV_LOOP_BRANCH=not-the-branch bash "$gate"
expect_status "2: branch mismatch exits 1" 1
expect_out "2: G1 branch failure action" "Do not start; branch is "

run_gate "$repo_root" env DEV_LOOP_PR_STATE=ready bash "$gate"
expect_status "3: ready without operator is advisory" 0
expect_out "3: G4 failure action" "Create or convert the pull request to draft."

run_gate "$repo_root" env DEV_LOOP_PR_STATE=ready bash "$gate" --strict
expect_status "3: ready without operator is strict failure" 1

run_gate "$repo_root" env DEV_LOOP_OPEN_JOBS=2 bash "$gate"
expect_status "4: two open jobs exits 1" 1
expect_out "4: G1 lock failure action" "Do not start; worktree lock needs 1 PR / 1 Issue per job."
expect_out "4: G7 refusal action" "Refuse new job; completion report only."

printf '== line cap ==\n'

cap_repo="$(make_repo)"
write_md "$cap_repo/docs/ok.md" 500
git -C "$cap_repo" add docs/ok.md

run_gate "$repo_root" bash "$gate" --repo "$cap_repo" --check line-cap
expect_status "5: 500-line tracked file exits 0" 0
expect_regex "5: line-cap pass row" "^LC +line-cap +PASS "
expect_out "5: checked summary" "1 files checked, 0 over cap."

big_repo="$(make_repo)"
write_md "$big_repo/docs/big.md" 501
git -C "$big_repo" add docs/big.md

run_gate "$repo_root" bash "$gate" --repo "$big_repo" --check line-cap
expect_status "6: 501-line file is advisory" 0
expect_out "6: fail row names the path" "docs/big.md"
expect_out "6: fail row names the count" "501 lines > cap 500; split before adding."
expect_out "6: over-cap summary" "1 files checked, 1 over cap."

run_gate "$repo_root" bash "$gate" --repo "$big_repo" --check line-cap --strict
expect_status "6: 501-line file fails under strict" 1

untracked_repo="$(make_repo)"
write_md "$untracked_repo/docs/ok.md" 500
git -C "$untracked_repo" add docs/ok.md
write_md "$untracked_repo/docs/untracked.md" 620

run_gate "$repo_root" bash "$gate" --repo "$untracked_repo" --check line-cap
expect_status "7: untracked over-cap file exits 0" 0
expect_no_out "7: untracked file is ignored" "untracked.md"
expect_out "7: only tracked file counted" "1 files checked, 0 over cap."

space_repo="$(make_repo)"
write_md "$space_repo/docs/with space.md" 501
git -C "$space_repo" add "docs/with space.md"

run_gate "$repo_root" bash "$gate" --repo "$space_repo" --check line-cap
expect_status "8: path with a space exits 0 advisory" 0
expect_out "8: path with a space is reported" "docs/with space.md"
expect_out "8: path with a space count" "501 lines > cap 500"

path_cfg="$work_tmp/exception-path.json"
cat > "$path_cfg" <<'JSON'
{
  "line_cap": {
    "default": 500,
    "exceptions": [
      {
        "path": "docs/long.md",
        "cap": 600,
        "reason": "single reference table"
      }
    ]
  }
}
JSON

long_repo="$(make_repo)"
write_md "$long_repo/docs/long.md" 600
git -C "$long_repo" add docs/long.md

run_gate "$repo_root" bash "$gate" --repo "$long_repo" --check line-cap --config "$path_cfg"
expect_status "9: path exception raises the cap" 0
expect_regex "9: path exception passes" "^LC +line-cap +PASS "
expect_out "9: path exception summary" "1 files checked, 0 over cap."

pattern_cfg="$work_tmp/exception-pattern.json"
cat > "$pattern_cfg" <<'JSON'
{
  "line_cap": {
    "default": 500,
    "exceptions": [
      {
        "pattern": "^docs/long\\.md$",
        "cap": 600,
        "reason": "single reference table"
      }
    ]
  }
}
JSON

run_gate "$repo_root" bash "$gate" --repo "$long_repo" --check line-cap --config "$pattern_cfg"
expect_status "9: anchored pattern exception raises the cap" 0
expect_regex "9: anchored pattern passes" "^LC +line-cap +PASS "

cfg_repo="$(make_repo)"
write_md "$cfg_repo/docs/a.md" 10
git -C "$cfg_repo" add docs/a.md

missing_reason="$work_tmp/bad-missing-reason.json"
cat > "$missing_reason" <<'JSON'
{"line_cap":{"default":500,"exceptions":[{"path":"docs/a.md","cap":600}]}}
JSON

both_keys="$work_tmp/bad-both.json"
cat > "$both_keys" <<'JSON'
{"line_cap":{"default":500,"exceptions":[{"path":"docs/a.md","pattern":"^docs/a\\.md$","cap":600,"reason":"x"}]}}
JSON

unanchored="$work_tmp/bad-unanchored.json"
cat > "$unanchored" <<'JSON'
{"line_cap":{"default":500,"exceptions":[{"pattern":"docs/a\\.md","cap":600,"reason":"x"}]}}
JSON

broad="$work_tmp/bad-broad.json"
cat > "$broad" <<'JSON'
{"line_cap":{"default":500,"exceptions":[{"pattern":"^docs/.*\\.md$","cap":600,"reason":"x"}]}}
JSON

bad_cap="$work_tmp/bad-cap.json"
cat > "$bad_cap" <<'JSON'
{"line_cap":{"default":500,"exceptions":[{"path":"docs/a.md","cap":"600","reason":"x"}]}}
JSON

run_gate "$repo_root" bash "$gate" --repo "$cfg_repo" --check line-cap --config "$missing_reason"
expect_status "10: missing reason exits 2" 2
run_gate "$repo_root" bash "$gate" --repo "$cfg_repo" --check line-cap --config "$both_keys"
expect_status "10: both path and pattern exits 2" 2
run_gate "$repo_root" bash "$gate" --repo "$cfg_repo" --check line-cap --config "$unanchored"
expect_status "10: unanchored pattern exits 2" 2
run_gate "$repo_root" bash "$gate" --repo "$cfg_repo" --check line-cap --config "$broad"
expect_status "10: broad glob pattern exits 2" 2
run_gate "$repo_root" bash "$gate" --repo "$cfg_repo" --check line-cap --config "$bad_cap"
expect_status "10: non-integer cap exits 2" 2
run_gate "$repo_root" bash "$gate" --repo "$cfg_repo" --check line-cap --config "$work_tmp/missing.json"
expect_status "10: missing explicit config exits 2" 2

non_git="$(make_dir)"
run_gate "$repo_root" bash "$gate" --repo "$non_git" --check line-cap
expect_status "11: --repo on a non-git dir exits 2" 2

run_gate "$non_git" bash "$gate" --repo "$cap_repo" --check line-cap
expect_status "11: --repo works from another cwd" 0
expect_regex "11: --repo from another cwd passes" "^LC +line-cap +PASS "

run_gate "$repo_root" bash "$gate" --check child-env
expect_status "12: unimplemented check exits 2" 2
run_gate "$repo_root" bash "$gate" --check bogus
expect_status "12: unknown check exits 2" 2
run_gate "$repo_root" bash "$gate" --not-a-flag
expect_status "12: unknown flag exits 2" 2

printf '== table outside git ==\n'

plain_dir="$(make_dir)"
run_gate "$plain_dir" bash "$gate"
expect_status "14: no-arg table outside git exits 0" 0
for id in G1 G2 G3 G4 G5 G6 G7; do
  if printf '%s\n' "$out" | grep -q "^$id "; then
    ok "14: non-git table has $id row"
  else
    bad "14: non-git table has $id row" "no $id row in stdout"
  fi
done
expect_regex "14: non-git G1 passes" "^G1 +checkout \+ worktree lock +PASS "

run_gate "$plain_dir" env DEV_LOOP_BRANCH=main bash "$gate"
expect_status "15: branch check outside git exits 1" 1
expect_regex "15: G1 fails on unknown branch" "^G1 +checkout \+ worktree lock +FAIL "
expect_out "15: G1 names the unknown branch" "Do not start; branch is unknown. One-line FYI."

printf '== line-cap quoting ==\n'

run_gate "$repo_root" bash "$gate" --repo "$big_repo" --check line-cap
expect_status "16: over-cap row is advisory" 0
expect_regex "16: over-cap row has no quotes" "^LC +docs/big\.md +FAIL +501 lines > cap 500; split before adding\.$"
expect_regex "16: summary row has no quotes" "^LC +line-cap +FAIL +1 files checked, 1 over cap\.$"
expect_no_quote "16: line-cap output has no double quote"

printf '== npm-ci ==\n'

npm_repo="$(make_repo)"
: > "$npm_repo/package-lock.json"

run_gate "$repo_root" bash "$gate" --repo "$npm_repo" --check npm-ci
expect_status "17: lockfile without node_modules exits 1" 1
expect_regex "17: npm-ci fail row" "^NM +npm-ci +FAIL "
expect_out "17: npm-ci hint names npm ci" "npm ci"

run_gate "$npm_repo" bash "$gate"
expect_status "17: default table fails on missing node_modules" 1
expect_out "17: default table hint names npm ci" "npm ci"
for id in G1 G2 G3 G4 G5 G6 G7; do
  if printf '%s\n' "$out" | grep -q "^$id "; then
    ok "17: table with missing node_modules has $id row"
  else
    bad "17: table with missing node_modules has $id row" "no $id row in stdout"
  fi
done

run_gate "$repo_root" bash "$gate" --repo "$npm_repo"
expect_status "18: default table with --repo fails on missing node_modules" 1
expect_out "18: --repo table hint names npm ci" "npm ci"

npm_ok_repo="$(make_repo)"
: > "$npm_ok_repo/package-lock.json"
mkdir -p "$npm_ok_repo/node_modules"

run_gate "$repo_root" bash "$gate" --repo "$npm_ok_repo" --check npm-ci
expect_status "19: lockfile with node_modules dir exits 0" 0
expect_regex "19: npm-ci pass row" "^NM +npm-ci +PASS "

run_gate "$npm_ok_repo" bash "$gate"
expect_status "19: default table passes with node_modules dir" 0
expect_regex "19: table pass row" "^NM +npm-ci +PASS "

npm_skip_repo="$(make_repo)"
run_gate "$repo_root" bash "$gate" --repo "$npm_skip_repo" --check npm-ci
expect_status "20: no lockfile exits 0" 0
expect_regex "20: no lockfile skips" "^NM +npm-ci +SKIP "

run_gate "$npm_skip_repo" bash "$gate"
expect_status "20: default table skips without a lockfile" 0
expect_regex "20: table skip row" "^NM +npm-ci +SKIP "

npm_file_repo="$(make_repo)"
: > "$npm_file_repo/package-lock.json"
: > "$npm_file_repo/node_modules"

run_gate "$repo_root" bash "$gate" --repo "$npm_file_repo" --check npm-ci
expect_status "21: node_modules file exits 1" 1
expect_out "21: node_modules file hints npm ci" "npm ci"

run_gate "$repo_root" bash "$gate" --repo "$npm_repo" --check npm-ci --strict
expect_status "22: strict FAIL still exits 1" 1

run_gate "$repo_root" bash "$gate" --repo "$npm_repo" --check line-cap
expect_status "22: line-cap ignores the npm-ci preflight" 0
expect_no_out "22: line-cap prints no npm ci hint" "npm ci"

printf '== this repo ==\n'

run_gate "$repo_root" bash "$gate" --strict --check line-cap
expect_status "13: this repo passes strict line cap" 0

printf '\n%d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -ne 0 ]; then
  exit 1
fi
exit 0
