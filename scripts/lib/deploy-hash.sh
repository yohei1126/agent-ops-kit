#!/usr/bin/env bash
# shellcheck disable=SC2154
# deploy-hash named check. Sourced by scripts/dev-loop-gate.sh, which parses
# the flags and fills the deploy_hash_* inputs below.
#
# Inputs (set by the caller):
#   deploy_hash_url              target URL
#   deploy_hash_source           source name, such as html or etag
#   deploy_hash_have_baseline    1 when --baseline was passed
#   deploy_hash_baseline         value recorded before the deploy
#   deploy_hash_timeout          wait limit in seconds
#   deploy_hash_interval         poll interval in seconds
#   deploy_hash_bundle_pattern   asset ERE; empty means the default
#   deploy_hash_print_current    1 for one fetch and print, 0 for wait mode
#   strict                       1 when --strict was passed
#
# The helper never runs a deploy or a smoke test. It sends no credentials,
# cookies, or custom auth headers, and it never reads a token environment
# variable.

deploy_hash_default_bundle_pattern='assets/[A-Za-z0-9_.-]+-[A-Za-z0-9_-]{8,}\.(js|css)'

# Source html: fetch the page and take the first match of the bundle pattern,
# sorted and unique. A page with no match is a fetch failure.
deploy_hash_source_html() {
  local url="$1"
  local pattern body matches first
  pattern="${deploy_hash_bundle_pattern:-$deploy_hash_default_bundle_pattern}"
  if ! body="$(curl -fsSL --max-time 20 --proto '=https,http' "$url" 2>/dev/null)"; then
    return 1
  fi
  if ! matches="$(printf '%s\n' "$body" | grep -Eo -- "$pattern" 2>/dev/null | LC_ALL=C sort -u)"; then
    return 1
  fi
  first="$(printf '%s\n' "$matches" | head -n 1)"
  if [ -z "$first" ]; then
    return 1
  fi
  printf '%s\n' "$first"
  return 0
}

# Source etag: send a HEAD request and read the ETag header. The header name is
# matched case-insensitively; quotes and a weak W/ prefix are removed.
deploy_hash_source_etag() {
  local url="$1"
  local headers line value
  if ! headers="$(curl -fsSI --max-time 20 --proto '=https,http' "$url" 2>/dev/null)"; then
    return 1
  fi
  value=""
  while IFS= read -r line; do
    line="${line%$'\r'}"
    case "$line" in
      [Ee][Tt][Aa][Gg]:*)
        value="${line#*:}"
        break
        ;;
    esac
  done <<EOF
$headers
EOF
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  case "$value" in
    W/*) value="${value#W/}" ;;
  esac
  value="${value%\"}"
  value="${value#\"}"
  if [ -z "$value" ]; then
    return 1
  fi
  printf '%s\n' "$value"
  return 0
}

# Keep one value short enough for a table row.
deploy_hash_short() {
  local value="$1"
  if [ "${#value}" -gt 12 ]; then
    printf '%s...' "${value:0:12}"
  else
    printf '%s' "$value"
  fi
}

run_deploy_hash() {
  local source_fn value elapsed=0 nap remaining reads_ok=0 action sleep_cmd

  source_fn="deploy_hash_source_$deploy_hash_source"
  if ! declare -F "$source_fn" >/dev/null 2>&1; then
    printf 'dev-loop-gate: deploy-hash: unknown source: %s\n' "$deploy_hash_source" >&2
    return 2
  fi

  if [ -z "$deploy_hash_url" ]; then
    printf 'dev-loop-gate: deploy-hash: --url is required\n' >&2
    return 2
  fi

  if [ "$deploy_hash_print_current" != 1 ] && [ "$deploy_hash_have_baseline" != 1 ]; then
    printf 'dev-loop-gate: deploy-hash: --baseline is required without --print-current\n' >&2
    return 2
  fi

  if ! command -v curl >/dev/null 2>&1; then
    printf 'dev-loop-gate: deploy-hash: curl is required\n' >&2
    return 3
  fi

  if [ "$deploy_hash_print_current" = 1 ]; then
    if value="$("$source_fn" "$deploy_hash_url")" && [ -n "$value" ]; then
      printf '%s\n' "$value"
      return 0
    fi
    printf 'dev-loop-gate: deploy-hash: could not read source %s\n' "$deploy_hash_source" >&2
    return 3
  fi

  sleep_cmd="${DEV_LOOP_SLEEP_CMD:-sleep}"

  row Gate Name Status Action
  row ---- ------------------------------ ------ ------

  while :; do
    if value="$("$source_fn" "$deploy_hash_url")" && [ -n "$value" ]; then
      reads_ok=1
      if [ "$value" != "$deploy_hash_baseline" ]; then
        action="baseline $(deploy_hash_short "$deploy_hash_baseline") -> current $(deploy_hash_short "$value") after ${elapsed}s"
        row DH deploy-hash PASS "$action"
        return 0
      fi
    fi
    remaining=$((deploy_hash_timeout - elapsed))
    if [ "$remaining" -le 0 ]; then
      break
    fi
    nap="$deploy_hash_interval"
    if [ "$nap" -gt "$remaining" ]; then
      nap="$remaining"
    fi
    if ! "$sleep_cmd" "$nap"; then
      printf 'dev-loop-gate: deploy-hash: sleep command failed: %s\n' "$sleep_cmd" >&2
      return 3
    fi
    elapsed=$((elapsed + nap))
  done

  if [ "$reads_ok" = 1 ]; then
    action="no change after ${elapsed}s; do not run the live smoke yet"
  else
    action="fetch failed after ${elapsed}s; source ${deploy_hash_source} returned an error; do not run the live smoke yet"
  fi
  row DH deploy-hash FAIL "$action"

  if [ "$strict" = 1 ]; then
    return 1
  fi
  return 0
}
