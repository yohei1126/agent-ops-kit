#!/usr/bin/env bash
# Tests for scripts/agy-review-launch.sh and scripts/lib/agy-settings-check.sh.
# A temp HOME holds the runs root and a stub agy on PATH records its argv.
# No real agy process runs and no global Antigravity settings are touched.
set -u

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
launcher="$repo_root/scripts/agy-review-launch.sh"

pass=0
fail=0
work_tmp="$(mktemp -d)"
err_file="$work_tmp/stderr"
: > "$err_file"

out=""
err=""
status=0
argv_file=""

trap 'rm -rf "$work_tmp"' EXIT

unset AGY_REVIEW_MODEL

test_home="$work_tmp/home"
mkdir -p "$test_home/agy-work"

repo_dir="$test_home/agy-work/repo"
mkdir -p "$repo_dir"
printf 'repo readme\n' > "$repo_dir/README.md"
repo_real="$(cd "$repo_dir" && pwd -P)"

runs_root="$test_home/agy-work/runs"

brief="$work_tmp/brief.md"
printf '# Brief\nRun the review.\n' > "$brief"

fake_bin="$work_tmp/bin"
mkdir -p "$fake_bin"

cat > "$fake_bin/agy" <<'SH'
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
} > "$FAKE_AGY_ARGV"
if [ -n "${FAKE_AGY_ARGV_ALL:-}" ]; then
  {
    printf 'ARGV_START\n'
    for arg in "$@"; do
      printf '%s\n' "$arg"
    done
    printf 'ARGV_END\n'
  } >> "$FAKE_AGY_ARGV_ALL"
fi
if [ "${FAKE_AGY_STALL:-}" = 1 ] || { [ "${FAKE_AGY_STALL_FIRST:-}" = 1 ] && [ "$n" -eq 1 ]; }; then
  # Stay alive without writing logs so the stall fallback can fire.
  # Honours TERM from the launcher watchdog.
  trap 'exit 0' TERM INT HUP
  while true; do
    sleep 1
  done
fi
if [ "${FAKE_AGY_EMPTY_FIRST:-}" = 1 ] && [ "$n" -eq 1 ]; then
  exit 0
fi
if [ "${FAKE_AGY_AUTODENY:-}" = 1 ] || { [ "${FAKE_AGY_AUTODENY_FIRST:-}" = 1 ] && [ "$n" -eq 1 ]; }; then
  printf 'no output produced — a tool required the "command" permission that headless mode cannot prompt for, so it was auto-denied. Add an allow-rule under permissions.allow in settings.json (e.g. command(<target>)). Alternatively, re-run with --dangerously-skip-permissions to auto-approve all tools.\n' >&2
  exit 0
fi
if [ "${FAKE_AGY_EMPTY:-}" = 1 ]; then
  exit 0
fi
# Non-empty stdout so a successful first run is not retried.
printf 'review output\n'
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

expect_no_out() {
  case "$out" in
    *"$2"*) bad "$1" "stdout should not contain: $2" ;;
    *) ok "$1" ;;
  esac
}

expect_err() {
  case "$err" in
    *"$2"*) ok "$1" ;;
    *) bad "$1" "stderr missing: $2; got: $err" ;;
  esac
}

expect_file() {
  if [ -f "$2" ]; then
    ok "$1"
  else
    bad "$1" "missing file: $2"
  fi
}

expect_no_file() {
  if [ -e "$2" ]; then
    bad "$1" "file should not exist: $2"
  else
    ok "$1"
  fi
}

expect_jq() {
  local label="$1"
  local file="$2"
  local filter="$3"
  local want="$4"
  local got
  got="$(jq -r "$filter" "$file" 2>/dev/null)"
  if [ "$got" = "$want" ]; then
    ok "$label"
  else
    bad "$label" "expected [$want], got [$got]"
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

wait_for_file() {
  local file="$1"
  local i=0
  while [ ! -s "$file" ] && [ "$i" -lt 100 ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "$file" ]
}

run_launcher() {
  local tag="$1"
  shift
  argv_file="$work_tmp/argv-$tag"
  launch_file="$work_tmp/launches-$tag"
  : > "$argv_file"
  : > "$launch_file"
  : > "$err_file"
  argv_all="$work_tmp/argv-all-$tag"
  : > "$argv_all"
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

# PATH for tests that must see or hide caffeinate regardless of the host OS.
# $1 is the extra bin directory (uname / caffeinate stubs). $2 is the remainder
# of PATH. An empty $2 means "only the extra bin and the stub agy".
run_launcher_on_path() {
  local tag="$1"
  local extra_bin="$2"
  local rest_path="$3"
  shift 3
  argv_file="$work_tmp/argv-$tag"
  launch_file="$work_tmp/launches-$tag"
  caffeinate_argv="$work_tmp/caffeinate-$tag"
  : > "$argv_file"
  : > "$launch_file"
  : > "$err_file"
  : > "$caffeinate_argv"
  if [ -n "$rest_path" ]; then
    launcher_path="$extra_bin:$fake_bin:$rest_path"
  else
    # Do not append a trailing colon: that would put "." on PATH.
    launcher_path="$extra_bin:$fake_bin"
  fi
  argv_all="$work_tmp/argv-all-$tag"
  : > "$argv_all"
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

# Symlink only the utilities the launcher needs into $1, never agy or
# caffeinate. Used to hide those binaries on Darwin without dropping jq.
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
  cat > "$dest/uname" <<SH
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
  cat > "$dest/caffeinate" <<'SH'
#!/usr/bin/env bash
set -u
if [ -n "${FAKE_CAFFEINATE_ARGV:-}" ]; then
  {
    printf 'CAFFEINATE_START\n'
    for arg in "$@"; do
      printf '%s\n' "$arg"
    done
    printf 'CAFFEINATE_END\n'
  } >> "$FAKE_CAFFEINATE_ARGV"
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

printf '== fresh launch ==\n'

run_launcher fresh run-one "$repo_dir" "$brief"
expect_status "1: fresh launch exits 0" 0
run_one="$runs_root/run-one"
run_one_real="$(cd "$run_one" && pwd -P)"
expect_file "1: settings.json exists" "$run_one/settings.json"
expect_file "1: BRIEF.md copied into the run folder" "$run_one/BRIEF.md"
expect_file "1: agy.pid written" "$run_one/agy.pid"
expect_jq "1: write_file allows only the resolved run dir" \
  "$run_one/settings.json" '.permissions.allow[0]' "write_file($run_one_real)"
expect_jq "1: allow list keeps the seven read-only commands" \
  "$run_one/settings.json" '.permissions.allow | length' "8"
wait_for_file "$argv_file"
expect_argv_pair "1: --settings points at the run settings" \
  "--settings" "$run_one_real/settings.json"
expect_argv_pair "1: --project is the run dir" "--project" "$run_one_real"
expect_argv_pair "1: first --add-dir is the run dir" "--add-dir" "$run_one_real"
expect_argv_pair "1: repo add-dir is the physical checkout" "--add-dir" "$repo_real"
expect_argv_pair "1: launch uses accept-edits mode" "--mode" "accept-edits"
expect_argv_absent "1: no --dangerously-skip-permissions" "--dangerously-skip-permissions"
expect_out "1: prints AGY_PID" "AGY_PID="
expect_out "1: prints RUN_DIR" "RUN_DIR=$run_one_real"
expect_out "1: prints SETTINGS" "SETTINGS=$run_one_real/settings.json"
expect_out "1: prints MODEL" "MODEL=gemini-4-argon-medium"
expect_out "1: prints stdout log path" "STDOUT_LOG=$run_one_real/agy.log"
expect_out "1: prints stderr log path" "STDERR_LOG=$run_one_real/agy.stderr.log"

run_launcher fresh-check --check-settings "$run_one/settings.json" "$run_one"
expect_status "2: generated settings pass --check-settings" 0

printf '== dry run ==\n'

run_launcher dry --dry-run run-dry "$repo_dir" "$brief"
expect_status "3: dry run exits 0" 0
dry_run_dir="$runs_root/run-dry"
dry_real="$(cd "$dry_run_dir" && pwd -P)"
expect_file "3: dry run still generates settings.json" "$dry_run_dir/settings.json"
expect_no_file "3: dry run writes no pid file" "$dry_run_dir/agy.pid"
expect_out "3: dry run prints the command" "AGY_COMMAND="
case "$out" in
  *'AGY_COMMAND='*'agy '*) ok "3: dry run command includes agy" ;;
  *) bad "3: dry run command includes agy" "stdout: $out" ;;
esac
expect_out "3: dry run prints RUN_DIR" "RUN_DIR=$dry_real"
expect_no_out "3: dry run prints no AGY_PID" "AGY_PID="
if [ -s "$argv_file" ]; then
  bad "3: dry run does not start the stub agy" "stub recorded argv"
else
  ok "3: dry run does not start the stub agy"
fi

printf '== stale settings are regenerated ==\n'

stale_run="$runs_root/run-stale"
mkdir -p "$stale_run"
printf 'staged brief\n' > "$stale_run/BRIEF.md"
printf 'staged diff\n' > "$stale_run/DIFF.patch"
old_run="$runs_root/old-run"
mkdir -p "$old_run"
printf '{"permissions": {"allow": ["write_file(%s)"]}}\n' "$old_run" > "$stale_run/settings.json"

run_launcher stale run-stale "$repo_dir" "$stale_run/BRIEF.md"
expect_status "4: pre-existing run folder relaunches" 0
stale_real="$(cd "$stale_run" && pwd -P)"
expect_jq "4: write_file now allows the current run dir" \
  "$stale_run/settings.json" '.permissions.allow[0]' "write_file($stale_real)"
if grep -qF -- "$old_run" "$stale_run/settings.json"; then
  bad "4: stale settings no longer mention the old run" "old run path still present"
else
  ok "4: stale settings no longer mention the old run"
fi
expect_out "4: staged BRIEF.md is kept in place" "RUN_DIR=$stale_real"
if [ "$(cat "$stale_run/BRIEF.md")" = "staged brief" ]; then
  ok "4: staged BRIEF.md content is not overwritten"
else
  bad "4: staged BRIEF.md content is not overwritten" "brief content changed"
fi
wait_for_file "$argv_file"
expect_argv_pair "4: relaunch uses the regenerated settings" \
  "--settings" "$stale_real/settings.json"

printf '== pre-launch check fixtures ==\n'

current_run="$runs_root/current-run"
mkdir -p "$current_run"
current_real="$(cd "$current_run" && pwd -P)"
old_real="$(cd "$old_run" && pwd -P)"

fixture_other="$work_tmp/fixture-other.json"
printf '{"permissions": {"allow": ["write_file(%s)", "command(ls)"]}}\n' \
  "$old_run" > "$fixture_other"
run_launcher check-other --check-settings "$fixture_other" "$current_run"
expect_status "5: write_file at another run folder exits 1" 1
expect_err "5: message names the offending entry" "write_file($old_run)"
expect_err "5: message explains the resolved path" "resolves to $old_real outside run folder $current_real"

fixture_dotdot="$work_tmp/fixture-dotdot.json"
printf '{"permissions": {"allow": ["write_file(%s/../old-run)"]}}\n' \
  "$current_run" > "$fixture_dotdot"
run_launcher check-dotdot --check-settings "$fixture_dotdot" "$current_run"
expect_status "6: write_file escaping via .. exits 1" 1
expect_err "6: message names the .. entry" "write_file($current_run/../old-run)"

mkdir -p "$work_tmp/outside"
ln -s "$work_tmp/outside" "$current_run/link-out"
fixture_symlink="$work_tmp/fixture-symlink.json"
printf '{"permissions": {"allow": ["write_file(%s)", "command(pwd)"]}}\n' \
  "$current_run/link-out" > "$fixture_symlink"
run_launcher check-symlink --check-settings "$fixture_symlink" "$current_run"
expect_status "7: write_file through a symlink pointing outside exits 1" 1
expect_err "7: message names the symlink entry" "write_file($current_run/link-out)"

mkdir -p "$current_run/link-in"
ln -s "$current_run/link-in" "$current_run/inner-link"
fixture_symlink_in="$work_tmp/fixture-symlink-in.json"
printf '{"permissions": {"allow": ["write_file(%s)"]}}\n' \
  "$current_run/inner-link" > "$fixture_symlink_in"
run_launcher check-symlink-in --check-settings "$fixture_symlink_in" "$current_run"
expect_status "7: write_file through a symlink staying inside passes" 0

run_a="$runs_root/a"
run_ab="$runs_root/ab"
mkdir -p "$run_a" "$run_ab"
fixture_prefix="$work_tmp/fixture-prefix.json"
printf '{"permissions": {"allow": ["write_file(%s)"]}}\n' "$run_ab" > "$fixture_prefix"
run_launcher check-prefix --check-settings "$fixture_prefix" "$run_a"
expect_status "8: sibling run name that shares a prefix exits 1" 1
expect_err "8: message names the sibling entry" "write_file($run_ab)"

fixture_glob="$work_tmp/fixture-glob.json"
printf '{"permissions": {"allow": ["write_file(%s/*)"]}}\n' "$current_run" > "$fixture_glob"
run_launcher check-glob --check-settings "$fixture_glob" "$current_run"
expect_status "9: write_file wildcard exits 1" 1

fixture_empty="$work_tmp/fixture-empty.json"
printf '{"permissions": {"allow": ["write_file()"]}}\n' > "$fixture_empty"
run_launcher check-empty --check-settings "$fixture_empty" "$current_run"
expect_status "9: write_file() exits 1" 1

fixture_noarg="$work_tmp/fixture-noarg.json"
printf '{"permissions": {"allow": ["write_file"]}}\n' > "$fixture_noarg"
run_launcher check-noarg --check-settings "$fixture_noarg" "$current_run"
expect_status "9: write_file without an argument exits 1" 1

fixture_json="$work_tmp/fixture-json.json"
printf '{"permissions": {"allow": ["write_file(%s)"}\n' "$current_run" > "$fixture_json"
run_launcher check-json --check-settings "$fixture_json" "$current_run"
expect_status "9: invalid JSON exits 1" 1
expect_err "9: invalid JSON is named" "invalid JSON"

fixture_nonstring="$work_tmp/fixture-nonstring.json"
printf '{"permissions": {"allow": [42]}}\n' > "$fixture_nonstring"
run_launcher check-nonstring --check-settings "$fixture_nonstring" "$current_run"
expect_status "9: non-string allow entry exits 1" 1

fixture_noallow="$work_tmp/fixture-noallow.json"
printf '{"permissions": {}}\n' > "$fixture_noallow"
run_launcher check-noallow --check-settings "$fixture_noallow" "$current_run"
expect_status "9: missing .permissions.allow exits 1" 1

printf '== settings path resolution through symlinks ==\n'

mkdir -p "$work_tmp/escape-dir"
printf 'outside file\n' > "$work_tmp/escape-file.md"

ln -s "$work_tmp/escape-file.md" "$current_run/REVIEW.md"
fixture_file_link="$work_tmp/fixture-file-link.json"
printf '{"permissions": {"allow": ["write_file(%s)"]}}\n' \
  "$current_run/REVIEW.md" > "$fixture_file_link"
run_launcher check-file-link --check-settings "$fixture_file_link" "$current_run"
expect_status "14: file symlink to an outside file exits 1" 1
expect_err "14: file symlink failure names the entry" "write_file($current_run/REVIEW.md)"
expect_err "14: file symlink failure says outside run folder" "outside run folder $current_real"

ln -s "$work_tmp/escape-dir/not-yet" "$current_run/dang"
fixture_dangling="$work_tmp/fixture-dangling.json"
printf '{"permissions": {"allow": ["write_file(%s)"]}}\n' \
  "$current_run/dang" > "$fixture_dangling"
run_launcher check-dangling --check-settings "$fixture_dangling" "$current_run"
expect_status "15: dangling symlink to an outside path exits 1" 1
expect_err "15: dangling symlink failure says outside run folder" "outside run folder $current_real"

fixture_dangling_child="$work_tmp/fixture-dangling-child.json"
printf '{"permissions": {"allow": ["write_file(%s)"]}}\n' \
  "$current_run/dang/child" > "$fixture_dangling_child"
run_launcher check-dangling-child --check-settings "$fixture_dangling_child" "$current_run"
expect_status "16: path through a dangling symlink exits 1" 1
expect_err "16: dangling child failure says outside run folder" "outside run folder $current_real"

ln -s "$work_tmp/escape-dir" "$current_run/lo"
fixture_dotdot_link="$work_tmp/fixture-dotdot-link.json"
printf '{"permissions": {"allow": ["write_file(%s)"]}}\n' \
  "$current_run/missing/../lo" > "$fixture_dotdot_link"
run_launcher check-dotdot-link --check-settings "$fixture_dotdot_link" "$current_run"
expect_status "17: .. before an outside dir symlink exits 1" 1
expect_err "17: .. before a symlink says outside run folder" "outside run folder $current_real"

mkdir -p "$test_home/agy-work/rel-out"
ln -s "../../rel-out" "$current_run/esc"
fixture_relative_link="$work_tmp/fixture-relative-link.json"
printf '{"permissions": {"allow": ["write_file(%s)"]}}\n' \
  "$current_run/esc" > "$fixture_relative_link"
run_launcher check-relative-link --check-settings "$fixture_relative_link" "$current_run"
expect_status "18: relative symlink escaping via ../.. exits 1" 1
expect_err "18: relative symlink failure says outside run folder" "outside run folder $current_real"

ln -s loop "$current_run/loop"
fixture_loop="$work_tmp/fixture-loop.json"
printf '{"permissions": {"allow": ["write_file(%s)"]}}\n' \
  "$current_run/loop" > "$fixture_loop"
run_launcher check-loop --check-settings "$fixture_loop" "$current_run"
expect_status "19: symlink loop exits 1" 1
expect_err "19: symlink loop failure is explained" "cannot resolve write_file($current_run/loop)"

mkdir -p "$current_run/link-in"
printf 'inner file\n' > "$current_run/link-in/target.md"
ln -s "$current_run/link-in/target.md" "$current_run/file-link"
fixture_inner_file_link="$work_tmp/fixture-inner-file-link.json"
printf '{"permissions": {"allow": ["write_file(%s)"]}}\n' \
  "$current_run/file-link" > "$fixture_inner_file_link"
run_launcher check-inner-file-link --check-settings "$fixture_inner_file_link" "$current_run"
expect_status "20: symlinked file inside the run folder passes" 0

fixture_inner_dir_link="$work_tmp/fixture-inner-dir-link.json"
printf '{"permissions": {"allow": ["write_file(%s)"]}}\n' \
  "$current_run/inner-link" > "$fixture_inner_dir_link"
run_launcher check-inner-dir-link --check-settings "$fixture_inner_dir_link" "$current_run"
expect_status "20: symlinked directory inside the run folder passes" 0

pass_run="$runs_root/pass-run"
mkdir -p "$pass_run"
printf 'review notes\n' > "$pass_run/REVIEW.md"
fixture_pass_file="$work_tmp/fixture-pass-file.json"
printf '{"permissions": {"allow": ["write_file(%s)"]}}\n' \
  "$pass_run/REVIEW.md" > "$fixture_pass_file"
run_launcher check-pass-file --check-settings "$fixture_pass_file" "$pass_run"
expect_status "21: plain file inside the run folder passes" 0

fixture_pass_missing="$work_tmp/fixture-pass-missing.json"
printf '{"permissions": {"allow": ["write_file(%s)"]}}\n' \
  "$pass_run/missing/../REVIEW.md" > "$fixture_pass_missing"
run_launcher check-pass-missing --check-settings "$fixture_pass_missing" "$pass_run"
expect_status "21: missing/../REVIEW.md plain file path still passes" 0
if [ -n "$err" ]; then
  bad "21: missing/../ pass writes no stderr" "stderr: $err"
else
  ok "21: missing/../ pass writes no stderr"
fi

printf '== strict allow entries ==\n'

strict_fail() {
  local label="$1"
  local entry="$2"
  local file="$work_tmp/strict-$label.json"

  printf '{"permissions": {"allow": [%s]}}\n' \
    "$(printf '%s' "$entry" | jq -R .)" >"$file"
  run_launcher "strict-$label" --check-settings "$file" "$current_run"
  expect_status "22: $label exits 1" 1
  expect_err "22: $label names the entry" "$entry"
}

strict_file="$work_tmp/strict-empty-string.json"
printf '{"permissions": {"allow": [""]}}\n' >"$strict_file"
run_launcher strict-empty-string --check-settings "$strict_file" "$current_run"
expect_status "22: empty string entry exits 1" 1
expect_err "22: empty string entry is named" 'allow entry "" is empty'

strict_file="$work_tmp/strict-empty-array.json"
printf '{"permissions": {"allow": []}}\n' >"$strict_file"
run_launcher strict-empty-array --check-settings "$strict_file" "$current_run"
expect_status "22: empty allow array exits 1" 1
expect_err "22: empty allow array is named" 'allow list is empty ([])'

strict_file="$work_tmp/strict-empty-second.json"
printf '{"permissions": {"allow": [%s, ""]}}\n' \
  "$(printf 'write_file(%s)' "$current_real" | jq -R .)" >"$strict_file"
run_launcher strict-empty-second --check-settings "$strict_file" "$current_run"
expect_status "22: empty second entry exits 1" 1
expect_err "22: empty second entry is named" 'allow entry "" is empty'

current_name="$(basename "$current_run")"
strict_fail split-entry "write_file(/outside)/../../$current_name)"
strict_fail open-paren "write_file((x)"
strict_fail no-close "write_file($current_real"
strict_fail empty-tool "($current_real)"
strict_fail trailing-junk "write_file($current_real)junk"
strict_fail command-trailing "command(ls) extra"
strict_fail glob-question "write_file($current_real/?)"
strict_fail glob-class "write_file($current_real/[a])"
strict_fail edit-empty "edit_file()"
strict_fail bare-read "read_file"
strict_fail command-empty "command()"

strict_file="$work_tmp/strict-relative-ok.json"
printf '{"permissions": {"allow": ["edit_file(REVIEW.md)"]}}\n' >"$strict_file"
run_launcher strict-relative-ok --check-settings "$strict_file" "$pass_run"
expect_status "22: relative edit_file(REVIEW.md) inside the run folder passes" 0
if [ -n "$err" ]; then
  bad "22: relative edit_file pass writes no stderr" "stderr: $err"
else
  ok "22: relative edit_file pass writes no stderr"
fi

pass_real="$(cd "$pass_run" && pwd -P)"
strict_file="$work_tmp/strict-generated.json"
sed "s|@RUN_DIR@|$pass_real|g" \
  "$repo_root/scripts/templates/agy-review-settings.json" >"$strict_file"
run_launcher strict-generated --check-settings "$strict_file" "$pass_run"
expect_status "22: generated template entries still pass" 0

printf '== symlinked log and pid files are refused ==\n'

for symlink_name in agy.log agy.stderr.log agy.pid; do
  symlink_slug="${symlink_name//./-}"
  symlink_run="$runs_root/relaunch-$symlink_slug"
  mkdir -p "$symlink_run"
  symlink_target="$work_tmp/target-$symlink_slug"
  printf 'outside target\n' >"$symlink_target"
  ln -s "$symlink_target" "$symlink_run/$symlink_name"
  run_launcher "relaunch-$symlink_slug" "relaunch-$symlink_slug" "$repo_dir" "$brief"
  expect_status "23: symlinked $symlink_name relaunch exits 1" 1
  expect_err "23: symlinked $symlink_name is named" "refusing symlinked $symlink_name"
  if [ "$(cat "$symlink_target")" = "outside target" ]; then
    ok "23: symlinked $symlink_name target is unchanged"
  else
    bad "23: symlinked $symlink_name target is unchanged" "target content changed"
  fi
  if [ -s "$argv_file" ]; then
    bad "23: symlinked $symlink_name does not start agy" "stub recorded argv"
  else
    ok "23: symlinked $symlink_name does not start agy"
  fi
done

printf '== usage and path validation ==\n'

run_launcher bad-dotdot "../x" "$repo_dir" "$brief"
expect_status "10: run name ../x exits 2" 2
run_launcher bad-slash "a/b" "$repo_dir" "$brief"
expect_status "10: run name a/b exits 2" 2
run_launcher bad-dash "-x" "$repo_dir" "$brief"
expect_status "10: run name -x exits 2" 2
run_launcher bad-dots ".." "$repo_dir" "$brief"
expect_status "10: run name .. exits 2" 2

mkdir -p "$work_tmp/outside-repo"
run_launcher outside-repo run-outside "$work_tmp/outside-repo" "$brief"
expect_status "11: repo outside \$HOME/agy-work exits 1" 1
expect_err "11: outside repo is named" "outside"
expect_no_file "11: failed repo check creates no run folder" "$runs_root/run-outside"

mkdir -p "$work_tmp/target-run"
ln -s "$work_tmp/target-run" "$runs_root/linked-run"
run_launcher linked-run linked-run "$repo_dir" "$brief"
expect_status "12: run folder symlink is refused" 1
expect_err "12: symlink refusal is explained" "refusing run folder symlink"

printf '== caffeinate wrapper and empty-output retry ==\n'

darwin_bin="$work_tmp/darwin-bin"
mkdir -p "$darwin_bin"
write_uname_stub "$darwin_bin" Darwin
write_caffeinate_stub "$darwin_bin"

hidden_bin="$work_tmp/hidden-bin"
build_path_hiding "$hidden_bin" caffeinate
write_uname_stub "$hidden_bin" Darwin

# caffeinate present (uname stub reports Darwin): agy is started as
# caffeinate -i agy ..., one launch, non-empty first log, exit 0.
unset FAKE_AGY_EMPTY FAKE_AGY_EMPTY_FIRST
run_launcher_on_path cafe-present "$darwin_bin" "$PATH" run-cafe-present "$repo_dir" "$brief"
expect_status "24: caffeinate present exits 0" 0
expect_launches "24: caffeinate present launches once" 1
if grep -q -F 'holding idle-sleep assertion with caffeinate -i' "$runs_root/run-cafe-present/agy.stderr.log"; then
  ok "24: wrapper holds a caffeinate -i idle-sleep assertion"
else
  bad "24: wrapper holds a caffeinate -i idle-sleep assertion" "stderr log: $(tr '\n' ' ' <"$runs_root/run-cafe-present/agy.stderr.log")"
fi
if grep -qx -- 'agy' "$caffeinate_argv"; then
  bad "24: caffeinate is assertion-only (agy is not the operand)" "argv: $(tr '\n' ' ' <"$caffeinate_argv")"
else
  ok "24: caffeinate is assertion-only (agy is not the operand)"
fi
expect_out "24: caffeinate present prints AGY_PID" "AGY_PID="
cafe_present="$runs_root/run-cafe-present"
if [ -s "$cafe_present/agy.log" ]; then
  ok "24: caffeinate present leaves a non-empty agy.log"
else
  bad "24: caffeinate present leaves a non-empty agy.log" "log missing or empty"
fi

# caffeinate absent on a Darwin uname: hide the real binary, do not wrap.
# Put the stub agy ahead of the tool dir so a real agy on the host cannot run.
unset FAKE_AGY_EMPTY FAKE_AGY_EMPTY_FIRST
run_launcher_on_path cafe-absent "$fake_bin" "$hidden_bin" run-cafe-absent "$repo_dir" "$brief"
expect_status "25: caffeinate absent exits 0" 0
expect_launches "25: caffeinate absent launches once" 1
if [ -s "$caffeinate_argv" ]; then
  bad "25: caffeinate absent does not invoke caffeinate" "argv: $(tr '\n' ' ' <"$caffeinate_argv")"
else
  ok "25: caffeinate absent does not invoke caffeinate"
fi

# First run empty, second non-empty: success, exactly two launches.
FAKE_AGY_EMPTY_FIRST=1
unset FAKE_AGY_EMPTY
run_launcher_on_path empty-then-ok "$darwin_bin" "$PATH" run-empty-then-ok "$repo_dir" "$brief"
unset FAKE_AGY_EMPTY_FIRST
expect_status "26: empty then non-empty exits 0" 0
expect_launches "26: empty then non-empty launches twice" 2
expect_err "26: empty then non-empty mentions the retry" "empty stdout log"
if printf '%s' "$err" | grep -q 'giving up'; then
  bad "26: empty then non-empty does not give up" "stderr: $err"
else
  ok "26: empty then non-empty does not give up"
fi
empty_then_ok="$runs_root/run-empty-then-ok"
expect_file "26: first empty log is preserved" "$empty_then_ok/agy.log.attempt1"
if [ ! -s "$empty_then_ok/agy.log.attempt1" ] && [ -e "$empty_then_ok/agy.log.attempt1" ]; then
  ok "26: preserved first log is empty"
else
  bad "26: preserved first log is empty" "attempt1 missing or non-empty"
fi
if [ -s "$empty_then_ok/agy.log" ]; then
  ok "26: second log is non-empty"
else
  bad "26: second log is non-empty" "agy.log missing or empty"
fi

# Both runs empty: fail closed, exactly two launches.
FAKE_AGY_EMPTY=1
unset FAKE_AGY_EMPTY_FIRST
run_launcher_on_path both-empty "$darwin_bin" "$PATH" run-both-empty "$repo_dir" "$brief"
unset FAKE_AGY_EMPTY
expect_status "27: both empty exits 1" 1
expect_launches "27: both empty launches twice" 2
expect_err "27: both empty mentions the retry" "retrying once"
expect_err "27: both empty fails closed after retry" "automatic retry also failed"
expect_err "27: both empty asks the operator" "ask the operator"
both_empty="$runs_root/run-both-empty"
expect_file "27: both empty preserves the first log" "$both_empty/agy.log.attempt1"
if [ ! -s "$both_empty/agy.log" ]; then
  ok "27: both empty leaves a final empty log"
else
  bad "27: both empty leaves a final empty log" "agy.log is non-empty"
fi

# Non-empty first run: one launch, exit 0, no retry message.
unset FAKE_AGY_EMPTY FAKE_AGY_EMPTY_FIRST
run_launcher_on_path nonempty-first "$darwin_bin" "$PATH" run-nonempty-first "$repo_dir" "$brief"
expect_status "28: non-empty first run exits 0" 0
expect_launches "28: non-empty first run launches once" 1
if [ -n "$err" ] && printf '%s' "$err" | grep -q 'retrying once'; then
  bad "28: non-empty first run does not retry" "stderr: $err"
else
  ok "28: non-empty first run does not retry"
fi
if [ -s "$runs_root/run-nonempty-first/agy.log" ]; then
  ok "28: non-empty first run leaves a non-empty log"
else
  bad "28: non-empty first run leaves a non-empty log" "agy.log missing or empty"
fi

# Default stub (no caffeinate stubs forced) still writes non-empty output and
# does not retry, so earlier happy-path cases stay at one launch. Re-check
# with a fresh run name through the ordinary run_launcher helper.
run_launcher default-nonempty run-default-nonempty "$repo_dir" "$brief"
expect_status "29: default stub launch exits 0" 0
expect_launches "29: default stub launches once" 1

printf '== auto-deny, stall fallback, and shared retry budget ==\n'

# First run auto-denies (official stderr notice, empty stdout), second
# succeeds: exactly two launches, retry brief contains the instruction,
# original BRIEF.md is unchanged.
FAKE_AGY_AUTODENY_FIRST=1
unset FAKE_AGY_AUTODENY FAKE_AGY_EMPTY FAKE_AGY_EMPTY_FIRST FAKE_AGY_STALL FAKE_AGY_STALL_FIRST
run_launcher_on_path deny-then-ok "$darwin_bin" "$PATH" run-deny-then-ok "$repo_dir" "$brief"
unset FAKE_AGY_AUTODENY_FIRST
expect_status "30: auto-deny then non-empty exits 0" 0
expect_launches "30: auto-deny then non-empty launches twice" 2
expect_err "30: auto-deny then non-empty mentions auto-deny" "headless auto-deny"
if printf '%s' "$err" | grep -q 'giving up'; then
  bad "30: auto-deny then non-empty does not give up" "stderr: $err"
else
  ok "30: auto-deny then non-empty does not give up"
fi
deny_then_ok="$runs_root/run-deny-then-ok"
expect_file "30: auto-deny preserves the first stderr log" "$deny_then_ok/agy.stderr.log.attempt1"
if grep -q -F 'headless mode cannot prompt for' "$deny_then_ok/agy.stderr.log.attempt1"; then
  ok "30: preserved first stderr has the auto-deny notice"
else
  bad "30: preserved first stderr has the auto-deny notice" "missing needle"
fi
expect_file "30: retry brief is written" "$deny_then_ok/BRIEF.retry.md"
if grep -q -F 'use simple commands one at a time; no pipes, no redirects, no regex special characters.' "$deny_then_ok/BRIEF.retry.md"; then
  ok "30: retry brief has the simpler-commands instruction"
else
  bad "30: retry brief has the simpler-commands instruction" "missing instruction"
fi
if grep -q -F 'use simple commands one at a time' "$deny_then_ok/BRIEF.md"; then
  bad "30: original brief is not mutated" "BRIEF.md was appended to"
else
  ok "30: original brief is not mutated"
fi
if grep -q -F 'use simple commands one at a time' "$argv_all"; then
  ok "30: second launch passes the retry brief"
else
  bad "30: second launch passes the retry brief" "instruction missing from argv"
fi

# Both auto-denies: fail closed, exactly two launches, ask the operator.
FAKE_AGY_AUTODENY=1
unset FAKE_AGY_AUTODENY_FIRST
run_launcher_on_path both-deny "$darwin_bin" "$PATH" run-both-deny "$repo_dir" "$brief"
unset FAKE_AGY_AUTODENY
expect_status "31: both auto-deny exits 1" 1
expect_launches "31: both auto-deny launches twice" 2
expect_err "31: both auto-deny fails closed after retry" "automatic retry also failed"
expect_err "31: both auto-deny asks the operator" "ask the operator"
expect_err "31: both auto-deny does not suggest widening allow" "Do not add allow-rules"

# Shared budget: empty first, auto-deny second: still only two launches.
FAKE_AGY_EMPTY_FIRST=1
FAKE_AGY_AUTODENY=1
unset FAKE_AGY_EMPTY FAKE_AGY_AUTODENY_FIRST
run_launcher_on_path empty-then-deny "$darwin_bin" "$PATH" run-empty-then-deny "$repo_dir" "$brief"
unset FAKE_AGY_EMPTY_FIRST FAKE_AGY_AUTODENY
expect_status "32: empty then auto-deny exits 1" 1
expect_launches "32: empty then auto-deny launches twice" 2
expect_err "32: empty then auto-deny mentions the empty retry" "empty stdout log"
expect_err "32: empty then auto-deny fails closed after retry" "automatic retry also failed"
# Empty-only first retry must not write or pass a retry brief.
empty_then_deny="$runs_root/run-empty-then-deny"
if [ -e "$empty_then_deny/BRIEF.retry.md" ]; then
  bad "32: empty-first retry does not write a retry brief" "BRIEF.retry.md exists"
else
  ok "32: empty-first retry does not write a retry brief"
fi

# Stall then success: override the fallback window so the test stays short.
FAKE_AGY_STALL_FIRST=1
unset FAKE_AGY_STALL FAKE_AGY_EMPTY FAKE_AGY_EMPTY_FIRST FAKE_AGY_AUTODENY FAKE_AGY_AUTODENY_FIRST
AGY_LAUNCH_STALL_SECONDS=2
run_launcher_on_path stall-then-ok "$darwin_bin" "$PATH" run-stall-then-ok "$repo_dir" "$brief"
unset FAKE_AGY_STALL_FIRST
unset AGY_LAUNCH_STALL_SECONDS
expect_status "33: stall then non-empty exits 0" 0
expect_launches "33: stall then non-empty launches twice" 2
expect_err "33: stall then non-empty mentions the stall" "no log growth"
if printf '%s' "$err" | grep -q 'giving up\|automatic retry also failed'; then
  bad "33: stall then non-empty does not give up" "stderr: $err"
else
  ok "33: stall then non-empty does not give up"
fi
stall_then_ok="$runs_root/run-stall-then-ok"
expect_file "33: stall retry writes a retry brief" "$stall_then_ok/BRIEF.retry.md"
if grep -q -F 'use simple commands one at a time' "$stall_then_ok/BRIEF.md"; then
  bad "33: stall retry does not mutate the original brief" "BRIEF.md was appended to"
else
  ok "33: stall retry does not mutate the original brief"
fi

# Stall then stall: fail closed, two launches only.
FAKE_AGY_STALL=1
AGY_LAUNCH_STALL_SECONDS=2
run_launcher_on_path both-stall "$darwin_bin" "$PATH" run-both-stall "$repo_dir" "$brief"
unset FAKE_AGY_STALL
unset AGY_LAUNCH_STALL_SECONDS
expect_status "34: both stall exits 1" 1
expect_launches "34: both stall launches twice" 2
expect_err "34: both stall fails closed after retry" "automatic retry also failed"
expect_err "34: both stall asks the operator" "ask the operator"

# Dry-run stays immediate and never starts or retries agy, even when a
# stall timeout is set.
unset FAKE_AGY_EMPTY FAKE_AGY_EMPTY_FIRST FAKE_AGY_AUTODENY FAKE_AGY_AUTODENY_FIRST
unset FAKE_AGY_STALL FAKE_AGY_STALL_FIRST
AGY_LAUNCH_STALL_SECONDS=2
run_launcher dry-no-side --dry-run run-dry-no-side "$repo_dir" "$brief"
unset AGY_LAUNCH_STALL_SECONDS
expect_status "35: dry-run with stall override exits 0" 0
expect_launches "35: dry-run with stall override does not start agy" 0
expect_no_file "35: dry-run does not write attempt logs" "$runs_root/run-dry-no-side/agy.log.attempt1"
expect_no_file "35: dry-run does not write a retry brief" "$runs_root/run-dry-no-side/BRIEF.retry.md"
if printf '%s' "$err" | grep -q 'retrying once\|auto-deny\|no log growth'; then
  bad "35: dry-run does not retry" "stderr: $err"
else
  ok "35: dry-run does not retry"
fi

printf '== agents never touch global settings ==\n'

for name in .gemini .antigravity .agy .config; do
  if [ -e "$test_home/$name" ]; then
    bad "13: temp HOME has no $name" "$test_home/$name exists"
  else
    ok "13: temp HOME has no $name"
  fi
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -ne 0 ]; then
  exit 1
fi
exit 0
