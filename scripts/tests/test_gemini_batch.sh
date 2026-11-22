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
new_case; mk_prs 1 2 3
printf 'diff --git a/x b/x\n+TOKEN=ghp_abcdefghijklmnopqrstuvwxyz0123\n' > "$MOCK_DIR/diff-2.txt"
gb scan; gb submit
[ "$(posts)" = 1 ] && [ "$(count_status failed)" = 1 ] && [ "$(count_status submitted)" = 2 ]; check "secret pattern: that input refused, others submitted" "$?"
grep -q 'ghp_' "$MOCK_DIR/submit-last.json"; [ "$?" != 0 ]; check "secret pattern never reaches the provider" "$?"
case "$err" in *ghp_abc*) bad "secret value not logged" "$err" ;; *) ok "secret value not logged" ;; esac

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
make_done 'Findings. key ghp_abcdefghijklmnopqrstuvwxyz0123 leaked'
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

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
