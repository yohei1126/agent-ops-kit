#!/usr/bin/env bash
# Weekly hygiene check for open Dependabot pull requests whose CI is still red
# or that have stayed open too long.
#
# This script is read-only and report-only. It runs one `gh pr list` per
# repository and never comments, closes, rebases, or merges.
#
# When a pull request is flagged, open one human pull request that fixes the
# update, including peer dependency updates in the same change, and propose
# closing the original as a duplicate. The maintainer closes the original; this
# script does not.
set -euo pipefail

script="dependabot-red-prs"

usage() {
  cat <<'USAGE'
Usage: scripts/dependabot-red-prs.sh --repo OWNER/REPO [--repo OWNER/REPO ...] [--days N]

Read open Dependabot pull requests and report the ones that still need a human.

Options:
  --repo OWNER/REPO  Repository to check. Repeat for each repository.
  --days N           Flag an open pull request older than N whole days
                     (default 3; N must be a non-negative integer).
  -h, --help         Print this help and exit.

This script is read-only and report-only. It never comments, closes, rebases,
or merges.

Exit codes: 0 nothing flagged, 1 at least one flagged, 2 usage error, missing
gh or jq, gh failure, or unreadable JSON.
USAGE
}

usage_error() {
  printf '%s: %s\n' "$script" "$1" >&2
  exit 2
}

repos=""
have_repo=0
days=3

add_repo() {
  if ! [[ "$1" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
    usage_error "--repo must be owner/repo: $1"
  fi
  repos="$repos$1"$'\n'
  have_repo=1
}

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
      add_repo "$2"
      shift 2
      ;;
    --repo=*)
      add_repo "${1#--repo=}"
      shift
      ;;
    --days)
      if [ "$#" -lt 2 ]; then
        usage_error "--days needs a non-negative integer"
      fi
      days="$2"
      shift 2
      ;;
    --days=*)
      days="${1#--days=}"
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

case "$days" in
  ''|*[!0-9]*)
    usage_error "--days must be a non-negative integer: ${days:-empty}"
    ;;
esac

if ! command -v gh >/dev/null 2>&1; then
  usage_error "gh is required"
fi
if ! command -v jq >/dev/null 2>&1; then
  usage_error "jq is required"
fi

now="${DEPENDABOT_RED_NOW:-}"
if [ -z "$now" ]; then
  now="$(date +%s)"
fi
case "$now" in
  ''|*[!0-9]*)
    usage_error "DEPENDABOT_RED_NOW must be whole epoch seconds"
    ;;
esac

# Classify the same way scripts/lib/pr-state.sh does. A red pull request is one
# with any failing check. A pull request with no checks reports "none".
jq_program="$(cat <<'JQ'
def kind:
  if type != "object" then "pending"
  elif (has("conclusion") or ((."__typename" // "") == "CheckRun")) then
    (.conclusion // "") as $c
    | if ($c == "SUCCESS" or $c == "NEUTRAL" or $c == "SKIPPED") then "success"
      elif ($c == "FAILURE" or $c == "CANCELLED" or $c == "TIMED_OUT"
            or $c == "ACTION_REQUIRED" or $c == "STARTUP_FAILURE"
            or $c == "STALE") then "failure"
      else "pending" end
  else
    (.state // "") as $s
    | if $s == "SUCCESS" then "success"
      elif ($s == "FAILURE" or $s == "ERROR") then "failure"
      else "pending" end
  end;

($now | tonumber) as $now_epoch
| ($days | tonumber) as $limit
| . as $prs
| if ($prs | type) != "array" then
    error("not a pull request list")
  else
    $prs[]
    | . as $pr
    | if (($pr | type) != "object"
          or ($pr.number | type) != "number"
          or ($pr.title | type) != "string"
          or ($pr.url | type) != "string"
          or ($pr.createdAt | type) != "string")
      then error("not a pull request object")
      else
        (($pr.statusCheckRollup // []) | map(kind)) as $kinds
        | (if ($kinds | length) == 0 then "none"
           elif ($kinds | map(select(. == "failure")) | length) > 0 then "red"
           elif ($kinds | map(select(. == "pending")) | length) > 0 then "pending"
           else "green" end) as $status
        | ((($now_epoch - ($pr.createdAt | fromdateiso8601)) / 86400)
            | floor) as $age
        | (if $status == "red" or $age > $limit then "FLAG" else "ok" end) as $flag
        | [$flag, ($pr.number | tostring), $status, ($age | tostring),
           $pr.url, $pr.title]
        | @tsv
      end
  end
JQ
)"

gh_err="$(mktemp "${TMPDIR:-/tmp}/dependabot-red-prs.XXXXXX")" ||
  usage_error "could not create a temporary file"
trap 'rm -f "$gh_err"' EXIT

checked=0
flagged=0

while IFS= read -r repo; do
  [ -n "$repo" ] || continue

  if ! json="$(gh pr list -R "$repo" --author app/dependabot --state open \
    --limit 100 \
    --json number,title,url,createdAt,headRefOid,statusCheckRollup \
    </dev/null 2>"$gh_err")"; then
    first_line=""
    IFS= read -r first_line < "$gh_err" || true
    printf '%s: gh failed for %s: %s\n' "$script" "$repo" "$first_line" >&2
    exit 2
  fi

  case "$json" in
    *[![:space:]]*) ;;
    *)
      printf '%s: could not read the gh JSON for %s\n' "$script" "$repo" >&2
      exit 2
      ;;
  esac

  if ! rows="$(printf '%s' "$json" |
    jq -r --arg now "$now" --arg days "$days" "$jq_program" 2>/dev/null)"; then
    printf '%s: could not read the gh JSON for %s\n' "$script" "$repo" >&2
    exit 2
  fi

  while IFS=$'\t' read -r flag number status age url title; do
    [ -n "$flag" ] || continue
    checked=$((checked + 1))
    if [ "$flag" = FLAG ]; then
      flagged=$((flagged + 1))
    fi
    printf '%s  %s#%s  %s  %sd  %s  %s\n' \
      "$flag" "$repo" "$number" "$status" "$age" "$url" "$title"
  done <<EOF
$rows
EOF
done <<EOF
$repos
EOF

printf 'summary: %s open dependabot PRs, %s flagged\n' "$checked" "$flagged"

if [ "$flagged" -gt 0 ]; then
  exit 1
fi
exit 0
