#!/usr/bin/env bash
# Named check: pr-state. Sourced by dev-loop-gate.sh.
# Reads one pull request through the GitHub CLI. Needs network, gh, and jq.
# Never prints tokens, environment values, or command lines.
#
# Globals provided by dev-loop-gate.sh: pr_number_arg, gh_repo_arg,
# expect_head_arg, repo, strict. shellcheck cannot see the caller.
# shellcheck disable=SC2154

pr_state_jq_program="$(cat <<'JQ'
def kind:
  if type != "object" then "pending"
  elif (has("conclusion") or ((."__typename" // "") == "CheckRun")) then
    (.conclusion // "") as $c
    | if ($c == "SUCCESS" or $c == "NEUTRAL" or $c == "SKIPPED") then "success"
      elif ($c == "FAILURE" or $c == "CANCELLED" or $c == "TIMED_OUT"
            or $c == "ACTION_REQUIRED" or $c == "STARTUP_FAILURE") then "failure"
      else "pending" end
  else
    (.state // "") as $s
    | if $s == "SUCCESS" then "success"
      elif ($s == "FAILURE" or $s == "ERROR") then "failure"
      else "pending" end
  end;

. as $pr
| ($pr.statusCheckRollup // []) as $rollup
| ($rollup | map(kind)) as $kinds
| ($kinds | map(select(. == "failure")) | length) as $failed
| ($kinds | map(select(. == "pending")) | length) as $pending
| ($kinds | map(select(. == "success")) | length) as $ok
| ($pr.headRefOid // "") as $head
| ($head[0:7]) as $short
| ($pr.mergeable // "UNKNOWN") as $mergeable
| (
    ["state", "PASS", ($pr.state // "UNKNOWN")],
    ["draft", "PASS", (if $pr.isDraft then "true" else "false" end)],
    (if $expect == "" then
       ["head", "PASS", $short]
     elif (($head | ascii_downcase) | startswith($expect | ascii_downcase)) then
       ["head", "PASS", $short]
     else
       ["head", "FAIL",
        ("live head " + $short + " != expected " + $expect
         + "; re-read before reporting")]
     end),
    ["mergeable", "PASS",
     (if $mergeable == "UNKNOWN" then
        "GitHub still computing; re-run later"
      else $mergeable end)],
    (if ($kinds | length) == 0 then
       ["checks", "PASS", "no checks"]
     elif $failed > 0 then
       ["checks", "FAIL", ("failure " + ($failed | tostring))]
     elif $pending > 0 then
       ["checks", "PASS", ("pending " + ($pending | tostring))]
     else
       ["checks", "PASS", ("success " + ($ok | tostring))]
     end)
  )
| @tsv
JQ
)"

# Usage errors exit 2. Missing gh or jq exits 3. A gh call failure exits 3.
# A FAIL row exits 1 only under --strict.
run_pr_state() {
  local pr_number expect_sha gh_slug gh_fields
  local gh_err_file gh_json gh_status first_line
  local rows name state action any_fail

  pr_number="${pr_number_arg:-${DEV_LOOP_PR:-}}"
  expect_sha="${expect_head_arg:-${DEV_LOOP_EXPECT_HEAD:-}}"
  gh_slug="$gh_repo_arg"

  if [ -z "$pr_number" ]; then
    printf 'dev-loop-gate: --pr or DEV_LOOP_PR is required for pr-state\n' >&2
    exit 2
  fi
  case "$pr_number" in
    *[!0-9]*)
      printf 'dev-loop-gate: --pr must be a number: %s\n' "$pr_number" >&2
      exit 2
      ;;
  esac

  if [ -n "$expect_sha" ]; then
    case "$expect_sha" in
      *[!0-9a-fA-F]*)
        printf 'dev-loop-gate: --expect-head must be a hex SHA prefix\n' >&2
        exit 2
        ;;
    esac
    if [ "${#expect_sha}" -lt 7 ]; then
      printf 'dev-loop-gate: --expect-head needs at least 7 characters\n' >&2
      exit 2
    fi
  fi

  if [ -n "$gh_slug" ]; then
    if ! [[ "$gh_slug" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
      printf 'dev-loop-gate: --gh-repo must be owner/repo: %s\n' "$gh_slug" >&2
      exit 2
    fi
  fi

  if ! command -v gh >/dev/null 2>&1; then
    printf 'dev-loop-gate: gh is required for pr-state\n' >&2
    exit 3
  fi
  if ! command -v jq >/dev/null 2>&1; then
    printf 'dev-loop-gate: jq is required for pr-state\n' >&2
    exit 3
  fi

  gh_fields="number,state,isDraft,headRefOid,mergeable,mergeStateStatus,statusCheckRollup,url"
  gh_err_file="$(mktemp "${TMPDIR:-/tmp}/dev-loop-gate-gh.XXXXXX")"

  set -- pr view "$pr_number"
  if [ -n "$gh_slug" ]; then
    set -- "$@" -R "$gh_slug"
  fi
  set -- "$@" --json "$gh_fields"

  gh_json="$(cd "$repo" && gh "$@" 2>"$gh_err_file")"
  gh_status=$?
  first_line=""
  IFS= read -r first_line < "$gh_err_file"
  rm -f "$gh_err_file"

  if [ "$gh_status" -ne 0 ]; then
    printf 'dev-loop-gate: gh failed: %s\n' "$first_line" >&2
    exit 3
  fi

  if ! rows="$(printf '%s' "$gh_json" | jq -r --arg expect "$expect_sha" "$pr_state_jq_program" 2>/dev/null)"; then
    printf 'dev-loop-gate: could not read the gh JSON output\n' >&2
    exit 3
  fi

  row Gate Name Status Action
  row ---- ------------------------------ ------ ------

  any_fail=0
  while IFS=$'\t' read -r name state action; do
    if [ -z "$name" ]; then
      continue
    fi
    row PR "$name" "$state" "$action"
    if [ "$state" = FAIL ]; then
      any_fail=1
    fi
  done <<EOF
$rows
EOF

  row PR fetched PASS "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  if [ "$any_fail" = 1 ] && [ "$strict" = 1 ]; then
    return 1
  fi
  return 0
}
