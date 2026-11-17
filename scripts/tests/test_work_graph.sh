#!/usr/bin/env bash
# Tests for scripts/work-graph.sh.
# Uses a fake gh on PATH. No network and no real repository.
set -u

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
check="$repo_root/scripts/work-graph.sh"
fixtures="$repo_root/scripts/tests/fixtures/work-graph"

pass=0
fail=0
work_tmp="$(mktemp -d)"
home_tmp="$work_tmp/home"
fake_bin="$work_tmp/bin"
argv_file="$work_tmp/argv"
err_file="$work_tmp/stderr"

mkdir -p "$home_tmp" "$fake_bin"
: > "$argv_file"
: > "$err_file"

trap 'rm -rf "$work_tmp"' EXIT

unset WORK_GRAPH_NOW WORK_GRAPH_ARGV_FILE WORK_GRAPH_GH_FAIL WORK_GRAPH_GH_JSON

# Fixed clock: 2026-01-10T00:00:00Z.
now_epoch=1768003200

cat > "$fake_bin/gh" <<'EOF'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${WORK_GRAPH_ARGV_FILE:-/dev/null}"
if [ "${WORK_GRAPH_GH_FAIL:-0}" = 1 ]; then
  printf 'gh: boom, not logged in\n' >&2
  printf 'gh: see the log\n' >&2
  exit 1
fi
if [ -n "${WORK_GRAPH_GH_JSON:-}" ]; then
  cat "$WORK_GRAPH_GH_JSON"
  exit 0
fi
printf '%s\n' '{"data":{"repository":{"issues":{"nodes":[]},"pullRequests":{"nodes":[]},"merged":{"nodes":[]},"closed":{"nodes":[]}}}}'
EOF
chmod +x "$fake_bin/gh"

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

expect_err() {
  case "$err" in
    *"$2"*) ok "$1" ;;
    *) bad "$1" "stderr missing: $2" ;;
  esac
}

expect_no_err() {
  case "$err" in
    *"$2"*) bad "$1" "stderr should not contain: $2" ;;
    *) ok "$1" ;;
  esac
}

expect_out_eq() {
  if [ "$out" = "$2" ]; then
    ok "$1"
  else
    bad "$1" "stdout is '$out'"
  fi
}

expect_contains() {
  case "$out" in
    *"$2"*) ok "$1" ;;
    *) bad "$1" "stdout missing: $2" ;;
  esac
}

expect_argv_calls() {
  local actual
  actual="$(wc -l < "$argv_file" | tr -d ' ')"
  if [ "$actual" -eq "$2" ]; then
    ok "$1"
  else
    bad "$1" "argv has $actual calls, expected $2"
  fi
}

expect_argv_has() {
  if grep -Fq -- "$2" "$argv_file"; then
    ok "$1"
  else
    bad "$1" "argv missing: $2"
  fi
}

expect_argv_never() {
  if grep -Eq -- "$2" "$argv_file"; then
    bad "$1" "argv matches a forbidden form: $2"
  else
    ok "$1"
  fi
}

json_value() {
  printf '%s' "$out" | jq -r "$1"
}

expect_json_eq() {
  local actual
  actual="$(json_value "$2")"
  if [ "$actual" = "$3" ]; then
    ok "$1"
  else
    bad "$1" "json '$2' is '$actual', expected '$3'"
  fi
}

expect_field() {
  local actual
  actual="$(printf '%s' "$out" | jq -r \
    --arg a "$2" --arg f "$3" \
    '.stuck[] | select(.artifact == $a) | .[$f]')"
  if [ "$actual" = "$4" ]; then
    ok "$1"
  else
    bad "$1" "artifact $2 field $3 is '$actual', expected '$4'"
  fi
}

expect_sb() {
  local actual
  actual="$(printf '%s' "$out" | jq -r \
    --arg a "$2" \
    '.stuck[] | select(.artifact == $a) | "\(.stage)|\(.block)"')"
  if [ "$actual" = "$3|$4" ]; then
    ok "$1"
  else
    bad "$1" "artifact $2 is '$actual', expected '$3|$4'"
  fi
}

expect_absent() {
  if printf '%s' "$out" | jq -e --arg a "$2" 'any(.stuck[]; .artifact == $a)' >/dev/null; then
    bad "$1" "artifact $2 should not be rendered"
  else
    ok "$1"
  fi
}

check_path="$fake_bin:$PATH"

run_check() {
  : > "$argv_file"
  : > "$err_file"
  out="$(env HOME="$home_tmp" \
    WORK_GRAPH_NOW="$now_epoch" \
    WORK_GRAPH_ARGV_FILE="$argv_file" \
    WORK_GRAPH_GH_FAIL="${gh_fail:-0}" \
    WORK_GRAPH_GH_JSON="${WORK_GRAPH_GH_JSON:-}" \
    PATH="$check_path" \
    bash "$check" "$@" 2>"$err_file")"
  status=$?
  err="$(cat "$err_file")"
}

# Link only the named commands into a fresh directory, following
# scripts/tests/test_dependabot_red_prs.sh.
make_tool_path() {
  local dir="$1"
  shift
  local tool found

  mkdir -p "$dir"
  for tool in "$@"; do
    found="$(command -v "$tool" 2>/dev/null || true)"
    if [ -n "$found" ]; then
      ln -s "$found" "$dir/$tool"
    fi
  done
}

printf '== stage and block rules ==\n'

gh_fail=0
run_check --repo example/widgets --fixture "$fixtures/rules" --format json
expect_status "rules: exits 0 with stuck rows" 0
expect_json_eq "rules: view time is the fixed clock" '.view_time' "$now_epoch"

expect_sb "S1/B1: merged closing link" \
  "example/widgets#issue-101" post_merge retro_pending
expect_field "B1 waits on the maintainer" \
  "example/widgets#issue-101" waits_on "the maintainer"
expect_field "B1 wait starts at mergedAt" \
  "example/widgets#issue-101" wait_started_at "2025-12-01T00:00:00Z"

expect_sb "S2/B2: closed unmerged closing link" \
  "example/widgets#issue-102" planning rework_needed
expect_field "B2 waits on the pull request author" \
  "example/widgets#issue-102" waits_on "the pull request author"
expect_field "B2 wait starts at closedAt" \
  "example/widgets#issue-102" wait_started_at "2025-12-05T00:00:00Z"

expect_sb "S2/B3: no closing link" \
  "example/widgets#issue-103" planning no_pr_yet
expect_field "B3 waits on the assignee" \
  "example/widgets#issue-103" waits_on "assignee-example"
expect_field "B3 wait starts at createdAt" \
  "example/widgets#issue-103" wait_started_at "2025-11-22T00:00:00Z"

expect_sb "mention only does not trigger S1/B1" \
  "example/widgets#issue-105" planning no_pr_yet
expect_field "B3 unassigned waits on the maintainer" \
  "example/widgets#issue-105" waits_on "the maintainer"

expect_sb "S1/B1: owner/repo hash closing keyword" \
  "example/widgets#issue-109" post_merge retro_pending
expect_field "qualified keyword wait starts at mergedAt" \
  "example/widgets#issue-109" wait_started_at "2025-12-06T00:00:00Z"

expect_sb "S1/B1: timeline merged link outside the related window" \
  "example/widgets#issue-110" post_merge retro_pending
expect_field "timeline-only wait starts at mergedAt" \
  "example/widgets#issue-110" wait_started_at "2025-12-07T00:00:00Z"

expect_sb "S3/B4: draft pull request" \
  "example/widgets#pr-201" implementation draft_in_progress
expect_field "B4 wait starts at createdAt" \
  "example/widgets#pr-201" wait_started_at "2026-01-01T00:00:00Z"

expect_sb "S4/B5: conflict wins over failing checks" \
  "example/widgets#pr-202" verification merge_conflict

expect_sb "S5/B6: changes requested wins over failing checks" \
  "example/widgets#pr-203" changes_requested changes_requested
expect_field "B6 wait start moves after a later push" \
  "example/widgets#pr-203" wait_started_at "2026-01-07T00:00:00Z"

expect_sb "S6/B7: failing check" \
  "example/widgets#pr-204" verification checks_failing
expect_field "B7 wait starts at the failing check" \
  "example/widgets#pr-204" wait_started_at "2026-01-06T00:00:00Z"

expect_sb "S7/B8: pending check" \
  "example/widgets#pr-205" verification checks_pending
expect_field "B8 waits on CI then the author" \
  "example/widgets#pr-205" waits_on "CI, then the pull request author"
expect_field "B8 wait starts at the pending check" \
  "example/widgets#pr-205" wait_started_at "2026-01-08T00:00:00Z"

expect_sb "S8/B9: no review requested and no review" \
  "example/widgets#pr-206" first_review review_not_routed

expect_sb "S8/B10: review requested and no review" \
  "example/widgets#pr-207" first_review review_pending
expect_field "B10 waits on the requested reviewers" \
  "example/widgets#pr-207" waits_on "the requested reviewers"
expect_field "B10 wait starts at the request time" \
  "example/widgets#pr-207" wait_started_at "2026-01-05T12:00:00Z"

expect_sb "S9/B14: submitted review without approval" \
  "example/widgets#pr-208" first_review review_followup
expect_field "B14 wait starts at the latest review" \
  "example/widgets#pr-208" wait_started_at "2026-01-06T00:00:00Z"

expect_sb "S10/B12: approved clean pull request" \
  "example/widgets#pr-209" merge_ready awaiting_merge

expect_sb "S10/B13: unknown is not a conflict" \
  "example/widgets#pr-210" merge_ready mergeability_unknown

expect_sb "S10/B11: has_hooks is a gated state" \
  "example/widgets#pr-211" merge_ready merge_gated
expect_sb "S10/B11: behind is a gated state" \
  "example/widgets#pr-214" merge_ready merge_gated

expect_sb "S10 wins over a COMMENTED review" \
  "example/widgets#pr-212" merge_ready awaiting_merge

expect_absent "open issue covered by an open draft link" \
  "example/widgets#issue-104"
expect_absent "open issue with merged and open links" \
  "example/widgets#issue-106"
expect_absent "issue covered by a timeline closing event" \
  "example/widgets#issue-108"

printf '== ordering and grouping ==\n'

run_check --repo example/widgets --fixture "$fixtures/ordering" --format json
expect_status "ordering: exits 0" 0
expect_json_eq "view 1 sorts by numeric duration" \
  '[.stuck[].artifact] | join(",")' \
  "example/widgets#issue-303,example/widgets#pr-304,example/widgets#pr-302,example/widgets#pr-301,example/widgets#pr-305"
expect_json_eq "view 1 renders durations" \
  '[.stuck[].wait_duration] | join(",")' \
  "1d 20h,1d 6h,10h,9h,1h"
expect_json_eq "view 2 sorts by items then max_wait" \
  '[.resolve_first[].resolution] | join(",")' \
  "author_fix,assign_or_start,author_finish,maintainer_merge"
expect_json_eq "view 2 groups both fix blocks" \
  '.resolve_first[] | select(.resolution == "author_fix") | .block' \
  "checks_failing, checks_pending"
expect_json_eq "view 2 reports the group max_wait" \
  '.resolve_first[] | select(.resolution == "author_fix") | .max_wait' "10h"
expect_json_eq "view 2 orders group artifacts" \
  '.resolve_first[] | select(.resolution == "author_fix") | .artifacts' \
  "example/widgets#pr-302, example/widgets#pr-301"
expect_json_eq "actors keep first position and review order" \
  '.stuck[] | select(.artifact == "example/widgets#pr-305") | .actors | join(",")' \
  "assignee-one,author-one,reviewer-late,reviewer-early,commenter-old,commenter-new"

printf '== table output ==\n'

run_check --repo example/widgets --fixture "$fixtures/ordering"
expect_status "table: exits 0" 0
expect_contains "table: labels the stuck view" "stuck (5)"
expect_contains "table: lists the column names" "wait_started_at"
expect_contains "table: labels the resolve view" "resolve first (4)"

printf '== usage errors ==\n'

run_check --format json
expect_status "usage: missing --repo exits 2" 2
expect_err "usage: missing --repo is named" "--repo is required"
expect_argv_calls "usage: missing --repo never calls gh" 0

run_check --repo not-a-slug --fixture "$fixtures/empty"
expect_status "usage: malformed --repo exits 2" 2
expect_err "usage: malformed --repo names the shape" "--repo must be owner/repo"

run_check --repo example/widgets --fixture "$fixtures/empty" --format yaml
expect_status "usage: bad --format exits 2" 2
expect_err "usage: bad --format names the rule" \
  "--format must be table or json: yaml"
expect_argv_calls "usage: bad --format never calls gh" 0

run_check --repo example/widgets --fixture "$work_tmp/missing"
expect_status "usage: missing fixture directory exits 2" 2
expect_err "usage: missing fixture directory is named" \
  "fixture directory not found"

run_check --repo example/widgets --fixture "$fixtures/invalid"
expect_status "usage: invalid fixture JSON exits 2" 2
expect_err "usage: invalid fixture JSON is named" \
  "could not read the fixture JSON"

printf '== help ==\n'

run_check --help
expect_status "help: exits 0" 0
expect_contains "help: prints usage" "Usage: scripts/work-graph.sh"
expect_contains "help: names the stuck view" "stuck"
expect_contains "help: names the resolve view" "resolve first"
expect_contains "help: states read-only" "read-only"
expect_argv_calls "help: never calls gh" 0

printf '== fixture mode never calls gh ==\n'

gh_fail=0
run_check --repo example/widgets --fixture "$fixtures/rules" --format json
expect_status "fixture: exits 0" 0
expect_argv_calls "fixture: never calls gh" 0

printf '== live mode ==\n'

gh_fail=0
run_check --repo example/widgets --format json
expect_status "live: empty read exits 0" 0
expect_json_eq "live: no stuck rows" '.stuck | length' "0"
expect_json_eq "live: no resolutions" '.resolve_first | length' "0"
expect_argv_has "live: reads through graphql" "api graphql"
expect_argv_never "live: never uses a write method" \
  '(--method|-X) (POST|PATCH|PUT|DELETE)'

gh_fail=0
WORK_GRAPH_GH_JSON="$fixtures/live-graphql/response.json"
run_check --repo example/widgets --format json
unset WORK_GRAPH_GH_JSON
expect_status "live graphql: exits 0" 0
expect_sb "live graphql: timeline merged link normalizes to S1/B1" \
  "example/widgets#issue-401" post_merge retro_pending
expect_field "live graphql: wait starts at timeline mergedAt" \
  "example/widgets#issue-401" wait_started_at "2025-09-01T00:00:00Z"
expect_argv_has "live graphql: reads through graphql" "api graphql"

gh_fail=1
run_check --repo example/widgets --format json
expect_status "live: gh failure exits 2" 2
expect_err "live: gh failure names the repository" \
  "gh failed for example/widgets"
expect_err "live: gh failure shows the first stderr line" \
  "gh: boom, not logged in"
expect_no_err "live: gh failure hides later stderr lines" "see the log"
expect_out_eq "live: gh failure prints no report" ""

printf '== missing tools ==\n'

gh_fail=0
make_tool_path "$work_tmp/no-jq" bash sh cat date mktemp rm
ln -s "$fake_bin/gh" "$work_tmp/no-jq/gh"
check_path="$work_tmp/no-jq"
run_check --repo example/widgets --format json
expect_status "tools: missing jq exits 2" 2
expect_err "tools: missing jq is named" "jq is required"
expect_argv_calls "tools: missing jq never calls gh" 0

make_tool_path "$work_tmp/no-gh" bash sh cat date mktemp rm jq
check_path="$work_tmp/no-gh"
run_check --repo example/widgets --format json
expect_status "tools: live missing gh exits 2" 2
expect_err "tools: live missing gh is named" "gh is required"

run_check --repo example/widgets --fixture "$fixtures/ordering" --format json
expect_status "tools: fixture mode works without gh" 0

check_path="$fake_bin:$PATH"

printf '== the script stays read-only ==\n'

patterns=(
  'gh api -X[[:space:]]+(POST|PATCH|PUT|DELETE)'
  '--method[[:space:]]+(POST|PATCH|PUT|DELETE)'
  'gh pr[[:space:]]+(comment|close|merge|edit|ready|review)'
  'gh issue[[:space:]]+(comment|close|edit|delete|lock|transfer)'
  'gh (pr|issue)[[:space:]]+create'
)
for pattern in "${patterns[@]}"; do
  if grep -Eq -- "$pattern" "$check"; then
    bad "read-only: forbidden form absent: $pattern" "found in the script"
  else
    ok "read-only: forbidden form absent: $pattern"
  fi
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -ne 0 ]; then
  exit 1
fi
exit 0
