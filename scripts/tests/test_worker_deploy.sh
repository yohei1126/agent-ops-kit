#!/usr/bin/env bash
# Tests for scripts/worker-deploy.sh and the reusable workers-deploy workflow.
# Fixtures only: stub npm, npx, and curl are prepended to PATH, so nothing
# deploys, calls Cloudflare, or needs a real token.
set -u

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
deploy_script="$repo_root/scripts/worker-deploy.sh"
workflow="$repo_root/.github/workflows/workers-deploy.yml"
gate_workflow="$repo_root/.github/workflows/dev-loop-gate.yml"

version_id="16f5b577-0000-4000-8000-000000000000"
fake_token="fake-token-value-123456"
fake_account="fakeacct0123456789"
fake_secret="fake-other-secret-987654"

pass=0
fail=0
work_tmp="$(mktemp -d)"
bin_dir="$work_tmp/bin"
worker_dir="$work_tmp/worker"
ts_worker_dir="$work_tmp/worker-ts"
bare_worker_dir="$work_tmp/worker-bare"
no_wrangler_dir="$work_tmp/worker-no-wrangler"
rl_dir="$work_tmp/rl-scripts"
stub_log="$work_tmp/calls.log"
github_output="$work_tmp/github-output"
out_file="$work_tmp/stdout"
err_file="$work_tmp/stderr"

out=""
err=""
status=0

# shellcheck disable=SC2317,SC2329  # called from the EXIT trap below
cleanup() {
  if [ -n "${sig_pid:-}" ] && kill -0 "$sig_pid" 2>/dev/null; then
    kill -KILL -"$sig_pid" 2>/dev/null || kill -KILL "$sig_pid" 2>/dev/null || true
  fi
  if [ -n "${sig_child:-}" ] && kill -0 "$sig_child" 2>/dev/null; then
    kill -KILL "$sig_child" 2>/dev/null || true
  fi
  rm -rf "$work_tmp"
}
trap cleanup EXIT

unset CLOUDFLARE_API_TOKEN CLOUDFLARE_ACCOUNT_ID OTHER_SECRET \
  STUB_FAIL STUB_NO_VERSION_ID STUB_CURL_CODE STUB_RL_EXIT

mkdir -p "$bin_dir" "$worker_dir" "$ts_worker_dir" "$bare_worker_dir" \
  "$no_wrangler_dir" "$rl_dir"

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
    bad "$1" "expected exit $2, got $status; stdout: [$out]; stderr: [$err]"
  fi
}

expect_out() {
  case "$out" in
    *"$2"*) ok "$1" ;;
    *) bad "$1" "stdout missing [$2]; got [$out]" ;;
  esac
}

expect_err() {
  case "$err" in
    *"$2"*) ok "$1" ;;
    *) bad "$1" "stderr missing [$2]; got [$err]" ;;
  esac
}

expect_no_secret() {
  if printf '%s\n%s' "$out" "$err" | grep -qF -- "$2"; then
    bad "$1" "output leaked [$2]; stdout: [$out]; stderr: [$err]"
  else
    ok "$1"
  fi
}

expect_redacted() {
  if printf '%s' "$err" | grep -qF '[REDACTED]'; then
    ok "$1"
  else
    bad "$1" "stderr has no [REDACTED] marker; got [$err]"
  fi
}

expect_call() {
  if grep -qxF -- "$2" "$stub_log"; then
    ok "$1"
  else
    bad "$1" "missing call [$2]; calls: [$(cat "$stub_log")]"
  fi
}

expect_no_call() {
  if grep -qxF -- "$2" "$stub_log"; then
    bad "$1" "unexpected call [$2]; calls: [$(cat "$stub_log")]"
  else
    ok "$1"
  fi
}

expect_order() {
  local label="$1"
  shift
  local prev=0 want n good=1

  for want in "$@"; do
    n="$(awk -v want="$want" '$0 == want { print NR; exit }' "$stub_log")"
    if [ -z "$n" ] || [ "$n" -le "$prev" ]; then
      good=0
      break
    fi
    prev="$n"
  done
  if [ "$good" = 1 ]; then
    ok "$label"
  else
    bad "$label" "call order is [$(tr '\n' '|' < "$stub_log")]"
  fi
}

run_script() {
  local target="$1"
  shift
  : > "$stub_log"
  : > "$github_output"
  : > "$out_file"
  : > "$err_file"
  out="$(PATH="$bin_dir:$PATH" STUB_LOG="$stub_log" GITHUB_OUTPUT="$github_output" \
    bash "$target" "$@" 2>"$err_file")"
  status=$?
  err="$(cat "$err_file")"
}

cat > "$worker_dir/package.json" <<'JSON'
{
  "name": "fixture-worker",
  "private": true,
  "scripts": {
    "typecheck": "tsc --noEmit",
    "test": "node --test"
  }
}
JSON

cat > "$worker_dir/wrangler.jsonc" <<'JSON'
{
  "name": "fixture-worker",
  "main": "src/index.ts"
}
JSON

cat > "$ts_worker_dir/package.json" <<'JSON'
{
  "name": "fixture-worker-ts",
  "private": true
}
JSON

cat > "$ts_worker_dir/wrangler.toml" <<'TOML'
name = "fixture-worker-ts"
main = "src/index.ts"
TOML

: > "$ts_worker_dir/tsconfig.json"

cat > "$bare_worker_dir/package.json" <<'JSON'
{
  "name": "fixture-worker-bare",
  "private": true
}
JSON

cat > "$bare_worker_dir/wrangler.json" <<'JSON'
{
  "name": "fixture-worker-bare",
  "main": "src/index.ts"
}
JSON

cat > "$no_wrangler_dir/package.json" <<'JSON'
{
  "name": "fixture-worker-no-wrangler",
  "private": true
}
JSON

cat > "$bin_dir/npm" <<'STUB'
#!/usr/bin/env bash
set -u
printf 'npm %s\n' "$*" >> "${STUB_LOG:?}"
token_state=unset
account_state=unset
if [ -n "${CLOUDFLARE_API_TOKEN+x}" ]; then
  token_state=set
fi
if [ -n "${CLOUDFLARE_ACCOUNT_ID+x}" ]; then
  account_state=set
fi
printf 'env npm %s token=%s account=%s\n' "$*" "$token_state" "$account_state" >> "${STUB_LOG:?}"
step=""
if [ "${1:-}" = "ci" ]; then
  step="npm-ci"
elif [ "${1:-}" = "run" ] && [ "${2:-}" = "typecheck" ]; then
  step="typecheck"
elif [ "${1:-}" = "test" ]; then
  step="test"
fi
printf 'stub npm stdout: token=%s account=%s secret=%s\n' \
  "${CLOUDFLARE_API_TOKEN:-}" "${CLOUDFLARE_ACCOUNT_ID:-}" "${OTHER_SECRET:-}"
printf 'stub npm stderr: token=%s account=%s secret=%s\n' \
  "${CLOUDFLARE_API_TOKEN:-}" "${CLOUDFLARE_ACCOUNT_ID:-}" "${OTHER_SECRET:-}" >&2
if [ -n "$step" ] && [ "${STUB_FAIL:-}" = "$step" ]; then
  printf 'stub npm: forced failure for %s\n' "$step" >&2
  exit 1
fi
exit 0
STUB

cat > "$bin_dir/npx" <<'STUB'
#!/usr/bin/env bash
set -u
printf 'npx %s\n' "$*" >> "${STUB_LOG:?}"
token_state=unset
account_state=unset
if [ -n "${CLOUDFLARE_API_TOKEN+x}" ]; then
  token_state=set
fi
if [ -n "${CLOUDFLARE_ACCOUNT_ID+x}" ]; then
  account_state=set
fi
printf 'env npx %s token=%s account=%s\n' "$*" "$token_state" "$account_state" >> "${STUB_LOG:?}"
step=""
if [ "${1:-}" = "--no-install" ] && [ "${2:-}" = "wrangler" ] && [ "${3:-}" = "deploy" ]; then
  if [ "${4:-}" = "--dry-run" ]; then
    step="dry-run"
  else
    step="deploy"
  fi
fi
printf 'stub npx stdout: token=%s account=%s secret=%s\n' \
  "${CLOUDFLARE_API_TOKEN:-}" "${CLOUDFLARE_ACCOUNT_ID:-}" "${OTHER_SECRET:-}"
printf 'stub npx stderr: token=%s account=%s secret=%s\n' \
  "${CLOUDFLARE_API_TOKEN:-}" "${CLOUDFLARE_ACCOUNT_ID:-}" "${OTHER_SECRET:-}" >&2
if [ -n "$step" ] && [ "${STUB_FAIL:-}" = "$step" ]; then
  printf 'stub npx: forced failure for %s\n' "$step" >&2
  exit 1
fi
if [ "$step" = "dry-run" ]; then
  printf 'Dry run complete; no changes were uploaded\n'
fi
if [ "$step" = "deploy" ] && [ "${STUB_NO_VERSION_ID:-}" != "1" ]; then
  printf 'Uploaded fixture-worker\n'
  printf 'Current Version ID: 16f5b577-0000-4000-8000-000000000000\n'
fi
exit 0
STUB

cat > "$bin_dir/curl" <<'STUB'
#!/usr/bin/env bash
set -u
printf 'curl %s\n' "$*" >> "${STUB_LOG:?}"
code="${STUB_CURL_CODE:-200}"
printf '%s' "$code"
if [ "$code" -ge 400 ]; then
  printf 'stub curl: HTTP %s\n' "$code" >&2
  exit 22
fi
exit 0
STUB

cat > "$rl_dir/rate-limit-check.sh" <<'STUB'
#!/usr/bin/env bash
set -u
printf 'rate-limit-check %s\n' "$*" >> "${STUB_LOG:?}"
printf 'stub rate-limit-check: token=%s\n' "${CLOUDFLARE_API_TOKEN:-}" >&2
exit "${STUB_RL_EXIT:-0}"
STUB

cp "$deploy_script" "$rl_dir/worker-deploy.sh"
chmod +x "$bin_dir/npm" "$bin_dir/npx" "$bin_dir/curl" \
  "$rl_dir/rate-limit-check.sh" "$deploy_script" "$rl_dir/worker-deploy.sh"

printf '== preflight ==\n'

run_script "$deploy_script" --dir "$worker_dir"
expect_status "1: default mode preflights and exits 0" 0
expect_order "1: preflight order is npm ci, typecheck, tests, dry run" \
  "npm ci" "npm run typecheck" "npm test" \
  "npx --no-install wrangler deploy --dry-run"
expect_no_call "1: preflight never runs a real deploy" \
  "npx --no-install wrangler deploy"
if [ -z "$out" ]; then
  ok "1: preflight prints nothing on stdout"
else
  bad "1: preflight prints nothing on stdout" "stdout: [$out]"
fi
expect_err "1: progress names the first step" "worker-deploy: preflight: npm ci"
expect_err "1: progress names the dry run" \
  "worker-deploy: preflight: npx --no-install wrangler deploy --dry-run"

run_script "$deploy_script" --dir "$ts_worker_dir"
expect_status "2: typecheck falls back to tsc when tsconfig.json exists" 0
expect_call "2: tsc fallback is invoked" "npx --no-install tsc --noEmit"
expect_no_call "2: no typecheck script is assumed" "npm run typecheck"
expect_err "2: missing test script is noted" "tests skipped (package.json has no test script)"

run_script "$deploy_script" --dir "$bare_worker_dir"
expect_status "3: preflight without a typecheck script or tsconfig exits 0" 0
expect_no_call "3: no typecheck command is guessed" "npx --no-install tsc --noEmit"
expect_err "3: skipped typecheck is noted" "typecheck skipped"

printf '== deploy ==\n'

export CLOUDFLARE_API_TOKEN="$fake_token"
export CLOUDFLARE_ACCOUNT_ID="$fake_account"
export OTHER_SECRET="$fake_secret"

run_script "$deploy_script" --dir "$worker_dir" --mode deploy
expect_status "4: deploy exits 0" 0
expect_order "4: deploy repeats the full preflight before the deploy" \
  "npm ci" "npm run typecheck" "npm test" \
  "npx --no-install wrangler deploy --dry-run" \
  "npx --no-install wrangler deploy"
if [ "$out" = "version_id=$version_id" ]; then
  ok "4: stdout is exactly version_id=<id>"
else
  bad "4: stdout is exactly version_id=<id>" "stdout: [$out]"
fi
expect_out "4: version id is parsed from wrangler output" "version_id=$version_id"
if grep -qxF "version_id=$version_id" "$github_output"; then
  ok "4: version id is appended to GITHUB_OUTPUT"
else
  bad "4: version id is appended to GITHUB_OUTPUT" "file: [$(cat "$github_output")]"
fi
expect_err "4: deploy is reported to stderr" "worker-deploy: deploy succeeded"
expect_redacted "5: redaction marker appears in child output"
expect_no_secret "5: stdout never shows the token" "$fake_token"
expect_no_secret "5: stdout never shows the account id" "$fake_account"
expect_no_secret "5: output never shows other secret-looking values" "$fake_secret"
expect_no_secret "5: the token never appears on stderr" "$fake_token"
expect_no_secret "5: the account id never appears on stderr" "$fake_account"

run_script "$deploy_script" --dir "$worker_dir" --mode deploy --skip-tests
expect_status "6: --skip-tests deploys" 0
expect_no_call "6: --skip-tests skips npm test" "npm test"
expect_err "6: --skip-tests is marked discouraged" "discouraged"

run_script "$deploy_script" --dir "$worker_dir" --mode deploy --smoke-url \
  "http://127.0.0.1:8080" --smoke-path "/health"
expect_status "7: smoke success exits 0" 0
expect_out "7: smoke keeps the version id on stdout" "version_id=$version_id"
if grep -qF "http://127.0.0.1:8080/health" "$stub_log"; then
  ok "7: smoke requests the base URL plus the smoke path"
else
  bad "7: smoke requests the base URL plus the smoke path" "calls: [$(cat "$stub_log")]"
fi
expect_err "7: smoke success is reported" "smoke: http://127.0.0.1:8080/health returned 200"

STUB_CURL_CODE=503
export STUB_CURL_CODE
run_script "$deploy_script" --dir "$worker_dir" --mode deploy --smoke-url \
  "http://127.0.0.1:8080"
expect_status "8: smoke failure exits 1" 1
expect_out "8: version id is printed before a smoke failure" "version_id=$version_id"
expect_err "8: smoke failure names the deploy as successful" \
  "smoke failed after a successful deploy"
if [ "$(grep -c '^curl ' "$stub_log")" -eq 3 ]; then
  ok "8: smoke retries three times"
else
  bad "8: smoke retries three times" "curl calls: [$(grep -c '^curl ' "$stub_log")]"
fi
unset STUB_CURL_CODE

run_script "$deploy_script" --dir "$worker_dir" --smoke-url "http://127.0.0.1:8080"
expect_status "9: preflight accepts smoke flags" 0
if grep -q '^curl ' "$stub_log"; then
  bad "9: preflight never invokes curl" "calls: [$(cat "$stub_log")]"
else
  ok "9: preflight never invokes curl"
fi

printf '== preflight failure stops deploy ==\n'

for step in npm-ci typecheck test dry-run; do
  STUB_FAIL="$step"
  export STUB_FAIL
  run_script "$deploy_script" --dir "$worker_dir" --mode deploy
  expect_status "10: failed $step exits 1" 1
  expect_no_call "10: failed $step skips the real deploy" \
    "npx --no-install wrangler deploy"
  expect_err "10: failed $step names the step" "preflight failed"
  unset STUB_FAIL
done

STUB_NO_VERSION_ID=1
export STUB_NO_VERSION_ID
run_script "$deploy_script" --dir "$worker_dir" --mode deploy
expect_status "11: missing version id exits 1" 1
expect_err "11: missing version id fails closed" "no valid Version ID"
if [ -z "$out" ]; then
  ok "11: missing version id prints nothing on stdout"
else
  bad "11: missing version id prints nothing on stdout" "stdout: [$out]"
fi
unset STUB_NO_VERSION_ID

STUB_FAIL=deploy
export STUB_FAIL
run_script "$deploy_script" --dir "$worker_dir" --mode deploy
expect_status "12: failed deploy exits 1" 1
expect_err "12: failed deploy names the deploy" "deploy failed"
if [ -z "$out" ]; then
  ok "12: failed deploy prints no version id"
else
  bad "12: failed deploy prints no version id" "stdout: [$out]"
fi
unset STUB_FAIL

unset CLOUDFLARE_API_TOKEN CLOUDFLARE_ACCOUNT_ID OTHER_SECRET
run_script "$deploy_script" --dir "$worker_dir" --mode deploy
expect_status "13: deploy without CLOUDFLARE_API_TOKEN exits 1" 1
expect_err "13: missing token names the variable" "CLOUDFLARE_API_TOKEN"
expect_no_call "13: missing token skips the deploy" \
  "npx --no-install wrangler deploy"
if [ -z "$out" ]; then
  ok "13: missing token prints no version id"
else
  bad "13: missing token prints no version id" "stdout: [$out]"
fi

printf '== preflight env isolation in deploy mode ==\n'

export CLOUDFLARE_API_TOKEN="$fake_token"
export CLOUDFLARE_ACCOUNT_ID="$fake_account"
export OTHER_SECRET="$fake_secret"

run_script "$deploy_script" --dir "$worker_dir" --mode deploy
expect_status "39: deploy with isolated preflight exits 0" 0
expect_call "39: npm ci does not inherit Cloudflare credentials" \
  "env npm ci token=unset account=unset"
expect_call "39: typecheck does not inherit Cloudflare credentials" \
  "env npm run typecheck token=unset account=unset"
expect_call "39: tests do not inherit Cloudflare credentials" \
  "env npm test token=unset account=unset"
expect_call "39: the wrangler dry run does not inherit Cloudflare credentials" \
  "env npx --no-install wrangler deploy --dry-run token=unset account=unset"
expect_call "39: the deploy still sees the token and account id" \
  "env npx --no-install wrangler deploy token=set account=set"

unset CLOUDFLARE_ACCOUNT_ID
run_script "$deploy_script" --dir "$worker_dir" --mode deploy
expect_status "39: deploy without an account id still exits 0" 0
expect_call "39: preflight stays isolated when account id is unset" \
  "env npm ci token=unset account=unset"
expect_call "39: the deploy still sees the token when account id is unset" \
  "env npx --no-install wrangler deploy token=set account=unset"
export CLOUDFLARE_ACCOUNT_ID="$fake_account"

printf '== rate-limit hook ==\n'

export CLOUDFLARE_API_TOKEN="$fake_token"
export CLOUDFLARE_ACCOUNT_ID="$fake_account"
export OTHER_SECRET="$fake_secret"

run_script "$rl_dir/worker-deploy.sh" --dir "$worker_dir" --mode deploy \
  --smoke-url "http://127.0.0.1:8080"
expect_status "14: deploy with the hook disabled exits 0" 0
if grep -q '^rate-limit-check ' "$stub_log"; then
  bad "14: hook is off by default" "the hook ran: [$(grep '^rate-limit-check ' "$stub_log")]"
else
  ok "14: hook is off by default"
fi

run_script "$rl_dir/worker-deploy.sh" --dir "$worker_dir" --mode deploy \
  --smoke-url "http://127.0.0.1:8080" --rate-limit-check \
  --rl-path "/health" --rl-limit 100 --rl-window 60 --rl-requests 101 \
  --rl-mode detect
expect_status "15: enabled hook exits 0" 0
if grep -qF -- "--base-url http://127.0.0.1:8080 --path /health --limit 100 --window 60 --requests 101 --mode detect" "$stub_log"; then
  ok "15: hook receives the expected arguments"
else
  bad "15: hook receives the expected arguments" "calls: [$(cat "$stub_log")]"
fi
expect_out "15: hook success keeps the version id on stdout" "version_id=$version_id"
expect_err "15: hook success is reported" "rate-limit hook passed"

STUB_RL_EXIT=1
export STUB_RL_EXIT
run_script "$rl_dir/worker-deploy.sh" --dir "$worker_dir" --mode deploy \
  --smoke-url "http://127.0.0.1:8080" --rate-limit-check \
  --rl-path "/health" --rl-limit 100 --rl-window 60
expect_status "16: hook failure exits 1" 1
expect_out "16: hook failure keeps the version id on stdout" "version_id=$version_id"
expect_err "16: hook failure names the successful deploy" \
  "rate-limit check failed after a successful deploy"
unset STUB_RL_EXIT

printf '== usage errors ==\n'

run_script "$deploy_script"
expect_status "17: missing --dir exits 2" 2
expect_err "17: missing --dir names the flag" "--dir is required"

run_script "$deploy_script" --dir "$worker_dir" --nope
expect_status "18: unknown option exits 2" 2
expect_err "18: unknown option names the flag" "unknown option: --nope"

run_script "$deploy_script" --dir "$worker_dir" --mode ship
expect_status "19: unknown mode exits 2" 2
expect_err "19: unknown mode names the rule" "--mode must be preflight or deploy"

run_script "$deploy_script" --dir "$worker_dir" --smoke-path health
expect_status "20: smoke path without a leading slash exits 2" 2
expect_err "20: bad smoke path names the rule" "--smoke-path must start with /"

run_script "$deploy_script" --dir "$worker_dir" --smoke-url http://example.com
expect_status "21: plain http smoke URL exits 2" 2
expect_err "21: plain http smoke URL names the scheme" "--smoke-url must start with https://"

run_script "$deploy_script" --dir "$worker_dir" --mode deploy --rate-limit-check \
  --smoke-url "http://127.0.0.1:8080"
expect_status "22: hook without limit and window exits 2" 2
expect_err "22: hook without limit names the flag" "--rl-limit"

run_script "$deploy_script" --dir "$worker_dir" --rl-limit 10
expect_status "23: hook options without the switch exit 2" 2
expect_err "23: hook options without the switch name the switch" \
  "--rl-* options need --rate-limit-check"

run_script "$deploy_script" --dir "$work_tmp/missing"
expect_status "24: missing --dir path exits 2" 2

run_script "$deploy_script" --dir "$no_wrangler_dir"
expect_status "25: worker dir without a wrangler config exits 2" 2
expect_err "25: missing wrangler config is named" "no wrangler.jsonc"

run_script "$deploy_script" --help
expect_status "26: --help exits 0" 0
expect_out "26: help shows the usage line" "usage: worker-deploy.sh --dir <worker-dir>"

printf '== xtrace and missing commands ==\n'

: > "$err_file"
out="$(CLOUDFLARE_API_TOKEN="$fake_token" bash -x "$deploy_script" --dir "$worker_dir" 2>"$err_file")"
status=$?
err="$(cat "$err_file")"
expect_status "27: bash -x is refused with exit 2" 2
expect_err "27: xtrace refusal says why" "refusing to run with shell xtrace on"
expect_no_secret "27: xtrace refusal leaks no token" "$fake_token"

empty_path="$work_tmp/empty-path"
mkdir -p "$empty_path"
bash_bin="$(command -v bash)"
: > "$err_file"
out="$(PATH="$empty_path" "$bash_bin" "$deploy_script" --dir "$worker_dir" 2>"$err_file")"
status=$?
err="$(cat "$err_file")"
expect_status "28: missing npm exits 3" 3
expect_err "28: missing npm is named" "npm is required"

printf '== reusable workflow ==\n'

if [ -f "$workflow" ]; then
  ok "29: workers-deploy workflow exists"
else
  bad "29: workers-deploy workflow exists" "missing $workflow"
fi

if grep -q '^  workflow_call:' "$workflow"; then
  ok "29: workflow declares workflow_call"
else
  bad "29: workflow declares workflow_call" "no workflow_call trigger"
fi

if grep -qE '^[[:space:]]*(push|pull_request|workflow_dispatch):' "$workflow"; then
  bad "29: workflow has no push, pull request, or dispatch trigger" \
    "$(grep -nE '^[[:space:]]*(push|pull_request|workflow_dispatch):' "$workflow")"
else
  ok "29: workflow has no push, pull request, or dispatch trigger"
fi

bad_uses="$(grep -E '^[[:space:]]*(-[[:space:]]+)?uses:' "$workflow" |
  grep -Ev '@[0-9a-fA-F]{40}([[:space:]]*#.*|[[:space:]]*)$')"
if [ -z "$bad_uses" ]; then
  ok "30: every uses line is pinned to a full commit SHA"
else
  bad "30: every uses line is pinned to a full commit SHA" "$bad_uses"
fi

if [ "$(grep -cE '^[[:space:]]*contents: read$' "$workflow")" -ge 2 ]; then
  ok "30: workflow and job both set contents: read"
else
  bad "30: workflow and job both set contents: read" \
    "$(grep -nE '^[[:space:]]*contents:' "$workflow")"
fi

if grep -qE '^[[:space:]]*node-version-file: \.nvmrc$' "$workflow"; then
  ok "31: setup-node reads node-version-file .nvmrc"
else
  bad "31: setup-node reads node-version-file .nvmrc" "node-version-file not found"
fi

if grep -qE '^[[:space:]]*node-version:' "$workflow"; then
  bad "31: workflow does not set node-version" \
    "$(grep -nE '^[[:space:]]*node-version:' "$workflow")"
else
  ok "31: workflow does not set node-version"
fi

if grep -qE '^[[:space:]]*concurrency:' "$workflow" &&
  grep -qE '^[[:space:]]*cancel-in-progress: false$' "$workflow"; then
  ok "32: deploy serializes with cancel-in-progress false"
else
  bad "32: deploy serializes with cancel-in-progress false" "concurrency config missing"
fi

bad_secret_lines="$(grep -n 'secrets\.' "$workflow" |
  grep -vE '^[0-9]+:[[:space:]]*(#|$)' |
  grep -vE '^[0-9]+:[[:space:]]*[A-Z_][A-Z0-9_]*: \$\{\{ secrets\.[A-Za-z_][A-Za-z0-9_]* \}\}[[:space:]]*$')"
if [ -z "$bad_secret_lines" ]; then
  ok "33: secrets appear only as env mappings"
else
  bad "33: secrets appear only as env mappings" "$bad_secret_lines"
fi

if grep -qE 'echo[^#]*CLOUDFLARE_' "$workflow"; then
  bad "34: no echo prints a CLOUDFLARE_ value" \
    "$(grep -nE 'echo[^#]*CLOUDFLARE_' "$workflow")"
else
  ok "34: no echo prints a CLOUDFLARE_ value"
fi

if grep -qF 'scripts/worker-deploy.sh' "$gate_workflow" &&
  grep -qF 'scripts/tests/test_worker_deploy.sh' "$gate_workflow"; then
  ok "35: dev-loop gate lists the new script and its tests"
else
  bad "35: dev-loop gate lists the new script and its tests" \
    "gate workflow lists are stale"
fi

printf '== deploy step argv ==\n'

wf_dir="$work_tmp/wf"
wf_run_block="$work_tmp/wf-deploy-run.sh"
wf_stub="$wf_dir/.agent-ops-kit/scripts/worker-deploy.sh"
argv_log="$work_tmp/wf-argv.log"
wf_err="$work_tmp/wf-stderr"

mkdir -p "$wf_dir/.agent-ops-kit/scripts"
cat > "$wf_stub" <<'STUB'
#!/usr/bin/env bash
set -u
: > "${ARGV_LOG:?}"
for arg in "$@"; do
  printf '%s\n' "$arg" >> "$ARGV_LOG"
done
exit 0
STUB
chmod +x "$wf_stub"

# Extract the deploy step's run block from the workflow, de-indented, with awk.
# The block runs against a stub script in a temporary working directory, so it
# is exercised as written without deploying anything.
awk '
  /^      - name: Deploy$/ { in_step = 1; next }
  in_step && /^      - name:/ { exit }
  in_step && /^        run: \|$/ { in_run = 1; next }
  in_run {
    if ($0 ~ /^          /) { print substr($0, 11); next }
    if ($0 ~ /^[[:space:]]*$/) { print ""; next }
    exit
  }
' "$workflow" > "$wf_run_block"

step_status=0
step_err=""

run_deploy_step() {
  : > "$argv_log"
  : > "$wf_err"
  (
    cd "$wf_dir" || exit 1
    WORKING_DIRECTORY="worker" \
      SMOKE="$1" SMOKE_URL="$3" SMOKE_PATH="/health" \
      RATE_LIMIT_CHECK="$2" RATE_LIMIT_PATH="/rl" RATE_LIMIT_LIMIT="100" \
      RATE_LIMIT_WINDOW="60" RATE_LIMIT_REQUESTS="" RATE_LIMIT_MODE="detect" \
      SKIP_TESTS="false" CLOUDFLARE_API_TOKEN="fake" CLOUDFLARE_ACCOUNT_ID="fake" \
      ARGV_LOG="$argv_log" bash "$wf_run_block"
  ) >/dev/null 2>"$wf_err"
  step_status=$?
  step_err="$(cat "$wf_err")"
}

count_arg() {
  grep -cxF -- "$1" "$argv_log" 2>/dev/null || true
}

if [ -s "$wf_run_block" ]; then
  ok "36: deploy step run block is extracted"
else
  bad "36: deploy step run block is extracted" "empty extraction from the workflow"
fi

run_deploy_step true true "https://worker.example.test"
if [ "$step_status" -eq 0 ]; then
  ok "36: deploy step exits 0 with both checks on"
else
  bad "36: deploy step exits 0 with both checks on" "exit $step_status; stderr: [$step_err]"
fi
if [ "$(count_arg --dir)" -eq 1 ] && [ "$(count_arg --mode)" -eq 1 ]; then
  ok "36: deploy step passes --dir and --mode once"
else
  bad "36: deploy step passes --dir and --mode once" "argv: [$(cat "$argv_log")]"
fi
if [ "$(count_arg --smoke-url)" -eq 1 ]; then
  ok "36: both checks on pass --smoke-url exactly once"
else
  bad "36: both checks on pass --smoke-url exactly once" \
    "count $(count_arg --smoke-url); argv: [$(cat "$argv_log")]"
fi
if [ "$(count_arg --smoke-path)" -eq 1 ]; then
  ok "36: both checks on pass --smoke-path exactly once"
else
  bad "36: both checks on pass --smoke-path exactly once" \
    "count $(count_arg --smoke-path); argv: [$(cat "$argv_log")]"
fi
if [ "$(count_arg --rate-limit-check)" -eq 1 ] &&
  [ "$(count_arg --rl-path)" -eq 1 ] &&
  [ "$(count_arg --rl-mode)" -eq 1 ] &&
  [ "$(count_arg --rl-requests)" -eq 0 ]; then
  ok "36: hook on passes its flags once and skips empty optional flags"
else
  bad "36: hook on passes its flags once and skips empty optional flags" \
    "argv: [$(cat "$argv_log")]"
fi

run_deploy_step true false "https://worker.example.test"
if [ "$step_status" -eq 0 ] && [ "$(count_arg --smoke-url)" -eq 1 ]; then
  ok "36: smoke alone passes --smoke-url once"
else
  bad "36: smoke alone passes --smoke-url once" \
    "exit $step_status; argv: [$(cat "$argv_log")]"
fi
if [ "$(count_arg --rate-limit-check)" -eq 0 ] &&
  [ "$(count_arg --rl-path)" -eq 0 ] &&
  [ "$(count_arg --rl-limit)" -eq 0 ] &&
  [ "$(count_arg --rl-mode)" -eq 0 ]; then
  ok "36: smoke alone passes no rate-limit flags"
else
  bad "36: smoke alone passes no rate-limit flags" "argv: [$(cat "$argv_log")]"
fi

run_deploy_step false true "https://worker.example.test"
if [ "$step_status" -eq 0 ] && [ "$(count_arg --smoke-url)" -eq 1 ] &&
  [ "$(count_arg --smoke-path)" -eq 1 ]; then
  ok "36: hook alone passes --smoke-url and --smoke-path once"
else
  bad "36: hook alone passes --smoke-url and --smoke-path once" \
    "exit $step_status; argv: [$(cat "$argv_log")]"
fi
if [ "$(count_arg --rate-limit-check)" -eq 1 ] && [ "$(count_arg --rl-mode)" -eq 1 ]; then
  ok "36: hook alone passes the rate-limit flags"
else
  bad "36: hook alone passes the rate-limit flags" "argv: [$(cat "$argv_log")]"
fi

run_deploy_step false false ""
if [ "$step_status" -eq 0 ] && [ "$(count_arg --smoke-url)" -eq 0 ] &&
  [ "$(count_arg --smoke-path)" -eq 0 ]; then
  ok "36: both checks off passes no smoke flags"
else
  bad "36: both checks off passes no smoke flags" \
    "exit $step_status; argv: [$(cat "$argv_log")]"
fi
if [ "$(count_arg --rate-limit-check)" -eq 0 ] && [ "$(count_arg --rl-mode)" -eq 0 ]; then
  ok "36: both checks off passes no rate-limit flags"
else
  bad "36: both checks off passes no rate-limit flags" "argv: [$(cat "$argv_log")]"
fi

run_deploy_step false false "https://worker.example.test"
if [ "$step_status" -eq 0 ] && [ "$(count_arg --smoke-url)" -eq 0 ]; then
  ok "36: both checks off ignores a set smoke URL"
else
  bad "36: both checks off ignores a set smoke URL" \
    "exit $step_status; argv: [$(cat "$argv_log")]"
fi

run_deploy_step true false ""
if [ "$step_status" -eq 2 ]; then
  ok "36: smoke with an empty smoke-url exits 2"
else
  bad "36: smoke with an empty smoke-url exits 2" "exit $step_status"
fi
case "$step_err" in
  *"smoke is true but smoke-url is empty"*)
    ok "36: empty smoke-url names the smoke input" ;;
  *)
    bad "36: empty smoke-url names the smoke input" "stderr: [$step_err]" ;;
esac
if [ "$(count_arg --smoke-url)" -eq 0 ]; then
  ok "36: empty smoke-url passes no flags to the script"
else
  bad "36: empty smoke-url passes no flags to the script" "argv: [$(cat "$argv_log")]"
fi

run_deploy_step false true ""
if [ "$step_status" -eq 2 ]; then
  ok "36: hook with an empty smoke-url exits 2"
else
  bad "36: hook with an empty smoke-url exits 2" "exit $step_status"
fi
case "$step_err" in
  *"rate-limit-check needs smoke-url as its base URL"*)
    ok "36: empty smoke-url names the hook input" ;;
  *)
    bad "36: empty smoke-url names the hook input" "stderr: [$step_err]" ;;
esac

printf '== signal cleanup ==\n'

sig_bin="$work_tmp/sig-bin"
sig_tmpdir="$work_tmp/sig-tmpdir"
sig_ready="$work_tmp/sig-ready"
sig_child_file="$work_tmp/sig-child"
sig_err="$work_tmp/sig-stderr"
mkdir -p "$sig_bin" "$sig_tmpdir"

cat > "$sig_bin/npm" <<'STUB'
#!/usr/bin/env bash
set -u
printf '%s\n' "$$" > "${SIG_CHILD_FILE:?}"
: > "${SIG_READY:?}"
sleep 30
exit 0
STUB
chmod +x "$sig_bin/npm"

rm -f "$sig_ready" "$sig_child_file"
: > "$sig_err"
sig_pid=""
sig_child=""
sig_status=0

set -m
PATH="$sig_bin:$PATH" TMPDIR="$sig_tmpdir" SIG_READY="$sig_ready" \
  SIG_CHILD_FILE="$sig_child_file" CLOUDFLARE_API_TOKEN="$fake_token" \
  CLOUDFLARE_ACCOUNT_ID="$fake_account" \
  "$bash_bin" "$deploy_script" --dir "$worker_dir" --mode deploy \
  >/dev/null 2>"$sig_err" &
sig_pid=$!
set +m

sig_wait=0
while [ ! -e "$sig_ready" ] && [ "$sig_wait" -lt 100 ]; do
  sig_wait=$((sig_wait + 1))
  sleep 0.1
done

if [ -e "$sig_ready" ]; then
  ok "37: the deploy script starts a long-running child"
else
  bad "37: the deploy script starts a long-running child" \
    "no ready marker; stderr: [$(cat "$sig_err")]"
fi
sig_child="$(cat "$sig_child_file" 2>/dev/null || true)"

if [ -n "$sig_pid" ]; then
  kill -TERM -"$sig_pid" 2>/dev/null || kill -TERM "$sig_pid" 2>/dev/null || true
fi

sig_wait=0
while kill -0 "$sig_pid" 2>/dev/null && [ "$sig_wait" -lt 100 ]; do
  sig_wait=$((sig_wait + 1))
  sleep 0.1
done
if kill -0 "$sig_pid" 2>/dev/null; then
  bad "37: TERM stops the deploy script" "still running after 10 s"
  kill -KILL -"$sig_pid" 2>/dev/null || kill -KILL "$sig_pid" 2>/dev/null || true
fi
wait "$sig_pid" 2>/dev/null
sig_status=$?
sig_pid=""

if [ "$sig_status" -ne 0 ]; then
  ok "37: TERM makes the deploy script exit non-zero"
else
  bad "37: TERM makes the deploy script exit non-zero" "exit $sig_status"
fi

leftovers="$(find "$sig_tmpdir" -mindepth 1 -maxdepth 1 -name 'worker-deploy.*' 2>/dev/null)"
if [ -z "$leftovers" ]; then
  ok "37: TERM removes the captured step directory"
else
  bad "37: TERM removes the captured step directory" "leftover: [$leftovers]"
fi

if [ -n "$sig_child" ]; then
  sig_wait=0
  while kill -0 "$sig_child" 2>/dev/null && [ "$sig_wait" -lt 50 ]; do
    sig_wait=$((sig_wait + 1))
    sleep 0.1
  done
  if kill -0 "$sig_child" 2>/dev/null; then
    bad "37: TERM stops the sleeping child" "child $sig_child still alive"
    kill -KILL "$sig_child" 2>/dev/null || true
  else
    ok "37: TERM stops the sleeping child"
  fi
else
  bad "37: TERM stops the sleeping child" "no child pid was recorded"
fi
sig_child=""

printf '== run blocks never interpolate inputs ==\n'

check_run_inputs() {
  awk '
    BEGIN { re = "\\$\\{\\{[[:space:]]*inputs\\." }
    {
      if (in_block) {
        if ($0 ~ /^[[:space:]]*$/) { next }
        match($0, /[^ ]/)
        if (RSTART - 1 > block_indent) {
          if ($0 ~ re) { print NR ": " $0 }
          next
        }
        in_block = 0
      }
      if ($0 ~ /^ *run:/) {
        pos = index($0, "run:")
        block_indent = pos - 1
        rest = substr($0, pos + 4)
        sub(/^[ ]+/, "", rest)
        if (rest ~ /^[|>]/) {
          in_block = 1
        } else if (rest != "" && rest ~ re) {
          print NR ": " $0
        }
        next
      }
    }
  ' "$1"
}

inputs_fixture="$work_tmp/run-inputs.yml"
cat > "$inputs_fixture" <<'YAML'
name: fixture
jobs:
  demo:
    steps:
      - name: Inline
        run: echo ${{ inputs.x }}
      - name: Block
        env:
          VALUE: ${{ inputs.y }}
        run: |
          set -eu
          echo ${{ inputs.z }}
YAML

fixture_hits="$(check_run_inputs "$inputs_fixture")"
inline_marker="echo \${{ inputs.x }}"
block_marker="echo \${{ inputs.z }}"
env_marker="inputs.y"
if printf '%s\n' "$fixture_hits" | grep -qF -- "$inline_marker"; then
  ok "38: the checker detects inline run interpolation"
else
  bad "38: the checker detects inline run interpolation" "hits: [$fixture_hits]"
fi
if printf '%s\n' "$fixture_hits" | grep -qF -- "$block_marker"; then
  ok "38: the checker detects block-scalar run interpolation"
else
  bad "38: the checker detects block-scalar run interpolation" "hits: [$fixture_hits]"
fi
if printf '%s\n' "$fixture_hits" | grep -qF -- "$env_marker"; then
  bad "38: the checker ignores env mappings" "hits: [$fixture_hits]"
else
  ok "38: the checker ignores env mappings"
fi

workflow_hits="$(check_run_inputs "$workflow")"
if [ -z "$workflow_hits" ]; then
  ok "38: no workflow run block interpolates inputs"
else
  bad "38: no workflow run block interpolates inputs" "$workflow_hits"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -ne 0 ]; then
  exit 1
fi
exit 0
