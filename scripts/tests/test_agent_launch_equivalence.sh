#!/usr/bin/env bash
# Golden-capture equivalence test for the agy compatibility wrappers, the
# shared launch helper, and the config-driven entry point.
#
# A stub `agy` records argv, working directory, and AGY_* environment entries.
# The launcher stdout lines and exit code are recorded too. Temp paths and PIDs
# are normalized so the captures stay identical across hosts and runs.
#
# Set AGENT_LAUNCH_CAPTURE_OUT=<dir> to write golden captures instead of
# comparing. Generate the golden files once, before refactoring, and never
# regenerate them afterwards.
#
# caffeinate is forced off (the test PATH only holds a controlled tool
# directory and the stub), so Linux and macOS produce the same captures.
# No real agent binary can be reached: the stub is first on PATH and the test
# asserts that `command -v agy` resolves to it.
set -u

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
fixtures_dir="$repo_root/scripts/tests/fixtures/agent-launch"
capture_out="${AGENT_LAUNCH_CAPTURE_OUT:-}"

pass=0
fail=0
work_tmp="$(mktemp -d)"
trap 'rm -rf "$work_tmp"' EXIT

ok() {
  pass=$((pass + 1))
  printf 'PASS %s\n' "$1"
}

bad() {
  fail=$((fail + 1))
  printf 'FAIL %s: %s\n' "$1" "$2"
}

# Symlink the utilities the launchers need into a private directory, never
# agy or caffeinate. The test PATH is this directory plus the stub directory.
tool_bin="$work_tmp/tool-bin"
mkdir -p "$tool_bin"
for cmd in bash jq tr mkdir kill cp mv cat uname mktemp sed wc rm ln \
  readlink realpath dirname basename chmod date head env nohup tee cut \
  sort uniq touch sleep grep find ps pgrep ls; do
  cmd_path="$(command -v "$cmd" 2>/dev/null)" || continue
  case "$cmd_path" in
    '' | */agy | */caffeinate) continue ;;
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
env | grep '^AGY_' | LC_ALL=C sort >>"${FAKE_AGY_ENV:-/dev/null}"
if [ "${FAKE_AGY_EMPTY_FIRST:-}" = 1 ] && [ "$n" -eq 1 ]; then
  exit 0
fi
printf 'stub output %s\n' "$n"
SH
chmod +x "$fake_bin/agy"

# The fixture config selects the agy adapter with the model each scenario
# fixes. Lane names match scenario names so the new path is mechanical.
config_file="$work_tmp/agents.json"
cat >"$config_file" <<'JSON'
{
  "schema_version": 1,
  "agents": {
    "fixture-agent": {
      "adapter": "agy",
      "display": "fixture-display",
      "provider": "fixture-provider",
      "who_can_launch": "maintainer",
      "provisioned": true
    }
  },
  "lanes": {
    "docs-default": {
      "entries": [
        {"agent": "fixture-agent", "model": "gemini-3.8-flash-medium", "model_name": "Docs Default", "mode": "docs"}
      ]
    },
    "docs-model-arg": {
      "entries": [
        {"agent": "fixture-agent", "model": "test-model-docs-arg", "model_name": "Docs Arg", "mode": "docs"}
      ]
    },
    "docs-model-env": {
      "entries": [
        {"agent": "fixture-agent", "model": "test-model-docs-env", "model_name": "Docs Env", "mode": "docs"}
      ]
    },
    "docs-retry": {
      "entries": [
        {"agent": "fixture-agent", "model": "gemini-3.8-flash-medium", "model_name": "Docs Retry", "mode": "docs"}
      ]
    },
    "review-default": {
      "entries": [
        {"agent": "fixture-agent", "model": "gemini-4-argon-medium", "model_name": "Review Default", "mode": "review"}
      ]
    },
    "review-model-arg": {
      "entries": [
        {"agent": "fixture-agent", "model": "test-model-review-arg", "model_name": "Review Arg", "mode": "review"}
      ]
    },
    "review-dry-run": {
      "entries": [
        {"agent": "fixture-agent", "model": "gemini-4-argon-medium", "model_name": "Review Dry", "mode": "review"}
      ]
    },
    "review-retry": {
      "entries": [
        {"agent": "fixture-agent", "model": "gemini-4-argon-medium", "model_name": "Review Retry", "mode": "review"}
      ]
    }
  }
}
JSON

scenarios="docs-default docs-model-arg docs-model-env docs-retry review-default review-model-arg review-dry-run review-retry"

# normalize <home> <stdout-file>: replace temp paths and PIDs with placeholders.
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
    -e 's|AGY_PID=[0-9][0-9]*|AGY_PID=@PID@|g' \
    "$file"
}

write_capture() {
  local dest="$1"
  local status="$2"
  local argv_file="$3"
  local cwd_file="$4"
  local env_file="$5"
  local stdout_file="$6"
  local home="$7"

  {
    printf 'EXIT=%s\n' "$status"
    printf 'ARGV\n'
    normalize "$home" "$argv_file"
    printf 'END_ARGV\n'
    printf 'CWD\n'
    normalize "$home" "$cwd_file"
    printf 'END_CWD\n'
    printf 'ENV\n'
    normalize "$home" "$env_file"
    printf 'END_ENV\n'
    printf 'STDOUT\n'
    normalize "$home" "$stdout_file"
    printf 'END_STDOUT\n'
  } >"$dest"
}

make_home() {
  local home="$1"
  mkdir -p "$home/agy-work/repo" "$home/agy-inbox"
  printf 'repo readme\n' >"$home/agy-work/repo/README.md"
  printf 'Update the docs.\n' >"$home/agy-inbox/brief.txt"
}

# scenario_env <scenario>: prints an extra AGY_ assignment, or nothing.
scenario_env() {
  case "$1" in
    docs-model-env) printf 'AGY_DOCS_MODEL=test-model-docs-env\n' ;;
  esac
}

# wrapper_args <scenario> <home>
wrapper_args() {
  local scenario="$1"
  local home="$2"
  case "$scenario" in
    docs-default)
      printf '%s\n' repo "$home/agy-inbox/brief.txt"
      ;;
    docs-model-arg)
      printf '%s\n' repo "$home/agy-inbox/brief.txt" docs-model-arg test-model-docs-arg
      ;;
    docs-model-env | docs-retry)
      printf '%s\n' repo "$home/agy-inbox/brief.txt"
      ;;
    review-default)
      printf '%s\n' "run-$scenario" "$home/agy-work/repo" "$home/agy-inbox/brief.txt"
      ;;
    review-model-arg)
      printf '%s\n' "run-$scenario" "$home/agy-work/repo" "$home/agy-inbox/brief.txt" test-model-review-arg
      ;;
    review-dry-run)
      printf '%s\n' --dry-run "run-$scenario" "$home/agy-work/repo" "$home/agy-inbox/brief.txt"
      ;;
    review-retry)
      printf '%s\n' "run-$scenario" "$home/agy-work/repo" "$home/agy-inbox/brief.txt"
      ;;
  esac
}

# adapter_args <scenario> <home>
adapter_args() {
  local scenario="$1"
  local home="$2"
  case "$scenario" in
    docs-default | docs-model-env | docs-retry)
      printf '%s\n' repo "$home/agy-inbox/brief.txt"
      ;;
    docs-model-arg)
      printf '%s\n' repo "$home/agy-inbox/brief.txt" docs-model-arg
      ;;
    review-default | review-model-arg | review-retry)
      printf '%s\n' "run-$scenario" "$home/agy-work/repo" "$home/agy-inbox/brief.txt"
      ;;
    review-dry-run)
      printf '%s\n' --dry-run "run-$scenario" "$home/agy-work/repo" "$home/agy-inbox/brief.txt"
      ;;
  esac
}

empty_first() {
  case "$1" in
    docs-retry | review-retry) printf '1' ;;
    *) printf '0' ;;
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
  local argv_file="$dest.argv"
  local cwd_file="$dest.cwd"
  local env_file="$dest.env"
  local stdout_file="$dest.stdout"
  local stderr_file="$dest.stderr"
  local count_file="$dest.count"
  local status=0
  local launcher
  local extra_env

  : >"$argv_file"
  : >"$cwd_file"
  : >"$env_file"
  : >"$stdout_file"
  : >"$stderr_file"
  : >"$count_file"

  case "$impl" in
    wrapper)
      case "$scenario" in
        docs-*) launcher="$repo_root/scripts/agy-docs-launch.sh" ;;
        review-*) launcher="$repo_root/scripts/agy-review-launch.sh" ;;
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

  extra_env="$(scenario_env "$scenario")"

  (
    export HOME="$home"
    export PATH="$fake_bin:$tool_bin"
    export AGY_LAUNCH_STALL_SECONDS=0
    export FAKE_AGY_ARGV="$argv_file"
    export FAKE_AGY_CWD="$cwd_file"
    export FAKE_AGY_ENV="$env_file"
    export FAKE_AGY_COUNT="$count_file"
    fake_empty_first="$(empty_first "$scenario")"
    export FAKE_AGY_EMPTY_FIRST="$fake_empty_first"
    if [ -n "$extra_env" ]; then
      export "${extra_env?}"
    fi
    cd "$home" || exit 1
    if [ "$impl" = new ]; then
      /bin/bash "$launcher" --config "$config_file" --lane "$scenario" \
        --as maintainer -- "$@"
    elif [ "$impl" = adapter ]; then
      /bin/bash "$launcher" --mode review --model gemini-4-argon-medium \
        --dry-run -- "$@"
    else
      /bin/bash "$launcher" "$@"
    fi
  ) >"$stdout_file" 2>"$stderr_file"
  status=$?

  write_capture "$dest.capture" "$status" "$argv_file" "$cwd_file" \
    "$env_file" "$stdout_file" "$home"
}

# capture_scenario <scenario> <impl> [args...]
capture_scenario() {
  local scenario="$1"
  local impl="$2"
  shift 2
  local home="$work_tmp/home-$scenario-$impl"
  local dest="$work_tmp/capture-$scenario-$impl"
  make_home "$home"
  run_capture "$scenario" "$home" "$dest" "$impl" "$@"
  printf '%s\n' "$dest.capture"
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
  for scenario in $scenarios; do
    # shellcheck disable=SC2046 # wrapper_args prints one argument per line
    capture_file="$(capture_scenario "$scenario" wrapper $(wrapper_args "$scenario" "$work_tmp/home-$scenario-wrapper"))"
    cp "$capture_file" "$capture_out/golden-$scenario.txt"
    printf 'WROTE %s\n' "$capture_out/golden-$scenario.txt"
  done
  printf '\n%d passed, %d failed\n' "$pass" "$fail"
  if [ "$fail" -ne 0 ]; then
    exit 1
  fi
  exit 0
fi

for scenario in $scenarios; do
  # shellcheck disable=SC2046 # wrapper_args prints one argument per line
  actual_wrapper="$(capture_scenario "$scenario" wrapper $(wrapper_args "$scenario" "$work_tmp/home-$scenario-wrapper"))"
  golden="$fixtures_dir/golden-$scenario.txt"
  if cmp -s "$golden" "$actual_wrapper"; then
    ok "wrapper $scenario matches the golden capture"
  else
    bad "wrapper $scenario matches the golden capture" "diff: $(diff -u "$golden" "$actual_wrapper" | head -n 20)"
  fi
done

for scenario in $scenarios; do
  # shellcheck disable=SC2046 # adapter_args prints one argument per line
  actual_new="$(capture_scenario "$scenario" new $(adapter_args "$scenario" "$work_tmp/home-$scenario-new"))"
  golden="$fixtures_dir/golden-$scenario.txt"
  if cmp -s "$golden" "$actual_new"; then
    ok "agent-launch $scenario matches the golden capture"
  else
    bad "agent-launch $scenario matches the golden capture" "diff: $(diff -u "$golden" "$actual_new" | head -n 20)"
  fi
done

# The review dry-run path has no child process, so compare it through the
# adapter interface directly; the wrapper comparison above covers the wrapper.
actual_adapter="$(capture_scenario review-dry-run adapter "run-review-dry-run" "$work_tmp/home-review-dry-run-adapter/agy-work/repo" "$work_tmp/home-review-dry-run-adapter/agy-inbox/brief.txt")"
golden="$fixtures_dir/golden-review-dry-run.txt"
if cmp -s "$golden" "$actual_adapter"; then
  ok "adapter review-dry-run matches the golden capture"
else
  bad "adapter review-dry-run matches the golden capture" "diff: $(diff -u "$golden" "$actual_adapter" | head -n 20)"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -ne 0 ]; then
  exit 1
fi
exit 0
