#!/usr/bin/env bash
# worker-deploy.sh: run one shared preflight and deploy path for a Worker, so
# CI and a maintainer machine cannot drift in the preflight order, the wrangler
# invocation, or the recorded version id.
#
# Safety: refuse shell xtrace, which would print expanded values. Every child
# process's output is redacted before it is printed. Secret values never reach
# argv, are never echoed, and are never written to disk unredacted except the
# mode 600 wrangler capture file inside a trap-removed mktemp directory. curl
# sends no credentials and never follows redirects. Preflight children run
# without CLOUDFLARE_API_TOKEN or CLOUDFLARE_ACCOUNT_ID, even in deploy mode.
# Those values are present only for the real wrangler deploy.
#
# Exit codes: 0 okay, 1 preflight, deploy, smoke, or hook failure, 2 usage
# error, 3 required command missing (npm, npx, node, or curl when smoke or the
# rate-limit hook is requested) or the sibling rate-limit-check.sh is missing.
set -euo pipefail

script_name="worker-deploy"

usage() {
  cat <<'EOF'
usage: worker-deploy.sh --dir <worker-dir> [--mode preflight|deploy] [options]

Run the shared Worker preflight in <worker-dir>, and optionally deploy.

Preflight, in order:
  1. npm ci
  2. typecheck: npm run typecheck when package.json has that script, else
     npx --no-install tsc --noEmit when tsconfig.json exists, else skip
  3. tests: npm test when package.json has that script (skip with --skip-tests)
  4. npx --no-install wrangler deploy --dry-run

Every preflight step is fail-closed: a non-zero exit stops the run, and deploy
never starts after a failed step.

Options:
  --dir <worker-dir>   Worker directory with package.json and a wrangler config
                       (wrangler.jsonc, wrangler.json, or wrangler.toml).
                       Required.
  --mode <mode>        preflight (default) or deploy. Deploy runs the same
                       preflight, then npx --no-install wrangler deploy.
  --skip-tests         Skip the test step. Discouraged; the reusable workflow
                       keeps this opt-in and off by default.
  --smoke-url <url>    After a successful deploy, GET <url><smoke-path> and
                       require a 2xx. https:// only; http://127.0.0.1 and
                       http://localhost are allowed for tests.
  --smoke-path <path>  Smoke request path, starting with /. Default: /health
  --rate-limit-check   Enable the post-deploy rate-limit hook. Off by default.
                       Requires --smoke-url, --rl-limit, and --rl-window.
  --rl-path <path>     Rate-limit request path, starting with /.
                       Default: /health
  --rl-limit <n>       Documented limit per window. Positive integer.
  --rl-window <s>      Documented window in seconds. Positive integer.
  --rl-requests <n>    Sequential requests for the hook. Default: limit + 1
  --rl-mode <mode>     enforce (default) or detect.
  -h, --help           Show this help.

Output:
  On a successful deploy the script prints one line on stdout:
    version_id=<id>
  When GITHUB_OUTPUT names a writable regular file, the same line is appended
  to it. Every child process's output goes to stderr after redaction.

Safety:
  The script refuses to run when shell xtrace is on (set -x or bash -x),
  because xtrace prints expanded values. Values of CLOUDFLARE_API_TOKEN,
  CLOUDFLARE_ACCOUNT_ID, and any environment variable whose name matches
  *TOKEN*, *SECRET*, *PASSWORD*, *_KEY, or *API_KEY* (case-insensitive, value
  length 6 or more) are replaced with [REDACTED] before output is printed.
  Secrets are never passed as command arguments and never echoed. Child output
  is captured in mode 600 files inside a mktemp directory that a trap removes.
  curl sends no credentials, cookies, or auth headers, and never follows
  redirects.

Exit codes:
  0  okay
  1  preflight, deploy, smoke, or rate-limit hook failure
  2  usage error
  3  required command missing (npm, npx, node, or curl when smoke or the
     rate-limit hook is requested), or the sibling rate-limit-check.sh is
     missing
EOF
}

usage_error() {
  printf '%s: %s\n' "$script_name" "$1" >&2
  printf '%s: run with --help for usage\n' "$script_name" >&2
  exit 2
}

trim() {
  local value="$1"

  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

validate_positive_int() {
  local name="$1"
  local value="$2"

  case "$value" in
    ''|*[!0-9]*) usage_error "$name needs a positive integer" ;;
  esac
  if [ "$((10#$value))" -le 0 ]; then
    usage_error "$name needs a positive integer"
  fi
}

case "$0" in
  */*) script_dir="${0%/*}" ;;
  *) script_dir="." ;;
esac
script_dir="$(cd "$script_dir" && pwd)"
rate_limit_script="$script_dir/rate-limit-check.sh"

# xtrace would print expanded values, including any secret a later line reads.
case "$-" in
  *x*)
    printf '%s: refusing to run with shell xtrace on; it would print values\n' "$script_name" >&2
    exit 2
    ;;
esac
case "${SHELLOPTS:-}" in
  *xtrace*)
    printf '%s: refusing to run with shell xtrace on; it would print values\n' "$script_name" >&2
    exit 2
    ;;
esac

dir=""
mode="preflight"
skip_tests=0
smoke_url=""
smoke_path="/health"
rate_limit_enabled=0
have_rate_limit_option=0
rl_path="/health"
rl_limit=""
rl_window=""
rl_requests=""
rl_mode="enforce"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dir)
      [ "$#" -ge 2 ] || usage_error "--dir needs a value"
      dir="$2"
      shift 2
      ;;
    --mode)
      [ "$#" -ge 2 ] || usage_error "--mode needs a value"
      mode="$2"
      shift 2
      ;;
    --skip-tests)
      skip_tests=1
      shift
      ;;
    --smoke-url)
      [ "$#" -ge 2 ] || usage_error "--smoke-url needs a value"
      smoke_url="$2"
      shift 2
      ;;
    --smoke-path)
      [ "$#" -ge 2 ] || usage_error "--smoke-path needs a value"
      smoke_path="$2"
      shift 2
      ;;
    --rate-limit-check)
      rate_limit_enabled=1
      shift
      ;;
    --rl-path)
      [ "$#" -ge 2 ] || usage_error "--rl-path needs a value"
      rl_path="$2"
      have_rate_limit_option=1
      shift 2
      ;;
    --rl-limit)
      [ "$#" -ge 2 ] || usage_error "--rl-limit needs a value"
      rl_limit="$2"
      have_rate_limit_option=1
      shift 2
      ;;
    --rl-window)
      [ "$#" -ge 2 ] || usage_error "--rl-window needs a value"
      rl_window="$2"
      have_rate_limit_option=1
      shift 2
      ;;
    --rl-requests)
      [ "$#" -ge 2 ] || usage_error "--rl-requests needs a value"
      rl_requests="$2"
      have_rate_limit_option=1
      shift 2
      ;;
    --rl-mode)
      [ "$#" -ge 2 ] || usage_error "--rl-mode needs a value"
      rl_mode="$2"
      have_rate_limit_option=1
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage_error "unknown option: $1"
      ;;
  esac
done

[ -n "$dir" ] || usage_error "--dir is required"
[ -d "$dir" ] || usage_error "--dir is not a directory: $dir"
[ -f "$dir/package.json" ] || usage_error "--dir has no package.json: $dir"
if [ ! -f "$dir/wrangler.jsonc" ] && [ ! -f "$dir/wrangler.json" ] && [ ! -f "$dir/wrangler.toml" ]; then
  usage_error "--dir has no wrangler.jsonc, wrangler.json, or wrangler.toml: $dir"
fi

case "$mode" in
  preflight|deploy) ;;
  *) usage_error "--mode must be preflight or deploy" ;;
esac

case "$smoke_path" in
  /*) ;;
  *) usage_error "--smoke-path must start with /" ;;
esac
case "$smoke_path" in
  *[[:space:]]*) usage_error "--smoke-path must not contain whitespace" ;;
esac

if [ -n "$smoke_url" ]; then
  case "$smoke_url" in
    https://?*) ;;
    http://127.0.0.1|http://127.0.0.1/*|http://127.0.0.1:*|\
    http://localhost|http://localhost/*|http://localhost:*) ;;
    *)
      usage_error "--smoke-url must start with https:// (http://127.0.0.1 and http://localhost are allowed for tests)"
      ;;
  esac
  case "$smoke_url" in
    *[[:space:]]*) usage_error "--smoke-url must not contain whitespace" ;;
  esac
fi

if [ "$rate_limit_enabled" = 1 ]; then
  [ -n "$smoke_url" ] || usage_error "--rate-limit-check needs --smoke-url as the base URL"
  [ -n "$rl_limit" ] || usage_error "--rate-limit-check needs --rl-limit"
  [ -n "$rl_window" ] || usage_error "--rate-limit-check needs --rl-window"
  validate_positive_int --rl-limit "$rl_limit"
  validate_positive_int --rl-window "$rl_window"
  if [ -n "$rl_requests" ]; then
    validate_positive_int --rl-requests "$rl_requests"
  fi
  case "$rl_mode" in
    enforce|detect) ;;
    *) usage_error "--rl-mode must be enforce or detect" ;;
  esac
  case "$rl_path" in
    /*) ;;
    *) usage_error "--rl-path must start with /" ;;
  esac
elif [ "$have_rate_limit_option" = 1 ]; then
  usage_error "--rl-* options need --rate-limit-check"
fi

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf '%s: %s is required\n' "$script_name" "$1" >&2
    exit 3
  fi
}

require_command npm
require_command npx
require_command node
if [ -n "$smoke_url" ] || [ "$rate_limit_enabled" = 1 ]; then
  require_command curl
fi
if [ "$rate_limit_enabled" = 1 ] && [ ! -f "$rate_limit_script" ]; then
  printf '%s: %s is missing; run from the kit scripts directory\n' \
    "$script_name" "rate-limit-check.sh" >&2
  exit 3
fi

if [ "$mode" = "deploy" ] && [ -z "${CLOUDFLARE_API_TOKEN:-}" ]; then
  printf '%s: CLOUDFLARE_API_TOKEN is not set; export a scoped token before deploying\n' \
    "$script_name" >&2
  exit 1
fi

secret_names=""

add_secret_name() {
  local name="$1"

  case " $secret_names " in
    *" $name "*) return 0 ;;
  esac
  secret_names="$secret_names $name"
}

collect_secret_names() {
  local line name upper

  if [ -n "${CLOUDFLARE_API_TOKEN:-}" ]; then
    add_secret_name CLOUDFLARE_API_TOKEN
  fi
  if [ -n "${CLOUDFLARE_ACCOUNT_ID:-}" ]; then
    add_secret_name CLOUDFLARE_ACCOUNT_ID
  fi

  while IFS= read -r line; do
    name="${line%%=*}"
    if [ "$name" = "$line" ]; then
      continue
    fi
    case "$name" in
      ''|[0-9]*|*[!A-Za-z0-9_]*) continue ;;
    esac
    upper="$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]')"
    case "$upper" in
      *TOKEN*|*SECRET*|*PASSWORD*|*_KEY|*API_KEY*) add_secret_name "$name" ;;
    esac
  done < <(env)
}

redact_text() {
  local content="$1"
  local name value

  for name in $secret_names; do
    value="${!name}"
    if [ "${#value}" -ge 6 ]; then
      content="${content//"$value"/[REDACTED]}"
    fi
  done
  printf '%s' "$content"
}

print_redacted_file() {
  local file="$1"
  local content

  content="$(cat "$file" || true)"
  if [ -n "$content" ]; then
    redact_text "$content" >&2
    printf '\n' >&2
  fi
}

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/worker-deploy.XXXXXX")" || {
  printf '%s: could not create a temporary directory\n' "$script_name" >&2
  exit 1
}
trap 'rm -rf "$tmp_dir"' EXIT
trap 'rm -rf "$tmp_dir"; exit 1' HUP INT TERM

collect_secret_names

step_log="$tmp_dir/step.log"
: > "$step_log"
chmod 600 "$step_log" 2>/dev/null || true

package_has_script() {
  node -e '
    const fs = require("node:fs");
    const file = process.argv[1];
    const name = process.argv[2];
    try {
      const pkg = JSON.parse(fs.readFileSync(file, "utf8"));
      const scripts = pkg && typeof pkg === "object" ? pkg.scripts : null;
      const found = scripts && typeof scripts === "object" &&
        Object.prototype.hasOwnProperty.call(scripts, name);
      process.exit(found ? 0 : 1);
    } catch (error) {
      process.exit(1);
    }
  ' "$dir/package.json" "$1"
}

# Preflight children must not inherit Cloudflare credentials, even when this
# script is in deploy mode. The real wrangler deploy uses run_deploy_in_worker_dir.
run_in_worker_dir() {
  ( cd "$dir" && env -u CLOUDFLARE_API_TOKEN -u CLOUDFLARE_ACCOUNT_ID "$@" ) >"$step_log" 2>&1
}

run_deploy_in_worker_dir() {
  ( cd "$dir" && "$@" ) >"$step_log" 2>&1
}

fail_step() {
  local label="$1"

  print_redacted_file "$step_log"
  printf '%s: preflight failed: %s\n' "$script_name" "$label" >&2
  exit 1
}

run_preflight() {
  printf '%s: preflight: npm ci\n' "$script_name" >&2
  if ! run_in_worker_dir npm ci; then
    fail_step "npm ci"
  fi
  print_redacted_file "$step_log"
  : > "$step_log"

  if package_has_script typecheck; then
    printf '%s: preflight: npm run typecheck\n' "$script_name" >&2
    if ! run_in_worker_dir npm run typecheck; then
      fail_step "npm run typecheck"
    fi
    print_redacted_file "$step_log"
  elif [ -f "$dir/tsconfig.json" ]; then
    printf '%s: preflight: npx --no-install tsc --noEmit\n' "$script_name" >&2
    if ! run_in_worker_dir npx --no-install tsc --noEmit; then
      fail_step "npx --no-install tsc --noEmit"
    fi
    print_redacted_file "$step_log"
  else
    printf '%s: preflight: typecheck skipped (no typecheck script and no tsconfig.json)\n' \
      "$script_name" >&2
  fi
  : > "$step_log"

  if [ "$skip_tests" = 1 ]; then
    printf '%s: preflight: tests skipped (--skip-tests; discouraged)\n' "$script_name" >&2
  elif package_has_script test; then
    printf '%s: preflight: npm test\n' "$script_name" >&2
    if ! run_in_worker_dir npm test; then
      fail_step "npm test"
    fi
    print_redacted_file "$step_log"
  else
    printf '%s: preflight: tests skipped (package.json has no test script)\n' "$script_name" >&2
  fi
  : > "$step_log"

  printf '%s: preflight: npx --no-install wrangler deploy --dry-run\n' "$script_name" >&2
  if ! run_in_worker_dir npx --no-install wrangler deploy --dry-run; then
    fail_step "npx --no-install wrangler deploy --dry-run"
  fi
  print_redacted_file "$step_log"
  : > "$step_log"
}

version_id=""

run_deploy() {
  local id

  printf '%s: deploy: npx --no-install wrangler deploy\n' "$script_name" >&2
  if ! run_deploy_in_worker_dir npx --no-install wrangler deploy; then
    print_redacted_file "$step_log"
    printf '%s: deploy failed; wrangler exited non-zero\n' "$script_name" >&2
    exit 1
  fi
  print_redacted_file "$step_log"

  id="$(awk '
    /Version ID:/ {
      line = $0
      sub(/^.*Version ID:[[:space:]]*/, "", line)
      sub(/[[:space:]].*$/, "", line)
      print line
      exit
    }
  ' "$step_log")"

  if ! printf '%s' "$id" | grep -Eq '^[0-9a-fA-F-]{8,}$'; then
    printf '%s: deploy output has no valid Version ID; refusing to report success\n' \
      "$script_name" >&2
    exit 1
  fi

  version_id="$(trim "$id")"
  printf 'version_id=%s\n' "$version_id"
  if [ -n "${GITHUB_OUTPUT:-}" ] && [ -f "$GITHUB_OUTPUT" ] && [ -w "$GITHUB_OUTPUT" ]; then
    printf 'version_id=%s\n' "$version_id" >> "$GITHUB_OUTPUT"
  fi
  printf '%s: deploy succeeded: version_id=%s\n' "$script_name" "$version_id" >&2
}

run_smoke() {
  local base="$smoke_url"
  local url code rc attempt=1
  local curl_err="$tmp_dir/curl-error"

  while [ "${base%/}" != "$base" ]; do
    base="${base%/}"
  done
  url="${base}${smoke_path}"

  printf '%s: smoke: GET %s\n' "$script_name" "$url" >&2
  : > "$curl_err"
  chmod 600 "$curl_err" 2>/dev/null || true

  while [ "$attempt" -le 3 ]; do
    : > "$curl_err"
    if code="$(curl --fail --silent --show-error --max-time 10 --proto '=https,http' \
      -o /dev/null -w '%{http_code}' "$url" 2>"$curl_err")"; then
      case "$code" in
        2[0-9][0-9])
          print_redacted_file "$curl_err"
          printf '%s: smoke: %s returned %s\n' "$script_name" "$url" "$code" >&2
          return 0
          ;;
      esac
      printf '%s: smoke: %s returned %s; retrying\n' "$script_name" "$url" "$code" >&2
    else
      rc=$?
      print_redacted_file "$curl_err"
      printf '%s: smoke: %s failed (curl exit %s); retrying\n' "$script_name" "$url" "$rc" >&2
    fi
    attempt=$((attempt + 1))
    if [ "$attempt" -le 3 ]; then
      sleep 2
    fi
  done

  printf '%s: smoke failed after a successful deploy (version_id=%s)\n' \
    "$script_name" "$version_id" >&2
  exit 1
}

run_rate_limit() {
  local hook_log="$tmp_dir/rate-limit.log"

  : > "$hook_log"
  chmod 600 "$hook_log" 2>/dev/null || true

  printf '%s: rate-limit hook: rate-limit-check.sh --base-url %s --path %s --limit %s --window %s\n' \
    "$script_name" "$smoke_url" "$rl_path" "$rl_limit" "$rl_window" >&2

  if [ -n "$rl_requests" ]; then
    if ! bash "$rate_limit_script" --base-url "$smoke_url" --path "$rl_path" \
      --limit "$rl_limit" --window "$rl_window" --requests "$rl_requests" \
      --mode "$rl_mode" >"$hook_log" 2>&1; then
      print_redacted_file "$hook_log"
      printf '%s: rate-limit check failed after a successful deploy (version_id=%s)\n' \
        "$script_name" "$version_id" >&2
      exit 1
    fi
  else
    if ! bash "$rate_limit_script" --base-url "$smoke_url" --path "$rl_path" \
      --limit "$rl_limit" --window "$rl_window" --mode "$rl_mode" \
      >"$hook_log" 2>&1; then
      print_redacted_file "$hook_log"
      printf '%s: rate-limit check failed after a successful deploy (version_id=%s)\n' \
        "$script_name" "$version_id" >&2
      exit 1
    fi
  fi

  print_redacted_file "$hook_log"
  printf '%s: rate-limit hook passed\n' "$script_name" >&2
}

run_preflight

if [ "$mode" = "deploy" ]; then
  run_deploy
  if [ -n "$smoke_url" ]; then
    run_smoke
  fi
  if [ "$rate_limit_enabled" = 1 ]; then
    run_rate_limit
  fi
fi

exit 0
