#!/usr/bin/env bash
# Thin local gate table for templates/dev-loop. No network, no secrets.
# Prints one status per gate: PASS, FAIL, SKIP, JUDGE, or QUIET.
# Exit 1 only on a hard preflight miss (G1). Otherwise exit 0.
# With --strict, any FAIL exits 1.
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
script_root="$(cd "$script_dir/.." && pwd)"

usage() {
  printf '%s\n' \
    'usage: dev-loop-gate.sh [--config <path>] [--repo <root>] [--check <id>] [--strict]' \
    '       dev-loop-gate.sh --check pr-state --pr <number> [--gh-repo <owner/repo>]' \
    '                        [--expect-head <sha>]' \
    '' \
    'Options:' \
    '  --config <path>  Gate config JSON. Default: templates/dev-loop/gate.config.json' \
    '                   next to this script. A missing default uses a 500-line cap.' \
    '  --repo <root>    Any git work tree. Default: the work tree of the cwd.' \
    '  --check <id>     Run one named check: line-cap or pr-state.' \
    '  --strict         Exit 1 when any row or check is FAIL.' \
    '  --pr <number>    Pull request for pr-state. Env: DEV_LOOP_PR.' \
    '  --gh-repo <slug> owner/repo for pr-state. Default: infer from --repo.' \
    '  --expect-head <sha> Expected head SHA prefix for pr-state, 7 or more' \
    '                   characters. Env: DEV_LOOP_EXPECT_HEAD.' \
    '  -h, --help       Show this help.' \
    '' \
    'Exit codes: 0 pass or advisory, 1 strict or G1 failure, 2 usage or config' \
    'error, 3 required command missing or gh read failure.'
}

config_path=""
repo_arg=""
check_id=""
have_check=0
strict=0
pr_number_arg=""
gh_repo_arg=""
expect_head_arg=""
pr_flags_used=0
have_pr_flag=0
have_gh_repo_flag=0
have_expect_head_flag=0

while [ $# -gt 0 ]; do
  case "$1" in
    --config)
      if [ $# -lt 2 ]; then
        printf 'dev-loop-gate: --config needs a path\n' >&2
        usage >&2
        exit 2
      fi
      config_path="$2"
      shift 2
      ;;
    --config=*)
      config_path="${1#--config=}"
      shift
      ;;
    --repo)
      if [ $# -lt 2 ]; then
        printf 'dev-loop-gate: --repo needs a path\n' >&2
        usage >&2
        exit 2
      fi
      repo_arg="$2"
      shift 2
      ;;
    --repo=*)
      repo_arg="${1#--repo=}"
      shift
      ;;
    --check)
      if [ $# -lt 2 ]; then
        printf 'dev-loop-gate: --check needs an id\n' >&2
        usage >&2
        exit 2
      fi
      check_id="$2"
      have_check=1
      shift 2
      ;;
    --check=*)
      check_id="${1#--check=}"
      have_check=1
      shift
      ;;
    --strict)
      strict=1
      shift
      ;;
    --pr)
      if [ $# -lt 2 ]; then
        printf 'dev-loop-gate: --pr needs a number\n' >&2
        usage >&2
        exit 2
      fi
      pr_number_arg="$2"
      pr_flags_used=1
      have_pr_flag=1
      shift 2
      ;;
    --pr=*)
      pr_number_arg="${1#--pr=}"
      pr_flags_used=1
      have_pr_flag=1
      shift
      ;;
    --gh-repo)
      if [ $# -lt 2 ]; then
        printf 'dev-loop-gate: --gh-repo needs owner/repo\n' >&2
        usage >&2
        exit 2
      fi
      gh_repo_arg="$2"
      pr_flags_used=1
      have_gh_repo_flag=1
      shift 2
      ;;
    --gh-repo=*)
      gh_repo_arg="${1#--gh-repo=}"
      pr_flags_used=1
      have_gh_repo_flag=1
      shift
      ;;
    --expect-head)
      if [ $# -lt 2 ]; then
        printf 'dev-loop-gate: --expect-head needs a SHA prefix\n' >&2
        usage >&2
        exit 2
      fi
      expect_head_arg="$2"
      pr_flags_used=1
      have_expect_head_flag=1
      shift 2
      ;;
    --expect-head=*)
      expect_head_arg="${1#--expect-head=}"
      pr_flags_used=1
      have_expect_head_flag=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'dev-loop-gate: unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ "$pr_flags_used" = 1 ] && [ "$check_id" != "pr-state" ]; then
  printf 'dev-loop-gate: --pr, --gh-repo, and --expect-head need --check pr-state\n' >&2
  usage >&2
  exit 2
fi

# The table keeps working outside a git work tree and without git installed,
# as it did before the named checks existed. Only --check needs both.
repo=""

require_git() {
  if ! command -v git >/dev/null 2>&1; then
    printf 'dev-loop-gate: git is required\n' >&2
    exit 3
  fi
}

resolve_repo() {
  local repo_dir repo_top

  if [ -n "$repo_arg" ]; then
    repo_dir="$repo_arg"
  else
    repo_dir="$PWD"
  fi

  if ! repo_top="$(git -C "$repo_dir" rev-parse --show-toplevel 2>/dev/null)"; then
    printf 'dev-loop-gate: not a git work tree: %s\n' "$repo_dir" >&2
    exit 2
  fi
  if [ -z "$repo_top" ]; then
    printf 'dev-loop-gate: not a git work tree: %s\n' "$repo_dir" >&2
    exit 2
  fi
  repo="$repo_top"
}

row() { printf '%-4s %-30s %-6s %s\n' "$1" "$2" "$3" "$4"; }

run_table() {
  local status=0 any_fail=0

  if [ -n "$repo_arg" ] && command -v git >/dev/null 2>&1; then
    resolve_repo
  fi

  expected_branch="${DEV_LOOP_BRANCH:-}"
  alias_name="${DEV_LOOP_ALIAS:-}"
  required_path="${DEV_LOOP_REQUIRED_PATH:-}"
  soft_deny_count="${DEV_LOOP_SOFT_DENY_COUNT:-0}"
  model_lane="${DEV_LOOP_MODEL_LANE:-grok}"
  diff_kind="${DEV_LOOP_DIFF_KIND:-other}"
  pr_state="${DEV_LOOP_PR_STATE:-draft}"
  operator_ready="${DEV_LOOP_OPERATOR_READY:-false}"
  vuln_silent="${DEV_LOOP_VULN_SILENT:-false}"
  retro_marker="${DEV_LOOP_RETRO_MARKER:-absent}"
  open_jobs="${DEV_LOOP_OPEN_JOBS:-1}"
  open_prs="${DEV_LOOP_OPEN_PRS:-1}"

  for name in soft_deny_count open_jobs open_prs; do
    value="${!name}"
    case "$value" in ''|*[!0-9]*) printf -v "$name" '%s' 0 ;; esac
  done

  row Gate Name Status Action
  row ---- ------------------------------ ------ ------
  branch_now="$(git -C "${repo_arg:-$PWD}" rev-parse --abbrev-ref HEAD 2>/dev/null || printf 'unknown')"
  g1=PASS; g1_action="Continue."
  if [ -n "$expected_branch" ] && [ "$branch_now" != "$expected_branch" ]; then
    g1=FAIL; g1_action="Do not start; branch is $branch_now. One-line FYI."
  elif [ -n "$alias_name" ] && [ ! -d "$HOME/agy-work/$alias_name" ]; then
    g1=FAIL; g1_action="Do not start; checkout path missing. One-line FYI."
  elif [ -n "$required_path" ] && [ ! -e "$required_path" ]; then
    g1=FAIL; g1_action="Do not start; required path missing. One-line FYI."
  elif [ "$open_jobs" -gt 1 ] || [ "$open_prs" -gt 1 ]; then
    g1=FAIL; g1_action="Do not start; worktree lock needs 1 PR / 1 Issue per job."
  fi
  if [ "$g1" = FAIL ]; then
    status=1
    any_fail=1
  fi
  row G1 "checkout + worktree lock" "$g1" "$g1_action"
  if [ "$soft_deny_count" -lt 2 ] || [ "${model_lane#opencode}" != "$model_lane" ]; then
    g2=PASS; g2_action="Continue."
  else
    g2=FAIL; g2_action="Switch to OpenCode Flash; never widen Allow."
  fi
  row G2 "soft-deny" "$g2" "$g2_action"
  if [ "$diff_kind" = "lock_and_constraint" ]; then
    g3=SKIP; g3_action="Argon SKIP; light review only."
  else
    g3=JUDGE; g3_action="Argon-need via RUBRIC tier A; not an Argon skip."
  fi
  row G3 "lock + matching constraint" "$g3" "$g3_action"
  if [ "$pr_state" = "draft" ] || { [ "$pr_state" = "ready" ] && [ "$operator_ready" = "true" ]; }; then
    g4=PASS; g4_action="Continue."
  else
    g4=FAIL; g4_action="Create or convert the pull request to draft."
  fi
  row G4 "draft" "$g4" "$g4_action"
  if [ "$vuln_silent" = "true" ]; then
    g5=FAIL; g5_action="Block; report every finding with its source."
  else
    g5=PASS; g5_action="Continue."
  fi
  row G5 "vulnerability silence" "$g5" "$g5_action"
  if [ "$retro_marker" = "present" ]; then
    g6=PASS; g6_action="Ingest path may run."
  else
    g6=QUIET; g6_action="Stay quiet; v1 silence, no invented retro."
  fi
  row G6 "RETRO ingest" "$g6" "$g6_action"
  if [ "$open_jobs" -le 1 ] && [ "$open_prs" -le 1 ]; then
    g7=PASS; g7_action="Continue."
  else
    g7=FAIL; g7_action="Refuse new job; completion report only."
  fi
  row G7 "one job" "$g7" "$g7_action"

  if [ "$g2" = FAIL ] || [ "$g4" = FAIL ] || [ "$g5" = FAIL ] || [ "$g7" = FAIL ]; then
    any_fail=1
  fi
  if [ "$strict" = 1 ] && [ "$any_fail" = 1 ]; then
    return 1
  fi
  return "$status"
}

config_errors_program="$(cat <<'JQ'
def isposint: (type == "number") and (. > 0) and (. == (. | floor));
if (.line_cap | type) != "object" then
  "line_cap must be an object"
else
  (if (.line_cap.default | isposint | not) then
     "line_cap.default must be a positive integer"
   else empty end),
  (if (.line_cap.exceptions | type) != "array" then
     "line_cap.exceptions must be an array"
   else empty end),
  ((if (.line_cap.exceptions | type) == "array" then .line_cap.exceptions else [] end)
   | to_entries[]
   | .key as $i
   | .value as $e
   | if ($e | type) != "object" then
       "line_cap.exceptions[\($i)] must be an object"
     else
       (if (($e | has("path")) and ($e | has("pattern"))) then
          "line_cap.exceptions[\($i)] has both path and pattern; use exactly one"
        else empty end),
       (if (((($e | has("path")) or ($e | has("pattern"))) | not)) then
          "line_cap.exceptions[\($i)] needs one of path or pattern"
        else empty end),
       (if ($e | has("path")) and ((($e.path | type) != "string") or (($e.path | length) == 0)) then
          "line_cap.exceptions[\($i)].path must be a non-empty string"
        else empty end),
       (if ($e | has("pattern")) and ((($e.pattern | type) != "string") or (($e.pattern | length) == 0)) then
          "line_cap.exceptions[\($i)].pattern must be a non-empty string"
        else empty end),
       (if ($e | has("pattern")) and (($e.pattern | type) == "string") and
           (((($e.pattern | startswith("^")) | not) or (($e.pattern | endswith("$")) | not))) then
          "line_cap.exceptions[\($i)].pattern must start with ^ and end with $"
        else empty end),
       (if ($e | has("pattern")) and (($e.pattern | type) == "string") and
           (($e.pattern | contains(".*")) or ($e.pattern | contains("**"))) then
          "line_cap.exceptions[\($i)].pattern must not contain broad globs (.* or **)"
        else empty end),
       (if ($e.cap | isposint | not) then
          "line_cap.exceptions[\($i)].cap must be a positive integer"
        else empty end),
       (if (($e.reason | type) != "string") or (($e.reason | length) == 0) then
          "line_cap.exceptions[\($i)].reason must be a non-empty single-line string"
        elif ($e.reason | test("\n")) then
          "line_cap.exceptions[\($i)].reason must be a non-empty single-line string"
        else empty end)
     end)
end
JQ
)"

default_cap=500
exceptions_blob=""

load_config() {
  local cfg
  local errors

  if [ -n "$config_path" ]; then
    cfg="$config_path"
    if [ ! -f "$cfg" ]; then
      printf 'dev-loop-gate: config file not found: %s\n' "$cfg" >&2
      exit 2
    fi
  else
    cfg="$script_root/templates/dev-loop/gate.config.json"
    if [ ! -f "$cfg" ]; then
      return 0
    fi
  fi

  if ! command -v jq >/dev/null 2>&1; then
    printf 'dev-loop-gate: jq is required to read %s\n' "$cfg" >&2
    exit 3
  fi

  if ! jq -e 'type == "object"' "$cfg" >/dev/null 2>&1; then
    printf 'dev-loop-gate: config must be a JSON object: %s\n' "$cfg" >&2
    exit 2
  fi

  if ! errors="$(jq -r "$config_errors_program" "$cfg" 2>/dev/null)"; then
    printf 'dev-loop-gate: config is not valid JSON: %s\n' "$cfg" >&2
    exit 2
  fi

  if [ -n "$errors" ]; then
    while IFS= read -r msg; do
      printf 'dev-loop-gate: config error: %s\n' "$msg" >&2
    done <<EOF
$errors
EOF
    exit 2
  fi

  default_cap="$(jq -r '.line_cap.default' "$cfg")"
  exceptions_blob="$(jq -r '.line_cap.exceptions[] | [(.path // ""), (.pattern // ""), (.cap | tostring)] | join("\u001f")' "$cfg")"
}

cap_for_path() {
  local path="$1"
  local cap="$default_cap"
  local e_path e_pattern e_cap

  if [ -n "$exceptions_blob" ]; then
    while IFS=$'\x1f' read -r e_path e_pattern e_cap; do
      if [ -n "$e_path" ] && [ "$path" = "$e_path" ]; then
        cap="$e_cap"
        break
      fi
      if [ -n "$e_pattern" ] && [[ "$path" =~ $e_pattern ]]; then
        cap="$e_cap"
        break
      fi
    done <<EOF
$exceptions_blob
EOF
  fi
  printf '%s' "$cap"
}

run_line_cap() {
  local checked=0
  local failed=0
  local path n cap action state

  load_config

  row Gate Name Status Action
  row ---- ------------------------------ ------ ------

  while IFS= read -r -d '' path; do
    if [ ! -f "$repo/$path" ]; then
      continue
    fi
    n="$(wc -l < "$repo/$path" 2>/dev/null)"
    n="${n//[!0-9]/}"
    if [ -z "$n" ]; then
      n=0
    fi
    checked=$((checked + 1))
    cap="$(cap_for_path "$path")"
    if [ "$n" -gt "$cap" ]; then
      failed=$((failed + 1))
      action="$n lines > cap $cap; split before adding."
      row LC "$path" FAIL "$action"
    fi
  done < <(git -C "$repo" ls-files -z -- '*.md')

  if [ "$failed" -gt 0 ]; then
    state=FAIL
  else
    state=PASS
  fi
  action="$checked files checked, $failed over cap."
  row LC line-cap "$state" "$action"

  if [ "$failed" -gt 0 ] && [ "$strict" = 1 ]; then
    return 1
  fi
  return 0
}

if [ "$have_check" = 0 ]; then
  run_table
  exit $?
fi

require_git
resolve_repo

case "$check_id" in
  line-cap)
    run_line_cap
    exit $?
    ;;
  pr-state)
    if [ ! -f "$script_dir/lib/pr-state.sh" ]; then
      printf 'dev-loop-gate: missing library: %s\n' "$script_dir/lib/pr-state.sh" >&2
      exit 2
    fi
    # shellcheck source-path=SCRIPTDIR
    # shellcheck source=lib/pr-state.sh
    . "$script_dir/lib/pr-state.sh"
    run_pr_state
    exit $?
    ;;
  docs-sweep|child-env|deploy-hash|all-offline|all)
    printf 'check %s is not implemented yet\n' "$check_id" >&2
    exit 2
    ;;
  *)
    printf 'unknown check: %s\n' "$check_id" >&2
    exit 2
    ;;
esac
