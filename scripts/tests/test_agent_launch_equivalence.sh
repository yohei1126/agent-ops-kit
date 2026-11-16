#!/usr/bin/env bash
# Golden-capture equivalence test for the agy compatibility wrappers, the
# shared launch helper, the deprecated helper shim, and the config-driven
# entry point.
#
# Each scenario runs under `env -i` with a fixed environment. A stub `agy`
# records argv, working directory, and the complete environment it inherits
# (minus the variables bash itself maintains, see the stub).
# The capture also holds the launcher exit status, stdout, and stderr, so
# usage, refusal, retry, and stall diagnostics are compared as well. Temp
# paths and PIDs are normalized so captures stay identical across hosts.
#
# The golden files come from the launchers as they were before the
# refactor. To regenerate them, export the pre-change tree and point the
# capture at it (the compatibility wrappers there are the former launchers):
#   git archive <pre-change-ref> scripts | tar -x -C <dir>
#   AGENT_LAUNCH_CAPTURE_REPO=<dir> AGENT_LAUNCH_CAPTURE_OUT=<fixtures-dir> \
#     bash scripts/tests/test_agent_launch_equivalence.sh
# Never regenerate them from the refactored launchers.
#
# caffeinate is forced off (the test PATH only holds a controlled tool
# directory and the stub), so Linux and macOS produce the same captures.
# No real agent binary can be reached: the stub is first on PATH and the test
# asserts that `command -v agy` resolves to it.
set -u

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
fixtures_dir="$repo_root/scripts/tests/fixtures/agent-launch"
capture_out="${AGENT_LAUNCH_CAPTURE_OUT:-}"
capture_repo="${AGENT_LAUNCH_CAPTURE_REPO:-}"

pass=0
fail=0
work_tmp="$(mktemp -d)"
work_tmp_real="$(cd "$work_tmp" && pwd -P)"
trap 'rm -rf "$work_tmp"' EXIT

ok() {
  pass=$((pass + 1))
  printf 'PASS %s\n' "$1"
}

bad() {
  fail=$((fail + 1))
  printf 'FAIL %s: %s\n' "$1" "$2"
}

if [ -n "$capture_out" ] && [ -z "$capture_repo" ]; then
  printf 'AGENT_LAUNCH_CAPTURE_OUT needs AGENT_LAUNCH_CAPTURE_REPO=<pre-change tree>\n' >&2
  exit 2
fi

# Symlink the utilities the launchers need into a private directory, never
# agy or caffeinate. The test PATH is this directory plus the stub directory.
tool_bin="$work_tmp/tool-bin"
mkdir -p "$tool_bin"
for cmd in bash jq tr mkdir kill cp mv cat uname mktemp sed wc rm ln \
  readlink realpath dirname basename chmod date head env nohup tee cut \
  sort uniq touch sleep grep find ls; do
  cmd_path="$(command -v "$cmd" 2>/dev/null)" || continue
  case "$cmd_path" in
    '' | */agy | */caffeinate) continue ;;
    /*) ;;
    *) continue ;;
  esac
  rm -f "$tool_bin/$cmd"
  ln -s "$cmd_path" "$tool_bin/$cmd"
done

fake_bin="$work_tmp/fake-bin"
mkdir -p "$fake_bin"
cat >"$fake_bin/agy" <<'SH'
#!/usr/bin/env bash
set -u
n=0
if [ -f "${FAKE_AGY_COUNT:-}" ]; then
  n="$(tr -d '[:space:]' <"$FAKE_AGY_COUNT" || true)"
  case "$n" in
    '' | *[!0-9]*) n=0 ;;
  esac
fi
n=$((n + 1))
printf '%s\n' "$n" >"${FAKE_AGY_COUNT:-/dev/null}"
{
  printf -- '--- ATTEMPT %s ---\n' "$n"
  for arg in "$@"; do
    printf '%s\n' "$arg"
  done
} >>"${FAKE_AGY_ARGV:-/dev/null}"
printf '%s\n' "$(pwd -P)" >>"${FAKE_AGY_CWD:-/dev/null}"
# Every inherited variable except the shell's own bookkeeping: SHLVL, OLDPWD,
# and _ are set by whichever bash runs the script (3.2 and 5.x differ), not by
# the launcher, so they cannot be part of the launcher contract.
{
  printf -- '--- ATTEMPT %s ---\n' "$n"
  env | LC_ALL=C grep -v -E '^(SHLVL|OLDPWD|_)=' | LC_ALL=C sort
} >>"${FAKE_AGY_ENV:-/dev/null}"
if [ "${FAKE_AGY_EMPTY_FIRST:-}" = 1 ] && [ "$n" -eq 1 ]; then
  exit 0
fi
if [ "${FAKE_AGY_STALL_FIRST:-}" = 1 ] && [ "$n" -eq 1 ]; then
  # Stay alive without output until the stall fallback stops this attempt.
  exec sleep 30
fi
printf 'stub output %s\n' "$n"
SH
chmod +x "$fake_bin/agy"

# The fixture config selects the agy adapter with the model each scenario
# fixes. Lane names match scenario names so the new path is mechanical.
config_file="$work_tmp/agents.json"
{
  printf '{\n  "schema_version": 1,\n'
  printf '  "agents": {"fixture-agent": {"adapter": "agy", "display": "fixture-display", "provider": "fixture-provider", "who_can_launch": "maintainer", "provisioned": true}},\n'
  printf '  "lanes": {\n'
  sep=""
  for spec in \
    "docs-default|gemini-3.8-flash-medium|docs" \
    "docs-model-arg|test-model-docs-arg|docs" \
    "docs-model-env|test-model-docs-env|docs" \
    "docs-retry|gemini-3.8-flash-medium|docs" \
    "docs-stall|gemini-3.8-flash-medium|docs" \
    "docs-refuse-symlink|gemini-3.8-flash-medium|docs" \
    "review-default|gemini-4-argon-medium|review" \
    "review-model-arg|test-model-review-arg|review" \
    "review-dry-run|gemini-4-argon-medium|review" \
    "review-retry|gemini-4-argon-medium|review" \
    "review-stall|gemini-4-argon-medium|review" \
    "review-refuse-symlink|gemini-4-argon-medium|review"; do
    lane="${spec%%|*}"
    rest="${spec#*|}"
    model="${rest%%|*}"
    mode="${rest#*|}"
    printf '%s    "%s": {"entries": [{"agent": "fixture-agent", "model": "%s", "model_name": "Fixture", "mode": "%s"}]}' \
      "$sep" "$lane" "$model" "$mode"
    sep=",
"
  done
  printf '\n  }\n}\n'
} >"$config_file"

# Scenarios run through both the wrapper and agent-launch.sh.
launch_scenarios="docs-default docs-model-arg docs-model-env docs-retry docs-stall docs-refuse-symlink review-default review-model-arg review-dry-run review-retry review-stall review-refuse-symlink"
# Scenarios that exercise the former CLI only (usage and validation output).
wrapper_scenarios="docs-usage review-usage review-bad-model review-bad-run-and-model collect-help collect-help-extra"

# normalize <home> <file>: replace temp paths and PIDs with placeholders.
# The launchers resolve physical paths, so normalize the real path too
# (macOS resolves /var to /private/var while Linux keeps /tmp as is).
normalize() {
  local home="$1"
  local file="$2"
  local home_real
  home_real="$(cd "$home" && pwd -P)"
  sed -e "s|$home_real/agy-work/runs|@RUN@|g" \
    -e "s|$home_real/agy-inbox|@INBOX@|g" \
    -e "s|$home/agy-work/runs|@RUN@|g" \
    -e "s|$home/agy-inbox|@INBOX@|g" \
    -e "s|$home_real|@HOME@|g" \
    -e "s|$home|@HOME@|g" \
    -e "s|$work_tmp_real|@TMP@|g" \
    -e "s|$work_tmp|@TMP@|g" \
    -e "s|$repo_root|@KIT@|g" \
    -e 's|@TMP@/cap-[a-z]*/|@CAP@/|g' \
    -e 's|AGY_PID=[0-9][0-9]*|AGY_PID=@PID@|g' \
    -e 's|PID [0-9][0-9]*|PID @PID@|g' \
    "$file"
}

write_capture() {
  local dest="$1"
  local status="$2"
  local base="$3"
  local home="$4"

  {
    printf 'EXIT=%s\n' "$status"
    printf 'ARGV\n'
    normalize "$home" "$base.argv"
    printf 'END_ARGV\n'
    printf 'CWD\n'
    normalize "$home" "$base.cwd"
    printf 'END_CWD\n'
    printf 'ENV\n'
    normalize "$home" "$base.env"
    printf 'END_ENV\n'
    printf 'STDOUT\n'
    normalize "$home" "$base.stdout"
    printf 'END_STDOUT\n'
    printf 'STDERR\n'
    normalize "$home" "$base.stderr"
    printf 'END_STDERR\n'
  } >"$dest"
}

make_home() {
  local home="$1"
  local scenario="$2"
  mkdir -p "$home/agy-work/repo" "$home/agy-inbox" "$home/tmp" "$home/elsewhere"
  printf 'repo readme\n' >"$home/agy-work/repo/README.md"
  printf 'Update the docs.\n' >"$home/agy-inbox/brief.txt"
  case "$scenario" in
    docs-refuse-symlink)
      ln -s "$home/elsewhere" "$home/agy-work/repo-link"
      ;;
    review-refuse-symlink)
      mkdir -p "$home/agy-work/runs"
      ln -s "$home/elsewhere" "$home/agy-work/runs/run-$scenario"
      ;;
  esac
}

# scenario_env <scenario>: prints extra NAME=value lines, one per line.
scenario_env() {
  case "$1" in
    docs-model-env) printf 'AGY_DOCS_MODEL=test-model-docs-env\n' ;;
    docs-retry | review-retry) printf 'FAKE_AGY_EMPTY_FIRST=1\n' ;;
    docs-stall | review-stall)
      printf 'FAKE_AGY_STALL_FIRST=1\n'
      printf 'AGY_LAUNCH_STALL_SECONDS=1\n'
      ;;
    review-bad-model | review-bad-run-and-model) printf 'AGY_REVIEW_MODEL=-bad-model\n' ;;
  esac
}

# wrapper_args <scenario> <home>
wrapper_args() {
  local scenario="$1"
  local home="$2"
  case "$scenario" in
    docs-default | docs-model-env | docs-retry | docs-stall)
      printf '%s\n' repo "$home/agy-inbox/brief.txt"
      ;;
    docs-model-arg)
      printf '%s\n' repo "$home/agy-inbox/brief.txt" docs-model-arg test-model-docs-arg
      ;;
    docs-refuse-symlink)
      printf '%s\n' repo-link "$home/agy-inbox/brief.txt"
      ;;
    review-default | review-retry | review-stall | review-refuse-symlink | review-bad-model)
      printf '%s\n' "run-$scenario" "$home/agy-work/repo" "$home/agy-inbox/brief.txt"
      ;;
    review-model-arg)
      printf '%s\n' "run-$scenario" "$home/agy-work/repo" "$home/agy-inbox/brief.txt" test-model-review-arg
      ;;
    review-dry-run)
      printf '%s\n' --dry-run "run-$scenario" "$home/agy-work/repo" "$home/agy-inbox/brief.txt"
      ;;
    review-bad-run-and-model)
      printf '%s\n' "bad+run" "$home/agy-work/repo" "$home/agy-inbox/brief.txt"
      ;;
    docs-usage | review-usage)
      printf '%s\n' only-one
      ;;
    collect-help)
      printf '%s\n' --help
      ;;
    collect-help-extra)
      printf '%s\n' -h extra
      ;;
  esac
}

# adapter_args <scenario> <home>: the launcher args after agent-launch's `--`.
adapter_args() {
  local scenario="$1"
  local home="$2"
  case "$scenario" in
    docs-model-arg)
      printf '%s\n' repo "$home/agy-inbox/brief.txt" docs-model-arg
      ;;
    review-model-arg)
      printf '%s\n' "run-$scenario" "$home/agy-work/repo" "$home/agy-inbox/brief.txt"
      ;;
    *)
      wrapper_args "$scenario" "$home"
      ;;
  esac
}

# run_capture <scenario> <home> <dest> <impl> [args...]
# impl is wrapper, new, or adapter.
run_capture() {
  local scenario="$1"
  local home="$2"
  local dest="$3"
  local impl="$4"
  shift 4
  local status=0
  local launcher_root="$repo_root"
  local launcher
  local line
  local env_args

  : >"$dest.argv"
  : >"$dest.cwd"
  : >"$dest.env"
  : >"$dest.stdout"
  : >"$dest.stderr"
  : >"$dest.count"

  if [ -n "$capture_repo" ] && [ "$impl" = wrapper ]; then
    launcher_root="$capture_repo"
  fi
  case "$impl" in
    wrapper)
      case "$scenario" in
        collect-*) launcher="$launcher_root/scripts/agy-docs-collect.sh" ;;
        docs-*) launcher="$launcher_root/scripts/agy-docs-launch.sh" ;;
        review-*) launcher="$launcher_root/scripts/agy-review-launch.sh" ;;
      esac
      ;;
    new)
      launcher="$repo_root/scripts/agent-launch.sh"
      ;;
    adapter)
      launcher="$repo_root/scripts/agents/agy/run"
      ;;
    *)
      printf 'unknown impl: %s\n' "$impl" >&2
      return 1
      ;;
  esac

  # The complete child environment: only these variables exist.
  env_args=(
    "HOME=$home"
    "PATH=$fake_bin:$tool_bin"
    "TMPDIR=$home/tmp"
    "AGY_LAUNCH_STALL_SECONDS=0"
    "FAKE_AGY_ARGV=$dest.argv"
    "FAKE_AGY_CWD=$dest.cwd"
    "FAKE_AGY_ENV=$dest.env"
    "FAKE_AGY_COUNT=$dest.count"
  )
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    env_args[${#env_args[@]}]="$line"
  done <<EOF
$(scenario_env "$scenario")
EOF

  (
    cd "$home" || exit 1
    if [ "$impl" = new ]; then
      exec env -i "${env_args[@]}" /bin/bash "$launcher" --config "$config_file" \
        --lane "$scenario" --as maintainer -- "$@"
    elif [ "$impl" = adapter ]; then
      exec env -i "${env_args[@]}" /bin/bash "$launcher" --mode review \
        --model gemini-4-argon-medium --dry-run -- "$@"
    else
      exec env -i "${env_args[@]}" /bin/bash "$launcher" "$@"
    fi
  ) >"$dest.stdout" 2>"$dest.stderr"
  status=$?

  write_capture "$dest.capture" "$status" "$dest" "$home"
}

# capture_scenario <scenario> <impl> <home> [args...]
capture_scenario() {
  local scenario="$1"
  local impl="$2"
  local home="$3"
  shift 3
  local dest="$work_tmp/cap-$impl/$scenario"
  mkdir -p "$work_tmp/cap-$impl"
  run_capture "$scenario" "$home" "$dest" "$impl" "$@"
  printf '%s\n' "$dest.capture"
}

# compare <label> <golden> <actual>
compare() {
  if cmp -s "$2" "$3"; then
    ok "$1"
  else
    bad "$1" "diff: $(diff -u "$2" "$3" | head -n 30)"
  fi
}

# Assert that the only agy the launchers can reach is the stub.
resolved="$(PATH="$fake_bin:$tool_bin" command -v agy)"
if [ "$resolved" = "$fake_bin/agy" ]; then
  ok "0: command -v agy resolves to the stub"
else
  bad "0: command -v agy resolves to the stub" "got: $resolved"
fi
if PATH="$fake_bin:$tool_bin" command -v caffeinate >/dev/null 2>&1; then
  bad "0: caffeinate is forced off" "caffeinate is on the test PATH"
else
  ok "0: caffeinate is forced off"
fi

if [ -n "$capture_out" ]; then
  mkdir -p "$capture_out"
  for scenario in $launch_scenarios $wrapper_scenarios; do
    home="$work_tmp/home-$scenario-wrapper"
    make_home "$home" "$scenario"
    # shellcheck disable=SC2046 # wrapper_args prints one argument per line
    capture_file="$(capture_scenario "$scenario" wrapper "$home" $(wrapper_args "$scenario" "$home"))"
    cp "$capture_file" "$capture_out/golden-$scenario.txt"
    printf 'WROTE %s\n' "$capture_out/golden-$scenario.txt"
  done
  printf '\n%d passed, %d failed\n' "$pass" "$fail"
  if [ "$fail" -ne 0 ]; then
    exit 1
  fi
  exit 0
fi

printf '== compatibility wrappers match the pre-change goldens ==\n'

for scenario in $launch_scenarios $wrapper_scenarios; do
  home="$work_tmp/home-$scenario-wrapper"
  make_home "$home" "$scenario"
  # shellcheck disable=SC2046 # wrapper_args prints one argument per line
  actual="$(capture_scenario "$scenario" wrapper "$home" $(wrapper_args "$scenario" "$home"))"
  compare "wrapper $scenario matches the golden capture" \
    "$fixtures_dir/golden-$scenario.txt" "$actual"
done

printf '== agent-launch matches the pre-change goldens ==\n'

for scenario in $launch_scenarios; do
  home="$work_tmp/home-$scenario-new"
  make_home "$home" "$scenario"
  # shellcheck disable=SC2046 # adapter_args prints one argument per line
  actual="$(capture_scenario "$scenario" new "$home" $(adapter_args "$scenario" "$home"))"
  compare "agent-launch $scenario matches the golden capture" \
    "$fixtures_dir/golden-$scenario.txt" "$actual"
done

# The review dry-run path has no child process, so compare it through the
# adapter interface directly; the wrapper comparison above covers the wrapper.
home="$work_tmp/home-review-dry-run-adapter"
make_home "$home" review-dry-run
actual="$(capture_scenario review-dry-run adapter "$home" "run-review-dry-run" "$home/agy-work/repo" "$home/agy-inbox/brief.txt")"
compare "adapter review-dry-run matches the golden capture" \
  "$fixtures_dir/golden-review-dry-run.txt" "$actual"

# The goldens must cover what they claim: the full environment and stderr.
if grep -qx 'HOME=@HOME@' "$fixtures_dir/golden-docs-default.txt" &&
  grep -qx 'PATH=@TMP@/fake-bin:@TMP@/tool-bin' "$fixtures_dir/golden-docs-default.txt"; then
  ok "goldens record the complete child environment, not only AGY_* entries"
else
  bad "goldens record the complete child environment, not only AGY_* entries" "HOME or PATH missing"
fi
if grep -q 'no log growth for 1 seconds' "$fixtures_dir/golden-review-stall.txt" &&
  grep -q 'retrying once' "$fixtures_dir/golden-docs-retry.txt" &&
  grep -q 'refusing run folder symlink' "$fixtures_dir/golden-review-refuse-symlink.txt" &&
  grep -q 'refusing symlinked checkout' "$fixtures_dir/golden-docs-refuse-symlink.txt" &&
  grep -q 'invalid run name' "$fixtures_dir/golden-review-bad-run-and-model.txt"; then
  ok "goldens record stall, retry, refusal, and usage diagnostics on stderr"
else
  bad "goldens record stall, retry, refusal, and usage diagnostics on stderr" "a diagnostic is missing"
fi

printf '== the shipped example config launches through agent-launch ==\n'

example="$repo_root/templates/agent-config.example.json"

# run_example <tag> <lane> [args...]: sets example_status, example_out, example_err.
run_example() {
  local tag="$1"
  local lane="$2"
  shift 2
  local home="$work_tmp/home-example-$tag"
  local dest="$work_tmp/example-$tag"
  make_home "$home" "example-$tag"
  : >"$dest.argv"
  : >"$dest.count"
  (
    cd "$home" || exit 1
    exec env -i "HOME=$home" "PATH=$fake_bin:$tool_bin" "TMPDIR=$home/tmp" \
      "AGY_LAUNCH_STALL_SECONDS=0" "FAKE_AGY_ARGV=$dest.argv" \
      "FAKE_AGY_COUNT=$dest.count" \
      /bin/bash "$repo_root/scripts/agent-launch.sh" --config "$example" \
      --lane "$lane" --as maintainer -- "$@"
  ) >"$dest.stdout" 2>"$dest.stderr"
  example_status=$?
  example_out="$(cat "$dest.stdout")"
  example_err="$(cat "$dest.stderr")"
  example_argv="$(cat "$dest.argv")"
}

ex_home="$work_tmp/home-example-docs"
run_example docs docs repo "$ex_home/agy-inbox/brief.txt"
if [ "$example_status" -eq 0 ]; then
  ok "example docs lane launches the agy adapter for the maintainer"
else
  bad "example docs lane launches the agy adapter for the maintainer" "exit $example_status: $example_err"
fi
case "$example_argv" in
  *"gemini-3.8-flash-medium"*) ok "example docs lane passes its configured model to agy" ;;
  *) bad "example docs lane passes its configured model to agy" "argv: $example_argv" ;;
esac

ex_home="$work_tmp/home-example-review"
run_example review review --dry-run run-example "$ex_home/agy-work/repo" "$ex_home/agy-inbox/brief.txt"
if [ "$example_status" -eq 0 ]; then
  ok "example review lane reaches the agy adapter for the maintainer"
else
  bad "example review lane reaches the agy adapter for the maintainer" "exit $example_status: $example_err"
fi
case "$example_out" in
  *"MODEL=gemini-4-hydrogen"*) ok "example review lane uses its configured model" ;;
  *) bad "example review lane uses its configured model" "stdout: $example_out" ;;
esac

ex_home="$work_tmp/home-example-coding"
run_example coding coding repo "$ex_home/agy-inbox/brief.txt"
case "$example_err" in
  *"missing --mode"* | *"needs one of"* | *"takes no mode"* | *"supports only"*)
    bad "example coding lane never selects an entry its adapter rejects" "stderr: $example_err"
    ;;
  *) ok "example coding lane never selects an entry its adapter rejects" ;;
esac
if [ -s "$work_tmp/example-coding.argv" ]; then
  bad "example coding lane does not start agy" "agy was started"
else
  ok "example coding lane does not start agy"
fi

printf '== deprecated helper shim bridges the former names ==\n'

# The assignments below are read by the sourced shim, and the forwarders
# take no arguments here.
# shellcheck disable=SC2034,SC2119
shim_out="$(
  PATH="$fake_bin:$tool_bin"
  # shellcheck source-path=SCRIPTDIR
  # shellcheck source=../lib/agy-launch-run.sh
  . "$repo_root/scripts/lib/agy-launch-run.sh"
  agy_launch_caffeinate=1
  printf 'PREFIX1=[%s]\n' "$(agy_launch_wrapper_prefix)"
  agy_launch_caffeinate=0
  printf 'PREFIX0=[%s]\n' "$(agy_launch_wrapper_prefix)"
  printf 'abc' >"$work_tmp/shim-bytes"
  printf 'BYTES=%s\n' "$(agy_launch_file_bytes "$work_tmp/shim-bytes")"
  agy_launch_stdout_log="$work_tmp/shim-bytes"
  if agy_launch_stdout_empty; then printf 'EMPTY=1\n'; else printf 'EMPTY=0\n'; fi
  agy_launch_stdout_log="$work_tmp/shim-missing"
  if agy_launch_stdout_empty; then printf 'MISSING_EMPTY=1\n'; else printf 'MISSING_EMPTY=0\n'; fi
  agy_launch_tag=shim-test
  agy_launch_stderr_log="$work_tmp/shim-err"
  printf 'x headless mode cannot prompt for y\n' >"$agy_launch_stderr_log"
  if agy_launch_has_auto_deny; then printf 'DENY=1\n'; else printf 'DENY=0\n'; fi
)"
for want in 'PREFIX1=[caffeinate -i ]' 'PREFIX0=[]' 'BYTES=3' 'EMPTY=0' 'MISSING_EMPTY=1' 'DENY=1'; do
  case "$shim_out" in
    *"$want"*) ok "shim: $want" ;;
    *) bad "shim: $want" "output: $shim_out" ;;
  esac
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -ne 0 ]; then
  exit 1
fi
exit 0
