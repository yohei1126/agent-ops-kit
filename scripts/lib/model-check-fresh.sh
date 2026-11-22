#!/usr/bin/env bash
# model-check-fresh named check for scripts/dev-loop-gate.sh.
# Sourced by the gate script, never run on its own. It expects row(), repo,
# pr_number_arg, gh_repo_arg, expect_head_arg, run_arg, and have_*_flag.
#
# Fail closed: a recorded or posted model-check result must match the live
# pull request head and the current UTC calendar day. Any FAIL exits 1, with
# or without --strict.
set -u

repo="${repo:-}"
pr_number_arg="${pr_number_arg:-}"
gh_repo_arg="${gh_repo_arg:-}"
expect_head_arg="${expect_head_arg:-}"
run_arg="${run_arg:-}"

usage_model_check_fresh() {
  cat <<'EOF'
usage: dev-loop-gate.sh --check model-check-fresh --pr <n>
                        [--gh-repo <owner/repo>] [--repo <checkout>]
                        [--run <dir>] [--expect-head <sha>]

--pr is required (or DEV_LOOP_PR when the flag is absent).
--gh-repo is optional (owner/repo; inferred from --repo when omitted).
--expect-head is optional (7+ hex chars; or DEV_LOOP_EXPECT_HEAD when absent).
--run <dir> is optional: also read <dir>/model-check.record.

The check reads gh pr view <n> --json headRefOid,comments from --repo and
prints MF rows:
  expect-head        Live head matches --expect-head (when given)
  freshness          Latest result matches live head and same UTC day
  model-check-fresh  Overall PASS or FAIL

"Same day" uses the UTC calendar date (YYYY-MM-DD), never the local machine
timezone. Posted comments (first line starting with "Model: ") use createdAt
and the first head-marker line matching either:
  gemini-batch-head: <7..40 hex chars>
  model-check-head: <7..40 hex chars>

Record file (<dir>/model-check.record) uses tab-separated keyed lines:
  head	<7..40 hex chars>
  time	<ISO-8601 timestamp>
Blank lines and # comments are ignored. Neither --run nor its record file may
be a symlink (exit 2). Both posted comments and the record file are considered;
the latest result by timestamp must pass. Missing or unreadable timestamps or
head markers fail closed.

Set DEV_LOOP_NOW to an ISO-8601 instant to pin "today" in tests.

Exit codes (fail closed: any FAIL exits 1 even without --strict):
  0  pass
  1  any FAIL
  2  usage error (missing --pr, bad --expect-head, symlink --run, etc.)
  3  gh or jq missing, a gh failure, or unreadable gh output
EOF
}

# ISO-8601 helper for jq: handles Z, fractional seconds, and [+-]HH:MM offsets.
# shellcheck disable=SC2016
mcf_jq_iso_helper='
def parse_iso:
  (capture("^(?<base>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(?:\\.[0-9]+)?(?<tz>Z|[+-][0-9]{2}:[0-9]{2})$") // error("bad iso"))
  | ((.base + "Z") | fromdateiso8601) as $t
  | if .tz == "Z" then $t
    else
      (.tz[0:1]) as $sign
      | (.tz[1:3] | tonumber) as $oh
      | (.tz[4:6] | tonumber) as $om
      | if ($oh > 23 or $om > 59) then error("bad offset")
        else
          (($oh * 3600) + ($om * 60)) as $off
          | if $sign == "+" then $t - $off else $t + $off end
        end
    end;
'

# Evaluates live head, posted comments, and optional record file.
# Outputs "<name>\t<status>\t<action>" rows.
# shellcheck disable=SC2016
mcf_jq_eval="${mcf_jq_iso_helper}"'
def head_from_body:
  (. | split("\n") | map(rtrimstr("\r"))) as $lines
  | if (($lines[0] // "") | startswith("Model: ")) | not then null
    else
      ([ $lines[]
         | capture("^(?:gemini-batch-head|model-check-head): (?<sha>[0-9a-fA-F]{7,40})[ \\t]*$")?
         | .sha ] | .[0] // "")
    end;

. as $pr
| if (($pr | type) != "object"
      or ($pr.headRefOid | type) != "string"
      or ($pr.headRefOid | length) == 0
      or ($pr.comments | type) != "array")
  then error("not a pull request object")
  else
    $pr.headRefOid as $live
    | ($live | ascii_downcase) as $live_lc
    | ($live[0:7]) as $short
    | (if $expect == "" then null
       elif ($live_lc | startswith($expect | ascii_downcase)) then
         ["expect-head", "PASS", $short]
       else
         ["expect-head", "FAIL",
          ("live head " + $short + " != expected " + $expect + "; re-read before checking")]
       end) as $expect_row
    | [
        ($pr.comments[]
         | select((.body | type) == "string" and (.body | startswith("Model: ")))
         | {
             source: "comment",
             raw_time: (.createdAt // ""),
             head: (.body | head_from_body)
           }),
        (if $rec_has == "1" then
           {
             source: "record",
             raw_time: $rec_time,
             head: (if ($rec_head | test("^[0-9a-fA-F]{7,40}$")) then $rec_head else "" end)
           }
         else empty end)
      ] as $raw_candidates
    | ($raw_candidates | map(
        . + { epoch: (if (.raw_time | type) == "string" and (.raw_time != "")
                      then (try (.raw_time | parse_iso) catch null)
                      else null end) }
      )) as $candidates
    | (if ($candidates | length) == 0 then
         ["FAIL", "missing result"]
       elif ($candidates | any(.epoch == null)) then
         ["FAIL", "timestamp missing or unreadable"]
       else
         ($candidates | sort_by(.epoch) | last) as $latest
         | ($latest.epoch | strftime("%Y-%m-%d")) as $rdate
         | if $latest.head == "" then
             ["FAIL", "head missing or unreadable in the result"]
           else
             ($latest.head | ascii_downcase) as $rhead_lc
             | ($latest.head[0:7]) as $rshort
             | if (($live_lc == $rhead_lc) or (($rhead_lc | length) >= 7 and ($live_lc | startswith($rhead_lc)))) | not then
                 ["FAIL", ("head moved: live " + $short + " != result " + $rshort)]
               elif $rdate != $today then
                 ["FAIL", ("result from a previous day: " + $rdate + " != today " + $today + " (UTC)")]
               else
                 ["PASS", ("matches live head " + $short + " on " + $today + " UTC (" + $latest.source + ")")]
               end
           end
       end) as $fresh
    | (if ($expect_row != null) and ($expect_row[1] == "FAIL") then
         ["FAIL", $expect_row[2]]
       else
         $fresh
       end) as $summary
    | (
        (if $expect_row != null then $expect_row else empty end),
        ["freshness", $fresh[0], $fresh[1]],
        ["model-check-fresh", $summary[0], $summary[1]]
      )
  end
| @tsv
'

run_model_check_fresh() {
  local pr_number expect_sha gh_slug today_utc
  local rec_file rec_has_data=0 rec_head="" rec_time=""
  local line key val
  local gh_err_file gh_json gh_status first_line
  local rows name state action any_fail=0

  if [ "${have_pr_flag:-0}" = 1 ]; then
    pr_number="$pr_number_arg"
    if [ -z "$pr_number" ]; then
      printf 'dev-loop-gate: --pr needs a number\n' >&2
      exit 2
    fi
  else
    pr_number="${DEV_LOOP_PR:-}"
    if [ -z "$pr_number" ]; then
      printf 'dev-loop-gate: --pr or DEV_LOOP_PR is required for model-check-fresh\n' >&2
      exit 2
    fi
  fi
  case "$pr_number" in
    *[!0-9]*)
      printf 'dev-loop-gate: --pr must be a number: %s\n' "$pr_number" >&2
      exit 2
      ;;
  esac

  if [ "${have_expect_head_flag:-0}" = 1 ]; then
    expect_sha="$expect_head_arg"
    if [ -z "$expect_sha" ]; then
      printf 'dev-loop-gate: --expect-head needs at least 7 characters\n' >&2
      exit 2
    fi
  else
    expect_sha="${DEV_LOOP_EXPECT_HEAD:-}"
  fi
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

  gh_slug="$gh_repo_arg"
  if [ "${have_gh_repo_flag:-0}" = 1 ] && [ -z "$gh_slug" ]; then
    printf 'dev-loop-gate: --gh-repo must be owner/repo: (empty)\n' >&2
    exit 2
  fi
  if [ -n "$gh_slug" ] && ! [[ "$gh_slug" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
    printf 'dev-loop-gate: --gh-repo must be owner/repo: %s\n' "$gh_slug" >&2
    exit 2
  fi

  if [ "${have_run_flag:-0}" = 1 ]; then
    if [ -L "$run_arg" ]; then
      printf 'dev-loop-gate: refusing symlinked --run directory: %s\n' "$run_arg" >&2
      exit 2
    fi
    if [ -e "$run_arg" ] && [ ! -d "$run_arg" ]; then
      printf 'dev-loop-gate: --run is not a directory: %s\n' "$run_arg" >&2
      exit 2
    fi
    rec_file="$run_arg/model-check.record"
    if [ -L "$rec_file" ]; then
      printf 'dev-loop-gate: refusing symlinked record file: %s\n' "$rec_file" >&2
      exit 2
    fi
    if [ -e "$rec_file" ] && [ ! -f "$rec_file" ]; then
      printf 'dev-loop-gate: record path is not a regular file: %s\n' "$rec_file" >&2
      exit 2
    fi
    if [ -f "$rec_file" ]; then
      while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        case "$line" in
          ''|\#*) continue ;;
        esac
        rec_has_data=1
        case "$line" in
          *$'\t'*)
            key="${line%%$'\t'*}"
            val="${line#*$'\t'}"
            case "$key" in
              head) rec_head="$val" ;;
              time) rec_time="$val" ;;
            esac
            ;;
        esac
      done < "$rec_file"
    fi
  fi

  if ! command -v gh >/dev/null 2>&1; then
    printf 'dev-loop-gate: gh is required for model-check-fresh\n' >&2
    exit 3
  fi
  if ! command -v jq >/dev/null 2>&1; then
    printf 'dev-loop-gate: jq is required for model-check-fresh\n' >&2
    exit 3
  fi

  if [ -n "${DEV_LOOP_NOW:-}" ]; then
    if ! today_utc="$(jq -rn --arg now "$DEV_LOOP_NOW" "${mcf_jq_iso_helper}"'$now | parse_iso | strftime("%Y-%m-%d")' 2>/dev/null)" || [ -z "$today_utc" ]; then
      printf 'dev-loop-gate: invalid DEV_LOOP_NOW timestamp: %s\n' "$DEV_LOOP_NOW" >&2
      exit 2
    fi
  else
    today_utc="$(date -u +%Y-%m-%d)"
  fi

  gh_err_file="$(mktemp "${TMPDIR:-/tmp}/dev-loop-gate-mcf.XXXXXX")"
  trap 'rm -f "$gh_err_file"' EXIT
  trap 'rm -f "$gh_err_file"; exit 130' INT
  trap 'rm -f "$gh_err_file"; exit 143' TERM

  set -- pr view "$pr_number"
  if [ -n "$gh_slug" ]; then
    set -- "$@" -R "$gh_slug"
  fi
  set -- "$@" --json headRefOid,comments

  gh_json="$(cd "$repo" && gh "$@" 2>"$gh_err_file")"
  gh_status=$?
  first_line=""
  IFS= read -r first_line < "$gh_err_file" || true
  rm -f "$gh_err_file"
  trap - EXIT INT TERM

  if [ "$gh_status" -ne 0 ]; then
    printf 'dev-loop-gate: gh failed: %s\n' "$first_line" >&2
    exit 3
  fi

  case "$gh_json" in
    *[![:space:]]*) ;;
    *)
      printf 'dev-loop-gate: could not read the gh JSON output\n' >&2
      exit 3
      ;;
  esac

  if ! rows="$(printf '%s' "$gh_json" | jq -er \
    --arg expect "$expect_sha" \
    --arg today "$today_utc" \
    --arg rec_has "$rec_has_data" \
    --arg rec_head "$rec_head" \
    --arg rec_time "$rec_time" \
    "$mcf_jq_eval" 2>/dev/null)"; then
    printf 'dev-loop-gate: could not read the gh JSON output\n' >&2
    exit 3
  fi

  row Gate Name Status Action
  row ---- ------------------------------ ------ ------

  while IFS=$'\t' read -r name state action; do
    [ -n "$name" ] || continue
    row MF "$name" "$state" "$action"
    if [ "$state" = FAIL ]; then
      any_fail=1
    fi
  done <<EOF
$rows
EOF

  if [ "$any_fail" = 1 ]; then
    return 1
  fi
  return 0
}
