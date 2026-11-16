#!/usr/bin/env bash
# Read GitHub facts and print two read-only views: what is stuck, and what to
# resolve first. It never changes pull request or repository state.
set -euo pipefail

script="work-graph"

usage() {
  cat <<'USAGE'
Usage: scripts/work-graph.sh --repo OWNER/REPO [--fixture DIR] [--format table|json]

Read GitHub facts and print two read-only views:

  stuck          One row per rendered open issue or open pull request with:
                 repo, artifact, stage, block, waits_on, actors,
                 wait_started_at, wait_duration.
  resolve first  One row per resolution with:
                 resolution, block, items, max_wait, artifacts.

Options:
  --repo OWNER/REPO  Repository to read. Required.
  --fixture DIR      Read recorded JSON from DIR/data.json and never call gh.
  --format FORMAT    table (default) or json.
  -h, --help         Print this help and exit.

This script is read-only. It never changes pull request or repository state.

A live run uses one GitHub GraphQL pass (up to 100 open issues, 100 open
pull requests, and 50 recently updated merged or closed pull requests).
A closing link on an issue timeline still counts when the linked pull
request is older than that window.

Exit codes: 0 views produced (stuck rows are not a failure), 2 usage error,
missing gh or jq, unreadable fixture JSON, or a gh failure.
USAGE
}

usage_error() {
  printf '%s: %s\n' "$script" "$1" >&2
  exit 2
}

repo=""
have_repo=0
fixture=""
have_fixture=0
format="table"

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --repo)
      if [ "$#" -lt 2 ]; then
        usage_error "--repo needs an owner/repo value"
      fi
      repo="$2"
      have_repo=1
      shift 2
      ;;
    --repo=*)
      repo="${1#--repo=}"
      have_repo=1
      shift
      ;;
    --fixture)
      if [ "$#" -lt 2 ]; then
        usage_error "--fixture needs a directory"
      fi
      fixture="$2"
      have_fixture=1
      shift 2
      ;;
    --fixture=*)
      fixture="${1#--fixture=}"
      have_fixture=1
      shift
      ;;
    --format)
      if [ "$#" -lt 2 ]; then
        usage_error "--format needs table or json"
      fi
      format="$2"
      shift 2
      ;;
    --format=*)
      format="${1#--format=}"
      shift
      ;;
    *)
      usage_error "unknown argument: $1"
      ;;
  esac
done

if [ "$have_repo" -eq 0 ]; then
  usage_error "--repo is required"
fi
if ! [[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
  usage_error "--repo must be owner/repo: $repo"
fi

case "$format" in
  table|json) ;;
  *) usage_error "--format must be table or json: $format" ;;
esac

if ! command -v jq >/dev/null 2>&1; then
  usage_error "jq is required"
fi

if [ "$have_fixture" -eq 1 ]; then
  if [ ! -d "$fixture" ]; then
    usage_error "fixture directory not found: $fixture"
  fi
  data_file="$fixture/data.json"
  if [ ! -r "$data_file" ]; then
    usage_error "cannot read fixture JSON: $data_file"
  fi
else
  if ! command -v gh >/dev/null 2>&1; then
    usage_error "gh is required"
  fi
fi

now="${WORK_GRAPH_NOW:-}"
if [ -z "$now" ]; then
  now="$(date +%s)"
fi
case "$now" in
  ''|*[!0-9]*)
    usage_error "WORK_GRAPH_NOW must be whole epoch seconds"
    ;;
esac

query="$(cat <<'GRAPHQL'
query($owner: String!, $name: String!) {
  repository(owner: $owner, name: $name) {
    issues(states: OPEN, first: 100) {
      nodes {
        number
        title
        body
        createdAt
        updatedAt
        url
        author { login }
        assignees(first: 10) { nodes { login } }
        comments(last: 3) { nodes { author { login } createdAt } }
        timelineItems(first: 100, itemTypes: [CROSS_REFERENCED_EVENT, CLOSED_EVENT]) {
          nodes {
            __typename
            ... on CrossReferencedEvent {
              willCloseTarget
              source { ... on PullRequest { number state merged mergedAt closedAt } }
            }
            ... on ClosedEvent {
              createdAt
              closer { ... on PullRequest { number state merged mergedAt closedAt } }
            }
          }
        }
      }
    }
    pullRequests(states: OPEN, first: 100) {
      nodes {
        number
        title
        body
        isDraft
        createdAt
        updatedAt
        url
        author { login }
        assignees(first: 10) { nodes { login } }
        reviewDecision
        mergeStateStatus
        mergeable
        reviews(first: 100) { nodes { author { login } state submittedAt } }
        reviewRequests(first: 10) { nodes { requestedReviewer { ... on User { login } } } }
        commits(last: 1) { nodes { commit { committedDate } } }
        statusCheckRollup {
          contexts(first: 100) {
            nodes {
              __typename
              ... on CheckRun { status conclusion completedAt startedAt }
              ... on StatusContext { state createdAt }
            }
          }
        }
        comments(last: 3) { nodes { author { login } createdAt } }
        timelineItems(first: 100, itemTypes: [READY_FOR_REVIEW_EVENT, CONVERT_TO_DRAFT_EVENT, REVIEW_REQUESTED_EVENT]) {
          nodes {
            __typename
            createdAt
            ... on ReviewRequestedEvent { requestedReviewer { ... on User { login } } }
          }
        }
      }
    }
    merged: pullRequests(states: MERGED, first: 50, orderBy: { field: UPDATED_AT, direction: DESC }) {
      nodes { number title body state mergedAt closedAt author { login } }
    }
    closed: pullRequests(states: CLOSED, first: 50, orderBy: { field: UPDATED_AT, direction: DESC }) {
      nodes { number title body state mergedAt closedAt author { login } }
    }
  }
}
GRAPHQL
)"

normalize_program="$(cat <<'JQ'
def login: if type == "object" then (.login // null) else null end;
def check_state:
  if .state == "SUCCESS" then { status: "COMPLETED", conclusion: "SUCCESS" }
  elif (.state == "FAILURE" or .state == "ERROR") then { status: "COMPLETED", conclusion: "FAILURE" }
  else { status: "PENDING", conclusion: "" } end;

.data.repository as $r
| {
    repo: $repo,
    issues: [
      ($r.issues.nodes // [])[]
      | . as $i
      | {
          number: $i.number,
          title: ($i.title // ""),
          body: ($i.body // ""),
          author: ($i.author | login),
          assignees: [ ($i.assignees.nodes // [])[] | login ],
          created_at: $i.createdAt,
          updated_at: $i.updatedAt,
          url: ($i.url // ""),
          comment_authors: [ ($i.comments.nodes // [])[] | (.author | login) ],
          timeline_closing_prs: [
            ($i.timelineItems.nodes // [])[]
            | if .__typename == "CrossReferencedEvent" and (.willCloseTarget == true) and ((.source.number // null) != null) then
                { number: .source.number, state: (.source.state // ""), merged: (.source.merged // false), merged_at: (.source.mergedAt // null), closed_at: (.source.closedAt // null) }
              elif .__typename == "ClosedEvent" and ((.closer.number // null) != null) then
                { number: .closer.number, state: (.closer.state // ""), merged: (.closer.merged // false), merged_at: (.closer.mergedAt // null), closed_at: (.closer.closedAt // .createdAt // null) }
              else empty end
          ]
        }
    ],
    prs: [
      ($r.pullRequests.nodes // [])[]
      | . as $p
      | ($p.timelineItems.nodes // []) as $tl
      | ([ ($p.reviewRequests.nodes // [])[] | (.requestedReviewer | login) ]) as $reqs
      | {
          number: $p.number,
          title: ($p.title // ""),
          body: ($p.body // ""),
          is_draft: ($p.isDraft // false),
          author: ($p.author | login),
          assignees: [ ($p.assignees.nodes // [])[] | login ],
          review_decision: ($p.reviewDecision // ""),
          mergeable_state: (($p.mergeStateStatus // "unknown") | ascii_downcase),
          reviews: [
            ($p.reviews.nodes // [])[]
            | { author: (.author | login), state: (.state // ""), submitted_at: (.submittedAt // null) }
          ],
          review_requests: $reqs,
          review_request_times: [
            $reqs[] as $l
            | ([ $tl[] | select(.__typename == "ReviewRequestedEvent") | select((.requestedReviewer | login) == $l) | .createdAt ] | min)
          ],
          checks: [
            ((($p.statusCheckRollup // {}) | .contexts.nodes) // [])[]
            | if .__typename == "CheckRun" then
                { status: (.status // ""), conclusion: (.conclusion // ""), completed_at: (.completedAt // null), started_at: (.startedAt // null) }
              else
                (check_state + { completed_at: (.createdAt // null), started_at: null })
              end
          ],
          last_commit_at: ([ ($p.commits.nodes // [])[] | .commit.committedDate ] | max // null),
          draft_conversion_at: ([ $tl[] | select(.__typename == "ConvertToDraftEvent") | .createdAt ] | max // null),
          non_draft_at: ([ $tl[] | select(.__typename == "ReadyForReviewEvent") | .createdAt ] | max // null),
          comment_authors: [ ($p.comments.nodes // [])[] | (.author | login) ],
          created_at: $p.createdAt,
          updated_at: $p.updatedAt,
          url: ($p.url // "")
        }
    ],
    related_prs: [
      (($r.merged.nodes // []) + ($r.closed.nodes // []))[]
      | {
          number,
          title: (.title // ""),
          body: (.body // ""),
          state: (.state // ""),
          merged_at: (.mergedAt // null),
          closed_at: (.closedAt // null),
          author: (.author | login)
        }
    ]
  }
JQ
)"

classify_program="$(cat <<'JQ'
def closing_numbers:
  (((.title // "") + "\n" + (.body // "")) | tostring)
  | [ scan("(?i)\\b(?:close|closes|closed|fix|fixes|fixed|resolve|resolves|resolved)\\s+(?:[A-Za-z0-9._-]+/[A-Za-z0-9._-]+)?#([0-9]+)")[]
      | (if type == "array" then .[0] else . end)
      | tonumber ];

def check_state:
  (.status // "") as $s
  | (.conclusion // "") as $c
  | if ($c == "FAILURE" or $c == "TIMED_OUT" or $c == "STALE"
        or $c == "ACTION_REQUIRED" or $c == "STARTUP_FAILURE") then "failing"
    elif ($s != "COMPLETED") then "pending"
    else "ok" end;

def submitted:
  [ (.reviews // [])[]
    | select(.state == "APPROVED" or .state == "CHANGES_REQUESTED" or .state == "COMMENTED") ];

def review_actor_order:
  submitted
  | group_by(.author)
  | map({ author: .[0].author, at: (map(.submitted_at) | min) })
  | sort_by(.at)
  | map(.author);

def uniq_actors:
  reduce .[] as $a ([];
    if ($a | type) != "string" or ($a | length) == 0 then .
    elif (index($a)) != null then .
    else . + [$a] end);

def actors:
  ((.assignees // [])
   + (if (.author // null) != null then [.author] else [] end)
   + (.review_requests // [])
   + review_actor_order
   + (.comment_authors // []))
  | uniq_actors;

def hours_since($start; $now):
  (($now - ($start | fromdateiso8601)) / 3600 | floor) as $h
  | if $h < 0 then 0 else $h end;

def fmt_dur($h):
  if $h >= 24 then "\(($h / 24 | floor))d \($h % 24)h" else "\($h)h" end;

def resolution:
  .block as $b
  | if $b == "no_pr_yet" then "assign_or_start"
    elif $b == "draft_in_progress" then "author_finish"
    elif (["rework_needed", "merge_conflict", "changes_requested", "checks_failing", "checks_pending"] | index($b)) != null then "author_fix"
    elif (["review_not_routed", "review_pending", "review_followup"] | index($b)) != null then "route_or_finish_review"
    elif (["merge_gated", "mergeability_unknown", "awaiting_merge"] | index($b)) != null then "maintainer_merge"
    elif $b == "retro_pending" then "close_or_record_retro"
    else "review_followup" end;

($now | tonumber) as $now_epoch
| . as $data
| ($data.repo // "") as $repo
| ($data.prs // []) as $prs
| ($data.related_prs // []) as $related
| ($prs | map(. + { cn: closing_numbers })) as $open_prs
| ($related | map(. + { cn: closing_numbers })) as $rel_prs

| def timeline_entries($issue):
    [ ($issue.timeline_closing_prs // [])[]
      | if type == "object" then .
        elif type == "number" then { number: . }
        else empty end ];

  def is_link($issue; $pr):
    (($pr.cn | index($issue.number)) != null)
    or (((timeline_entries($issue) | map(.number) | index($pr.number)) != null));

  def timeline_state_links($issue; $want):
    [ timeline_entries($issue)[]
      | .number as $n
      | select(([$open_prs[] | .number] | index($n)) == null)
      | if $want == "merged" then
          select(((.state // "") == "MERGED") or (.merged == true) or ((.merged_at // null) != null))
        elif $want == "closed" then
          select(((.state // "") == "CLOSED") and ((.merged_at // null) == null) and (.merged != true))
        else empty end
    ];

  def issue_rows:
    [ ($data.issues // [])[]
      | . as $issue
      | ([ $open_prs[] | select(is_link($issue; .)) ]) as $open_links
      | ([ $rel_prs[] | select(is_link($issue; .)) ]) as $rel_links
      | ([ $rel_links[] | select((.state // "") == "MERGED" or (.merged_at // null) != null) ] + timeline_state_links($issue; "merged")) as $merged_links
      | ([ $rel_links[] | select((.state // "") == "CLOSED" and (.merged_at // null) == null) ] + timeline_state_links($issue; "closed")) as $closed_links
      | select(($open_links | length) == 0)
      | (if (($merged_links | length) > 0) then "post_merge" else "planning" end) as $stage
      | (if (($merged_links | length) > 0) then "retro_pending"
         elif (($closed_links | length) > 0) then "rework_needed"
         else "no_pr_yet" end) as $block
      | (if $block == "retro_pending" then "the maintainer"
         elif $block == "rework_needed" then "the pull request author"
         else (if (($issue.assignees // []) | length) > 0 then $issue.assignees[0] else "the maintainer" end)
         end) as $waits_on
      | (if $block == "retro_pending" then ([ $merged_links[].merged_at ] | max)
         elif $block == "rework_needed" then ([ $closed_links[].closed_at ] | max)
         else $issue.created_at end) as $raw_start
      | (if ($raw_start // null) == null then $issue.updated_at else $raw_start end) as $start
      | (($raw_start // null) == null) as $approx
      | (hours_since($start; $now_epoch)) as $h
      | {
          repo: $repo,
          artifact: ($repo + "#issue-" + ($issue.number | tostring)),
          stage: $stage,
          block: $block,
          waits_on: $waits_on,
          actors: ($issue | actors),
          wait_started_at: $start,
          wait_started_approx: $approx,
          wait_duration_hours: $h,
          wait_duration: fmt_dur($h)
        }
    ];

  def pr_rows:
    [ $open_prs[]
      | . as $pr
      | (submitted) as $submitted
      | ([ (.checks // [])[] | select(check_state == "failing") ]) as $failing
      | ([ (.checks // [])[] | select(check_state == "pending") ]) as $pending
      | (if .is_draft then "implementation"
         elif .mergeable_state == "dirty" then "verification"
         elif (.review_decision // "") == "CHANGES_REQUESTED" then "changes_requested"
         elif ($failing | length) > 0 then "verification"
         elif ($pending | length) > 0 then "verification"
         elif ($submitted | length) == 0 then "first_review"
         elif (.review_decision // "") != "APPROVED" then "first_review"
         else "merge_ready" end) as $stage
      | (if .is_draft then "draft_in_progress"
         elif .mergeable_state == "dirty" then "merge_conflict"
         elif (.review_decision // "") == "CHANGES_REQUESTED" then "changes_requested"
         elif ($failing | length) > 0 then "checks_failing"
         elif ($pending | length) > 0 then "checks_pending"
         elif ((.review_requests // []) | length) == 0 and ($submitted | length) == 0 then "review_not_routed"
         elif ((.review_requests // []) | length) > 0 and ($submitted | length) == 0 then "review_pending"
         elif (.review_decision // "") == "APPROVED" and (.mergeable_state | length) > 0
              and .mergeable_state != "dirty" and .mergeable_state != "clean"
              and .mergeable_state != "unknown" then "merge_gated"
         elif (.review_decision // "") == "APPROVED" and .mergeable_state == "clean" then "awaiting_merge"
         elif (.review_decision // "") == "APPROVED" and .mergeable_state == "unknown" then "mergeability_unknown"
         else "review_followup" end) as $block
      | (if $block == "draft_in_progress" then "the pull request author"
         elif $block == "merge_conflict" then "the pull request author"
         elif $block == "changes_requested" then "the pull request author"
         elif $block == "checks_failing" then "the pull request author"
         elif $block == "checks_pending" then "CI, then the pull request author"
         elif $block == "review_not_routed" then "the maintainer"
         elif $block == "review_pending" then "the requested reviewers"
         else "the maintainer" end) as $waits_on
      | (if $block == "draft_in_progress" then (.draft_conversion_at // .created_at)
         elif $block == "merge_conflict" then .updated_at
         elif $block == "changes_requested" then
           ([ ([ (.reviews // [])[] | select(.state == "CHANGES_REQUESTED") | .submitted_at ] | max),
              (.last_commit_at // null) ] | map(select(. != null)) | max)
         elif $block == "checks_failing" then ([ $failing[] | .completed_at ] | map(select(. != null)) | min)
         elif $block == "checks_pending" then ([ $pending[] | .started_at ] | map(select(. != null)) | min)
         elif $block == "review_not_routed" then (.non_draft_at // .created_at)
         elif $block == "review_pending" then ([ (.review_request_times // [])[] | select(. != null) ] | min)
         elif $block == "review_followup" then ($submitted | map(.submitted_at) | max)
         else .updated_at end) as $raw_start
      | (if ($raw_start // null) == null then .updated_at else $raw_start end) as $start
      | (($raw_start // null) == null) as $approx
      | (hours_since($start; $now_epoch)) as $h
      | {
          repo: $repo,
          artifact: ($repo + "#pr-" + ($pr.number | tostring)),
          stage: $stage,
          block: $block,
          waits_on: $waits_on,
          actors: actors,
          wait_started_at: $start,
          wait_started_approx: $approx,
          wait_duration_hours: $h,
          wait_duration: fmt_dur($h)
        }
    ];

  (issue_rows + pr_rows)
  | sort_by(-.wait_duration_hours, .repo, .artifact) as $sorted
  | ([ $sorted[] | . + { resolution: resolution } ]) as $with_res
  | ([ ($with_res | group_by(.resolution))[]
       | . as $g
       | ($g | length) as $items
       | ($g | map(.wait_duration_hours) | max) as $maxh
       | {
           resolution: $g[0].resolution,
           block: ($g | group_by(.block) | map({ b: .[0].block, n: length })
                   | sort_by(-.n, .b) | map(.b) | join(", ")),
           items: $items,
           max_wait_hours: $maxh,
           max_wait: fmt_dur($maxh),
           artifacts: ($g | sort_by(-.wait_duration_hours, .artifact) | map(.artifact) | join(", "))
         }
     ] | sort_by(-.items, -.max_wait_hours, .resolution)) as $res
  | {
      view_time: $now_epoch,
      view_time_iso: ($now_epoch | todateiso8601),
      stuck: $sorted,
      resolve_first: $res
    }
JQ
)"

format_program="$(cat <<'JQ'
def pad($n): . as $s | $s + (" " * ($n - ($s | length)));
def colw($rows; $key): ([ ($key | length), ($rows[] | (.[$key] // "") | length) ] | max);
def nextw($cols; $rows): [ $cols[] as $c | colw($rows; $c) ];
def header($cols): reduce $cols[] as $c ({}; . + { ($c): $c });
def line($obj; $cols; $widths):
  [ ($cols | to_entries[]) | .key as $i | .value as $c
    | (($obj[$c] // "") | tostring | pad($widths[$i])) ] | join("  ");

. as $root
| ($root.stuck
   | map({
       repo: .repo,
       artifact: .artifact,
       stage: .stage,
       block: .block,
       waits_on: .waits_on,
       actors: (.actors | join(", ")),
       wait_started_at: (.wait_started_at + (if .wait_started_approx then "~" else "" end)),
       wait_duration: .wait_duration
     })) as $sr
| ($root.resolve_first
   | map({
       resolution: .resolution,
       block: .block,
       items: (.items | tostring),
       max_wait: .max_wait,
       artifacts: .artifacts
     })) as $rr
| ["repo", "artifact", "stage", "block", "waits_on", "actors", "wait_started_at", "wait_duration"] as $c1
| ["resolution", "block", "items", "max_wait", "artifacts"] as $c2
| (nextw($c1; $sr)) as $w1
| (nextw($c2; $rr)) as $w2
| [
    "stuck (\($sr | length))",
    line(header($c1); $c1; $w1),
    ($sr[] | line(.; $c1; $w1)),
    "",
    "resolve first (\($rr | length))",
    line(header($c2); $c2; $w2),
    ($rr[] | line(.; $c2; $w2))
  ] | join("\n")
JQ
)"

gh_err="$(mktemp "${TMPDIR:-/tmp}/work-graph.XXXXXX")" ||
  usage_error "could not create a temporary file"
trap 'rm -f "$gh_err"' EXIT
trap 'rm -f "$gh_err"; exit 129' HUP
trap 'rm -f "$gh_err"; exit 130' INT
trap 'rm -f "$gh_err"; exit 143' TERM

if [ "$have_fixture" -eq 1 ]; then
  if ! data="$(jq -c --arg repo "$repo" '. + {repo: $repo}' "$data_file" 2>/dev/null)"; then
    printf '%s: could not read the fixture JSON: %s\n' "$script" "$data_file" >&2
    exit 2
  fi
else
  owner="${repo%%/*}"
  name="${repo#*/}"
  if ! raw="$(gh api graphql -f query="$query" -f owner="$owner" -f name="$name" \
    </dev/null 2>"$gh_err")"; then
    first_line=""
    IFS= read -r first_line < "$gh_err" || true
    printf '%s: gh failed for %s: %s\n' "$script" "$repo" "$first_line" >&2
    exit 2
  fi
  if ! data="$(printf '%s' "$raw" |
    jq -c --arg repo "$repo" "$normalize_program" 2>/dev/null)"; then
    printf '%s: could not read the gh JSON for %s\n' "$script" "$repo" >&2
    exit 2
  fi
fi

if ! result="$(printf '%s' "$data" |
  jq -c --arg now "$now" "$classify_program" 2>/dev/null)"; then
  printf '%s: could not compute the views for %s\n' "$script" "$repo" >&2
  exit 2
fi

if [ "$format" = "json" ]; then
  printf '%s\n' "$result"
else
  printf '%s\n' "$result" | jq -r "$format_program"
fi

exit 0
