#!/usr/bin/env bash
# Tests for scripts/review-scope.sh, scripts/lib/review-scope.sh, and
# --scope-check in scripts/post-review-comment.sh.
# Uses a stub gh on PATH and a local temp git repo. No network.
set -u

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
scope_script="$repo_root/scripts/review-scope.sh"
post_script="$repo_root/scripts/post-review-comment.sh"
gate_script="$repo_root/scripts/dev-loop-gate.sh"

pass=0
fail=0
work_tmp="$(mktemp -d "${TMPDIR:-/tmp}/test_review_scope.XXXXXX")"
fake_bin="$work_tmp/bin"
run_dir="$work_tmp/run"
argv_file="$work_tmp/argv"
out_file="$work_tmp/out.md"
err_file="$work_tmp/stderr"

mkdir -p "$fake_bin" "$run_dir"
: > "$argv_file"
: > "$err_file"

trap 'rm -rf "$work_tmp"' EXIT

unset POST_REVIEW_COMMENT_OWNERS POST_REVIEW_COMMENT_MAX_BYTES

cat > "$fake_bin/gh" <<'EOF'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${RS_ARGV_FILE:-/dev/null}"
if [ "${RS_FAIL_VIEW:-0}" = 1 ] && [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then
  printf 'gh: view failed\n' >&2
  exit 1
fi
if [ "${RS_FAIL_DIFF:-0}" = 1 ] && [ "${1:-}" = "pr" ] && [ "${2:-}" = "diff" ]; then
  printf 'gh: diff failed\n' >&2
  exit 1
fi
if [ "${RS_FAIL_COMMENT:-0}" = 1 ] && [ "${1:-}" = "pr" ] && [ "${2:-}" = "comment" ]; then
  printf 'gh: comment failed\n' >&2
  exit 1
fi
case "${1:-} ${2:-}" in
  'pr view')
    printf '{"isDraft":true,"state":"OPEN"}\n'
    ;;
  'pr diff')
    if [ -n "${RS_DIFF_FILE:-}" ] && [ -f "$RS_DIFF_FILE" ]; then
      cat "$RS_DIFF_FILE"
    elif [ -n "${RS_DIFF_TEXT+set}" ]; then
      printf '%s' "$RS_DIFF_TEXT"
    else
      cat <<'DIFF'
diff --git a/scripts/in_scope.sh b/scripts/in_scope.sh
--- a/scripts/in_scope.sh
+++ b/scripts/in_scope.sh
@@ -1,3 +1,4 @@
 #!/usr/bin/env bash
+# changed line
 echo ok
DIFF
    fi
    ;;
  'pr comment')
    printf 'https://github.com/yohei1126/example/pull/1#issuecomment-100\n'
    ;;
  *)
    printf 'gh stub: unexpected command: %s\n' "$*" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$fake_bin/gh"

last_status=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    printf 'PASS %s\n' "$label"
    pass=$((pass + 1))
  else
    printf 'FAIL %s: expected [%s], got [%s]\n' "$label" "$expected" "$actual" >&2
    fail=$((fail + 1))
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack_file="$3"
  if grep -Fq -- "$needle" "$haystack_file"; then
    printf 'PASS %s\n' "$label"
    pass=$((pass + 1))
  else
    printf 'FAIL %s: %s missing [%s]\n' "$label" "$haystack_file" "$needle" >&2
    fail=$((fail + 1))
  fi
}

assert_not_contains() {
  local label="$1" needle="$2" haystack_file="$3"
  if ! grep -Fq -- "$needle" "$haystack_file"; then
    printf 'PASS %s\n' "$label"
    pass=$((pass + 1))
  else
    printf 'FAIL %s: %s unexpectedly contained [%s]\n' "$label" "$haystack_file" "$needle" >&2
    fail=$((fail + 1))
  fi
}

run_scope() {
  : > "$argv_file"
  last_status=0
  PATH="$fake_bin:$PATH" RS_ARGV_FILE="$argv_file" \
    "$scope_script" "$@" >"$out_file" 2>"$err_file" || last_status=$?
}

run_post() {
  : > "$argv_file"
  last_status=0
  PATH="$fake_bin:$PATH" RS_ARGV_FILE="$argv_file" \
    "$post_script" "$@" >"$out_file" 2>"$err_file" || last_status=$?
}

printf '== help and usage ==\n'
run_scope --help
assert_eq "1: --help exits 0" "0" "$last_status"
assert_contains "1: --help names script" "scripts/review-scope.sh" "$out_file"
assert_contains "1: --help lists citation forms" "path:N-M" "$out_file"
assert_contains "1: --help describes uncited finding" "no recognised citation fails closed" "$out_file"
assert_eq "1: --help never calls gh" "0" "$(wc -l < "$argv_file" | tr -d ' ')"

run_scope
assert_eq "2: missing --comment exits 2" "2" "$last_status"

comment="$work_tmp/comment.md"
printf 'Model: example-model\nReviewed.\n' > "$comment"
run_scope --comment "$comment"
assert_eq "2: missing diff/scope exits 2" "2" "$last_status"

run_scope --comment "$comment" --diff "$work_tmp/missing.diff" --repo yohei1126/example --pr 1
assert_eq "2: --diff with --repo exits 2" "2" "$last_status"

bash -x "$scope_script" --help >/dev/null 2>"$err_file" || last_status=$?
assert_eq "3: bash -x exits 2" "2" "$last_status"

printf '== in-scope citations ==\n'
scoped_out="$work_tmp/scoped.md"
sidecar="$work_tmp/sidecar.txt"
cat > "$comment" <<'EOF'
Model: example-model
Findings: 0 blocker, 1 major, 1 minor, 0 nit.

- [major] scripts/in_scope.sh:2 - missing quote.
- [minor] [link](scripts/in_scope.sh:1-3) and ./scripts/in_scope.sh#L1-L2 - style note.

Verdict: FIX
EOF

rm -f "$scoped_out" "$sidecar"
run_scope --comment "$comment" --repo yohei1126/example --pr 1 --out "$scoped_out" --sidecar "$sidecar"
assert_eq "4: all in-scope exits 0" "0" "$last_status"
if cmp -s "$comment" "$scoped_out"; then
  printf 'PASS 4: in-scope body is byte-for-byte unchanged\n'
  pass=$((pass + 1))
else
  printf 'FAIL 4: in-scope body was modified\n' >&2
  fail=$((fail + 1))
fi
assert_contains "4: sidecar records unchanged" "decision=unchanged" "$sidecar"

printf '== caller-declared --scope ==\n'
scope_list="$work_tmp/scope.txt"
printf '# extra allowed paths\ndocs/extra.md\n' > "$scope_list"
cat > "$comment" <<'EOF'
Model: example-model
Findings: 0 blocker, 1 major, 0 minor, 0 nit.

- [major] docs/extra.md:5,10-12:1 - broken heading.

Verdict: FIX
EOF
rm -f "$scoped_out" "$sidecar"
run_scope --comment "$comment" --repo yohei1126/example --pr 1 --scope "$scope_list" --out "$scoped_out" --sidecar "$sidecar"
assert_eq "5: declared --scope allows path" "0" "$last_status"
assert_contains "5: sidecar unchanged" "decision=unchanged" "$sidecar"

printf '== out-of-scope blocker/major refused ==\n'
cat > "$comment" <<'EOF'
Model: example-model
Findings: 1 blocker, 0 major, 1 minor, 0 nit.

- [blocker] scripts/other.sh:10 - out of scope blocker.
- [minor] scripts/in_scope.sh:2 - in scope minor.

Verdict: FIX
EOF
rm -f "$scoped_out" "$sidecar"
run_scope --comment "$comment" --repo yohei1126/example --pr 1 --out "$scoped_out" --sidecar "$sidecar"
assert_eq "6: out-of-scope blocker exits 1" "1" "$last_status"
assert_contains "6: error names out-of-scope blocker" "out-of-scope blocker finding cites scripts/other.sh" "$err_file"
assert_eq "6: --out not written on refusal" "0" "$([ -e "$scoped_out" ] && echo 1 || echo 0)"
assert_contains "6: sidecar records refusal" "decision=refused" "$sidecar"

printf '== mixed comment drops minor/nit and keeps in-scope ==\n'
cat > "$comment" <<'EOF'
Model: example-model
Findings: 0 blocker, 1 major, 1 minor, 1 nit.

- [major] scripts/in_scope.sh:2 - real bug in diff.
- [minor] scripts/unchanged.sh:12 - out-of-scope minor.
- [nit] docs/unchanged.md:4 - out-of-scope nit.

Verdict: FIX
EOF
rm -f "$scoped_out" "$sidecar"
run_scope --comment "$comment" --repo yohei1126/example --pr 1 --out "$scoped_out" --sidecar "$sidecar"
assert_eq "7: mixed comment exits 0" "0" "$last_status"
assert_contains "7: keeps in-scope major" "scripts/in_scope.sh:2" "$scoped_out"
assert_not_contains "7: drops out-of-scope minor" "scripts/unchanged.sh:12" "$scoped_out"
assert_not_contains "7: drops out-of-scope nit" "docs/unchanged.md:4" "$scoped_out"
assert_contains "7: updates Findings summary" "Findings: 0 blocker, 1 major, 0 minor, 0 nit." "$scoped_out"
assert_contains "7: appends Scope note" "Scope note: dropped 2 out-of-scope finding(s) (minor at scripts/unchanged.sh, nit at docs/unchanged.md)." "$scoped_out"
assert_contains "7: sidecar records rewritten" "decision=rewritten" "$sidecar"

printf '== all findings out of scope refused ==\n'
cat > "$comment" <<'EOF'
Model: example-model
Findings: 0 blocker, 0 major, 1 minor, 0 nit.

- [minor] scripts/unchanged.sh:12 - only out-of-scope finding.

Verdict: FIX
EOF
rm -f "$scoped_out"
run_scope --comment "$comment" --repo yohei1126/example --pr 1 --out "$scoped_out"
assert_eq "8: all dropped refuses with exit 1" "1" "$last_status"
assert_eq "8: --out not written when all dropped" "0" "$([ -e "$scoped_out" ] && echo 1 || echo 0)"

printf '== uncited finding and unparsable comment fail closed ==\n'
cat > "$comment" <<'EOF'
Model: example-model
Findings: 0 blocker, 0 major, 1 minor, 0 nit.

- [minor] missing error check somewhere in the repo.

Verdict: FIX
EOF
run_scope --comment "$comment" --repo yohei1126/example --pr 1
assert_eq "9: uncited finding exits 1" "1" "$last_status"
assert_contains "9: names uncited failure" "no recognised citation" "$err_file"

cat > "$comment" <<'EOF'
Model: example-model
Findings: 1 major, 0 minor, 0 nit.

Some unstructured paragraph mentioning scripts/in_scope.sh:2.

Verdict: FIX
EOF
run_scope --comment "$comment" --repo yohei1126/example --pr 1
assert_eq "10: claimed Findings mismatch exits 1" "1" "$last_status"
assert_contains "10: names unparsable comment" "refusing unparsable comment" "$err_file"

cat > "$comment" <<'EOF'
Model: example-model
Findings: 0 blocker, 0 major, 0 minor, 0 nit.

- [minor] scripts/in_scope.sh:2 - unexpected finding despite zero header.

Verdict: PASS
EOF
run_scope --comment "$comment" --repo yohei1126/example --pr 1
assert_eq "10b: claimed 0 Findings with parsed finding exits 1" "1" "$last_status"
assert_contains "10b: names unparsable comment" "refusing unparsable comment" "$err_file"

cat > "$comment" <<'EOF'
Model: example-model
Reviewed scripts/unchanged.sh:9 in prose.
EOF
run_scope --comment "$comment" --repo yohei1126/example --pr 1
assert_eq "11: out-of-scope prose citation exits 1" "1" "$last_status"

printf '== unreadable or empty diff fails closed ==\n'
RS_FAIL_DIFF=1 run_scope --comment "$comment" --repo yohei1126/example --pr 1
assert_eq "12: gh pr diff failure exits 3" "3" "$last_status"

RS_DIFF_TEXT="" run_scope --comment "$comment" --repo yohei1126/example --pr 1
assert_eq "12: empty diff exits 1" "1" "$last_status"

printf '== pipeline with review-citations and post-review-comment ==\n'
git_repo="$work_tmp/repo"
mkdir -p "$git_repo/scripts"
printf '#!/usr/bin/env bash\necho line2\necho line3\n' > "$git_repo/scripts/in_scope.sh"
git -C "$git_repo" init -q
git -C "$git_repo" config user.email "test@example.invalid"
git -C "$git_repo" config user.name "Test"
git -C "$git_repo" add scripts/in_scope.sh
git -C "$git_repo" commit -qm "init"
head_sha="$(git -C "$git_repo" rev-parse HEAD)"

# Case A: mixed comment -> rewritten -> passes review-citations -> posts via post-review-comment.sh
rm -rf "$run_dir"
mkdir -p "$run_dir"
cat > "$run_dir/COMMENT.md" <<'EOF'
Model: example-model
Findings: 0 blocker, 1 major, 1 minor, 0 nit.

- [major] scripts/in_scope.sh:2 - check exit code.
- [minor] scripts/unchanged.sh:99 - out-of-scope minor.

Verdict: FIX
EOF
run_scope --comment "$run_dir/COMMENT.md" --repo yohei1126/example --pr 1 --out "$scoped_out"
assert_eq "13a: scope rewrite exits 0" "0" "$last_status"
"$gate_script" --check review-citations --comment "$scoped_out" --expect-head "$head_sha" --repo "$git_repo" >/dev/null 2>&1
assert_eq "13a: rewritten body passes review-citations" "0" "$?"

# Case B: remaining citation out-of-bounds still fails review-citations
cat > "$run_dir/COMMENT.md" <<'EOF'
Model: example-model
Findings: 0 blocker, 1 major, 1 minor, 0 nit.

- [major] scripts/in_scope.sh:999 - line past end.
- [minor] scripts/unchanged.sh:10 - out-of-scope minor.

Verdict: FIX
EOF
run_scope --comment "$run_dir/COMMENT.md" --repo yohei1126/example --pr 1 --out "$scoped_out"
assert_eq "13b: scope rewrite exits 0" "0" "$last_status"
rc_status=0
"$gate_script" --check review-citations --comment "$scoped_out" --expect-head "$head_sha" --repo "$git_repo" >/dev/null 2>&1 || rc_status=$?
assert_eq "13b: bad remaining citation still fails review-citations" "1" "$rc_status"

# Case C: post-review-comment.sh --scope-check posts rewritten body and records sidecar
rm -rf "$run_dir"
mkdir -p "$run_dir"
cat > "$run_dir/COMMENT.md" <<'EOF'
Model: example-model
Findings: 0 blocker, 1 major, 1 minor, 0 nit.

- [major] scripts/in_scope.sh:2 - check exit code.
- [minor] scripts/unchanged.sh:99 - out-of-scope minor.

Verdict: FIX
EOF
run_post --run "$run_dir" --repo yohei1126/example --pr 1 --scope-check
assert_eq "14: post-review-comment --scope-check exits 0" "0" "$last_status"
assert_contains "14: records posted URL" "posted" "$run_dir/post-review-comment.record"
assert_contains "14: writes scope sidecar" "decision=rewritten" "$run_dir/post-review-comment.scope"

# Case D: post-review-comment.sh --scope-check refuses out-of-scope blocker and posts nothing
rm -rf "$run_dir"
mkdir -p "$run_dir"
cat > "$run_dir/COMMENT.md" <<'EOF'
Model: example-model
Findings: 1 blocker, 0 major, 0 minor, 0 nit.

- [blocker] scripts/unchanged.sh:5 - out-of-scope blocker.

Verdict: FIX
EOF
run_post --run "$run_dir" --repo yohei1126/example --pr 1 --scope-check
assert_eq "15: post-review-comment refuses out-of-scope blocker" "1" "$last_status"
assert_not_contains "15: gh pr comment not called" "pr comment" "$argv_file"
assert_eq "15: no record file written" "0" "$([ -e "$run_dir/post-review-comment.record" ] && echo 1 || echo 0)"

# Case E: post-review-comment.sh --scope-check still fails secret/URL/at-sign scans
for bad_line in 'sk-abc123' 'https://example.invalid' 'ping @someone'; do
  rm -rf "$run_dir"
  mkdir -p "$run_dir"
  cat > "$run_dir/COMMENT.md" <<EOF
Model: example-model
Findings: 0 blocker, 1 major, 0 minor, 0 nit.

- [major] scripts/in_scope.sh:2 - $bad_line

Verdict: FIX
EOF
  run_post --run "$run_dir" --repo yohei1126/example --pr 1 --scope-check
  assert_eq "16: scan still rejects '$bad_line'" "1" "$last_status"
  assert_not_contains "16: scan rejection posts nothing for '$bad_line'" "pr comment" "$argv_file"
done

printf 'review-scope tests: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
