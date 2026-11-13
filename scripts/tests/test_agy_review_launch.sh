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
{
  printf 'ARGV_START\n'
  for arg in "$@"; do
    printf '%s\n' "$arg"
  done
  printf 'ARGV_END\n'
} > "$FAKE_AGY_ARGV"
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
  : > "$argv_file"
  : > "$err_file"
  out="$(HOME="$test_home" PATH="$fake_bin:$PATH" FAKE_AGY_ARGV="$argv_file" \
    bash "$launcher" "$@" 2>"$err_file")"
  status=$?
  err="$(cat "$err_file")"
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
expect_out "3: dry run prints the command" "AGY_COMMAND=agy "
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
