#!/usr/bin/env bash
# Tests for scripts/rate-limit-check.sh. A local python3 fixture server serves
# deterministic responses on 127.0.0.1, so no live Worker is called.
set -u

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
check_script="$repo_root/scripts/rate-limit-check.sh"
fixture_dir="$repo_root/scripts/tests/fixtures/rate-limit-check"
fixture_server="$fixture_dir/server.py"

pass=0
fail=0
work_tmp="$(mktemp -d)"
port_file="$work_tmp/port"
record_file="$work_tmp/records"
server_log="$work_tmp/server.log"
err_file="$work_tmp/stderr"
: > "$err_file"

out=""
err=""
status=0
server_pid=""
base_url=""

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
    bad "$1" "expected exit $2, got $status; stdout: $out; stderr: $err"
  fi
}

expect_out() {
  case "$out" in
    *"$2"*) ok "$1" ;;
    *) bad "$1" "stdout missing: $2; got [$out]" ;;
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
    bad "$1" "stdout missing line matching: $2; got [$out]"
  fi
}

expect_err() {
  case "$err" in
    *"$2"*) ok "$1" ;;
    *) bad "$1" "stderr missing: $2; got [$err]" ;;
  esac
}

run_check() {
  : > "$err_file"
  out="$(bash "$check_script" "$@" 2>"$err_file")"
  status=$?
  err="$(cat "$err_file")"
}

stop_server() {
  if [ -n "$server_pid" ]; then
    kill "$server_pid" 2>/dev/null
    wait "$server_pid" 2>/dev/null
    server_pid=""
  fi
}

start_server() {
  local mode="$1"
  local limit="$2"
  local window="$3"
  local retry="$4"
  local tries=0

  stop_server
  rm -f "$port_file"
  : > "$record_file"
  : > "$server_log"
  python3 "$fixture_server" --mode "$mode" --limit "$limit" --window "$window" \
    --retry-value "$retry" --port-file "$port_file" --record "$record_file" \
    >"$server_log" 2>&1 &
  server_pid=$!
  while [ ! -s "$port_file" ]; do
    tries=$((tries + 1))
    if [ "$tries" -gt 100 ]; then
      printf 'fixture server did not start: %s\n' "$(cat "$server_log")" >&2
      exit 1
    fi
    sleep 0.05
  done
  base_url="http://127.0.0.1:$(cat "$port_file")"
}

trap 'stop_server; rm -rf "$work_tmp"' EXIT

printf '== usage errors ==\n'

run_check
expect_status "1: missing base url exits 2" 2
expect_err "1: missing base url names the flag" "--base-url is required"

run_check --base-url ftp://example.com --limit 1 --window 60
expect_status "2: non-http scheme exits 2" 2
expect_err "2: non-http scheme names the scheme" "must start with http:// or https://"

run_check --base-url https://user:pass@example.com --limit 1 --window 60
expect_status "3: userinfo URL exits 2" 2
expect_err "3: userinfo URL names the userinfo" "must not contain user:pass@ userinfo"

run_check --base-url https://example.com --limit 0 --window 60
expect_status "4: zero limit exits 2" 2
expect_err "4: zero limit names the flag" "--limit needs a positive integer"

run_check --base-url https://example.com --limit abc --window 60
expect_status "4: non-numeric limit exits 2" 2

run_check --base-url https://example.com --limit 1 --window 0
expect_status "4: zero window exits 2" 2

run_check --base-url https://example.com --limit 3 --window 60 --requests 3
expect_status "5: enforce requests below limit + 1 exits 2" 2
expect_err "5: enforce request floor is named" "at least limit + 1 in enforce mode"

run_check --base-url https://example.com --limit 3 --window 60 --mode detect --requests 3
expect_status "5: detect requests at the limit exits 2" 2
expect_err "5: detect request floor is named" "greater than limit in detect mode"

run_check --base-url https://example.com --path health --limit 1 --window 60
expect_status "6: path without a leading slash exits 2" 2
expect_err "6: bad path names the rule" "--path must start with /"

run_check --base-url https://example.com --method get --limit 1 --window 60
expect_status "6: lowercase method exits 2" 2
expect_err "6: bad method names the rule" "--method must be an uppercase token"

run_check --base-url https://example.com --limit 1 --window 60 --mode nope
expect_status "6: unknown mode exits 2" 2

run_check --help
expect_status "7: help exits 0" 0
expect_out "7: help shows usage" "--base-url <url>"

printf '== enforce mode ==\n'

start_server limit 3 60 0
run_check --base-url "$base_url" --path /health --limit 3 --window 60
expect_status "9: enforce pass exits 0" 0
expect_out "9: pass verdict" "rate-limit-check: PASS"
expect_out "9: default requests is limit + 1" "4 response(s)"
expect_out "9: 200 count line" "200: 3 response(s)"
expect_out "9: 429 count line" "429: 1 response(s)"
expect_out "9: location suffix is reported" "location SIN"
expect_out "9: locations line reports one location" "all responses shared one location"
expect_out "9: Retry-After is reported" "Retry-After 60s within the 60s window"
expect_no_out "9: pass output has no FAIL verdict" "rate-limit-check: FAIL"
expect_regex "9: verdict line starts the summary" "^rate-limit-check: PASS 4 response"

start_server never 0 60 0
run_check --base-url "$base_url" --limit 3 --window 60
expect_status "10: enforce fails when never limited" 1
expect_out "10: failure names the missing 429" "no 429 in 4 responses"
expect_out "10: failure verdict" "rate-limit-check: FAIL"

start_server bad-retry 0 60 0
run_check --base-url "$base_url" --limit 3 --window 60
expect_status "11: Retry-After 0 fails" 1
expect_out "11: zero Retry-After is named" "not a positive integer"

start_server bad-retry 0 60 abc
run_check --base-url "$base_url" --limit 3 --window 60
expect_status "11: non-integer Retry-After fails" 1
expect_out "11: text Retry-After is named" "not a positive integer"

start_server bad-retry 0 60 9999
run_check --base-url "$base_url" --limit 3 --window 60
expect_status "11: Retry-After above the window fails" 1
expect_out "11: high Retry-After names the window" "larger than the window 60s"

start_server bad-retry 0 60 1
run_check --base-url "$base_url" --limit 1 --window 60 --requests 2
expect_status "12: Retry-After of one second passes" 0

printf '== detect mode ==\n'

start_server never 0 60 0
run_check --base-url "$base_url" --limit 3 --window 60 --mode detect --requests 4
expect_status "13: detect fails on an unenforced limit" 1
expect_out "13: detect names the unenforced limit" "limit not enforced: 4 of 4 responses succeeded"

start_server limit 2 60 0
run_check --base-url "$base_url" --limit 2 --window 60 --mode detect --requests 4
expect_status "14: detect passes when a 429 appears" 0
expect_out "14: detect pass verdict" "429 seen, the limit is enforced"

printf '== request shape ==\n'

start_server limit 1 60 0
run_check --base-url "$base_url" --path '/probe/x?y=1' --method POST \
  --limit 1 --window 60 --requests 2
expect_status "15: POST probe exits 0" 0

if [ "$(wc -l < "$record_file")" -eq 2 ]; then
  ok "15: the server received two requests"
else
  bad "15: the server received two requests" "record: $(cat "$record_file")"
fi
if grep -q '"method": "POST"' "$record_file"; then
  ok "15: the method is forwarded"
else
  bad "15: the method is forwarded" "record: $(cat "$record_file")"
fi
if grep -q '"path": "/probe/x?y=1"' "$record_file"; then
  ok "15: the path and query are forwarded"
else
  bad "15: the path and query are forwarded" "record: $(cat "$record_file")"
fi
if ! grep -qv '"body_length": 0' "$record_file"; then
  ok "15: POST sends an empty body"
else
  bad "15: POST sends an empty body" "record: $(cat "$record_file")"
fi
if ! grep -Eq '"authorization": [^n]|"cookie": [^n]' "$record_file"; then
  ok "16: no Authorization or Cookie header is sent"
else
  bad "16: no Authorization or Cookie header is sent" "record: $(cat "$record_file")"
fi

printf '== transport failures ==\n'

closed_base="$base_url"
stop_server
run_check --base-url "$closed_base" --limit 1 --window 60 --requests 2
expect_status "17: connection refused exits 1" 1
expect_out "17: transport failure names curl" "curl exit"

empty_path="$work_tmp/nocurl"
mkdir -p "$empty_path"
bash_bin="$(command -v bash)"
out="$(PATH="$empty_path" "$bash_bin" "$check_script" --base-url https://example.com \
  --limit 1 --window 60 2>"$err_file")"
status=$?
err="$(cat "$err_file")"
expect_status "18: missing curl exits 3" 3
expect_err "18: missing curl is named" "curl is required"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -ne 0 ]; then
  exit 1
fi
exit 0
