#!/usr/bin/env bash
# review-ready named check for scripts/dev-loop-gate.sh.
# Sourced by the gate script, never run on its own. It expects row(), repo,
# script_dir, and the pr flag globals (pr_number_arg, expect_head_arg,
# gh_repo_arg, have_*_flag) plus test_log_arg and evidence_out_arg.
#
# Fail closed: a model review starts only when CI is green for the exact head
# under review, the checkout is at that head, and the offline named checks
# pass. Any FAIL exits 1, with or without --strict.
set -u

repo="${repo:-}"
script_dir="${script_dir:-}"
pr_number_arg="${pr_number_arg:-}"
expect_head_arg="${expect_head_arg:-}"
gh_repo_arg="${gh_repo_arg:-}"
test_log_arg="${test_log_arg:-}"
evidence_out_arg="${evidence_out_arg:-}"

# Offline named checks the review needs. An id this kit version does not
# implement is a SKIP row, so the list can name checks from other branches.
review_ready_checks="${DEV_LOOP_REVIEW_READY_CHECKS:-line-cap docs-sweep prose-dashes md-links model-ids}"

# Prints "<STATE>\t<action>\t<names>" for the statusCheckRollup.
# shellcheck disable=SC2016 # a jq program, not shell expansions
review_ready_ci_jq='
def good_run: (.status == "COMPLETED") and
  ((.conclusion // "") as $c | ($c == "SUCCESS" or $c == "NEUTRAL" or $c == "SKIPPED"));
def is_ctx: (.__typename == "StatusContext") or (has("context") and has("state"));
def check_label: (.name // .context // "?");
def pending: if is_ctx then (.state == "PENDING" or .state == "EXPECTED")
  else ((.status // "") != "COMPLETED") end;
def good: if is_ctx then .state == "SUCCESS" else good_run end;
def names: (map(check_label) | if length > 5 then (.[0:5] | join(", ")) + ", ..." else join(", ") end);
(.statusCheckRollup // []) as $all
| ($all | map(select(pending))) as $pend
| ($all | map(select((pending | not) and (good | not)))) as $bad
| [$all[] | "\(check_label)=\(.conclusion // .state // .status // "?")"] as $summary
| if ($all | length) == 0 then
    ["FAIL", "no checks reported; wait for CI before review", ""]
  elif ($bad | length) > 0 then
    ["FAIL", "\($bad | length) failing: \($bad | names); fix CI before review", ($summary | join(", "))]
  elif ($pend | length) > 0 then
    ["FAIL", "\($pend | length) pending: \($pend | names); wait for CI to finish", ($summary | join(", "))]
  else
    ["PASS", "\($all | length) checks green", ($summary | join(", "))]
  end
| @tsv
'

run_review_ready() {
  local pr expect gh_json first_line live_head local_head
  local ci_line ci_state ci_action ci_summary
  local rows_file fails=0 id err_file status

  pr="$pr_number_arg"
  if [ "${have_pr_flag:-0}" != 1 ]; then
    pr="${DEV_LOOP_PR:-}"
  fi
  expect="$expect_head_arg"
  if [ "${have_expect_head_flag:-0}" != 1 ]; then
    expect="${DEV_LOOP_EXPECT_HEAD:-}"
  fi
  if [ -z "$pr" ] || [ -z "$expect" ]; then
    printf 'dev-loop-gate: review-ready needs --pr and --expect-head so the review is pinned to one head\n' >&2
    exit 2
  fi
  case "$pr" in
    *[!0-9]*)
      printf 'dev-loop-gate: --pr must be a number: %s\n' "$pr" >&2
      exit 2
      ;;
  esac
  case "$expect" in
    *[!0-9a-fA-F]*)
      printf 'dev-loop-gate: --expect-head must be a hex SHA prefix\n' >&2
      exit 2
      ;;
  esac
  if [ "${#expect}" -lt 7 ]; then
    printf 'dev-loop-gate: --expect-head needs at least 7 characters\n' >&2
    exit 2
  fi
  if [ -n "$gh_repo_arg" ] && ! [[ "$gh_repo_arg" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
    printf 'dev-loop-gate: --gh-repo must be owner/repo: %s\n' "$gh_repo_arg" >&2
    exit 2
  fi
  if [ -n "$test_log_arg" ] && { [ ! -f "$test_log_arg" ] || [ ! -r "$test_log_arg" ]; }; then
    printf 'dev-loop-gate: --test-log is not a readable file: %s\n' "$test_log_arg" >&2
    exit 2
  fi
  if [ -n "$evidence_out_arg" ] && [ -L "$evidence_out_arg" ]; then
    printf 'dev-loop-gate: refusing symlinked --evidence-out: %s\n' "$evidence_out_arg" >&2
    exit 2
  fi
  if ! command -v gh >/dev/null 2>&1; then
    printf 'dev-loop-gate: gh is required for review-ready\n' >&2
    exit 3
  fi
  if ! command -v jq >/dev/null 2>&1; then
    printf 'dev-loop-gate: jq is required for review-ready\n' >&2
    exit 3
  fi

  err_file="$(mktemp "${TMPDIR:-/tmp}/review-ready-err.XXXXXX")"
  rows_file="$(mktemp "${TMPDIR:-/tmp}/review-ready-rows.XXXXXX")"
  trap 'rm -f "$err_file" "$rows_file"' EXIT

  set -- pr view "$pr"
  if [ -n "$gh_repo_arg" ]; then
    set -- "$@" -R "$gh_repo_arg"
  fi
  set -- "$@" --json headRefOid,statusCheckRollup
  status=0
  gh_json="$(cd "$repo" && gh "$@" 2>"$err_file")" || status=$?
  if [ "$status" -ne 0 ]; then
    first_line=""
    IFS= read -r first_line <"$err_file" || true
    printf 'dev-loop-gate: gh failed: %s\n' "$first_line" >&2
    exit 3
  fi
  if ! live_head="$(printf '%s' "$gh_json" | jq -er '.headRefOid | strings' 2>/dev/null)" ||
    ! ci_line="$(printf '%s' "$gh_json" | jq -er "$review_ready_ci_jq" 2>/dev/null)"; then
    printf 'dev-loop-gate: could not read the gh JSON output\n' >&2
    exit 3
  fi
  IFS=$'\t' read -r ci_state ci_action ci_summary <<EOF_CI
$ci_line
EOF_CI

  {
    row Gate Name Status Action
    row ---- ------------------------------ ------ ------
    case "$live_head" in
      "$expect"*) row RR head PASS "${live_head:0:12}" ;;
      *)
        row RR head FAIL "live head ${live_head:0:12} != expected $expect; re-read the PR and pass the current head"
        fails=$((fails + 1))
        ;;
    esac
    local_head="$(git -C "$repo" rev-parse HEAD 2>/dev/null || printf 'none')"
    case "$local_head" in
      "$expect"*) row RR checkout PASS "${local_head:0:12}" ;;
      *)
        row RR checkout FAIL "checkout is at ${local_head:0:12}; check out the PR head before review"
        fails=$((fails + 1))
        ;;
    esac
    row RR ci "$ci_state" "$ci_action"
    if [ "$ci_state" != PASS ]; then
      fails=$((fails + 1))
    fi
    for id in $review_ready_checks; do
      status=0
      "$script_dir/dev-loop-gate.sh" --strict --check "$id" --repo "$repo" \
        >/dev/null 2>"$err_file" || status=$?
      if [ "$status" -eq 0 ]; then
        row RR "$id" PASS "Continue."
      elif [ "$status" -eq 2 ] && grep -q 'unknown check' "$err_file"; then
        row RR "$id" SKIP "not in this kit version"
      else
        row RR "$id" FAIL "$id failed; run scripts/dev-loop-gate.sh --strict --check $id and fix the rows"
        fails=$((fails + 1))
      fi
    done
    if [ "$fails" -gt 0 ]; then
      row RR review-ready FAIL "$fails rows failed"
    else
      row RR review-ready PASS "0 rows failed"
    fi
  } >"$rows_file"
  cat "$rows_file"

  if [ "$fails" -gt 0 ]; then
    rm -f "$err_file" "$rows_file"
    trap - EXIT
    return 1
  fi

  if [ -n "$evidence_out_arg" ]; then
    {
      printf '## Machine evidence (settled; do not re-check)\n\n'
      printf 'Head: %s\n\n' "$live_head"
      printf 'CI: %s\n\n' "$ci_summary"
      printf 'Gate rows:\n\n```text\n'
      cat "$rows_file"
      printf '```\n\n'
      if [ -n "$test_log_arg" ]; then
        printf 'Test log tail (%s, last 40 lines):\n\n```text\n' "$test_log_arg"
        tail -n 40 "$test_log_arg"
        printf '```\n\n'
      else
        printf 'Test log tail: none provided.\n\n'
      fi
      printf 'Review only what these checks cannot decide: design, correctness, security, and the acceptance criteria of the linked Issue.\n'
    } >"$evidence_out_arg"
  fi
  rm -f "$err_file" "$rows_file"
  trap - EXIT
  return 0
}
