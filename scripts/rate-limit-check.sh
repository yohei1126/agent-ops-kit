#!/usr/bin/env bash
# rate-limit-check.sh: send one sequential request burst to one URL and report
# whether the route enforces the limit.
#
# Safety: exactly one URL from --base-url. The script never deploys, never
# follows redirects, sends no credentials, cookies, or custom auth headers, and
# never reads a token environment variable. A POST request carries an empty
# body. A live run against a real hostname stays a manual step for the
# maintainer; CI uses a local fixture server only.
#
# Exit codes: 0 pass, 1 check failed or transport error, 2 usage error,
# 3 required command missing (curl).
set -u

script_name="rate-limit-check"

usage() {
  cat <<'EOF'
usage: rate-limit-check.sh --base-url <url> --limit <n> --window <s> [options]

Send sequential requests to one URL and check whether the limit is enforced.

Required:
  --base-url <url>   http:// or https:// URL. No userinfo. One host only.
  --limit <n>        Documented request limit per window. Positive integer.
  --window <s>       Documented window length in seconds. Positive integer.

Options:
  --path <path>      Request path, starting with /. Default: /
  --method <token>   Uppercase method token such as GET, HEAD, or POST.
                     Default: GET
  --requests <n>     Number of sequential requests.
                     Default: limit + 1
  --mode <mode>      enforce (default): require a 429 and a valid Retry-After.
                     detect: fail when every response succeeds.
  --timeout <s>      Per-request timeout in seconds. Default: 10
  -h, --help         Show this help.

Modes:
  enforce  Requests must be at least limit + 1. At least one 429 is required,
           with a Retry-After that is a positive integer no larger than the
           window. A run longer than the window is reported but can still pass.
  detect   Requests must be more than limit. Every 2xx or 3xx response with no
           429 fails with "limit not enforced".

Examples:
  rate-limit-check.sh --base-url https://example.com --path /health \
    --limit 100 --window 60
  rate-limit-check.sh --base-url https://example.com --path /health \
    --limit 100 --window 60 --mode detect

Exit codes:
  0  check passed
  1  check failed, including a transport error
  2  usage error
  3  curl is missing
EOF
}

usage_error() {
  printf '%s: %s\n' "$script_name" "$1" >&2
  printf '%s: run with --help for usage\n' "$script_name" >&2
  exit 2
}

validate_posint() {
  local name="$1"
  local value="$2"
  case "$value" in
    ''|*[!0-9]*) usage_error "$name needs a positive integer" ;;
  esac
  if [ "$((10#$value))" -le 0 ]; then
    usage_error "$name needs a positive integer"
  fi
}

retry_after_value() {
  local file="$1"
  local line value=""
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in
      [Rr][Ee][Tt][Rr][Yy]-[Aa][Ff][Tt][Ee][Rr]:*) value="${line#*:}" ;;
    esac
  done < "$file"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

cf_ray_value() {
  local file="$1"
  local line value=""
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in
      [Cc][Ff]-[Rr][Aa][Yy]:*) value="${line#*:}" ;;
    esac
  done < "$file"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

base_url=""
path="/"
method="GET"
limit=""
window=""
requests=""
mode="enforce"
timeout="10"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --base-url)
      [ "$#" -ge 2 ] || usage_error "--base-url needs a value"
      base_url="$2"
      shift 2
      ;;
    --base-url=*)
      base_url="${1#--base-url=}"
      shift
      ;;
    --path)
      [ "$#" -ge 2 ] || usage_error "--path needs a value"
      path="$2"
      shift 2
      ;;
    --path=*)
      path="${1#--path=}"
      shift
      ;;
    --method)
      [ "$#" -ge 2 ] || usage_error "--method needs a value"
      method="$2"
      shift 2
      ;;
    --method=*)
      method="${1#--method=}"
      shift
      ;;
    --limit)
      [ "$#" -ge 2 ] || usage_error "--limit needs a value"
      limit="$2"
      shift 2
      ;;
    --limit=*)
      limit="${1#--limit=}"
      shift
      ;;
    --window)
      [ "$#" -ge 2 ] || usage_error "--window needs a value"
      window="$2"
      shift 2
      ;;
    --window=*)
      window="${1#--window=}"
      shift
      ;;
    --requests)
      [ "$#" -ge 2 ] || usage_error "--requests needs a value"
      requests="$2"
      shift 2
      ;;
    --requests=*)
      requests="${1#--requests=}"
      shift
      ;;
    --mode)
      [ "$#" -ge 2 ] || usage_error "--mode needs a value"
      mode="$2"
      shift 2
      ;;
    --mode=*)
      mode="${1#--mode=}"
      shift
      ;;
    --timeout)
      [ "$#" -ge 2 ] || usage_error "--timeout needs a value"
      timeout="$2"
      shift 2
      ;;
    --timeout=*)
      timeout="${1#--timeout=}"
      shift
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

[ -n "$base_url" ] || usage_error "--base-url is required"
case "$base_url" in
  http://*|https://*) ;;
  *) usage_error "--base-url must start with http:// or https://" ;;
esac
case "$base_url" in
  *[[:space:]]*) usage_error "--base-url must not contain whitespace" ;;
esac
authority="${base_url#*://}"
authority="${authority%%/*}"
case "$authority" in
  '') usage_error "--base-url must include a host" ;;
  *@*) usage_error "--base-url must not contain user:pass@ userinfo" ;;
esac

case "$path" in
  /*) ;;
  *) usage_error "--path must start with /" ;;
esac
case "$path" in
  *[[:space:]]*) usage_error "--path must not contain whitespace" ;;
esac

case "$method" in
  ''|-*|*[!A-Z-]*) usage_error "--method must be an uppercase token" ;;
esac

case "$mode" in
  enforce|detect) ;;
  *) usage_error "--mode must be enforce or detect" ;;
esac

[ -n "$limit" ] || usage_error "--limit is required"
validate_posint --limit "$limit"
limit="$((10#$limit))"

[ -n "$window" ] || usage_error "--window is required"
validate_posint --window "$window"
window="$((10#$window))"

if [ -z "$requests" ]; then
  requests="$((limit + 1))"
fi
validate_posint --requests "$requests"
requests="$((10#$requests))"

validate_posint --timeout "$timeout"
timeout="$((10#$timeout))"

if [ "$mode" = "enforce" ] && [ "$requests" -lt "$((limit + 1))" ]; then
  usage_error "--requests must be at least limit + 1 in enforce mode"
fi
if [ "$mode" = "detect" ] && [ "$requests" -le "$limit" ]; then
  usage_error "--requests must be greater than limit in detect mode"
fi

if ! command -v curl >/dev/null 2>&1; then
  printf '%s: curl is required\n' "$script_name" >&2
  exit 3
fi

while [ "${base_url%/}" != "$base_url" ]; do
  base_url="${base_url%/}"
done
url="${base_url}${path}"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/rate-limit-check.XXXXXX")" || {
  printf '%s: could not create a temporary directory\n' "$script_name" >&2
  exit 1
}
trap 'rm -rf "$tmp_dir"' EXIT
trap 'rm -rf "$tmp_dir"; exit 1' HUP INT TERM

header_file="$tmp_dir/headers"
error_file="$tmp_dir/curl-error"
records_file="$tmp_dir/records"
: > "$records_file"

printf '%s: %s mode, limit %s, window %ss, %s sequential request(s)\n' \
  "$script_name" "$mode" "$limit" "$window" "$requests"
printf '%s: target %s %s\n' "$script_name" "$method" "$url"

start_epoch="$(date +%s)"
retry_after=""
retry_seen=0
index=1

while [ "$index" -le "$requests" ]; do
  : > "$header_file"
  : > "$error_file"
  if [ "$method" = "POST" ]; then
    code="$(curl -sS -o /dev/null -D "$header_file" -w '%{http_code}' \
      --max-time "$timeout" --proto '=https,http' -X "$method" \
      --data '' "$url" 2>"$error_file")"
  else
    code="$(curl -sS -o /dev/null -D "$header_file" -w '%{http_code}' \
      --max-time "$timeout" --proto '=https,http' -X "$method" \
      "$url" 2>"$error_file")"
  fi
  rc=$?
  if [ "$rc" -ne 0 ]; then
    detail="$(tr '\n' ' ' < "$error_file")"
    printf '%s: FAIL request %s of %s failed: curl exit %s: %s\n' \
      "$script_name" "$index" "$requests" "$rc" "$detail"
    exit 1
  fi
  case "$code" in
    [0-9][0-9][0-9]) ;;
    *)
      printf '%s: FAIL request %s of %s returned no HTTP status\n' \
        "$script_name" "$index" "$requests"
      exit 1
      ;;
  esac

  if [ "$code" = "429" ] && [ "$retry_seen" = 0 ]; then
    retry_seen=1
    retry_after="$(retry_after_value "$header_file")"
  fi

  location="$(cf_ray_value "$header_file")"
  if [ -n "$location" ]; then
    location="${location##*-}"
  fi
  printf '%s\t%s\n' "$code" "$location" >> "$records_file"

  index=$((index + 1))
done

end_epoch="$(date +%s)"
elapsed=$((end_epoch - start_epoch))

printf '%s: %s response(s), elapsed %ss\n' \
  "$script_name" "$requests" "$elapsed"

awk -F '\t' '
  {
    count[$1] += 1
    if ($2 != "" && seen[$1 SUBSEP $2] == 0) {
      seen[$1 SUBSEP $2] = 1
      loc[$1] = (loc[$1] == "" ? $2 : loc[$1] "," $2)
    }
  }
  END {
    for (status in count) {
      print status, count[status], loc[status]
    }
  }
' "$records_file" | sort -n | while read -r status total places; do
  if [ -n "$places" ]; then
    printf '%s: %s: %s response(s) (location %s)\n' \
      "$script_name" "$status" "$total" "$places"
  else
    printf '%s: %s: %s response(s)\n' "$script_name" "$status" "$total"
  fi
done

locations="$(awk -F '\t' '$2 != "" { print $2 }' "$records_file" |
  sort -u | awk 'NR == 1 { all = $0; next } { all = all "," $0 } END { print all }')"
if [ -z "$locations" ]; then
  printf '%s: locations: none reported by cf-ray\n' "$script_name"
else
  location_count="$(printf '%s\n' "$locations" | awk -F ',' '{ print NF }')"
  if [ "$location_count" -eq 1 ]; then
    printf '%s: locations: %s (all responses shared one location)\n' \
      "$script_name" "$locations"
  else
    printf '%s: locations: %s (locations differ)\n' \
      "$script_name" "$locations"
  fi
fi

count_429="$(awk -F '\t' '$1 == "429" { total += 1 } END { print total + 0 }' \
  "$records_file")"
count_other="$(awk -F '\t' '$1 !~ /^[23][0-9][0-9]$/ { total += 1 }
  END { print total + 0 }' "$records_file")"

if [ "$mode" = "enforce" ]; then
  if [ "$count_429" -eq 0 ]; then
    printf '%s: FAIL no 429 in %s responses; the limit was not enforced\n' \
      "$script_name" "$requests"
    exit 1
  fi

  retry_problem=""
  case "$retry_after" in
    '') retry_problem="the first 429 has no Retry-After header" ;;
    *[!0-9]*) retry_problem="Retry-After [$retry_after] is not a positive integer" ;;
    *)
      if [ "$((10#$retry_after))" -lt 1 ]; then
        retry_problem="Retry-After [$retry_after] is not a positive integer"
      elif [ "$((10#$retry_after))" -gt "$window" ]; then
        retry_problem="Retry-After [$retry_after] is larger than the window ${window}s"
      fi
      ;;
  esac
  if [ -n "$retry_problem" ]; then
    printf '%s: FAIL %s\n' "$script_name" "$retry_problem"
    exit 1
  fi

  if [ "$elapsed" -gt "$window" ]; then
    printf '%s: note: the run took %ss, longer than the %ss window; responses may span windows\n' \
      "$script_name" "$elapsed" "$window"
  fi
  printf '%s: PASS %s response(s), %s blocked by 429, Retry-After %ss within the %ss window\n' \
    "$script_name" "$requests" "$count_429" "$((10#$retry_after))" "$window"
  exit 0
fi

if [ "$count_429" -gt 0 ]; then
  printf '%s: PASS 429 seen, the limit is enforced\n' "$script_name"
  exit 0
fi
if [ "$count_other" -eq 0 ]; then
  printf '%s: FAIL limit not enforced: %s of %s responses succeeded\n' \
    "$script_name" "$requests" "$requests"
  exit 1
fi
printf '%s: FAIL no 429 in %s responses; the statuses did not show a limit\n' \
  "$script_name" "$requests"
exit 1
