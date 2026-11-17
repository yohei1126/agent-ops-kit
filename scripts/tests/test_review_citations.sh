#!/usr/bin/env bash
# Tests for scripts/dev-loop-gate.sh --check review-citations.
# Local temp git repos only, no network. Bash 3.2.
set -u

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
gate="$repo_root/scripts/dev-loop-gate.sh"

pass=0
fail=0
work_tmp="$(mktemp -d)"
trap 'rm -rf "$work_tmp"' EXIT

out=""
err=""
status=0
err_file="$work_tmp/stderr"

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

expect_no_out() {
  case "$out" in
    *"$2"*) bad "$1" "stdout should not contain: $2" ;;
    *) ok "$1" ;;
  esac
}

expect_regex() {
  if printf '%s\n' "$out" | grep -Eq "$2"; then
    ok "$1"
  else
    bad "$1" "stdout missing line matching: $2"
  fi
}

make_repo() {
  local dir i
  dir="$(mktemp -d "$work_tmp/repo.XXXXXX")"
  git -C "$dir" init -q
  mkdir -p "$dir/a"
  printf 'one\ntwo\nthree\nfour\nfive\n' > "$dir/a/b.sh"
  printf 'one\ntwo' > "$dir/a/noeol.sh"
  : > "$dir/a/long.sh"
  i=1
  while [ "$i" -le 200 ]; do
    printf 'line %s\n' "$i" >> "$dir/a/long.sh"
    i=$((i + 1))
  done
  git -C "$dir" add a/b.sh a/noeol.sh a/long.sh
  git -C "$dir" -c user.name=t -c user.email=t@example.invalid commit -q -m init
  printf '%s\n' "$dir"
}

run_gate() {
  : > "$err_file"
  out="$("$BASH" "$gate" "$@" 2>"$err_file")"
  status=$?
  err="$(cat "$err_file")"
}

dir="$(make_repo)"
sha="$(git -C "$dir" rev-parse HEAD)"

cat > "$work_tmp/valid.md" <<'MD'
Seen in a/b.sh:3 and a/b.sh:2-4, plus a/b.sh:L2-L4 and a/b.sh#L1-L2.
Also `a/b.sh:1` and ./a/b.sh:1.
MD

run_gate --check review-citations --repo "$dir" --comment "$work_tmp/valid.md" --expect-head "$sha"
expect_status "1: valid citations pass" 0
expect_out "1: summary counts six" "6 citations, 0 bad"
expect_regex "1: summary passes" "^RC +review-citations +PASS"

cat > "$work_tmp/eight.md" <<'MD'
See a/b.sh:10 a/b.sh:11 a/b.sh:12 a/b.sh:13 a/b.sh:14 a/b.sh:15 a/b.sh:16 a/b.sh:17.
MD
run_gate --check review-citations --repo "$dir" --comment "$work_tmp/eight.md" --expect-head "$sha"
expect_status "2: out of range citations fail" 1
expect_regex "2: summary counts eight bad" "^RC +review-citations +FAIL +8 citations, 8 bad$"
n="$(printf '%s\n' "$out" | grep -cE '^RC +a/b\.sh:[0-9]+ +FAIL')"
if [ "$n" -eq 8 ]; then
  ok "2: lists all eight bad citations"
else
  bad "2: lists all eight bad citations" "found $n"
fi

cat > "$work_tmp/reversed.md" <<'MD'
See a/b.sh:4-2.
MD
run_gate --check review-citations --repo "$dir" --comment "$work_tmp/reversed.md" --expect-head "$sha"
expect_status "3: reversed range fails" 1
expect_out "3: reversed range message" "reversed range; write the lower line first"

cat > "$work_tmp/zero.md" <<'MD'
See a/b.sh:0.
MD
run_gate --check review-citations --repo "$dir" --comment "$work_tmp/zero.md" --expect-head "$sha"
expect_status "4: line zero fails" 1
expect_regex "4: line zero row" "^RC +a/b\.sh:0 +FAIL"

printf 'x\n' > "$dir/a/untracked.sh"
cat > "$work_tmp/untracked.md" <<'MD'
See a/untracked.sh:1.
MD
run_gate --check review-citations --repo "$dir" --comment "$work_tmp/untracked.md" --expect-head "$sha"
expect_status "5: untracked file fails" 1
expect_out "5: untracked message" "not a tracked file at"

cat > "$work_tmp/missing.md" <<'MD'
See a/ghost.sh:1.
MD
run_gate --check review-citations --repo "$dir" --comment "$work_tmp/missing.md" --expect-head "$sha"
expect_status "6: missing file fails" 1
expect_out "6: missing file message" "not a tracked file at"

cat > "$work_tmp/urls.md" <<'MD'
See http://localhost:8787 and https://example.com:443/x for details.
MD
run_gate --check review-citations --repo "$dir" --comment "$work_tmp/urls.md" --expect-head "$sha"
expect_status "7: URLs are not citations" 0
expect_out "7: zero citations" "0 citations; nothing to check"

cat > "$work_tmp/trailing.md" <<'MD'
See a/long.sh:173-196,420 for the block.
MD
run_gate --check review-citations --repo "$dir" --comment "$work_tmp/trailing.md" --expect-head "$sha"
expect_status "8: a comma list checks every line" 1
expect_out "8: the trailing line is checked, not dropped" "line 420 is past the end"

cat > "$work_tmp/noeol-ok.md" <<'MD'
See a/noeol.sh:2.
MD
run_gate --check review-citations --repo "$dir" --comment "$work_tmp/noeol-ok.md" --expect-head "$sha"
expect_status "9: last line without newline counts" 0
cat > "$work_tmp/noeol-bad.md" <<'MD'
See a/noeol.sh:3.
MD
run_gate --check review-citations --repo "$dir" --comment "$work_tmp/noeol-bad.md" --expect-head "$sha"
expect_status "10: line past a short file fails" 1

run_gate --check review-citations --repo "$dir" --comment "$work_tmp/valid.md" --expect-head 0000000
expect_status "11: head mismatch exits 1" 1
expect_out "11: head mismatch message" "check out the reviewed head"
expect_no_out "11: no citation summary before the check" "citations, "

run_gate --check review-citations --repo "$dir" --expect-head "$sha"
expect_status "12: missing --comment exits 2" 2
run_gate --check review-citations --repo "$dir" --comment "$work_tmp/valid.md"
expect_status "13: missing --expect-head exits 2" 2

cat > "$work_tmp/empty.md" <<'MD'
Nothing to cite here.
MD
run_gate --check review-citations --repo "$dir" --comment "$work_tmp/empty.md" --expect-head "$sha"
expect_status "14: zero citations pass" 0
expect_out "14: zero citation summary" "0 citations; nothing to check"

# 15. Tracked root files without a dot are citations; prose is not.
rootdir="$(make_repo)"
printf 'all:\n\ttrue\n' >"$rootdir/Makefile"
printf 'node_modules\n' >"$rootdir/.gitignore"
git -C "$rootdir" add Makefile .gitignore
git -C "$rootdir" -c user.name=t -c user.email=t@example.invalid commit -q -m root
rootsha="$(git -C "$rootdir" rev-parse HEAD)"
cat >"$work_tmp/root.md" <<'MD'
See Makefile:2 and .gitignore:1, step:1, and example.com:443.
MD
run_gate --check review-citations --repo "$rootdir" --comment "$work_tmp/root.md" --expect-head "$rootsha"
expect_status "15: tracked root files pass" 0
expect_out "15: two citations counted, prose skipped" "2 citations, 0 bad"
cat >"$work_tmp/root-bad.md" <<'MD'
See Makefile:9 and missing.sh:3.
MD
run_gate --check review-citations --repo "$rootdir" --comment "$work_tmp/root-bad.md" --expect-head "$rootsha"
expect_status "15: a bad root citation fails" 1
expect_out "15: Makefile past the end" "Makefile:9: line 9 is past the end"
expect_out "15: an untracked script name fails" "missing.sh:3: not a tracked file"

# 15b. Emphasis and Markdown links around a citation.
cat >"$work_tmp/md.md" <<'MD'
See **a/b.sh:9**, _a/b.sh:2_, and [the block](a/b.sh:7).
MD
run_gate --check review-citations --repo "$dir" --comment "$work_tmp/md.md" --expect-head "$sha"
expect_status "15b: bad citations in emphasis or links fail" 1
expect_out "15b: three citations counted" "3 citations, 2 bad"

# 16. Column suffix, comma lists, and uppercase or short heads.
cat >"$work_tmp/col.md" <<'MD'
See a/b.sh:2:5 and a/b.sh:1,3-4.
MD
run_gate --check review-citations --repo "$dir" --comment "$work_tmp/col.md" --expect-head "$sha"
expect_status "16: column suffix and a comma list pass" 0
expect_out "16: both counted" "2 citations, 0 bad"
upper="$(printf '%s' "$sha" | tr 'a-f' 'A-F')"
run_gate --check review-citations --repo "$dir" --comment "$work_tmp/col.md" --expect-head "$upper"
expect_status "16: an uppercase head matches" 0
run_gate --check review-citations --repo "$dir" --comment "$work_tmp/col.md" --expect-head abc
expect_status "16: a head shorter than 7 exits 2" 2
run_gate --check review-citations --repo "$dir" --comment "$work_tmp/col.md" --expect-head zzzzzzz
expect_status "16: a non-hex head exits 2" 2

# 17. --check review-citations --help prints forms, FAIL actions, and exit codes.
run_gate --check review-citations --help
expect_status "17: --check review-citations --help exits 0" 0
expect_out "17: usage line" "--check review-citations --comment"
expect_out "17: path:N form" "path:N"
expect_out "17: range form" "path:N-M"
expect_out "17: LN form" "path:LN-LM"
expect_out "17: hash form" "path#LN-LM"
expect_out "17: not tracked FAIL" "not a tracked file at"
expect_out "17: past the end FAIL" "past the end"
expect_out "17: line 0 FAIL" "line 0 is not a valid line"
expect_out "17: reversed range FAIL" "reversed range"
expect_out "17: exit 0" "0  pass"
expect_out "17: exit 1" "1  any FAIL"
expect_out "17: exit 2" "2  usage error"
expect_out "17: exit 3" "3  git missing"

printf 'review-citations tests: %s passed, %s failed\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
  exit 1
fi
exit 0
