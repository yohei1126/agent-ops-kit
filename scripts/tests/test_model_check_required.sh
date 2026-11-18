#!/usr/bin/env bash
# Tests for scripts/dev-loop-gate.sh --check model-check-required.
# Local temp git repos only, no network. Bash 3.2 compatible.
set -u

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
gate="$repo_root/scripts/dev-loop-gate.sh"

pass=0
fail=0
work_tmp="$(mktemp -d)"
home_tmp="$work_tmp/home"
mkdir -p "$home_tmp"
err_file="$work_tmp/stderr"
: > "$err_file"

out=""
err=""
status=0
base_sha=""

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

expect_err() {
  case "$err" in
    *"$2"*) ok "$1" ;;
    *) bad "$1" "stderr missing: $2" ;;
  esac
}

expect_out() {
  case "$out" in
    *"$2"*) ok "$1" ;;
    *) bad "$1" "stdout missing: $2" ;;
  esac
}

# expect_decision <name> <REQUIRED|SKIP> <reason substring>
expect_decision() {
  local name="$1"
  local decision="$2"
  local reason="$3"
  local line=""

  line="$(printf '%s\n' "$out" | grep '^MC ' | head -n 1)"
  if [ -z "$line" ]; then
    bad "$name" "no MC decision row; stdout: $out"
    return 0
  fi
  case "$line" in
    *"$decision"*) ;;
    *)
      bad "$name" "MC row is not $decision: $line"
      return 0
      ;;
  esac
  case "$line" in
    *"$reason"*) ok "$name" ;;
    *) bad "$name" "MC row missing reason '$reason': $line" ;;
  esac
}

expect_required() {
  local name="$1"
  local line=""

  line="$(printf '%s\n' "$out" | grep '^MC ' | head -n 1)"
  case "$line" in
    *REQUIRED*) ok "$name" ;;
    *) bad "$name" "MC row is not REQUIRED: $line" ;;
  esac
}

# rgit <dir> <git args...>: test identity, temp HOME, no system config.
rgit() {
  local dir="$1"
  shift
  HOME="$home_tmp" GIT_CONFIG_NOSYSTEM=1 \
    GIT_AUTHOR_NAME="Gate Test" GIT_AUTHOR_EMAIL="gate@example.invalid" \
    GIT_COMMITTER_NAME="Gate Test" GIT_COMMITTER_EMAIL="gate@example.invalid" \
    git -C "$dir" "$@"
}

# clean_env <args...>: temp HOME and no DEV_LOOP_* value from the caller.
clean_env() {
  env -u DEV_LOOP_BASE -u DEV_LOOP_BRANCH -u DEV_LOOP_ALIAS \
    -u DEV_LOOP_REQUIRED_PATH -u DEV_LOOP_SOFT_DENY_COUNT \
    -u DEV_LOOP_MODEL_LANE -u DEV_LOOP_DIFF_KIND -u DEV_LOOP_PR_STATE \
    -u DEV_LOOP_OPERATOR_READY -u DEV_LOOP_VULN_SILENT \
    -u DEV_LOOP_RETRO_MARKER -u DEV_LOOP_OPEN_JOBS -u DEV_LOOP_OPEN_PRS \
    -u DEV_LOOP_NAME_LIST -u DEV_LOOP_SLEEP_CMD -u DEV_LOOP_PR \
    -u DEV_LOOP_EXPECT_HEAD \
    HOME="$home_tmp" "$@"
}

run_gate() {
  local dir="$1"
  shift
  : > "$err_file"
  out="$(cd "$dir" && clean_env "$@" 2>"$err_file")"
  status=$?
  err="$(cat "$err_file")"
}

# run_case <dir> [gate flags...]: the check with DEV_LOOP_BASE at the base sha.
run_case() {
  local dir="$1"
  shift
  run_gate "$dir" DEV_LOOP_BASE="$base_sha" bash "$gate" \
    --repo "$dir" --check model-check-required "$@"
}

new_work() {
  local dir="$1"

  mkdir -p "$dir/docs" "$dir/scripts/tests" "$dir/scripts/lib" "$dir/.github/workflows"
  printf '# Guide\nShort guide text.\nKeep it brief.\n' > "$dir/docs/guide.md"
  printf '# Project\nA fixture repository.\n' > "$dir/README.md"
  printf '#!/usr/bin/env bash\n# Foo bar entry point.\nprintf foo-bar\n' > "$dir/scripts/foo-bar.sh"
  printf '#!/usr/bin/env bash\n# Foo bar test.\n' > "$dir/scripts/tests/test_foo_bar.sh"
  printf '#!/usr/bin/env bash\n# Thing helper.\n' > "$dir/scripts/lib/thing.sh"
  printf '#!/usr/bin/env bash\n# Thing test.\n' > "$dir/scripts/tests/test_thing.sh"
  printf '#!/usr/bin/env bash\n# No test file for this one.\nprintf nolib\n' > "$dir/scripts/nolib.sh"
  printf '#!/usr/bin/env bash\n# Agent launcher.\n' > "$dir/scripts/agent-launch.sh"
  printf 'name: ci\non: push\njobs: {}\n' > "$dir/.github/workflows/ci.yml"
}

commit_all() {
  local dir="$1"
  local msg="$2"

  rgit "$dir" add -A >/dev/null 2>&1
  rgit "$dir" commit -q -m "$msg" >/dev/null 2>&1
}

# case_repo <name>: a fresh copy of the base repo on branch work.
case_repo() {
  local dir="$work_tmp/$1"

  cp -R "$base_repo" "$dir"
  rgit "$dir" checkout -q -b work >/dev/null 2>&1
  printf '%s' "$dir"
}

base_repo="$work_tmp/base"
new_work "$base_repo"
rgit "$base_repo" init -q >/dev/null 2>&1
rgit "$base_repo" checkout -q -b main >/dev/null 2>&1 ||
  rgit "$base_repo" checkout -q main >/dev/null 2>&1
commit_all "$base_repo" "base"
base_sha="$(rgit "$base_repo" rev-parse HEAD)"

printf '== model-check-required ==\n'

r="$(case_repo c01)"
printf 'alpha\nbeta\ngamma\n' >> "$r/docs/guide.md"
commit_all "$r" "docs change"
run_case "$r"
expect_status "1: three docs lines exit 0" 0
expect_decision "1: three docs lines are SKIP" SKIP "allow list"

r="$(case_repo c02)"
printf 'More README text.\n' >> "$r/README.md"
commit_all "$r" "readme change"
run_case "$r"
expect_status "2: README edit exits 0" 0
expect_decision "2: README edit is SKIP" SKIP "allow list"

r="$(case_repo c03)"
printf 'extra: true\n' >> "$r/.github/workflows/ci.yml"
commit_all "$r" "workflow change"
run_case "$r"
expect_status "3: workflow change exits 0" 0
expect_decision "3: workflow change is REQUIRED" REQUIRED "deny-listed path: .github/workflows/ci.yml"

r="$(case_repo c04)"
printf 'printf extra\n' >> "$r/scripts/agent-launch.sh"
commit_all "$r" "launcher change"
run_case "$r"
expect_status "4: launcher change exits 0" 0
expect_decision "4: launcher change is REQUIRED" REQUIRED "deny-listed path"

r="$(case_repo c05)"
printf '# Token notes\n' > "$r/docs/TOKEN-notes.md"
commit_all "$r" "token notes"
run_case "$r"
expect_status "5: uppercase token path exits 0" 0
expect_decision "5: uppercase token path is REQUIRED" REQUIRED "deny-listed path"

r="$(case_repo c06)"
printf 'printf more\n' >> "$r/scripts/foo-bar.sh"
commit_all "$r" "foo-bar change"
run_case "$r"
expect_status "6: script with a test exits 0" 0
expect_decision "6: script with a test is SKIP" SKIP "allow list"

r="$(case_repo c07)"
printf 'printf more\n' >> "$r/scripts/nolib.sh"
commit_all "$r" "nolib change"
run_case "$r"
expect_status "7: script without a test exits 0" 0
expect_decision "7: script without a test is REQUIRED" REQUIRED "not on allow list: scripts/nolib.sh"

r="$(case_repo c08)"
mkdir -p "$r/src"
printf 'console.log(1);\n' > "$r/src/app.js"
commit_all "$r" "app file"
run_case "$r"
expect_status "8: src file exits 0" 0
expect_decision "8: src file is REQUIRED" REQUIRED "not on allow list: src/app.js"

r="$(case_repo c09a)"
i=0
while [ "$i" -lt 151 ]; do
  printf 'filler %s\n' "$i" >> "$r/docs/guide.md"
  i=$((i + 1))
done
commit_all "$r" "151 lines"
run_case "$r"
expect_status "9: 151 added lines exits 0" 0
expect_decision "9: 151 added lines is REQUIRED" REQUIRED "151 changed lines over cap 150"

r="$(case_repo c09b)"
i=0
while [ "$i" -lt 150 ]; do
  printf 'filler %s\n' "$i" >> "$r/docs/guide.md"
  i=$((i + 1))
done
commit_all "$r" "150 lines"
run_case "$r"
expect_status "9: 150 added lines exits 0" 0
expect_decision "9: 150 added lines is SKIP" SKIP "150 lines"

r="$(case_repo c10)"
printf 'More guide text.\n' >> "$r/docs/guide.md"
commit_all "$r" "docs change"
run_gate "$r" DEV_LOOP_BASE="$base_sha" DEV_LOOP_VULN_SILENT=true \
  bash "$gate" --repo "$r" --check model-check-required
expect_status "10: G5 FAIL exits 0" 0
expect_decision "10: G5 FAIL is REQUIRED" REQUIRED "default gate table has a FAIL"

r="$(case_repo c11)"
run_case "$r"
expect_status "11: empty diff exits 0" 0
expect_decision "11: empty diff is REQUIRED" REQUIRED "empty diff"

r="$(case_repo c12)"
run_gate "$r" DEV_LOOP_BASE=no-such-ref bash "$gate" \
  --repo "$r" --check model-check-required
expect_status "12: missing base exits 0" 0
expect_decision "12: missing base is REQUIRED" REQUIRED "base not found: no-such-ref"

r="$(case_repo c13a)"
printf 'Committed guide text.\n' >> "$r/docs/guide.md"
commit_all "$r" "docs change"
printf 'Uncommitted guide text.\n' >> "$r/docs/guide.md"
run_case "$r"
expect_status "13: uncommitted edit exits 0" 0
expect_decision "13: uncommitted edit is REQUIRED" REQUIRED "uncommitted changes"

r="$(case_repo c13b)"
printf 'Committed guide text.\n' >> "$r/docs/guide.md"
commit_all "$r" "docs change"
printf '# Untracked\n' > "$r/docs/untracked.md"
run_case "$r"
expect_status "13: untracked file exits 0" 0
expect_decision "13: untracked file is REQUIRED" REQUIRED "uncommitted changes"

r="$(case_repo c14)"
rgit "$r" mv docs/guide.md .github/guide.md
commit_all "$r" "rename"
run_case "$r"
expect_status "14: rename exits 0" 0
expect_decision "14: rename is REQUIRED" REQUIRED "deny-listed path"

r="$(case_repo c15)"
rgit "$r" config core.fileMode true
chmod +x "$r/docs/guide.md"
commit_all "$r" "mode change"
run_case "$r"
expect_status "15: chmod exits 0" 0
expect_decision "15: chmod is REQUIRED" REQUIRED "mode change: docs/guide.md"

r="$(case_repo c16)"
printf 'a\000b' > "$r/docs/blob.md"
commit_all "$r" "binary file"
run_case "$r"
expect_status "16: NUL byte file exits 0" 0
expect_decision "16: NUL byte file is REQUIRED" REQUIRED "binary change"

r="$(case_repo c17)"
printf '# Space\n' > "$r/docs/with space.md"
commit_all "$r" "space path"
run_case "$r"
expect_status "17: space in path exits 0" 0
expect_decision "17: space in path is REQUIRED" REQUIRED "unusual path"

r="$(case_repo c18)"
ln -s ../README.md "$r/docs/link.md"
commit_all "$r" "symlink"
run_case "$r"
expect_status "18: symlink exits 0" 0
expect_decision "18: symlink is REQUIRED" REQUIRED "mode change"

r="$(case_repo c19)"
printf 'extra: true\n' >> "$r/.github/workflows/ci.yml"
commit_all "$r" "workflow change"
run_case "$r" --strict
expect_status "19: strict with REQUIRED exits 0" 0
expect_decision "19: strict keeps the deny decision" REQUIRED "deny-listed path"

plain="$work_tmp/plain"
mkdir -p "$plain"
run_gate "$work_tmp" bash "$gate" --repo "$plain" --check model-check-required
expect_status "20: non-git repo exits 2" 2
expect_err "20: non-git repo is named" "not a git work tree"

run_gate "$work_tmp" bash "$gate" --check model-check-required --help
expect_status "21: help exits 0" 0
expect_out "21: help prints the line cap" "Line cap: 150"
expect_out "21: help prints the deny list heading" "Deny list:"
expect_out "21: help prints the workflow deny pattern" ".github/*"
expect_out "21: help prints the library deny pattern" "scripts/lib/*"
expect_out "21: help prints the allow list heading" "Allow list:"
expect_out "21: help prints the docs allow pattern" "docs/*.md"
expect_out "21: help prints the paired test rule" "changed together"

r="$(case_repo c22)"
printf '# More test body.\n' >> "$r/scripts/tests/test_foo_bar.sh"
commit_all "$r" "test change"
run_case "$r"
expect_status "22: test-only change exits 0" 0
expect_decision "22: test-only change is SKIP" SKIP "allow list"

r="$(case_repo c23)"
printf '#!/usr/bin/env bash\n# New tool.\n' > "$r/scripts/newtool.sh"
printf '#!/usr/bin/env bash\n# New tool test.\n' > "$r/scripts/tests/test_newtool.sh"
commit_all "$r" "new script"
run_case "$r"
expect_status "23: new script with a test exits 0" 0
expect_decision "23: new script is REQUIRED" REQUIRED "not on allow list: scripts/newtool.sh"

r="$(case_repo c24)"
printf '#!/usr/bin/env bash\n' > "$r/scripts/tests/test_foo_bar.sh"
commit_all "$r" "test line removed"
run_case "$r"
expect_status "24: removed test line exits 0" 0
expect_decision "24: removed test line is REQUIRED" REQUIRED "test lines removed: scripts/tests/test_foo_bar.sh"

r="$(case_repo c25)"
rm -f "$r/scripts/nolib.sh"
commit_all "$r" "delete script"
run_case "$r"
expect_status "25: deleted script exits 0" 0
expect_required "25: deleted script is REQUIRED"

r="$(case_repo c26)"
printf 'printf extra\n' >> "$r/scripts/lib/thing.sh"
commit_all "$r" "lib change"
run_case "$r"
expect_status "26: library change exits 0" 0
expect_decision "26: library change is REQUIRED" REQUIRED "deny-listed path: scripts/lib/thing.sh"

r="$(case_repo c27)"
rgit "$r" checkout -q --orphan orphan
printf 'Orphan guide.\n' > "$r/docs/orphan.md"
commit_all "$r" "orphan"
run_case "$r"
expect_status "27: orphan branch exits 0" 0
expect_decision "27: orphan branch is REQUIRED" REQUIRED "no merge base"

r="$(case_repo c28)"
mkdir -p "$r/docs/sub"
rgit "$r" update-index --add --cacheinfo "160000,$base_sha,docs/sub"
rgit "$r" commit -q -m "submodule"
run_case "$r"
expect_status "28: gitlink exits 0" 0
expect_decision "28: gitlink is REQUIRED" REQUIRED "mode change: docs/sub"

r="$(case_repo c29)"
printf 'printf more\n' >> "$r/scripts/foo-bar.sh"
printf '# More test body.\n' >> "$r/scripts/tests/test_foo_bar.sh"
commit_all "$r" "script and test change"
run_case "$r"
expect_status "29: script and test together exit 0" 0
expect_decision "29: script and test together are REQUIRED" REQUIRED "script and its test changed together: scripts/foo-bar.sh"

r="$(case_repo c30)"
printf 'printf more\n' >> "$r/scripts/foo-bar.sh"
head -n 1 "$r/scripts/tests/test_foo_bar.sh" > "$r/scripts/tests/test_foo_bar.new"
printf 'exit 0\n' >> "$r/scripts/tests/test_foo_bar.new"
tail -n +2 "$r/scripts/tests/test_foo_bar.sh" >> "$r/scripts/tests/test_foo_bar.new"
mv "$r/scripts/tests/test_foo_bar.new" "$r/scripts/tests/test_foo_bar.sh"
commit_all "$r" "script and exit line"
run_case "$r"
expect_status "30: script with exit line test exits 0" 0
expect_decision "30: script with exit line test is REQUIRED" REQUIRED "script and its test changed together: scripts/foo-bar.sh"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -ne 0 ]; then
  exit 1
fi
exit 0
