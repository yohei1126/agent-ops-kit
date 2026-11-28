#!/usr/bin/env bash
# Tests for scripts/gemini-batch.sh. Fake gh and curl on PATH, no network, no
# real provider call, no real repository. Bash 3.2 compatible.
# The checks pipe a condition into check() through $?, on purpose.
# shellcheck disable=SC2319,SC2181,SC2015
set -u

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
gb_script="$repo_root/scripts/gemini-batch.sh"

pass=0
fail=0
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fake_bin="$work/bin"
mkdir -p "$fake_bin"
KEY="test-key-not-real-0123456789"
NOW=1798000000

ok() { pass=$((pass + 1)); printf 'PASS %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s: %s\n' "$1" "$2"; }
check() { # NAME CONDITION-RC MSG
  if [ "$2" = 0 ]; then ok "$1"; else bad "$1" "${3:-condition failed}"; fi
}

cat > "$fake_bin/gh" <<'EOF'
#!/usr/bin/env bash
set -u
m="$MOCK_DIR"
printf '%s\n' "$*" >> "$m/gh.log"
repo=""
prev=""
for a in "$@"; do
  case "$prev" in -R | --repo) repo="$a" ;; esac
  prev="$a"
done
slug="$(printf '%s' "$repo" | tr '/' '_')"
case "${1:-} ${2:-}" in
  'repo view')
    if [ "${MOCK_PRIVATE:-0}" = 1 ]; then echo '{"isPrivate":true}'; else echo '{"isPrivate":false}'; fi ;;
  'pr list')
    case " $* " in
      *' --state all '*) cat "$m/all-$slug.json" 2>/dev/null || echo '[]' ;;
      *) cat "$m/prs-$slug.json" 2>/dev/null || echo '[]' ;;
    esac ;;
  'pr diff') cat "$m/diff-$3.txt" 2>/dev/null || echo 'diff --git a/x b/x' ;;
  'pr view') cat "$m/view-$3.json" ;;
  'pr comment')
    cp "$(printf '%s\n' "$@" | sed -n '/^--body-file$/{n;p;}')" "$m/comment-$3.md"
    echo "$* " >> "$m/comments.log"
    echo "https://github.example/$repo/pull/$3#issuecomment-1" ;;
  'api '*) cat "$m/advisories.json" 2>/dev/null || echo '[]' ;;
  *) echo "gh: unexpected: $*" >&2; exit 1 ;;
esac
EOF
cat > "$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -u
m="$MOCK_DIR"
method=GET; outf=""; body=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    -o) outf="$2"; shift 2 ;;
    --data-binary) body="${2#@}"; shift 2 ;;
    -K | --connect-timeout | --max-time | -H | -w) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
printf '%s %s\n' "$method" "$url" >> "$m/curl.log"
code=200
case "$method $url" in
  'GET '*models*) cat "$m/models.json" > "$outf" ;;
  'POST '*batchGenerateContent)
    n=$(($(wc -l < "$m/curl.log")))
    cp "$body" "$m/submit-$n.json"; cp "$body" "$m/submit-last.json"
    if [ "${MOCK_SUBMIT_CODE:-200}" = 000 ]; then exit 28; fi
    echo '{"name":"batches/abc"}' > "$outf"; code="${MOCK_SUBMIT_CODE:-200}" ;;
  'GET '*batches\?*)
    if [ -f "$m/batches-list.json" ]; then cat "$m/batches-list.json" > "$outf"; else echo '{}' > "$outf"; code=404; fi ;;
  'GET '*batches/*) cat "$m/batch-state.json" > "$outf" ;;
  *) echo '{}' > "$outf"; code=404 ;;
esac
printf '%s' "$code"
EOF
chmod +x "$fake_bin/gh" "$fake_bin/curl"

new_case() { # sets MOCK_DIR, STATE and default fixtures
  rm -rf "$work/case"; mkdir -p "$work/case/mock" "$work/case/state"
  MOCK_DIR="$work/case/mock"; STATE="$work/case/state"
  export MOCK_DIR
  : > "$MOCK_DIR/gh.log"; : > "$MOCK_DIR/curl.log"
  echo '{"models":[{"name":"models/gemini-4-argon","supportedGenerationMethods":["batchGenerateContent"]},{"name":"models/gemini-3.8-flash","supportedGenerationMethods":["batchGenerateContent"]}]}' > "$MOCK_DIR/models.json"
  unset MOCK_PRIVATE MOCK_SUBMIT_CODE
  NOW_USE="$NOW"
}
sha() { printf '%s%s' "$1" "$(printf 'a%.0s' 1 2 3 4 5 6)"; }
mk_prs() { # N... : owner drafts at head sha<N>
  local out="[" sep="" n
  for n in "$@"; do
    out="$out$sep{\"number\":$n,\"isDraft\":true,\"headRefOid\":\"$(sha "$n")000\",\"author\":{\"login\":\"yohei1126\"},\"isCrossRepository\":false}"
    sep=","
    echo "{\"headRefOid\":\"$(sha "$n")000\",\"isDraft\":true,\"state\":\"OPEN\",\"author\":{\"login\":\"yohei1126\"},\"isCrossRepository\":false,\"comments\":[]}" > "$MOCK_DIR/view-$n.json"
  done
  echo "$out]" > "$MOCK_DIR/prs-yohei1126_agent-ops-kit.json"
}
gb() { # args -> out, err, rc
  GEMINI_API_KEY="$KEY" GEMINI_BATCH_NOW="$NOW_USE" PATH="$fake_bin:$PATH" \
    bash "$gb_script" --state "$STATE" "$@" > "$work/out" 2> "$work/err"
  rc=$?
  out="$(cat "$work/out")"; err="$(cat "$work/err")"
}
batch_file() { local f; for f in "$STATE"/batches/b*[0-9].json; do printf '%s' "$f"; return 0; done; }
batch_count() { local n=0 f; for f in "$STATE"/batches/*.json; do [ -e "$f" ] && n=$((n + 1)); done; echo "$n"; }
posts() { grep -c POST "$MOCK_DIR/curl.log" 2>/dev/null || true; }
count_status() { # status
  local n=0 f
  for f in "$STATE"/items/*.json; do [ -e "$f" ] && [ "$(jq -r .status "$f")" = "$1" ] && n=$((n + 1)); done
  echo "$n"
}
make_done() { # write a succeeded batch-state with a text per submitted key
  jq -n --slurpfile s "$MOCK_DIR/submit-last.json" --arg t "$1" \
    '{done:true,metadata:{state:"JOB_STATE_SUCCEEDED"},response:{inlinedResponses:{inlinedResponses:[$s[0].batch.input_config.requests.requests[]|{metadata:{key:.metadata.key},response:{candidates:[{finishReason:"STOP",content:{parts:[{text:$t}]}}]}}]}}}' > "$MOCK_DIR/batch-state.json"
}
make_done_state() { # STATE TEXT: done:true batch-state under a given state name
  jq -n --slurpfile s "$MOCK_DIR/submit-last.json" --arg st "$1" --arg t "$2" \
    '{done:true,metadata:{state:$st},response:{inlinedResponses:{inlinedResponses:[$s[0].batch.input_config.requests.requests[]|{metadata:{key:.metadata.key},response:{candidates:[{finishReason:"STOP",content:{parts:[{text:$t}]}}]}}]}}}' > "$MOCK_DIR/batch-state.json"
}
make_done_nostate() { # TEXT: done:true with no metadata state and no error
  jq -n --slurpfile s "$MOCK_DIR/submit-last.json" --arg t "$1" \
    '{done:true,response:{inlinedResponses:{inlinedResponses:[$s[0].batch.input_config.requests.requests[]|{metadata:{key:.metadata.key},response:{candidates:[{finishReason:"STOP",content:{parts:[{text:$t}]}}]}}]}}}' > "$MOCK_DIR/batch-state.json"
}
REVIEW_TEXT='Findings: 0 blocker, 0 major, 0 minor, 0 nit. See https://example.com/x or mail a@b.example. Verdict: PASS'

# --- help and usage ---------------------------------------------------------
new_case
gb --help; check "help exits 0" "$rc"
case "$out" in *"Fail-closed rules"*) ok "help describes fail-closed" ;; *) bad "help describes fail-closed" "$out" ;; esac
gb bogus; [ "$rc" = 2 ]; check "unknown command is usage error" "$?"
gb scan --threshold 0; [ "$rc" = 2 ]; check "zero threshold is usage error" "$?"

# --- visibility, allowlist, PR eligibility ---------------------------------------
new_case; mk_prs 1 2 3; export MOCK_PRIVATE=1
gb scan; [ "$(count_status queued)" = 0 ] && [ "$rc" = 0 ]; check "private repo queues nothing" "$?"
grep -q 'pr list' "$MOCK_DIR/gh.log"; [ "$?" != 0 ]; check "private repo: no pull request read" "$?"
unset MOCK_PRIVATE

new_case
cat > "$MOCK_DIR/prs-yohei1126_agent-ops-kit.json" <<'EOF'
[{"number":1,"isDraft":false,"headRefOid":"1111111aaaa","author":{"login":"yohei1126"},"isCrossRepository":false},
 {"number":2,"isDraft":true,"headRefOid":"2222222aaaa","author":{"login":"yohei1126"},"isCrossRepository":true},
 {"number":3,"isDraft":true,"headRefOid":"3333333aaaa","author":{"login":"someone"},"isCrossRepository":false},
 {"number":4,"isDraft":true,"headRefOid":"4444444aaaa","author":{"login":"Yohei1126"},"isCrossRepository":false},
 {"number":5,"isDraft":true,"headRefOid":"zzzz","author":{"login":"yohei1126"},"isCrossRepository":false}]
EOF
gb scan
[ "$(count_status queued)" = 1 ]; check "scan queues only owner same-repo open drafts with a SHA" "$?"

new_case; mk_prs 1
grep -v 'md-deck' "$repo_root/policy/rules" > "$work/rules.noop"
awk 'BEGIN{RS="";ORS="\n\n"} !/gemini-batch.repo/ || /agent-ops-kit/' "$repo_root/policy/rules" > "$work/rules.kit"
( export POLICY_RULES="$work/rules.kit"; gb scan )
grep -q 'md-deck' "$MOCK_DIR/gh.log"; [ "$?" != 0 ]; check "repo off the allowlist is never read" "$?"

# --- allowlisted organization repositories --------------------------------------
new_case
cat > "$MOCK_DIR/prs-edgesentry_ontographia.json" <<'EOF'
[{"number":1,"isDraft":true,"headRefOid":"1111111aaaa","author":{"login":"yohei1126"},"isCrossRepository":false},
 {"number":2,"isDraft":true,"headRefOid":"2222222aaaa","author":{"login":"someone"},"isCrossRepository":false}]
EOF
gb scan
[ "$(count_status queued)" = 1 ]; check "org repo: only the mapped author's draft is queued" "$?"

new_case
cat > "$MOCK_DIR/prs-edgesentry_ontographia.json" <<'EOF'
[{"number":1,"isDraft":true,"headRefOid":"1111111aaaa","author":{"login":"yohei1126"},"isCrossRepository":false}]
EOF
echo '{"headRefOid":"1111111aaaa","isDraft":true,"state":"OPEN","author":{"login":"yohei1126"},"isCrossRepository":false,"comments":[]}' > "$MOCK_DIR/view-1.json"
gb scan
[ "$(count_status queued)" = 1 ]; check "org repo: mapped author's draft is queued" "$?"
printf '%s\n' '{"headRefOid":"1111111aaaa","isDraft":true,"state":"OPEN","author":{"login":"someone"},"isCrossRepository":false,"comments":[]}' > "$MOCK_DIR/view-1.json"
gb submit --threshold 1
[ "$(count_status skipped)" = 1 ] && [ "$(count_status submitted)" = 0 ] && [ "$(posts)" = 0 ]; check "submit re-reads the author: unmapped live author is skipped" "$?"

# --- happy path, restart resume, once per head SHA ------------------------------
new_case; mk_prs 1 2 3
gb scan; [ "$(count_status queued)" = 3 ]; check "happy: three queued" "$?"
gb submit
[ "$rc" = 0 ] && [ "$(posts)" = 1 ] && [ "$(count_status submitted)" = 3 ]; check "happy: one batch submitted for 3 PRs" "$?"
jq -e '.batch.input_config.requests.requests|length==3' "$MOCK_DIR/submit-last.json" >/dev/null; check "happy: 3 requests in the batch" "$?"
grep -q 'models/gemini-4-argon:batchGenerateContent' "$MOCK_DIR/curl.log"; check "happy: pinned Argon model on the Gemini API" "$?"
grep -q 'aiplatform' "$MOCK_DIR/curl.log"; [ "$?" != 0 ]; check "happy: never Vertex" "$?"
jq -e '.check_requests==3 and .batches==1 and .cost_microusd>0' "$STATE/counters/"*.json >/dev/null; check "happy: counters reserved" "$?"
echo '{"done":false,"metadata":{"state":"JOB_STATE_RUNNING"}}' > "$MOCK_DIR/batch-state.json"
gb poll; [ "$(jq -r .status "$STATE"/batches/b*.json | head -1)" = submitted ]; check "pending batch stays submitted" "$?"
# restart: a new process resumes from disk
make_done "$REVIEW_TEXT"
gb poll; [ "$(jq -r .status "$(batch_file)")" = "done" ]; check "restart: poll marks done from disk state" "$?"
gb post
[ "$(wc -l < "$MOCK_DIR/comments.log" | tr -d ' ')" = 3 ] && [ "$(count_status posted)" = 3 ]; check "happy: 3 comments through the poster" "$?"
first="$(head -1 "$MOCK_DIR/comment-1.md")"
[ "$first" = 'Model: Gemini 4 Argon (gemini-4-argon) (Gemini API)' ]; check "comment first line is the Model line" "$?"
grep -q "gemini-batch-head: $(sha 1)000" "$MOCK_DIR/comment-1.md"; check "comment carries the head SHA marker" "$?"
grep -qi 'http' "$MOCK_DIR/comment-1.md"; [ "$?" != 0 ]; check "URLs stripped from model text" "$?"
grep -q '@' "$MOCK_DIR/comment-1.md"; [ "$?" != 0 ]; check "at signs stripped from model text" "$?"
gb post; gb run
[ "$(wc -l < "$MOCK_DIR/comments.log" | tr -d ' ')" = 3 ]; check "second run does not post again" "$?"
gb status; case "$out" in *"items posted: 3"*) ok "status reports posted" ;; *) bad "status reports posted" "$out" ;; esac
grep -rq "$KEY" "$STATE" "$work/out" "$work/err"; [ "$?" != 0 ]; check "API key never in state or output" "$?"

# --- threshold and max wait -----------------------------------------------------
new_case; mk_prs 1 2
gb scan; gb submit
[ "$(posts)" = 0 ] && [ "$(count_status queued)" = 2 ]; check "below threshold and max wait: nothing submitted" "$?"
NOW_USE=$((NOW + 25 * 3600)); gb submit
[ "$(posts)" = 1 ] && [ "$(count_status submitted)" = 2 ]; check "max wait reached: submitted below threshold" "$?"
new_case; mk_prs 1 2
gb scan; gb submit --threshold 2
[ "$(posts)" = 1 ]; check "configurable threshold" "$?"

# --- fail-closed inputs ---------------------------------------------------------
fake_gh_prefix="ghp_"
fake_gh_body="abcdefghijklmnopqrstuvwxyz0123"
tok_key="TOKEN"
new_case; mk_prs 1 2 3
printf 'diff --git a/x b/x\n+%s=%s%s\n' "$tok_key" "$fake_gh_prefix" "$fake_gh_body" > "$MOCK_DIR/diff-2.txt"
gb scan; gb submit
[ "$(posts)" = 1 ] && [ "$(count_status failed)" = 1 ] && [ "$(count_status submitted)" = 2 ]; check "secret pattern: that input refused, others submitted" "$?"
grep -q "$fake_gh_prefix" "$MOCK_DIR/submit-last.json"; [ "$?" != 0 ]; check "secret pattern never reaches the provider" "$?"
case "$err" in *"$fake_gh_prefix"abc*) bad "secret value not logged" "$err" ;; *) ok "secret value not logged" ;; esac

new_case; mk_prs 1
cat > "$MOCK_DIR/diff-1.txt" <<'EOF'
diff --git a/scripts/tests/test_gemini_batch.sh b/scripts/tests/test_gemini_batch.sh
+fake_gh_prefix="ghp_"
+fake_gh_body="abcdefghijklmnopqrstuvwxyz0123"
+printf '+%s=%s%s\n' "$tok_key" "$fake_gh_prefix" "$fake_gh_body"
diff --git a/policy/cases b/policy/cases
+gb-scan-github	gemini-batch.input-scan	input.txt	text=token ghp_<<JOIN>>abcdefghijklmnopqrstuvwx here	DENY	gbatch.forbid.secret.github
EOF
gb scan; gb submit --threshold 1
[ "$rc" = 0 ] && [ "$(posts)" = 1 ] && [ "$(count_status submitted)" = 1 ] && [ "$(count_status failed)" = 0 ]; check "runtime-built fixture diff passes input scan and submits" "$?"

scan_hits=0
while IFS="$(printf '\t')" read -r _id ere _label; do
  [ -n "$ere" ] || continue
  for f in "$repo_root/scripts/tests/test_gemini_batch.sh" "$repo_root/scripts/tests/test_post_review_comment.sh" "$repo_root/policy/cases"; do
    if LC_ALL=C grep -Eq -- "$ere" "$f"; then scan_hits=1; fi
  done
done < <(bash "$repo_root/scripts/policy-eval.sh" --list-forbids --action gemini-batch.input-scan)
[ "$scan_hits" = 0 ]; check "committed test and policy fixture files have no contiguous secret-scan match" "$?"

new_case; mk_prs 1 2 3
echo '{"models":[{"name":"models/gemini-3.8-flash","supportedGenerationMethods":["batchGenerateContent"]}]}' > "$MOCK_DIR/models.json"
gb scan; gb submit
[ "$rc" = 1 ] && [ "$(posts)" = 0 ] && [ "$(count_status queued)" = 3 ]; check "pinned model missing from list: fail closed" "$?"

new_case; mk_prs 1 2 3
echo '{"models":[{"name":"models/gemini-4-argon","supportedGenerationMethods":["generateContent"]}]}' > "$MOCK_DIR/models.json"
gb scan; gb submit
[ "$rc" = 1 ] && [ "$(posts)" = 0 ]; check "model without batch support: fail closed" "$?"

new_case; mk_prs 1 2 3
gb scan
mkdir -p "$STATE/counters"
echo '{"batches":2,"requests":14,"check_requests":14,"in_tokens":100,"out_tokens":100,"cost_microusd":100}' > "$STATE/counters/$(date -u -d "@$NOW" +%Y-%m 2>/dev/null || date -u -r "$NOW" +%Y-%m).json"
gb submit
[ "$rc" = 1 ] && [ "$(posts)" = 0 ] && [ "$(count_status queued)" = 3 ]; check "monthly PR cap: nothing submitted" "$?"
case "$err" in *gbatch.forbid.month-check-requests*) ok "cap refusal names the rule" ;; *) bad "cap refusal names the rule" "$err" ;; esac

new_case; mk_prs 1 2 3
gb scan
echo '{"batches":2,"requests":2,"check_requests":2,"in_tokens":100,"out_tokens":100,"cost_microusd":7799999}' > "$STATE/counters/$(date -u -d "@$NOW" +%Y-%m 2>/dev/null || date -u -r "$NOW" +%Y-%m).json"
gb submit
[ "$rc" = 1 ] && [ "$(posts)" = 0 ]; check "monthly cost cap: nothing submitted" "$?"

new_case; mk_prs 1 2 3
gb scan; gb submit --dry-run
[ "$rc" = 0 ] && [ "$(posts)" = 0 ] && [ "$(count_status queued)" = 3 ]; check "dry run submits and reserves nothing" "$?"

# --- stale queue at submit time -----------------------------------------------------
new_case; mk_prs 1 2 3
gb scan
printf '%s\n' "{\"headRefOid\":\"deadbeef000\",\"isDraft\":true,\"state\":\"OPEN\",\"comments\":[]}" > "$MOCK_DIR/view-1.json"
printf '%s\n' "{\"headRefOid\":\"$(sha 2)000\",\"isDraft\":false,\"state\":\"OPEN\",\"comments\":[]}" > "$MOCK_DIR/view-2.json"
gb submit --threshold 1
[ "$(count_status skipped)" = 2 ] && [ "$(count_status submitted)" = 1 ] && jq -e '.batch.input_config.requests.requests|length==1' "$MOCK_DIR/submit-last.json" >/dev/null; check "submit re-reads the PR: moved head and ready PR are not sent" "$?"

# --- crash safety -----------------------------------------------------------------
new_case; mk_prs 1 2 3
gb scan; MOCK_SUBMIT_CODE=000 gb submit
[ "$rc" = 4 ]; check "transport failure on submit needs the maintainer" "$?"
gb status; [ "$rc" = 4 ]; check "every command refuses while a batch is 'submitting'" "$?"
new_case; mk_prs 1 2 3
gb scan; MOCK_SUBMIT_CODE=400 gb submit
[ "$rc" = 3 ] && [ "$(batch_count)" = 0 ]; check "clean HTTP refusal leaves no batch" "$?"

# --- post-time guards -------------------------------------------------------------
submit_and_finish() {
  gb scan; gb submit; make_done "$REVIEW_TEXT"; gb poll
}
new_case; mk_prs 1 2 3; submit_and_finish
echo "{\"headRefOid\":\"deadbeef000\",\"isDraft\":true,\"state\":\"OPEN\",\"comments\":[]}" > "$MOCK_DIR/view-1.json"
gb post
[ ! -e "$MOCK_DIR/comment-1.md" ] && [ -e "$MOCK_DIR/comment-2.md" ]; check "head changed before post: skipped, others posted" "$?"

new_case; mk_prs 1 2 3; submit_and_finish
printf '%s\n' "{\"headRefOid\":\"$(sha 2)000\",\"isDraft\":true,\"state\":\"OPEN\",\"comments\":[{\"author\":{\"login\":\"yohei1126\"},\"body\":\"Model: x\\ngemini-batch-head: $(sha 2)000\\nold\"}]}" > "$MOCK_DIR/view-2.json"
gb post
[ ! -e "$MOCK_DIR/comment-2.md" ] && [ -e "$MOCK_DIR/comment-1.md" ]; check "existing owner comment for this head: skipped" "$?"

new_case; mk_prs 1 2 3; submit_and_finish
echo "{\"headRefOid\":\"$(sha 3)000\",\"isDraft\":false,\"state\":\"OPEN\",\"comments\":[]}" > "$MOCK_DIR/view-3.json"
gb post
[ ! -e "$MOCK_DIR/comment-3.md" ]; check "PR no longer a draft: nothing posted" "$?"

new_case; mk_prs 1 2 3; submit_and_finish
mkdir -p "$STATE/ledger"; printf 'pending\t1\n' > "$STATE/ledger/yohei1126_agent-ops-kit__pr1__$(sha 1)000"
gb post
[ ! -e "$MOCK_DIR/comment-1.md" ] && [ -e "$MOCK_DIR/comment-2.md" ]; check "ledger entry after a crash fails closed" "$?"

new_case; mk_prs 1 2 3; gb scan; gb submit
jq -n --slurpfile s "$MOCK_DIR/submit-last.json" '{done:true,metadata:{state:"JOB_STATE_SUCCEEDED"},response:{inlinedResponses:{inlinedResponses:[$s[0].batch.input_config.requests.requests[]|{metadata:{key:.metadata.key},response:{candidates:[{finishReason:"MAX_TOKENS",content:{parts:[{text:"cut"}]}}]}}]}}}' > "$MOCK_DIR/batch-state.json"
gb poll; gb post
[ ! -e "$MOCK_DIR/comments.log" ] || [ ! -s "$MOCK_DIR/comments.log" ]; check "truncated model output is not posted" "$?"

new_case; mk_prs 1 2 3; gb scan; gb submit
echo '{"done":true,"metadata":{"state":"JOB_STATE_FAILED"}}' > "$MOCK_DIR/batch-state.json"
gb poll
[ "$(count_status failed)" = 3 ]; check "failed batch fails its items without resubmitting" "$?"
gb scan; gb submit
[ "$(posts)" = 1 ]; check "failed head is not resubmitted automatically" "$?"

# --- live batch API state names and done flag in poll -------------------------
new_case; mk_prs 1 2 3; gb scan; gb submit
make_done_state BATCH_STATE_SUCCEEDED "$REVIEW_TEXT"
gb poll
[ "$(jq -r .status "$(batch_file)")" = "done" ]; check "BATCH_STATE_SUCCEEDED marks the batch done" "$?"

new_case; mk_prs 1 2 3; gb scan; gb submit
echo '{"done":true,"metadata":{"state":"BATCH_STATE_FAILED"}}' > "$MOCK_DIR/batch-state.json"
gb poll
[ "$(jq -r .status "$(batch_file)")" = "failed" ] && [ "$(count_status failed)" = 3 ] && [ "$(jq -r .reason "$(batch_file)")" = BATCH_STATE_FAILED ]; check "BATCH_STATE_FAILED fails batch and items" "$?"
gb scan; gb submit
[ "$(posts)" = 1 ]; check "BATCH_STATE_FAILED: no automatic resubmit" "$?"

new_case; mk_prs 1 2 3; gb scan; gb submit
echo '{"done":true,"metadata":{"state":"BATCH_STATE_CANCELLED"}}' > "$MOCK_DIR/batch-state.json"
gb poll
[ "$(jq -r .status "$(batch_file)")" = "failed" ] && [ "$(count_status failed)" = 3 ]; check "BATCH_STATE_CANCELLED fails batch and items" "$?"
gb scan; gb submit
[ "$(posts)" = 1 ]; check "BATCH_STATE_CANCELLED: no automatic resubmit" "$?"

new_case; mk_prs 1 2 3; gb scan; gb submit
echo '{"done":true,"metadata":{"state":"BATCH_STATE_EXPIRED"}}' > "$MOCK_DIR/batch-state.json"
gb poll
[ "$(jq -r .status "$(batch_file)")" = "failed" ] && [ "$(count_status failed)" = 3 ]; check "BATCH_STATE_EXPIRED fails batch and items" "$?"
gb scan; gb submit
[ "$(posts)" = 1 ]; check "BATCH_STATE_EXPIRED: no automatic resubmit" "$?"

new_case; mk_prs 1 2 3; gb scan; gb submit
make_done_nostate "$REVIEW_TEXT"
gb poll
[ "$(jq -r .status "$(batch_file)")" = "done" ]; check "done with no state and no error marks done" "$?"

new_case; mk_prs 1 2 3; gb scan; gb submit
echo '{"done":true,"error":{"code":3,"message":"x"}}' > "$MOCK_DIR/batch-state.json"
gb poll
[ "$(jq -r .status "$(batch_file)")" = "failed" ] && [ "$(count_status failed)" = 3 ] && [ "$(jq -r .reason "$(batch_file)")" = "done with error" ]; check "done with a top-level error fails batch and items" "$?"

new_case; mk_prs 1 2 3; gb scan; gb submit
echo '{"done":true,"metadata":{"state":"BATCH_STATE_SOMETHING_NEW"}}' > "$MOCK_DIR/batch-state.json"
gb poll
[ "$(jq -r .status "$(batch_file)")" = "submitted" ] && [ "$(count_status submitted)" = 3 ]; check "unknown state with done stays submitted" "$?"

new_case; mk_prs 1 2 3; submit_and_finish
make_done "Findings. key ${fake_gh_prefix}${fake_gh_body} leaked"
bf="$(batch_file)"; cp "$MOCK_DIR/batch-state.json" "${bf%.json}.response.json"
gb post
[ ! -s "$MOCK_DIR/comments.log" ] 2>/dev/null || [ ! -e "$MOCK_DIR/comments.log" ]; check "secret in model output is not posted" "$?"

# --- weekly jobs: file only ------------------------------------------------------
new_case
echo '[{"ghsa_id":"GHSA-xxxx","severity":"high","summary":"Prototype pollution","vulnerabilities":[{"package":{"ecosystem":"npm"}}]}]' > "$MOCK_DIR/advisories.json"
gb security
[ "$(posts)" = 1 ] && grep -q 'models/gemini-3.8-flash:batchGenerateContent' "$MOCK_DIR/curl.log"; check "security: one pinned Flash batch" "$?"
gb security; [ "$(posts)" = 1 ]; check "security: interval blocks a second submit" "$?"
make_done 'Summary of advisories.'; gb poll
f=""; for g in "$STATE"/out/security-*.md; do f="$g"; done
[ -n "$f" ] && [ "$(head -1 "$f")" = 'Model: Gemini 3.8 Flash (gemini-3.8-flash) (Gemini API)' ]; check "security: output file with Model line" "$?"
[ ! -s "$MOCK_DIR/comments.log" ] 2>/dev/null || [ ! -e "$MOCK_DIR/comments.log" ]; check "security: nothing posted externally" "$?"
NOW_USE=$((NOW + 8 * 86400)); gb security; [ "$(posts)" = 2 ]; check "security: runs again after the interval" "$?"
new_case
echo '[{"ghsa_id":"GHSA-xxxx","severity":"high","summary":"Prototype pollution","vulnerabilities":[{"package":{"ecosystem":"npm"}}]}]' > "$MOCK_DIR/advisories.json"
gb security; NOW_USE=$((NOW + 8 * 86400)); gb security
[ "$(posts)" = 1 ]; check "security: a batch still in flight blocks another submit" "$?"

new_case
printf '%s\n' '[{"number":9,"comments":[{"body":"Model: Gemini 4 Argon (gemini-4-argon) (Gemini API)\nFindings: none"},{"body":"chat noise"}]}]' > "$MOCK_DIR/all-yohei1126_agent-ops-kit.json"
gb lessons
[ "$(posts)" = 1 ]; check "lessons: one Flash batch" "$?"
grep -q 'chat noise' "$MOCK_DIR/submit-last.json"; [ "$?" != 0 ]; check "lessons: only Model-prefixed public results as input" "$?"
new_case; export MOCK_PRIVATE=1
printf '%s\n' '[{"number":9,"comments":[{"body":"Model: x\nprivate"}]}]' > "$MOCK_DIR/all-yohei1126_agent-ops-kit.json"
gb lessons; [ "$(posts)" = 0 ]; check "lessons: private repos are not read" "$?"
unset MOCK_PRIVATE

# --- public reserve, settle, release, import, and status reconciliation ---------
cur_month="$(date -u -d "@$NOW" +%Y-%m 2>/dev/null || date -u -r "$NOW" +%Y-%m)"

# reserve: dry-run writes no counters and no ledger
new_case
gb reserve --job security --requests 2 --in-tokens 1000 --dry-run
ledger_count=0
for f in "$STATE/budget-ledger"/*.json; do [ -e "$f" ] && ledger_count=$((ledger_count + 1)); done
[ "$rc" = 0 ] && [ "$(posts)" = 0 ] && [ ! -e "$STATE/counters/$cur_month.json" ] && [ "$ledger_count" = 0 ]; check "reserve --dry-run writes no counters or ledger" "$?"

# reserve: unknown job fails closed (not silently counted as check)
new_case
gb reserve --job bogus --requests 1 --in-tokens 100
[ "$rc" = 1 ] && [ "$(jq -r .batches "$STATE/counters/$cur_month.json")" = 0 ]; check "reserve unknown job fails closed" "$?"
case "$err" in *"unknown job"*) ok "reserve unknown job names the cause" ;; *) bad "reserve unknown job names the cause" "$err" ;; esac

# reserve: eval is a known job on the Argon model, shared caps, not a check
new_case
gb reserve --job eval --requests 2 --in-tokens 1000 --id res-eval-1
[ "$rc" = 0 ] && [ "$out" = "res-eval-1" ] && [ "$(posts)" = 0 ]; check "reserve eval returns id with no provider call" "$?"
jq -e '.batches==1 and .requests==2 and .check_requests==0 and .in_tokens==1000 and .out_tokens==32768 and .cost_microusd==329680' "$STATE/counters/$cur_month.json" >/dev/null; check "reserve eval counts shared caps but not check_requests" "$?"
jq -e '.status=="reserved" and .job=="eval" and .model=="gemini-4-argon" and .reserved.out_tokens==32768' "$STATE/budget-ledger/res-eval-1.json" >/dev/null; check "reserve eval ledger pins gemini-4-argon" "$?"
gb reserve --job eval --requests 41 --in-tokens 1000 --id res-eval-over
[ "$rc" = 1 ] && [ ! -e "$STATE/budget-ledger/res-eval-over.json" ]; check "reserve eval over the shared request cap fails closed" "$?"
case "$err" in *gbatch.forbid.month-requests*) ok "eval cap refusal names the shared rule" ;; *) bad "eval cap refusal names the shared rule" "$err" ;; esac
echo '{"batches":1,"requests":15,"check_requests":15,"in_tokens":100,"out_tokens":100,"cost_microusd":100}' > "$STATE/counters/$cur_month.json"
gb reserve --job eval --requests 1 --in-tokens 100 --id res-eval-nocheckcap
[ "$rc" = 0 ] && jq -e '.check_requests==15 and .requests==16' "$STATE/counters/$cur_month.json" >/dev/null; check "eval is allowed when the check cap is full" "$?"
gb reserve --job check --requests 1 --in-tokens 100 --id res-chk-full
[ "$rc" = 1 ]; check "check is refused when the check cap is full" "$?"
gb import --id ext-eval-1 --job eval --requests 2 --in-tokens 10 --out-tokens 10 --cost-microusd 10
[ "$rc" = 0 ] && jq -e '.check_requests==15' "$STATE/counters/$cur_month.json" >/dev/null; check "import eval does not count as check" "$?"

# reserve: under budget succeeds, writes counters and budget ledger, no provider submit
new_case
gb reserve --job security --requests 2 --in-tokens 1000 --id res-sec-1
[ "$rc" = 0 ] && [ "$out" = "res-sec-1" ] && [ "$(posts)" = 0 ]; check "reserve under budget returns id with no provider call" "$?"
jq -e '.batches==1 and .requests==2 and .check_requests==0 and .in_tokens==1000 and .out_tokens==16384 and .cost_microusd==62190' "$STATE/counters/$cur_month.json" >/dev/null; check "reserve updates monthly counters" "$?"
jq -e '.status=="reserved" and .job=="security" and .reserved.out_tokens==16384' "$STATE/budget-ledger/res-sec-1.json" >/dev/null; check "reserve writes budget ledger" "$?"

# reserve: over cap refuses with same policy rule as submit
gb reserve --job check --requests 16 --in-tokens 1000 --id res-over-cap
[ "$rc" = 1 ] && [ ! -e "$STATE/budget-ledger/res-over-cap.json" ]; check "reserve over cap fails closed" "$?"
case "$err" in *gbatch.forbid.month-check-requests*) ok "reserve cap refusal names the rule" ;; *) bad "reserve cap refusal names the rule" "$err" ;; esac

# settle: dry-run leaves reservation unchanged
gb settle --id res-sec-1 --in-tokens 500 --out-tokens 1000 --cost-microusd 4125 --dry-run
[ "$rc" = 0 ] && [ "$(jq -r .status "$STATE/budget-ledger/res-sec-1.json")" = reserved ]; check "settle --dry-run leaves ledger reserved" "$?"

# settle: releases unused upper-bound tokens and cost, keeps batches and requests
gb settle --id res-sec-1 --in-tokens 500 --out-tokens 1000 --cost-microusd 4125
[ "$rc" = 0 ]; check "settle succeeds" "$?"
jq -e '.batches==1 and .requests==2 and .in_tokens==500 and .out_tokens==1000 and .cost_microusd==4125' "$STATE/counters/$cur_month.json" >/dev/null; check "settle adjusts tokens/cost and keeps batches/requests" "$?"
# idempotent second settle
gb settle --id res-sec-1 --in-tokens 500 --out-tokens 1000 --cost-microusd 4125
[ "$rc" = 0 ] && jq -e '.batches==1 and .in_tokens==500 and .cost_microusd==4125' "$STATE/counters/$cur_month.json" >/dev/null; check "second settle with same values is idempotent" "$?"
# conflicting second settle fails closed
gb settle --id res-sec-1 --in-tokens 600 --out-tokens 1000 --cost-microusd 4125
[ "$rc" = 1 ]; check "second settle with different values fails closed" "$?"
# release after settle fails closed
gb release --id res-sec-1
[ "$rc" = 1 ]; check "release after settle fails closed" "$?"

# release: rolls back reserved counts and is idempotent
gb reserve --job check --requests 3 --in-tokens 1000 --id res-chk-1
[ "$rc" = 0 ]; check "second reserve for release test succeeds" "$?"
gb release --id res-chk-1 --dry-run
[ "$rc" = 0 ] && [ "$(jq -r .status "$STATE/budget-ledger/res-chk-1.json")" = reserved ]; check "release --dry-run leaves ledger reserved" "$?"
gb release --id res-chk-1
[ "$rc" = 0 ]; check "release succeeds" "$?"
jq -e '.batches==1 and .requests==2 and .check_requests==0 and .in_tokens==500 and .out_tokens==1000 and .cost_microusd==4125' "$STATE/counters/$cur_month.json" >/dev/null; check "release rolls back its reservation" "$?"
gb release --id res-chk-1
[ "$rc" = 0 ] && jq -e '.batches==1 and .requests==2' "$STATE/counters/$cur_month.json" >/dev/null; check "second release is idempotent" "$?"
gb settle --id res-chk-1 --in-tokens 100 --out-tokens 100 --cost-microusd 100
[ "$rc" = 1 ]; check "settle after release fails closed" "$?"

# import: dry-run writes nothing
gb import --id ext-dry --job eval --requests 1 --in-tokens 100 --out-tokens 50 --cost-microusd 100 --dry-run
[ "$rc" = 0 ] && [ ! -e "$STATE/budget-ledger/ext-dry.json" ]; check "import --dry-run writes no ledger" "$?"

# import: records external usage even over cap, then reserve/submit fail closed
gb import --id ext-1 --job eval --requests 5 --in-tokens 2000 --out-tokens 1000 --cost-microusd 7800000 --api-name batches/ext-1
[ "$rc" = 0 ]; check "import over-cap usage still records" "$?"
jq -e '.batches==2 and .requests==7 and .cost_microusd==7804125' "$STATE/counters/$cur_month.json" >/dev/null; check "import appends to monthly counters" "$?"
gb import --id ext-1 --job eval --requests 5 --in-tokens 2000 --out-tokens 1000 --cost-microusd 7800000 --api-name batches/ext-1
[ "$rc" = 0 ] && jq -e '.batches==2' "$STATE/counters/$cur_month.json" >/dev/null; check "second identical import is idempotent" "$?"
gb reserve --job security --requests 1 --in-tokens 100 --id res-after-import
[ "$rc" = 1 ]; check "reserve after over-cap import fails closed" "$?"
mk_prs 1 2 3; gb scan; gb submit
[ "$rc" = 1 ] && [ "$(posts)" = 0 ]; check "submit after over-cap import fails closed" "$?"

# status: shows reserved/settled/imported and API list reconciliation without mutating counters
gb reserve --job security --requests 1 --in-tokens 100 --id res-vis 2>/dev/null || true
new_case
gb reserve --job security --requests 1 --in-tokens 100 --id s-res-1
gb reserve --job security --requests 1 --in-tokens 100 --id s-set-1
gb settle --id s-set-1 --in-tokens 80 --out-tokens 200 --cost-microusd 810 --api-name batches/known-1
gb import --id s-imp-1 --job eval --requests 2 --in-tokens 300 --out-tokens 400 --cost-microusd 1200 --api-name batches/known-2
cat > "$MOCK_DIR/batches-list.json" <<EOF
{"batches":[{"name":"batches/known-1","createTime":"${cur_month}-15T00:00:00Z"},{"name":"batches/known-2","createTime":"${cur_month}-16T00:00:00Z"},{"name":"batches/unknown-3","createTime":"${cur_month}-17T00:00:00Z"},{"name":"batches/unknown-4","createTime":"${cur_month}-18T00:00:00Z"}]}
EOF
before_counters="$(cat "$STATE/counters/$cur_month.json")"
gb status
[ "$rc" = 0 ]; check "status with stub API list succeeds" "$?"
case "$out" in
  *"month $cur_month ledger reserved:"*'"batches":1'*) ok "status shows reserved split" ;;
  *) bad "status shows reserved split" "$out" ;;
esac
case "$out" in
  *"month $cur_month ledger settled:"*'"batches":1'*) ok "status shows settled split" ;;
  *) bad "status shows settled split" "$out" ;;
esac
case "$out" in
  *"month $cur_month ledger imported:"*'"batches":1'*) ok "status shows imported split" ;;
  *) bad "status shows imported split" "$out" ;;
esac
case "$out" in
  *"api batches ($cur_month): 4 (local: 3, discrepancy: 1, untracked: 2)"*) ok "status shows API view and discrepancy" ;;
  *) bad "status shows API view and discrepancy" "$out" ;;
esac
[ "$(cat "$STATE/counters/$cur_month.json")" = "$before_counters" ]; check "status API list does not overwrite local counters" "$?"

# fail closed on corrupt counter or unknown ledger state
printf '{broken\n' > "$STATE/counters/$cur_month.json"
gb status
[ "$rc" = 1 ]; check "corrupt counter state fails closed" "$?"
new_case
mkdir -p "$STATE/budget-ledger"
printf '{"id":"bad-1","status":"mystery","job":"check","month":"%s","requests":1,"in_tokens":1,"out_tokens":1,"cost_microusd":1}\n' "$cur_month" > "$STATE/budget-ledger/bad-1.json"
gb status
[ "$rc" = 1 ]; check "unknown ledger status fails closed" "$?"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
