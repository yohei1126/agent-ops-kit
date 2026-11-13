#!/usr/bin/env bash
# Tests for the deploy-hash named check. No network: a fake curl on PATH serves
# fixture responses from a sequence file and records its argv.
set -u

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
gate="$repo_root/scripts/dev-loop-gate.sh"
fixtures="$repo_root/scripts/tests/fixtures/deploy-hash"

pass=0
fail=0
work_tmp="$(mktemp -d)"
err_file="$work_tmp/stderr"
: > "$err_file"

out=""
err=""
status=0

trap 'rm -rf "$work_tmp"' EXIT

unset DEV_LOOP_BRANCH DEV_LOOP_ALIAS DEV_LOOP_REQUIRED_PATH \
  DEV_LOOP_SOFT_DENY_COUNT DEV_LOOP_MODEL_LANE DEV_LOOP_DIFF_KIND \
  DEV_LOOP_PR_STATE DEV_LOOP_OPERATOR_READY DEV_LOOP_VULN_SILENT \
  DEV_LOOP_RETRO_MARKER DEV_LOOP_OPEN_JOBS DEV_LOOP_OPEN_PRS

fake_home="$work_tmp/home"
mkdir -p "$fake_home"

fake_bin="$work_tmp/bin"
mkdir -p "$fake_bin"
sequence_file="$work_tmp/sequence"
count_file="$work_tmp/count"
argv_log="$work_tmp/argv"

cat > "$fake_bin/curl" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FAKE_CURL_ARGV"
count=0
if [ -f "$FAKE_CURL_COUNT" ]; then
  count="$(cat "$FAKE_CURL_COUNT")"
fi
count=$((count + 1))
printf '%s\n' "$count" > "$FAKE_CURL_COUNT"
line="$(sed -n "${count}p" "$FAKE_CURL_SEQUENCE")"
if [ -z "$line" ]; then
  line="$(tail -n 1 "$FAKE_CURL_SEQUENCE")"
fi
if [ "$line" = "FAIL" ]; then
  exit 22
fi
cat "$line"
SH
chmod +x "$fake_bin/curl"

# The repository pins Node 22. A stub Node that matches the pin keeps the
# no-argument table stable on a machine with another Node major.
cat > "$fake_bin/node" <<'SH'
#!/usr/bin/env bash
printf 'v22.11.0\n'
SH
chmod +x "$fake_bin/node"

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
    bad "$1" "expected exit $2, got $status; stderr: $err"
  fi
}

expect_eq() {
  if [ "$out" = "$2" ]; then
    ok "$1"
  else
    bad "$1" "expected [$2], got [$out]"
  fi
}

expect_regex() {
  if printf '%s\n' "$out" | grep -Eq "$2"; then
    ok "$1"
  else
    bad "$1" "stdout missing line matching: $2; got [$out]"
  fi
}

expect_no_out() {
  case "$out" in
    *"$2"*) bad "$1" "stdout should not contain: $2" ;;
    *) ok "$1" ;;
  esac
}

expect_err() {
  case "$err" in
    *"$2"*) ok "$1" ;;
    *) bad "$1" "stderr missing: $2; got [$err]" ;;
  esac
}

expect_count() {
  local seen
  seen="$(cat "$count_file" 2>/dev/null)"
  if [ "$seen" = "$2" ]; then
    ok "$1"
  else
    bad "$1" "expected $2 fetches, got $seen"
  fi
}

set_sequence() {
  local item
  : > "$sequence_file"
  for item in "$@"; do
    printf '%s\n' "$item" >> "$sequence_file"
  done
}

run_dh() {
  : > "$err_file"
  : > "$argv_log"
  : > "$count_file"
  out="$(cd "$repo_root" && HOME="$fake_home" PATH="$fake_bin:$PATH" \
    FAKE_CURL_ARGV="$argv_log" \
    FAKE_CURL_COUNT="$count_file" \
    FAKE_CURL_SEQUENCE="$sequence_file" \
    DEV_LOOP_SLEEP_CMD=true \
    bash "$gate" "$@" 2>"$err_file")"
  status=$?
  err="$(cat "$err_file")"
}

v1_asset="assets/app-1a2b3c4d.css"

printf '== print current ==\n'

set_sequence "$fixtures/html-v1.html"
run_dh --check deploy-hash --url https://example.com/ --print-current
expect_status "1: print-current html exits 0" 0
expect_eq "1: print-current html prints the asset" "$v1_asset"
expect_count "1: print-current fetches once" 1

set_sequence "$fixtures/headers-etag-v1.txt"
run_dh --check deploy-hash --url https://example.com/ --source etag --print-current
expect_status "2: print-current etag exits 0" 0
expect_eq "2: print-current etag strips quotes" "etag-v1-0123456789"

set_sequence "$fixtures/weak-etag"
run_dh --check deploy-hash --url https://example.com/ --source etag --print-current
expect_status "3: weak etag exits 0" 0
expect_eq "3: weak etag strips W/ and quotes" "abc"

set_sequence "$fixtures/html-no-bundle.html"
run_dh --check deploy-hash --url https://example.com/ --print-current
expect_status "4: html with no bundle match exits 3" 3
expect_eq "4: html with no bundle match prints nothing" ""

set_sequence FAIL
run_dh --check deploy-hash --url https://example.com/ --print-current
expect_status "5: failed fetch in print mode exits 3" 3

printf '== wait mode ==\n'

set_sequence "$fixtures/html-v1.html" "$fixtures/html-v1.html" "$fixtures/html-v2.html"
run_dh --check deploy-hash --url https://example.com/ \
  --baseline "$v1_asset" --timeout-sec 60 --interval-sec 5
expect_status "6: change on the third poll exits 0" 0
expect_regex "6: change row shows the elapsed sleep" \
  "^DH +deploy-hash +PASS +baseline .* -> current .* after 10s$"
expect_count "6: change on the third poll makes three fetches" 3

set_sequence "$fixtures/html-v1.html"
run_dh --check deploy-hash --url https://example.com/ \
  --baseline "$v1_asset" --timeout-sec 20 --interval-sec 5
expect_status "7: no change at timeout is advisory" 0
expect_regex "7: no change row" \
  "^DH +deploy-hash +FAIL +no change after 20s; do not run the live smoke yet$"
expect_count "7: no change polls until the timeout" 5

run_dh --check deploy-hash --url https://example.com/ \
  --baseline "$v1_asset" --timeout-sec 20 --interval-sec 5 --strict
expect_status "8: no change at timeout fails under strict" 1

set_sequence "$fixtures/html-v1.html"
run_dh --check deploy-hash --url https://example.com/ \
  --baseline "$v1_asset" --timeout-sec 7 --interval-sec 3
expect_status "9: a partial last interval still ends at the timeout" 0
expect_regex "9: elapsed time stops at the timeout" \
  "^DH +deploy-hash +FAIL +no change after 7s; do not run the live smoke yet$"
expect_count "9: a partial last interval adds one fetch" 4

set_sequence "$fixtures/headers-etag-v1.txt" "$fixtures/headers-etag-v2.txt"
run_dh --check deploy-hash --url https://example.com/ --source etag \
  --baseline "etag-v1-0123456789" --timeout-sec 30 --interval-sec 10
expect_status "10: etag change exits 0" 0
expect_regex "10: etag change row" \
  "^DH +deploy-hash +PASS +baseline .* -> current .* after 10s$"

set_sequence "$fixtures/weak-etag"
run_dh --check deploy-hash --url https://example.com/ --source etag \
  --baseline "abc" --timeout-sec 10 --interval-sec 5
expect_status "11: weak etag normalised baseline keeps waiting" 0
expect_regex "11: weak etag no change row" \
  "^DH +deploy-hash +FAIL +no change after 10s; do not run the live smoke yet$"

printf '== fetch failures ==\n'

set_sequence "$fixtures/html-no-bundle.html"
run_dh --check deploy-hash --url https://example.com/ \
  --baseline "$v1_asset" --timeout-sec 10 --interval-sec 5
expect_status "12: html without a bundle match fails advisory" 0
expect_regex "12: html without a bundle match reports a fetch failure" \
  "^DH +deploy-hash +FAIL +fetch failed after 10s; source html returned an error; do not run the live smoke yet$"
expect_no_out "12: failure row dumps no page body" "DOCTYPE"
expect_count "12: html without a bundle match polls until the timeout" 3

set_sequence FAIL
run_dh --check deploy-hash --url https://example.com/ \
  --baseline "$v1_asset" --timeout-sec 10 --interval-sec 5
expect_status "13: every fetch failing is advisory" 0
expect_regex "13: every fetch failing reports the reason" \
  "^DH +deploy-hash +FAIL +fetch failed after 10s; source html returned an error; do not run the live smoke yet$"

run_dh --check deploy-hash --url https://example.com/ \
  --baseline "$v1_asset" --timeout-sec 10 --interval-sec 5 --strict
expect_status "13: every fetch failing exits 1 under strict" 1

printf '== usage errors ==\n'

run_dh --check deploy-hash
expect_status "14: missing --url exits 2" 2
expect_err "14: missing --url names the flag" "--url is required"

run_dh --check deploy-hash --url https://example.com/
expect_status "14: missing --baseline exits 2" 2
expect_err "14: missing --baseline names the flag" "--baseline is required"

run_dh --check deploy-hash --url ""
expect_status "14: empty --url exits 2" 2
expect_err "14: empty --url names the scheme" "--url must start with https:// or http://"

run_dh --check deploy-hash --url=
expect_status "14: empty --url= exits 2" 2
expect_err "14: empty --url= names the scheme" "--url must start with https:// or http://"

run_dh --check deploy-hash --url
expect_status "14: --url without a value exits 2" 2

run_dh --check deploy-hash --url ftp://example.com/
expect_status "14: non-http scheme exits 2" 2
expect_err "14: non-http scheme names the scheme" "--url must start with https:// or http://"

run_dh --check deploy-hash --url https://example.com/ --baseline ""
expect_status "14: empty --baseline exits 2" 2
expect_err "14: empty --baseline names the flag" "--baseline needs a non-empty value"

run_dh --check deploy-hash --url https://example.com/ --timeout-sec abc
expect_status "14: non-numeric timeout exits 2" 2
expect_err "14: non-numeric timeout names the flag" "--timeout-sec needs a positive integer"

run_dh --check deploy-hash --url https://example.com/ --interval-sec 0
expect_status "14: zero interval exits 2" 2
expect_err "14: zero interval names the flag" "--interval-sec needs a positive integer"

run_dh --check deploy-hash --url https://example.com/ --source ""
expect_status "14: empty --source exits 2" 2
expect_err "14: empty --source names the flag" "--source needs a non-empty value"

run_dh --check deploy-hash --url https://example.com/ --source nope --baseline x
expect_status "14: unknown source exits 2" 2
expect_err "14: unknown source names the source" "unknown source: nope"

run_dh --check deploy-hash --url https://example.com/ --bundle-pattern "["
expect_status "14: invalid bundle pattern exits 2" 2
expect_err "14: invalid bundle pattern names the flag" "not a valid ERE"

run_dh --url https://example.com/ --print-current
expect_status "15: deploy-hash flags without --check exit 2" 2
expect_err "15: deploy-hash flags without --check name the check" "deploy-hash flags need --check deploy-hash"

run_dh --check line-cap --url https://example.com/
expect_status "15: deploy-hash flag with another check exits 2" 2
expect_err "15: deploy-hash flag with another check names the check" "deploy-hash flags need --check deploy-hash"

run_dh --print-current
expect_status "15: --print-current alone exits 2" 2
expect_err "15: --print-current alone names the check" "deploy-hash flags need --check deploy-hash"

printf '== curl missing ==\n'

nocurl_bin="$work_tmp/nocurl-bin"
mkdir -p "$nocurl_bin"
ln -s "$(command -v dirname)" "$nocurl_bin/dirname"
bash_bin="$(command -v bash)"
: > "$err_file"
out="$(cd "$repo_root" && HOME="$fake_home" PATH="$nocurl_bin" \
  "$bash_bin" "$gate" --check deploy-hash --url https://example.com/ \
  --print-current 2>"$err_file")"
status=$?
err="$(cat "$err_file")"
expect_status "16: missing curl exits 3" 3

printf '== request shape ==\n'

set_sequence "$fixtures/html-v1.html"
run_dh --check deploy-hash --url https://example.com/ --print-current
if [ -s "$argv_log" ] && ! grep -Eq '(^| )-(u|b)( |$)|--cookie|Authorization|(^| )-H( |$)' "$argv_log"; then
  ok "17: request sends no credentials, cookies, or auth headers"
else
  bad "17: request sends no credentials, cookies, or auth headers" "argv: $(cat "$argv_log")"
fi
if grep -q -- "--max-time 20" "$argv_log"; then
  ok "17: request sets --max-time"
else
  bad "17: request sets --max-time" "argv: $(cat "$argv_log")"
fi

set_sequence "$fixtures/headers-etag-v1.txt"
run_dh --check deploy-hash --url https://example.com/ --source etag --print-current
if grep -q -- "-fsSI" "$argv_log" && grep -q -- "--max-time 20" "$argv_log"; then
  ok "18: etag request is a HEAD request with --max-time"
else
  bad "18: etag request is a HEAD request with --max-time" "argv: $(cat "$argv_log")"
fi

printf '== no-arg table ==\n'

out="$(cd "$repo_root" && PATH="$fake_bin:$PATH" bash "$gate")"
status=$?
err=""
expect_status "19: no-arg table exits 0" 0

expected_table="$(cat <<'TABLE'
Gate Name                           Status Action
---- ------------------------------ ------ ------
G1   checkout + worktree lock       PASS   Continue.
G2   soft-deny                      PASS   Continue.
G3   lock + matching constraint     JUDGE  Argon-need via RUBRIC tier A; not an Argon skip.
G4   draft                          PASS   Continue.
G5   vulnerability silence          PASS   Continue.
G6   RETRO ingest                   QUIET  Stay quiet; v1 silence, no invented retro.
G7   one job                        PASS   Continue.
NM   npm-ci                         SKIP   no package-lock.json; npm is not in use.
NP   node-pin                       PASS   Continue.
TABLE
)"

if [ "$out" = "$expected_table" ]; then
  ok "19: no-arg table output is unchanged"
else
  bad "19: no-arg table output is unchanged" "got [$out]"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -ne 0 ]; then
  exit 1
fi
exit 0
