#!/usr/bin/env bash
# Tests for scripts/agy-docs-launch.sh with the shared settings library.
# A temp HOME holds $HOME/agy-work and $HOME/agy-inbox, and a stub agy on PATH
# records its argv. Failure fixtures run a copy of the launcher whose template
# is replaced, so the real launch path is exercised end to end. No real agy
# process runs and no global Antigravity settings are touched.
set -u

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"

pass=0
fail=0
work_tmp="$(mktemp -d)"
err_file="$work_tmp/stderr"
: >"$err_file"

out=""
err=""
status=0
argv_file=""

trap 'rm -rf "$work_tmp"' EXIT

unset AGY_DOCS_MODEL AGY_MODEL

test_home="$work_tmp/home"
mkdir -p "$test_home/agy-work" "$test_home/agy-inbox"

checkout="$test_home/agy-work/repo"
mkdir -p "$checkout"
printf 'repo readme\n' >"$checkout/README.md"
checkout_real="$(cd "$checkout" && pwd -P)"

other="$test_home/agy-work/other-repo"
mkdir -p "$other"
other_real="$(cd "$other" && pwd -P)"

inbox_real="$(cd "$test_home/agy-inbox" && pwd -P)"
brief="$test_home/agy-inbox/brief.txt"
printf 'Update the docs.\n' >"$brief"

# Copy of the scripts tree; each failure fixture rewrites its template.
copy_root="$work_tmp/kit"
mkdir -p "$copy_root/scripts/lib" "$copy_root/scripts/templates" \
  "$copy_root/scripts/agents/agy"
cp "$repo_root/scripts/agy-docs-launch.sh" "$copy_root/scripts/"
cp "$repo_root/scripts/agents/agy/run" "$copy_root/scripts/agents/agy/"
cp "$repo_root/scripts/lib/agy-settings-check.sh" "$copy_root/scripts/lib/"
cp "$repo_root/scripts/lib/launch-run.sh" "$copy_root/scripts/lib/"
cp "$repo_root/scripts/lib/agy-launch-run.sh" "$copy_root/scripts/lib/"
copy_template="$copy_root/scripts/templates/agy-docs-settings.json"

fake_bin="$work_tmp/bin"
mkdir -p "$fake_bin"
cat >"$fake_bin/agy" <<'SH'
#!/usr/bin/env bash
set -u
n=0
if [ -n "${FAKE_AGY_LAUNCHES:-}" ]; then
  if [ -f "$FAKE_AGY_LAUNCHES" ]; then
    n="$(tr -d '[:space:]' <"$FAKE_AGY_LAUNCHES" || true)"
    case "$n" in
      '' | *[!0-9]*) n=0 ;;
    esac
  fi
  n=$((n + 1))
  printf '%s\n' "$n" >"$FAKE_AGY_LAUNCHES"
fi
{
  printf 'ARGV_START\n'
  for arg in "$@"; do
    printf '%s\n' "$arg"
  done
  printf 'ARGV_END\n'
} >"$FAKE_AGY_ARGV"
if [ -n "${FAKE_AGY_ARGV_ALL:-}" ]; then
  {
    printf 'ARGV_START\n'
    for arg in "$@"; do
      printf '%s\n' "$arg"
    done
    printf 'ARGV_END\n'
  } >>"$FAKE_AGY_ARGV_ALL"
fi
if [ "${FAKE_AGY_STALL:-}" = 1 ] || { [ "${FAKE_AGY_STALL_FIRST:-}" = 1 ] && [ "$n" -eq 1 ]; }; then
  trap 'exit 0' TERM INT HUP
  while true; do
    sleep 1
  done
fi
if [ "${FAKE_AGY_EMPTY_FIRST:-}" = 1 ] && [ "$n" -eq 1 ]; then
  exit 0
fi
if [ "${FAKE_AGY_AUTODENY:-}" = 1 ] || { [ "${FAKE_AGY_AUTODENY_FIRST:-}" = 1 ] && [ "$n" -eq 1 ]; }; then
  printf 'no output produced — a tool required the "command" permission that headless mode cannot prompt for, so it was auto-denied.\n' >&2
  exit 0
fi
if [ "${FAKE_AGY_EMPTY:-}" = 1 ]; then
  exit 0
fi
# Non-empty stdout so a successful first run is not retried.
printf 'docs output\n'
SH
chmod +x "$fake_bin/agy"

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

expect_out() {
  case "$out" in
    *"$2"*) ok "$1" ;;
    *) bad "$1" "stdout missing: $2" ;;
  esac
}

expect_err() {
  case "$err" in
    *"$2"*) ok "$1" ;;
    *) bad "$1" "stderr missing: $2; got: $err" ;;
  esac
}

expect_jq() {
  local got
  got="$(jq -r "$3" "$2" 2>/dev/null)"
  if [ "$got" = "$4" ]; then
    ok "$1"
  else
    bad "$1" "expected [$4], got [$got]"
  fi
}

expect_no_file() {
  if [ -e "$2" ] || [ -L "$2" ]; then
    bad "$1" "file should not exist: $2"
  else
    ok "$1"
  fi
}

expect_argv_pair() {
  if grep -x -A1 -- "$2" "$argv_file" 2>/dev/null | grep -qxF -- "$3"; then
    ok "$1"
  else
    bad "$1" "argv has no pair $2 $3"
  fi
}

expect_argv_absent() {
  if grep -qxF -- "$2" "$argv_file" 2>/dev/null; then
    bad "$1" "argv should not contain: $2"
  else
    ok "$1"
  fi
}

expect_not_started() {
  sleep 0.2
  if [ -s "$argv_file" ]; then
    bad "$1" "stub recorded argv"
  else
    ok "$1"
  fi
}

wait_for_file() {
  local i=0
  while [ ! -s "$1" ] && [ "$i" -lt 100 ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "$1" ]
}

# run_launcher <tag> <launcher> [args...]
run_launcher() {
  local tag="$1"
  local launcher="$2"
  shift 2
  argv_file="$work_tmp/argv-$tag"
  launch_file="$work_tmp/launches-$tag"
  argv_all="$work_tmp/argv-all-$tag"
  : >"$argv_file"
  : >"$launch_file"
  : >"$argv_all"
  : >"$err_file"
  out="$(HOME="$test_home" PATH="$fake_bin:$PATH" FAKE_AGY_ARGV="$argv_file" \
    FAKE_AGY_ARGV_ALL="$argv_all" FAKE_AGY_LAUNCHES="$launch_file" \
    FAKE_AGY_EMPTY="${FAKE_AGY_EMPTY:-}" \
    FAKE_AGY_EMPTY_FIRST="${FAKE_AGY_EMPTY_FIRST:-}" \
    FAKE_AGY_AUTODENY="${FAKE_AGY_AUTODENY:-}" \
    FAKE_AGY_AUTODENY_FIRST="${FAKE_AGY_AUTODENY_FIRST:-}" \
    FAKE_AGY_STALL="${FAKE_AGY_STALL:-}" \
    FAKE_AGY_STALL_FIRST="${FAKE_AGY_STALL_FIRST:-}" \
    AGY_LAUNCH_STALL_SECONDS="${AGY_LAUNCH_STALL_SECONDS:-}" \
    bash "$launcher" "$@" 2>"$err_file")"
  status=$?
  err="$(cat "$err_file")"
}

launch_count() {
  local file="$1"
  local n=0
  if [ -f "$file" ]; then
    n="$(tr -d '[:space:]' <"$file" || true)"
    case "$n" in
      '' | *[!0-9]*) n=0 ;;
    esac
  fi
  printf '%s\n' "$n"
}

expect_launches() {
  local got
  got="$(launch_count "$launch_file")"
  if [ "$got" = "$2" ]; then
    ok "$1"
  else
    bad "$1" "expected $2 launches, got $got"
  fi
}

expect_file() {
  if [ -f "$2" ]; then
    ok "$1"
  else
    bad "$1" "missing file: $2"
  fi
}

build_path_hiding() {
  local dest="$1"
  local cmd path
  mkdir -p "$dest"
  for cmd in bash jq tr mkdir kill cp mv cat uname mktemp sed wc rm ln \
    readlink realpath dirname basename chmod date head env nohup tee cut \
    sort uniq touch sleep grep; do
    path="$(command -v "$cmd" 2>/dev/null)" || continue
    case "$path" in
      '' | */agy | */caffeinate) continue ;;
    esac
    rm -f "$dest/$cmd"
    ln -s "$path" "$dest/$cmd"
  done
}

write_uname_stub() {
  local dest="$1"
  local os="$2"
  local real_uname
  real_uname="$(command -v uname)"
  rm -f "$dest/uname"
  cat >"$dest/uname" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = "-s" ]; then
  printf '%s\n' "$os"
  exit 0
fi
exec $(printf '%q' "$real_uname") "\$@"
SH
  chmod +x "$dest/uname"
}

write_caffeinate_stub() {
  local dest="$1"
  rm -f "$dest/caffeinate"
  cat >"$dest/caffeinate" <<'SH'
#!/usr/bin/env bash
set -u
if [ -n "${FAKE_CAFFEINATE_ARGV:-}" ]; then
  {
    printf 'CAFFEINATE_START\n'
    for arg in "$@"; do
      printf '%s\n' "$arg"
    done
    printf 'CAFFEINATE_END\n'
  } >>"$FAKE_CAFFEINATE_ARGV"
fi
wait_pid=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -t)
      shift
      [ "$#" -gt 0 ] && shift
      ;;
    -w)
      shift
      if [ "$#" -gt 0 ]; then
        wait_pid="$1"
        shift
      fi
      ;;
    -*)
      shift
      ;;
    *)
      break
      ;;
  esac
done
if [ "$#" -eq 0 ]; then
  trap 'exit 0' TERM INT HUP
  if [ -n "$wait_pid" ]; then
    while kill -0 "$wait_pid" 2>/dev/null; do
      sleep 0.1
    done
    exit 0
  fi
  while true; do
    sleep 1
  done
fi
exec "$@"
SH
  chmod +x "$dest/caffeinate"
}

run_launcher_on_path() {
  local tag="$1"
  local extra_bin="$2"
  local rest_path="$3"
  local launcher="$4"
  shift 4
  argv_file="$work_tmp/argv-$tag"
  launch_file="$work_tmp/launches-$tag"
  argv_all="$work_tmp/argv-all-$tag"
  caffeinate_argv="$work_tmp/caffeinate-$tag"
  : >"$argv_file"
  : >"$launch_file"
  : >"$argv_all"
  : >"$err_file"
  : >"$caffeinate_argv"
  if [ -n "$rest_path" ]; then
    launcher_path="$extra_bin:$fake_bin:$rest_path"
  else
    launcher_path="$extra_bin:$fake_bin"
  fi
  out="$(HOME="$test_home" PATH="$launcher_path" \
    FAKE_AGY_ARGV="$argv_file" FAKE_AGY_ARGV_ALL="$argv_all" \
    FAKE_AGY_LAUNCHES="$launch_file" \
    FAKE_CAFFEINATE_ARGV="$caffeinate_argv" \
    FAKE_AGY_EMPTY="${FAKE_AGY_EMPTY:-}" \
    FAKE_AGY_EMPTY_FIRST="${FAKE_AGY_EMPTY_FIRST:-}" \
    FAKE_AGY_AUTODENY="${FAKE_AGY_AUTODENY:-}" \
    FAKE_AGY_AUTODENY_FIRST="${FAKE_AGY_AUTODENY_FIRST:-}" \
    FAKE_AGY_STALL="${FAKE_AGY_STALL:-}" \
    FAKE_AGY_STALL_FIRST="${FAKE_AGY_STALL_FIRST:-}" \
    AGY_LAUNCH_STALL_SECONDS="${AGY_LAUNCH_STALL_SECONDS:-}" \
    bash "$launcher" "$@" 2>"$err_file")"
  status=$?
  err="$(cat "$err_file")"
}

# write_template <allow-entry>: one write_file entry plus a read-only command.
write_template() {
  printf '{"permissions": {"allow": ["%s", "command(ls)"]}}\n' "$1" >"$copy_template"
}

launcher="$repo_root/scripts/agy-docs-launch.sh"
settings="$inbox_real/brief.settings.json"

printf '== happy path ==\n'

run_launcher happy "$launcher" repo "$brief"
expect_status "1: launch exits 0" 0
expect_launches "1: default stub launches once" 1
expect_jq "1: write_file allows only the resolved checkout" \
  "$settings" '.permissions.allow[0]' "write_file($checkout_real)"
expect_jq "1: template keeps the seven read-only commands" \
  "$settings" '[.permissions.allow[] | select(startswith("command("))] | length' "7"
wait_for_file "$argv_file"
expect_argv_pair "1: --settings points at the generated file" "--settings" "$settings"
expect_argv_pair "1: --project is the checkout" "--project" "$test_home/agy-work/repo"
expect_argv_pair "1: default model is unchanged" "--model" "gemini-3.8-flash-medium"
expect_argv_pair "1: brief is passed with -p" "-p" "Update the docs."
expect_argv_absent "1: no --dangerously-skip-permissions" "--dangerously-skip-permissions"
expect_out "1: prints AGY_PID" "AGY_PID="
expect_out "1: prints SETTINGS" "SETTINGS=$settings"
expect_out "1: prints MODEL" "MODEL=gemini-3.8-flash-medium"
expect_out "1: prints PID_FILE" "PID_FILE=$test_home/agy-inbox/brief.pid"
expect_no_file "1: no settings file inside the checkout" "$checkout/settings.json"
leftover="$(find "$inbox_real" -name '.agy-settings.*' | head -n 1)"
if [ -z "$leftover" ]; then
  ok "1: no settings temp file left in the inbox"
else
  bad "1: no settings temp file left in the inbox" "found $leftover"
fi

printf '== stale settings are regenerated ==\n'

printf '{"permissions": {"allow": ["write_file(%s)"]}}\n' "$other_real" >"$settings"
rm -f "$test_home/agy-inbox/brief.pid"
run_launcher stale "$launcher" repo "$brief"
expect_status "2: relaunch exits 0" 0
wait_for_file "$argv_file"
expect_jq "2: stale allow path is replaced" \
  "$settings" '.permissions.allow[0]' "write_file($checkout_real)"

printf '== stem and model arguments stay compatible ==\n'

run_launcher compat "$launcher" repo "$brief" custom-stem gemini-test-model
expect_status "3: stem and model launch exits 0" 0
wait_for_file "$argv_file"
expect_argv_pair "3: 4th argument sets the model" "--model" "gemini-test-model"
expect_argv_pair "3: stem names the settings file" "--settings" "$inbox_real/custom-stem.settings.json"
expect_out "3: stem names the PID file" "PID_FILE=$test_home/agy-inbox/custom-stem.pid"

printf '== allow paths outside the checkout fail ==\n'

copy_launcher="$copy_root/scripts/agy-docs-launch.sh"

write_template "write_file($other_real)"
run_launcher other "$copy_launcher" repo "$brief" other-case
expect_status "4: allow path at another checkout exits 1" 1
expect_err "4: message names the entry" "write_file($other_real)"
expect_err "4: message says outside the checkout" "resolves to $other_real outside run folder $checkout_real"
expect_err "4: launch is refused" "settings check failed; not launching"
expect_not_started "4: agy does not start"
expect_no_file "4: no PID file written" "$test_home/agy-inbox/other-case.pid"

write_template "write_file(@RUN_DIR@/../other-repo)"
run_launcher dotdot "$copy_launcher" repo "$brief" dotdot-case
expect_status "5: .. escape exits 1" 1
expect_err "5: message names the .. entry" "write_file($checkout_real/../other-repo)"
expect_err "5: message says outside the checkout" "outside run folder $checkout_real"
expect_not_started "5: agy does not start"

ln -s "$other" "$checkout/link-out"
write_template "write_file(@RUN_DIR@/link-out)"
run_launcher symlink "$copy_launcher" repo "$brief" symlink-case
expect_status "6: symlink escape exits 1" 1
expect_err "6: message names the symlink entry" "write_file($checkout_real/link-out)"
expect_err "6: message shows the resolved target" "resolves to $other_real outside run folder $checkout_real"
expect_not_started "6: agy does not start"
rm -f "$checkout/link-out"

write_template "write_file(@RUN_DIR@/docs/*)"
run_launcher glob "$copy_launcher" repo "$brief" glob-case
expect_status "7: wildcard entry exits 1" 1
expect_err "7: wildcard is explained" "uses a wildcard"
expect_not_started "7: agy does not start"

printf '{not json\n' >"$copy_template"
run_launcher badjson "$copy_launcher" repo "$brief" badjson-case
expect_status "8: invalid template exits 1" 1
expect_err "8: invalid JSON is named" "generated settings is not valid JSON"
expect_not_started "8: agy does not start"
expect_no_file "8: no settings file left behind" "$inbox_real/badjson-case.settings.json"

printf '== symlinked settings file is refused ==\n'

link_target="$work_tmp/outside-settings"
printf 'outside target\n' >"$link_target"
ln -s "$link_target" "$test_home/agy-inbox/linked.settings.json"
run_launcher linked "$launcher" repo "$brief" linked
expect_status "9: symlinked settings file exits 1" 1
expect_err "9: refusal is explained" "refusing symlinked settings file"
if [ "$(cat "$link_target")" = "outside target" ]; then
  ok "9: symlink target is unchanged"
else
  bad "9: symlink target is unchanged" "target content changed"
fi
expect_not_started "9: agy does not start"

printf '== unusual checkout names ==\n'

amp="$test_home/agy-work/a&b|c"
mkdir -p "$amp"
amp_real="$(cd "$amp" && pwd -P)"
run_launcher amp "$launcher" 'a&b|c' "$brief" amp-case
expect_status "12: checkout with & and | launches" 0
expect_jq "12: & and | survive substitution" \
  "$inbox_real/amp-case.settings.json" '.permissions.allow[0]' "write_file($amp_real)"
wait_for_file "$argv_file"

mkdir -p "$test_home/agy-work/q\"x"
run_launcher quote "$launcher" 'q"x' "$brief" quote-case
expect_status "13: checkout with a quote exits 1" 1
expect_err "13: quote refusal is explained" "refusing run folder path with a quote"
expect_not_started "13: agy does not start"
expect_no_file "13: no settings file written" "$inbox_real/quote-case.settings.json"

ln -s "$other" "$test_home/agy-work/linked-repo"
run_launcher linkrepo "$launcher" linked-repo "$brief" linkrepo-case
expect_status "14: symlinked checkout exits 1" 1
expect_err "14: symlinked checkout is named" "refusing symlinked checkout"
expect_not_started "14: agy does not start"

printf '== symlinked PID and log files are refused ==\n'

for suffix in .pid -stdout.log -stderr.log; do
  slug="sym${suffix//./-}"
  target="$work_tmp/target$slug"
  printf 'outside target\n' >"$target"
  ln -s "$target" "$test_home/agy-inbox/$slug$suffix"
  run_launcher "$slug" "$launcher" repo "$brief" "$slug"
  expect_status "15: symlinked $suffix exits 1" 1
  expect_err "15: symlinked $suffix is named" "refusing symlinked $slug$suffix"
  if [ "$(cat "$target")" = "outside target" ]; then
    ok "15: symlinked $suffix target is unchanged"
  else
    bad "15: symlinked $suffix target is unchanged" "target content changed"
  fi
  expect_not_started "15: symlinked $suffix does not start agy"
done

printf '== a live run keeps its settings ==\n'

printf '{"keep": true}\n' >"$inbox_real/live.settings.json"
printf '%s\n' "$$" >"$test_home/agy-inbox/live.pid"
run_launcher live "$launcher" repo "$brief" live
expect_status "16: live PID exits 1" 1
expect_err "16: live PID is named" "is still running"
expect_jq "16: settings of the live run are untouched" \
  "$inbox_real/live.settings.json" '.keep' "true"
rm -f "$test_home/agy-inbox/live.pid"

printf '== the shared check refuses a symlinked settings file ==\n'

ln -s "$inbox_real/brief.settings.json" "$work_tmp/linked-check.json"
check_err="$(bash -c '. "$1"; agy_settings_check "$2" "$3"' _ \
  "$repo_root/scripts/lib/agy-settings-check.sh" "$work_tmp/linked-check.json" "$checkout" 2>&1)"
check_status=$?
if [ "$check_status" -eq 1 ]; then
  ok "17: symlinked settings file fails the check"
else
  bad "17: symlinked settings file fails the check" "exit $check_status"
fi
case "$check_err" in
  *"refusing symlinked settings file"*) ok "17: refusal is explained" ;;
  *) bad "17: refusal is explained" "got: $check_err" ;;
esac

printf '== caffeinate wrapper, empty-output retry, auto-deny, and stall ==\n'

darwin_bin="$work_tmp/darwin-bin"
mkdir -p "$darwin_bin"
write_uname_stub "$darwin_bin" Darwin
write_caffeinate_stub "$darwin_bin"

hidden_bin="$work_tmp/hidden-bin"
build_path_hiding "$hidden_bin"
write_uname_stub "$hidden_bin" Darwin

unset FAKE_AGY_EMPTY FAKE_AGY_EMPTY_FIRST FAKE_AGY_AUTODENY FAKE_AGY_AUTODENY_FIRST
unset FAKE_AGY_STALL FAKE_AGY_STALL_FIRST
run_launcher_on_path cafe-present "$darwin_bin" "$PATH" "$launcher" repo "$brief" cafe-present
expect_status "18: caffeinate present exits 0" 0
expect_launches "18: caffeinate present launches once" 1
if grep -q -F 'holding idle-sleep assertion with caffeinate -i' "$inbox_real/cafe-present-stderr.log"; then
  ok "18: wrapper holds a caffeinate -i idle-sleep assertion"
else
  bad "18: wrapper holds a caffeinate -i idle-sleep assertion" "stderr log: $(tr '\n' ' ' <"$inbox_real/cafe-present-stderr.log")"
fi

unset FAKE_AGY_EMPTY FAKE_AGY_EMPTY_FIRST
run_launcher_on_path cafe-absent "$fake_bin" "$hidden_bin" "$launcher" repo "$brief" cafe-absent
expect_status "19: caffeinate absent exits 0" 0
expect_launches "19: caffeinate absent launches once" 1
if [ -s "$caffeinate_argv" ]; then
  bad "19: caffeinate absent does not invoke caffeinate" "argv: $(tr '\n' ' ' <"$caffeinate_argv")"
else
  ok "19: caffeinate absent does not invoke caffeinate"
fi

FAKE_AGY_EMPTY_FIRST=1
unset FAKE_AGY_EMPTY
run_launcher_on_path empty-then-ok "$darwin_bin" "$PATH" "$launcher" repo "$brief" empty-then-ok
unset FAKE_AGY_EMPTY_FIRST
expect_status "20: empty then non-empty exits 0" 0
expect_launches "20: empty then non-empty launches twice" 2
expect_err "20: empty then non-empty mentions the retry" "empty stdout log"
if printf '%s' "$err" | grep -q 'giving up\|automatic retry also failed'; then
  bad "20: empty then non-empty does not give up" "stderr: $err"
else
  ok "20: empty then non-empty does not give up"
fi
expect_file "20: first empty log is preserved" "$inbox_real/empty-then-ok-stdout.log.attempt1"
if [ -s "$inbox_real/empty-then-ok-stdout.log" ]; then
  ok "20: second stdout log is non-empty"
else
  bad "20: second stdout log is non-empty" "missing or empty"
fi
if [ -e "$inbox_real/empty-then-ok.retry-brief.txt" ]; then
  bad "20: empty retry does not write a retry brief" "retry brief exists"
else
  ok "20: empty retry does not write a retry brief"
fi
if grep -q -F 'use simple commands one at a time' "$brief"; then
  bad "20: original brief is not mutated on empty retry" "brief was appended to"
else
  ok "20: original brief is not mutated on empty retry"
fi

FAKE_AGY_EMPTY=1
unset FAKE_AGY_EMPTY_FIRST
run_launcher_on_path both-empty "$darwin_bin" "$PATH" "$launcher" repo "$brief" both-empty
unset FAKE_AGY_EMPTY
expect_status "21: both empty exits 1" 1
expect_launches "21: both empty launches twice" 2
expect_err "21: both empty mentions the retry" "retrying once"
expect_err "21: both empty fails closed after retry" "automatic retry also failed"
expect_err "21: both empty asks the operator" "ask the operator"
expect_err "21: both empty does not suggest widening allow" "Do not add allow-rules"

FAKE_AGY_AUTODENY_FIRST=1
unset FAKE_AGY_AUTODENY FAKE_AGY_EMPTY FAKE_AGY_EMPTY_FIRST
run_launcher_on_path deny-then-ok "$darwin_bin" "$PATH" "$launcher" repo "$brief" deny-then-ok
unset FAKE_AGY_AUTODENY_FIRST
expect_status "22: auto-deny then non-empty exits 0" 0
expect_launches "22: auto-deny then non-empty launches twice" 2
expect_err "22: auto-deny then non-empty mentions auto-deny" "headless auto-deny"
expect_file "22: retry brief is written under the inbox" "$inbox_real/deny-then-ok.retry-brief.txt"
if grep -q -F 'use simple commands one at a time; no pipes, no redirects, no regex special characters.' "$inbox_real/deny-then-ok.retry-brief.txt"; then
  ok "22: retry brief has the simpler-commands instruction"
else
  bad "22: retry brief has the simpler-commands instruction" "missing instruction"
fi
if grep -q -F 'use simple commands one at a time' "$brief"; then
  bad "22: original brief is not mutated" "brief was appended to"
else
  ok "22: original brief is not mutated"
fi

FAKE_AGY_STALL_FIRST=1
unset FAKE_AGY_STALL
AGY_LAUNCH_STALL_SECONDS=2
run_launcher_on_path stall-then-ok "$darwin_bin" "$PATH" "$launcher" repo "$brief" stall-then-ok
unset FAKE_AGY_STALL_FIRST
unset AGY_LAUNCH_STALL_SECONDS
expect_status "23: stall then non-empty exits 0" 0
expect_launches "23: stall then non-empty launches twice" 2
expect_err "23: stall then non-empty mentions the stall" "no log growth"
expect_file "23: stall retry writes a retry brief" "$inbox_real/stall-then-ok.retry-brief.txt"
if grep -q -F 'use simple commands one at a time' "$brief"; then
  bad "23: stall retry does not mutate the original brief" "brief was appended to"
else
  ok "23: stall retry does not mutate the original brief"
fi

printf '== usage stays the same ==\n'

run_launcher usage-one "$launcher" repo
expect_status "10: one argument exits 2" 2
run_launcher usage-five "$launcher" repo "$brief" a b c
expect_status "10: five arguments exit 2" 2
run_launcher usage-slash "$launcher" a/b "$brief"
expect_status "10: repo with a slash exits 2" 2

printf '== agents never touch global settings ==\n'

for name in .gemini .antigravity .agy .config; do
  if [ -e "$test_home/$name" ]; then
    bad "11: temp HOME has no $name" "$test_home/$name exists"
  else
    ok "11: temp HOME has no $name"
  fi
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -ne 0 ]; then
  exit 1
fi
exit 0
