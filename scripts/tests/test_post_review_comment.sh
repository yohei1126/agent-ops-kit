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
    if [ -n "${PRC_VIEW_JSON:-}" ]; then
      printf '%s\n' "$PRC_VIEW_JSON"
    else
      printf '{"isDraft":%s,"state":"%s"}\n' "${PRC_IS_DRAFT:-true}" "${PRC_STATE:-OPEN}"
    fi
    exit 0
    ;;
  'pr comment')
    if [ "${PRC_COMMENT_NO_URL:-0}" = 1 ]; then
      printf 'posted with no URL\n'
      exit 0
    fi
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
  run_check_mode plain "$@"
}

run_check_xtrace() {
  run_check_mode xtrace "$@"
}

run_check_env() {
  : > "$argv_file"
  : > "$err_file"
  env HOME="$home_tmp" \
    PRC_ARGV_FILE="$argv_file" \
    PRC_IS_DRAFT="${PRC_IS_DRAFT:-true}" \
    PRC_STATE="${PRC_STATE:-OPEN}" \
    PRC_VIEW_JSON="${PRC_VIEW_JSON:-}" \
    PRC_FAIL_VIEW="${PRC_FAIL_VIEW:-0}" \
    PRC_FAIL_COMMENT="${PRC_FAIL_COMMENT:-0}" \
    PRC_COMMENT_NO_URL="${PRC_COMMENT_NO_URL:-0}" \
    PATH="$check_path" \
    "$@"
}

run_check_mode() {
  local mode="$1"
  shift
  if [ "$mode" = xtrace ]; then
    out="$(run_check_env bash -x "$check" "$@" 2>"$err_file")"
  else
    out="$(run_check_env bash "$check" "$@" 2>"$err_file")"
  fi
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
  PRC_STATE=OPEN
  PRC_VIEW_JSON=""
  PRC_FAIL_VIEW=0
  PRC_FAIL_COMMENT=0
  PRC_COMMENT_NO_URL=0
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
expect_argv_has "4: reads isDraft and state" "--json isDraft,state"
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

for word in desk-fan task-runner risk-free whisk-; do
  reset_run
  printf 'Model: example-model\n%s\n' "$word" > "$run/COMMENT.md"
  run_check --run "$run" --repo "$repo" --pr 7
  expect_status "7: token-like word $word exits 0" 0
  expect_post_once "7: token-like word $word posts once"
done

reset_run
printf 'Model: example-model\nsk-abc\n' > "$run/COMMENT.md"
run_check --run "$run" --repo "$repo" --pr 7
expect_status "7: sk- at a line start exits 1" 1
expect_no_post "7: sk- at a line start posts nothing"

reset_run
# shellcheck disable=SC2016 # literal backticks in the fixture
printf 'Model: example-model\n`sk-abc`\n' > "$run/COMMENT.md"
run_check --run "$run" --repo "$repo" --pr 7
expect_status "7: sk- inside backticks exits 1" 1
expect_no_post "7: sk- inside backticks posts nothing"

reset_run
printf 'Model: example-model\nkey=sk-abc\n' > "$run/COMMENT.md"
run_check --run "$run" --repo "$repo" --pr 7
expect_status "7: sk- after = exits 1" 1
expect_no_post "7: sk- after = posts nothing"

reset_run
printf 'Model: example-model\n(ghp_abc\n' > "$run/COMMENT.md"
run_check --run "$run" --repo "$repo" --pr 7
expect_status "7: ghp_ after ( exits 1" 1
expect_no_post "7: ghp_ after ( posts nothing"

reset_run
printf 'Model: example-model\n"github_pat_abc\n' > "$run/COMMENT.md"
run_check --run "$run" --repo "$repo" --pr 7
expect_status "7: github_pat_ after a quote exits 1" 1
expect_no_post "7: github_pat_ after a quote posts nothing"

reset_run
printf 'Model: example-model\nxai-abc\n' > "$run/COMMENT.md"
run_check --run "$run" --repo "$repo" --pr 7
expect_status "7: xai- at a line start exits 1" 1
expect_no_post "7: xai- at a line start posts nothing"

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
make_tool_path "$check_path" bash sh cat wc grep tr mktemp rm mkdir rmdir dirname
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

printf '== symlinked run and record ==\n'
reset_run
good_body
real_run="$work_tmp/real-run"
rm -rf "$real_run"
mkdir -p "$real_run"
printf 'Model: example-model\nReviewed the change.\n' > "$real_run/COMMENT.md"
link_run="$work_tmp/link-run"
rm -rf "$link_run"
ln -s "$real_run" "$link_run"
run_check --run "$link_run" --repo "$repo" --pr 7
expect_status "14: a symlinked --run exits 1" 1
expect_no_post "14: a symlinked --run posts nothing"
expect_argv_calls "14: a symlinked --run never calls gh" 0

reset_run
good_body
ln -s "$work_tmp/missing-record" "$run/post-review-comment.record"
run_check --run "$run" --repo "$repo" --pr 7
expect_status "14: a dangling record symlink exits 1" 1
expect_no_post "14: a dangling record symlink posts nothing"
expect_argv_calls "14: a dangling record symlink never calls gh" 0

reset_run
good_body
printf 'posted\t%s\t%s\t%s\n' "$repo" 7 "https://github.example/pr/7#comment-7" > "$work_tmp/outside.record"
ln -s "$work_tmp/outside.record" "$run/post-review-comment.record"
run_check --run "$run" --repo "$repo" --pr 7
expect_status "14: a record symlink exits 1" 1
expect_no_post "14: a record symlink posts nothing"
expect_argv_calls "14: a record symlink never calls gh" 0

printf '== open draft and state ==\n'
for state in CLOSED MERGED; do
  reset_run
  good_body
  PRC_STATE="$state"
  run_check --run "$run" --repo "$repo" --pr 7
  expect_status "15: isDraft true with state $state exits 1" 1
  expect_no_post "15: isDraft true with state $state posts nothing"
done

reset_run
good_body
run_check --run "$run" --repo "$repo" --pr 7
expect_status "15: isDraft true with state OPEN exits 0" 0
expect_post_once "15: an open draft posts once"

printf '== model line and body ==\n'
for fixture in 'Model: ' 'Model:     '; do
  reset_run
  printf '%s\nbody text\n' "$fixture" > "$run/COMMENT.md"
  run_check --run "$run" --repo "$repo" --pr 7
  expect_status "16: '$fixture' exits 1" 1
  expect_no_post "16: '$fixture' posts nothing"
done

reset_run
printf 'Model: example-model\n' > "$run/COMMENT.md"
run_check --run "$run" --repo "$repo" --pr 7
expect_status "16: a one-line Model file exits 1" 1
expect_no_post "16: a one-line Model file posts nothing"

reset_run
printf 'Model: example-model\r\nbody text\r\n' > "$run/COMMENT.md"
run_check --run "$run" --repo "$repo" --pr 7
expect_status "16: a CRLF body exits 0" 0
expect_post_once "16: a CRLF body posts once"

printf '== env defaults and flags ==\n'
reset_run
good_body
POST_REVIEW_COMMENT_OWNERS=someoneelse
export POST_REVIEW_COMMENT_OWNERS
run_check --run "$run" --repo someoneelse/example-repo --pr 7
expect_status "17: POST_REVIEW_COMMENT_OWNERS allows an owner" 0
expect_post_once "17: the env allowed owner posts once"
unset POST_REVIEW_COMMENT_OWNERS

reset_run
good_body
POST_REVIEW_COMMENT_MAX_BYTES=10
export POST_REVIEW_COMMENT_MAX_BYTES
run_check --run "$run" --repo "$repo" --pr 7
expect_status "17: POST_REVIEW_COMMENT_MAX_BYTES caps the body" 1
expect_no_post "17: the env byte cap posts nothing"
unset POST_REVIEW_COMMENT_MAX_BYTES

reset_run
good_body
POST_REVIEW_COMMENT_OWNERS=other
POST_REVIEW_COMMENT_MAX_BYTES=10
export POST_REVIEW_COMMENT_OWNERS POST_REVIEW_COMMENT_MAX_BYTES
run_check --run "$run" --repo someoneelse/example-repo --pr 7 --owners someoneelse --max-bytes 65536
expect_status "17: CLI flags win over the env vars" 0
expect_post_once "17: the CLI override posts once"
unset POST_REVIEW_COMMENT_OWNERS POST_REVIEW_COMMENT_MAX_BYTES

reset_run
good_body
run_check --run="$run" --repo=someoneelse/example-repo --pr=7 --owners=someoneelse --max-bytes=65536
expect_status "17: equals-delimited flags exit 0" 0
expect_post_once "17: equals-delimited flags post once"

printf '== second default owner ==\n'
reset_run
good_body
run_check --run "$run" --repo edgesentry/example-repo --pr 7
expect_status "18: the second default owner passes" 0
expect_post_once "18: the second default owner posts once"

printf '== record repo case ==\n'
reset_run
good_body
run_check --run "$run" --repo yohei1126/agent-ops-kit --pr 7
expect_status "19: the first repo spelling posts" 0
expect_post_once "19: the first repo spelling posts once"
run_check --run "$run" --repo yohei1126/Agent-Ops-Kit --pr 7
expect_status "19: a case variant fails closed" 1
expect_no_post "19: a case variant posts nothing"
expect_argv_calls "19: a case variant never calls gh" 0
expect_err "19: the case variant finds the record" "already posted"

printf '== multi-line record ==\n'
reset_run
good_body
printf 'posted\t%s\t%s\t%s\n' "yohei1126/other-repo" 9 "https://github.example/pr/9#comment-9" > "$run/post-review-comment.record"
run_check --run "$run" --repo yohei1126/agent-ops-kit --pr 7
expect_status "20: a record for another PR still posts" 0
expect_post_once "20: a record for another PR posts once"

reset_run
good_body
printf 'pending\t%s\t%s\t\n' "yohei1126/agent-ops-kit" 7 > "$run/post-review-comment.record"
printf 'posted\t%s\t%s\t%s\n' "yohei1126/agent-ops-kit" 7 "https://github.example/pr/7#comment-7" >> "$run/post-review-comment.record"
run_check --run "$run" --repo yohei1126/agent-ops-kit --pr 7
expect_status "20: pending then posted fails closed" 1
expect_no_post "20: pending then posted posts nothing"
expect_err "20: pending then posted names the post" "already posted"

reset_run
good_body
printf 'posted\t%s\t%s\t\n' "yohei1126/agent-ops-kit" 7 > "$run/post-review-comment.record"
run_check --run "$run" --repo yohei1126/agent-ops-kit --pr 7
expect_status "20: posted with an empty URL fails closed" 1
expect_no_post "20: posted with an empty URL posts nothing"
expect_err "20: posted with an empty URL names the attempt" "did not finish"

printf '== gh read and post shapes ==\n'
reset_run
good_body
PRC_COMMENT_NO_URL=1
run_check --run "$run" --repo "$repo" --pr 7
expect_status "21: a comment with no URL exits 3" 3
if grep -Fq "posted" "$run/post-review-comment.record" 2>/dev/null; then bad "21: no URL records no success" "record holds a posted line"; else ok "21: no URL records no success"; fi

reset_run
good_body
PRC_VIEW_JSON='not json'
run_check --run "$run" --repo "$repo" --pr 7
expect_status "21: malformed view JSON exits 3" 3
expect_no_post "21: malformed view JSON posts nothing"
if [ -f "$run/post-review-comment.record" ] && grep -Fq "pending" "$run/post-review-comment.record"; then bad "21: malformed view JSON leaves no pending" "record holds a pending line"; else ok "21: malformed view JSON leaves no pending"; fi

printf '== concurrent lock ==\n'
reset_run
good_body
mkdir "$run/post-review-comment.lock"
run_check --run "$run" --repo "$repo" --pr 7
expect_status "22: an existing lock exits 1" 1
expect_no_post "22: an existing lock posts nothing"
if [ -d "$run/post-review-comment.lock" ]; then ok "22: a foreign lock is left in place"; else bad "22: a foreign lock is left in place" "the lock was removed"; fi

reset_run
good_body
run_check --run "$run" --repo "$repo" --pr 7
expect_status "22: a clean run exits 0" 0
if [ -e "$run/post-review-comment.lock" ]; then bad "22: a clean run removes the lock" "lock left behind"; else ok "22: a clean run removes the lock"; fi

printf '== xtrace refusal ==\n'
reset_run
good_body
run_check_xtrace --run "$run" --repo "$repo" --pr 7
expect_status "23: bash -x exits 2" 2
expect_no_post "23: bash -x posts nothing"
expect_argv_calls "23: bash -x never calls gh" 0
expect_err "23: bash -x names xtrace" "xtrace"

printf '== policy failure ==\n'
reset_run
good_body
POLICY_RULES="$work_tmp/missing-policy"
export POLICY_RULES
run_check --run "$run" --repo "$repo" --pr 7
expect_status "24: missing policy exits 3" 3
expect_no_post "24: missing policy posts nothing"
expect_err "24: missing policy names the failure" "policy file missing or invalid"
unset POLICY_RULES

printf '\n%d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -ne 0 ]; then
  exit 1
fi
exit 0
