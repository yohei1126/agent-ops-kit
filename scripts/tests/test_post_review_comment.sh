#!/usr/bin/env bash
# Tests for scripts/post-review-comment.sh.
# Uses a fake gh on PATH. No network and no real repository.
set -u

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
check="$repo_root/scripts/post-review-comment.sh"

pass=0
fail=0
work_tmp="$(mktemp -d)"
home_tmp="$work_tmp/home"
fake_bin="$work_tmp/bin"
run="$work_tmp/run"
argv_file="$work_tmp/argv"
err_file="$work_tmp/stderr"

mkdir -p "$home_tmp" "$fake_bin" "$run"
: > "$argv_file"
: > "$err_file"

trap 'rm -rf "$work_tmp"' EXIT

unset POST_REVIEW_COMMENT_OWNERS POST_REVIEW_COMMENT_MAX_BYTES

cat > "$fake_bin/gh" <<'EOF'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${PRC_ARGV_FILE:-/dev/null}"
if [ "${PRC_FAIL_VIEW:-0}" = 1 ] && [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then
  printf 'gh: view failed\n' >&2
  exit 1
fi
if [ "${PRC_FAIL_COMMENT:-0}" = 1 ] && [ "${1:-}" = "pr" ] && [ "${2:-}" = "comment" ]; then
  printf 'gh: comment failed\n' >&2
  exit 1
fi
case "${1:-} ${2:-}" in
  'pr view')
    printf '{"isDraft":%s}\n' "${PRC_IS_DRAFT:-true}"
    exit 0
    ;;
  'pr comment')
    printf 'https://github.example/pr/1#comment-1\n'
    exit 0
    ;;
esac
printf 'gh: unexpected command: %s\n' "$*" >&2
exit 1
EOF
chmod +x "$fake_bin/gh"

ok() { pass=$((pass + 1)); printf 'PASS %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s: %s\n' "$1" "$2"; }

expect_status() {
  if [ "$status" -eq "$2" ]; then ok "$1"; else bad "$1" "expected exit $2, got $status; stderr: $err"; fi
}
expect_err() {
  case "$err" in *"$2"*) ok "$1" ;; *) bad "$1" "stderr missing: $2" ;; esac
}
expect_out_has() {
  case "$out" in *"$2"*) ok "$1" ;; *) bad "$1" "stdout missing: $2" ;; esac
}
expect_argv_has() {
  if grep -Fq -- "$2" "$argv_file"; then ok "$1"; else bad "$1" "argv missing: $2"; fi
}
expect_argv_calls() {
  local actual
  actual="$(wc -l < "$argv_file" | tr -d ' ')"
  if [ "$actual" -eq "$2" ]; then ok "$1"; else bad "$1" "argv has $actual calls, expected $2"; fi
}
expect_no_post() {
  if grep -Eq -- '(^| )pr comment( |$)' "$argv_file"; then bad "$1" "gh pr comment was invoked"; else ok "$1"; fi
}
expect_post_once() {
  local actual
  actual="$(grep -Ec -- '(^| )pr comment( |$)' "$argv_file")"
  if [ "$actual" -eq 1 ]; then ok "$1"; else bad "$1" "gh pr comment ran $actual times"; fi
}

check_path="$fake_bin:$PATH"

run_check() {
  : > "$argv_file"
  : > "$err_file"
  out="$(env HOME="$home_tmp" \
    PRC_ARGV_FILE="$argv_file" \
    PRC_IS_DRAFT="${PRC_IS_DRAFT:-true}" \
    PRC_FAIL_VIEW="${PRC_FAIL_VIEW:-0}" \
    PRC_FAIL_COMMENT="${PRC_FAIL_COMMENT:-0}" \
    PATH="$check_path" \
    bash "$check" "$@" 2>"$err_file")"
  status=$?
  err="$(cat "$err_file")"
}

make_tool_path() {
  local dir="$1"
  local tool found
  shift
  mkdir -p "$dir"
  for tool in "$@"; do
    found="$(command -v "$tool" 2>/dev/null || true)"
    if [ -n "$found" ]; then ln -s "$found" "$dir/$tool"; fi
  done
}

reset_run() {
  rm -rf "$run"
  mkdir -p "$run"
  PRC_IS_DRAFT=true
  PRC_FAIL_VIEW=0
  PRC_FAIL_COMMENT=0
}

good_body() {
  printf 'Model: example-model\nReviewed the change.\n' > "$run/COMMENT.md"
}

record_has_url() {
  grep -Fq "https://github.example/pr/1#comment-1" "$run/post-review-comment.record" 2>/dev/null
}

repo="yohei1126/example-repo"

printf '== help ==\n'
reset_run
run_check --help
expect_status "1: --help exits 0" 0
expect_out_has "1: --help names the script" "scripts/post-review-comment.sh"
expect_argv_calls "1: --help never calls gh" 0

printf '== usage errors ==\n'
reset_run
good_body
run_check --repo "$repo" --pr 7
expect_status "2: missing --run exits 2" 2
run_check --run "$run" --pr 7
expect_status "2: missing --repo exits 2" 2
run_check --run "$run" --repo "$repo"
expect_status "2: missing --pr exits 2" 2
run_check --run "$run" --repo not-a-slug --pr 7
expect_status "2: bad repo shape exits 2" 2
for value in abc 0 -1 3.5; do
  run_check --run "$run" --repo "$repo" --pr "$value"
  expect_status "2: --pr '$value' exits 2" 2
done
run_check --run "$run" --repo "$repo" --pr 7 --owners ""
expect_status "2: empty --owners exits 2" 2
for value in abc 0 -1; do
  run_check --run "$run" --repo "$repo" --pr 7 --max-bytes "$value"
  expect_status "2: --max-bytes '$value' exits 2" 2
done
expect_argv_calls "2: usage errors never call gh" 0

printf '== COMMENT.md problems ==\n'
reset_run
run_check --run "$run" --repo "$repo" --pr 7
expect_status "3: missing COMMENT.md exits 1" 1
expect_no_post "3: missing COMMENT.md posts nothing"

reset_run
mkdir "$run/COMMENT.md"
run_check --run "$run" --repo "$repo" --pr 7
expect_status "3: a directory at COMMENT.md exits 1" 1
expect_no_post "3: a directory at COMMENT.md posts nothing"

reset_run
printf 'Model: example-model\nsafe\n' > "$work_tmp/outside.md"
ln -s "$work_tmp/outside.md" "$run/COMMENT.md"
run_check --run "$run" --repo "$repo" --pr 7
expect_status "3: a symlink at COMMENT.md exits 1" 1
expect_no_post "3: a symlink at COMMENT.md posts nothing"

reset_run
: > "$run/COMMENT.md"
run_check --run "$run" --repo "$repo" --pr 7
expect_status "3: an empty COMMENT.md exits 1" 1
expect_no_post "3: an empty COMMENT.md posts nothing"

printf '== pass ==\n'
reset_run
good_body
run_check --run "$run" --repo "$repo" --pr 7
expect_status "4: a valid draft post exits 0" 0
expect_out_has "4: prints the comment URL" "https://github.example/pr/1#comment-1"
expect_post_once "4: gh pr comment runs once"
expect_argv_has "4: posts the run body file" "--body-file $run/COMMENT.md"
expect_argv_has "4: reads isDraft" "--json isDraft"
if record_has_url; then ok "4: the record holds the comment URL"; else bad "4: the record holds the comment URL" "record missing the URL"; fi

printf '== first line ==\n'
for fixture in "model: example-model" "Model:example-model" " Model: example-model" "Not a model line"; do
  reset_run
  printf '%s\nbody text\n' "$fixture" > "$run/COMMENT.md"
  run_check --run "$run" --repo "$repo" --pr 7
  expect_status "5: '$fixture' exits 1" 1
  expect_no_post "5: '$fixture' posts nothing"
done

printf '== byte cap ==\n'
reset_run
printf 'Model: example-model\nbody text that is longer\n' > "$run/COMMENT.md"
run_check --run "$run" --repo "$repo" --pr 7 --max-bytes 20
expect_status "6: over the cap exits 1" 1
expect_no_post "6: over the cap posts nothing"

reset_run
total=64
printf 'Model: pad\n' > "$run/COMMENT.md"
n=$((total - 12))
head -c "$n" /dev/zero | tr '\0' 'a' >> "$run/COMMENT.md"
printf '\n' >> "$run/COMMENT.md"
actual="$(wc -c < "$run/COMMENT.md" | tr -d ' ')"
if [ "$actual" -eq "$total" ]; then ok "6: fixture is exactly $total bytes"; else bad "6: fixture is exactly $total bytes" "size is $actual"; fi
run_check --run "$run" --repo "$repo" --pr 7 --max-bytes "$total"
expect_status "6: exactly at the cap exits 0" 0
expect_post_once "6: exactly at the cap posts once"

printf '== secrets ==\n'
for token in ghp_ gho_ ghs_ github_pat_ xai- sk-; do
  reset_run
  printf 'Model: example-model\nnote %sdummy_value\n' "$token" > "$run/COMMENT.md"
  run_check --run "$run" --repo "$repo" --pr 7
  expect_status "7: token prefix $token exits 1" 1
  expect_no_post "7: token prefix $token posts nothing"
done

reset_run
printf 'Model: example-model\n-----BEGIN RSA PRIVATE KEY-----\ndummy body\n' > "$run/COMMENT.md"
run_check --run "$run" --repo "$repo" --pr 7
expect_status "7: a PEM header exits 1" 1
expect_no_post "7: a PEM header posts nothing"

printf '== urls and mentions ==\n'
for link in 'http://example.invalid' 'https://example.invalid' 'HTTP://example.invalid'; do
  reset_run
  printf 'Model: example-model\nsee %s\n' "$link" > "$run/COMMENT.md"
  run_check --run "$run" --repo "$repo" --pr 7
  expect_status "8: '$link' exits 1" 1
  expect_no_post "8: '$link' posts nothing"
done

reset_run
printf 'Model: example-model\nthanks @someone\n' > "$run/COMMENT.md"
run_check --run "$run" --repo "$repo" --pr 7
expect_status "9: an at sign exits 1" 1
expect_no_post "9: an at sign posts nothing"

printf '== owner allowlist ==\n'
reset_run
good_body
run_check --run "$run" --repo someoneelse/example-repo --pr 7
expect_status "10: owner outside the default list exits 1" 1
expect_no_post "10: owner outside the default list posts nothing"

reset_run
good_body
run_check --run "$run" --repo someoneelse/example-repo --pr 7 --owners someoneelse,other
expect_status "10: --owners can allow another owner" 0
expect_post_once "10: the allowed owner posts once"

reset_run
good_body
run_check --run "$run" --repo someoneelse/example-repo --pr 7 --owners other-org
expect_status "10: --owners can reject one not listed" 1
expect_no_post "10: a rejected owner posts nothing"

printf '== draft ==\n'
reset_run
good_body
PRC_IS_DRAFT=false
run_check --run "$run" --repo "$repo" --pr 7
expect_status "11: a non-draft PR exits 1" 1
expect_no_post "11: a non-draft PR posts nothing"
expect_argv_calls "11: a non-draft PR only reads the PR" 1

printf '== the record file ==\n'
reset_run
good_body
printf 'posted\t%s\t%s\t%s\n' "$repo" 7 "https://example.invalid/comment" > "$run/post-review-comment.record"
run_check --run "$run" --repo "$repo" --pr 7
expect_status "12: an existing success record exits 1" 1
expect_no_post "12: an existing success record posts nothing"
expect_argv_calls "12: an existing success record never calls gh" 0
expect_err "12: the success record is named" "already posted"

reset_run
good_body
printf 'pending\t%s\t%s\t\n' "$repo" 7 > "$run/post-review-comment.record"
run_check --run "$run" --repo "$repo" --pr 7
expect_status "12: a pending record exits 1" 1
expect_no_post "12: a pending record posts nothing"
expect_argv_calls "12: a pending record never calls gh" 0
expect_err "12: the pending record is named" "did not finish"

printf '== gh failures ==\n'
reset_run
good_body
check_path="$work_tmp/no-gh"
make_tool_path "$check_path" bash sh cat wc grep tr mktemp rm mkdir
run_check --run "$run" --repo "$repo" --pr 7
expect_status "13: missing gh exits 3" 3
expect_argv_calls "13: missing gh never calls gh" 0
check_path="$fake_bin:$PATH"

reset_run
good_body
PRC_FAIL_VIEW=1
run_check --run "$run" --repo "$repo" --pr 7
expect_status "13: gh pr view failure exits 3" 3
expect_no_post "13: gh pr view failure posts nothing"

reset_run
good_body
PRC_FAIL_COMMENT=1
run_check --run "$run" --repo "$repo" --pr 7
expect_status "13: gh pr comment failure exits 3" 3
if record_has_url; then bad "13: a failed post records no URL" "record holds a URL"; else ok "13: a failed post records no URL"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -ne 0 ]; then
  exit 1
fi
exit 0
