#!/usr/bin/env bash
# Tests for scripts/dev-loop-gate.sh --check docs-usage-dup.
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
  out="$(cd "$dir" && HOME="$work_tmp/home" XDG_CONFIG_HOME="$work_tmp/home/.config" \
    "$@" 2>"$err_file")"
  status=$?
  err="$(cat "$err_file")"
}

write_help_source() {
  local dir="$1"
  mkdir -p "$dir/scripts"
  cat > "$dir/scripts/rate-limit-check.sh" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  -h|--help)
    cat <<'EOF'
usage: rate-limit-check.sh --dir <path> [--mode quick|full] [--strict]

Options:
  --dir <path>     Directory to inspect. Required.
  --mode <mode>    quick or full. Default: quick.
  --strict         Fail on warnings.

Exit codes:
  0  pass
  1  check failed
  2  usage error
  3  required command missing
EOF
    exit 0
    ;;
esac
exit 2
SH
}

copied_help() {
  cat <<'MD'
# Copied help

```text
usage: rate-limit-check.sh --dir <path> [--mode quick|full] [--strict]

Options:
  --dir <path>     Directory to inspect. Required.
  --mode <mode>    quick or full. Default: quick.
  --strict         Fail on warnings.

Exit codes:
  0  pass
  1  check failed
  2  usage error
  3  required command missing
```
MD
}

printf '== pasted help ==\n'

hit_repo="$(make_repo)"
write_help_source "$hit_repo"
copied_help > "$hit_repo/docs/copy.md"
track "$hit_repo" scripts/rate-limit-check.sh docs/copy.md

run_gate "$repo_root" bash "$gate" --repo "$hit_repo" --check docs-usage-dup
expect_status "1: pasted help is advisory" 0
expect_regex "1: pasted help row" "^DU +docs/copy\.md:[0-9]+ +FAIL +pasted help text from scripts/rate-limit-check\.sh$"
expect_regex "1: summary fails" "^DU +docs-usage-dup +FAIL +[0-9]+ files, [0-9]+ hits$"
expect_no_quote "1: rows have no double quote"

run_gate "$repo_root" bash "$gate" --repo "$hit_repo" --check docs-usage-dup --strict
expect_status "2: pasted help fails under strict" 1

printf '== clean prose ==\n'

clean_repo="$(make_repo)"
write_help_source "$clean_repo"
cat > "$clean_repo/docs/clean.md" <<'MD'
# Clean

Run `scripts/rate-limit-check.sh --help` for flags and exit codes.
A single flag such as `--strict` is fine in prose.
MD
track "$clean_repo" scripts/rate-limit-check.sh docs/clean.md

run_gate "$repo_root" bash "$gate" --repo "$clean_repo" --check docs-usage-dup --strict
expect_status "3: clean doc passes under strict" 0
expect_regex "3: clean summary passes" "^DU +docs-usage-dup +PASS +1 files, 0 hits$"

printf '== opt-out ==\n'

allow_repo="$(make_repo)"
write_help_source "$allow_repo"
cat > "$allow_repo/docs/allow.md" <<'MD'
# Allow

<!-- docs-usage-dup:allow -->
```text
usage: rate-limit-check.sh --dir <path> [--mode quick|full] [--strict]

Options:
  --dir <path>     Directory to inspect. Required.
  --mode <mode>    quick or full. Default: quick.
  --strict         Fail on warnings.

Exit codes:
  0  pass
  1  check failed
  2  usage error
  3  required command missing
```
MD
track "$allow_repo" scripts/rate-limit-check.sh docs/allow.md

run_gate "$repo_root" bash "$gate" --repo "$allow_repo" --check docs-usage-dup --strict
expect_status "4: opt-out block passes under strict" 0
expect_regex "4: opt-out summary passes" "^DU +docs-usage-dup +PASS +1 files, 0 hits$"

printf '== untracked docs ==\n'

untracked_repo="$(make_repo)"
write_help_source "$untracked_repo"
printf '# Clean\n' > "$untracked_repo/docs/clean.md"
copied_help > "$untracked_repo/docs/draft.md"
track "$untracked_repo" scripts/rate-limit-check.sh docs/clean.md

run_gate "$repo_root" bash "$gate" --repo "$untracked_repo" --check docs-usage-dup --strict
expect_status "5: untracked doc is ignored" 0
expect_no_out "5: untracked path is not reported" "docs/draft.md"
expect_out "5: only tracked Markdown counted" "1 files, 0 hits"

printf '== kit self-check ==\n'

run_gate "$repo_root" bash "$gate" --repo "$repo_root" --check docs-usage-dup --strict
expect_status "6: kit passes strict docs-usage-dup" 0
expect_regex "6: kit summary passes" "^DU +docs-usage-dup +PASS +[0-9]+ files, 0 hits$"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -ne 0 ]; then
  exit 1
fi
exit 0
