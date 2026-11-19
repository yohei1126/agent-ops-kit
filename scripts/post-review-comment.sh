#!/usr/bin/env bash
# Post one model-review comment on a draft pull request, but only after a set
# of mechanical checks pass. This is a pre-post gate, not a reviewer: it never
# approves, requests changes, merges, labels, or edits an existing comment.
#
# The body comes only from <run>/COMMENT.md. The run folder also holds
# post-review-comment.record, so one run posts at most one comment per pull
# request, and a retry after a crash fails closed.
set -euo pipefail

script="post-review-comment"
default_owners="yohei1126,edgesentry"
default_max_bytes=65536

usage() {
  cat <<'USAGE'
Usage: scripts/post-review-comment.sh --run <dir> --repo OWNER/REPO --pr N
         [--owners LIST] [--max-bytes N] [-h|--help]

Post one model-review comment on a draft pull request, and only after the
mechanical checks pass. The body is read only from <run>/COMMENT.md; the
same run folder records the post, so one run posts at most one comment per
pull request. Any failure exits non-zero and posts nothing, so the caller
can fall back to a manual approval path.

Options:
  --run DIR          Run folder holding COMMENT.md and the record file.
                     Required.
  --repo OWNER/REPO  Repository holding the pull request. Required.
  --pr N             Pull request number, a positive integer. Required.
  --owners LIST      Comma-separated owner allowlist.
                     Default: yohei1126,edgesentry.
                     Env: POST_REVIEW_COMMENT_OWNERS.
  --max-bytes N      Byte cap for the whole COMMENT.md, a positive integer.
                     Default: 65536.
                     Env: POST_REVIEW_COMMENT_MAX_BYTES.
  -h, --help         Print this help and exit.

Checks, all of which must pass:
  - The first line of COMMENT.md starts with "Model: ".
  - The file is at most --max-bytes bytes.
  - No token prefix (ghp_, gho_, ghs_, github_pat_, xai-, sk-) and no PEM
    private-key header appear.
  - No http:// or https:// URL, in any letter case.
  - No at sign anywhere in the body.
  - The --repo owner is on the allowlist, compared exactly.
  - The pull request is a draft, read with gh pr view --json isDraft.
  - The record file holds no earlier post or pending attempt for this
    repository and pull request.

On pass, the script writes a pending marker, posts one new issue comment
with gh pr comment --body-file, and records the comment URL that gh prints.
It never approves, requests changes, merges, labels, or edits or deletes a
comment.

Exit codes: 0 posted, 1 a check failed and nothing was posted, 2 usage
error, 3 gh is missing or a gh read or post failed before a successful
post.
USAGE
}

usage_error() {
  printf '%s: %s\n' "$script" "$1" >&2
  exit 2
}

fail_closed() {
  printf '%s: %s\n' "$script" "$1" >&2
  exit 1
}

gh_error() {
  printf '%s: %s\n' "$script" "$1" >&2
  exit 3
}

#
# Checks, all of which run before anything is posted:
#   1. The first line of COMMENT.md is "Model: " plus a name.
#   2. The whole file is at most the byte cap.
#   3. No token prefix and no PEM private-key header appears.
#   4. No http:// or https:// URL appears, in any letter case.
#   5. No at sign appears anywhere in the body.
#   6. The repository owner is on the allowlist, compared exactly.
#   7. The pull request is a draft, read with gh pr view.
#   8. The record file holds no earlier post or pending attempt.
#
# The pending marker goes into the record before the post, so a crash after
# the post but before the URL is saved still fails closed on the next try.
# The script posts one new issue comment with gh pr comment --body-file. It
# never approves, requests changes, merges, labels, or edits or deletes a
# comment. A check failure exits 1, a usage error exits 2, and a missing gh
# or a gh read or post failure exits 3.
#
run_dir=""
have_run=0
repo=""
have_repo=0
pr=""
have_pr=0
owners=""
have_owners=0
max_bytes=""
have_max_bytes=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --run)
      [ "$#" -ge 2 ] || usage_error "--run needs a directory"
      run_dir="$2"
      have_run=1
      shift 2
      ;;
    --run=*)
      run_dir="${1#--run=}"
      have_run=1
      shift
      ;;
    --repo)
      [ "$#" -ge 2 ] || usage_error "--repo needs an owner/repo value"
      repo="$2"
      have_repo=1
      shift 2
      ;;
    --repo=*)
      repo="${1#--repo=}"
      have_repo=1
      shift
      ;;
    --pr)
      [ "$#" -ge 2 ] || usage_error "--pr needs a positive integer"
      pr="$2"
      have_pr=1
      shift 2
      ;;
    --pr=*)
      pr="${1#--pr=}"
      have_pr=1
      shift
      ;;
    --owners)
      [ "$#" -ge 2 ] || usage_error "--owners needs a list"
      owners="$2"
      have_owners=1
      shift 2
      ;;
    --owners=*)
      owners="${1#--owners=}"
      have_owners=1
      shift
      ;;
    --max-bytes)
      [ "$#" -ge 2 ] || usage_error "--max-bytes needs a positive integer"
      max_bytes="$2"
      have_max_bytes=1
      shift 2
      ;;
    --max-bytes=*)
      max_bytes="${1#--max-bytes=}"
      have_max_bytes=1
      shift
      ;;
    *)
      usage_error "unknown argument: $1"
      ;;
  esac
done

if [ "$have_run" -eq 0 ]; then
  usage_error "--run is required"
fi
if [ ! -d "$run_dir" ]; then
  usage_error "--run must be a directory: ${run_dir:-empty}"
fi

if [ "$have_repo" -eq 0 ]; then
  usage_error "--repo is required"
fi
if ! [[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
  usage_error "--repo must be owner/repo: ${repo:-empty}"
fi

if [ "$have_pr" -eq 0 ]; then
  usage_error "--pr is required"
fi
case "$pr" in
  ''|*[!0-9]*)
    usage_error "--pr must be a positive integer: ${pr:-empty}"
    ;;
esac
pr=$((10#$pr))
if [ "$pr" -le 0 ]; then
  usage_error "--pr must be a positive integer: $pr"
fi

if [ "$have_owners" -eq 0 ]; then
  if [ -n "${POST_REVIEW_COMMENT_OWNERS+set}" ]; then
    owners="$POST_REVIEW_COMMENT_OWNERS"
  else
    owners="$default_owners"
  fi
fi
if [ -z "$owners" ]; then
  usage_error "--owners must not be empty"
fi

if [ "$have_max_bytes" -eq 0 ]; then
  if [ -n "${POST_REVIEW_COMMENT_MAX_BYTES+set}" ]; then
    max_bytes="$POST_REVIEW_COMMENT_MAX_BYTES"
  else
    max_bytes="$default_max_bytes"
  fi
fi
case "$max_bytes" in
  ''|*[!0-9]*)
    usage_error "--max-bytes must be a positive integer: ${max_bytes:-empty}"
    ;;
esac
max_bytes=$((10#$max_bytes))
if [ "$max_bytes" -le 0 ]; then
  usage_error "--max-bytes must be a positive integer: $max_bytes"
fi

# The allowlist is a comma-separated list of owners. An empty entry matches
# nothing, and the compare is case-sensitive because owners are not
# case-folded here. A value such as "a,,b" allows a and b only.
#
# The owner comes from --repo, so an owner outside the list fails before
# any gh call and before the draft read.
owner_allowed() {
  local want="$1"
  local rest="$2"
  local item

  while [ -n "$rest" ]; do
    case "$rest" in
      *,*) item="${rest%%,*}"; rest="${rest#*,}" ;;
      *) item="$rest"; rest="" ;;
    esac
    if [ "$item" = "$want" ]; then
      return 0
    fi
  done
  return 1
}

owner="${repo%%/*}"
if ! owner_allowed "$owner" "$owners"; then
  fail_closed "repository owner is not allowed: $owner"
fi

# COMMENT.md must be a regular file in the run folder. A symlink is
# refused even when it points at a valid file, because the gate promises
# to read only that one path. The record file sits beside it and holds
# tab-separated lines: "pending" or "posted", the repo, the pull request,
# then an optional comment URL. A posted line without a URL, or a pending
# line, means an earlier attempt did not finish.
#
comment="$run_dir/COMMENT.md"
record="$run_dir/post-review-comment.record"

if [ -L "$comment" ]; then
  fail_closed "COMMENT.md must not be a symlink: $comment"
fi
if [ ! -f "$comment" ]; then
  fail_closed "COMMENT.md is missing or not a regular file: $comment"
fi
if [ ! -r "$comment" ]; then
  fail_closed "COMMENT.md is not readable: $comment"
fi

first_line=""
IFS= read -r first_line < "$comment" || true
case "$first_line" in
  "Model: "*) ;;
  *) fail_closed 'the first line of COMMENT.md must start with "Model: "' ;;
esac

size="$(wc -c < "$comment")"
size="${size//[!0-9]/}"
[ -n "$size" ] || size=0
if [ "$size" -gt "$max_bytes" ]; then
  fail_closed "COMMENT.md is $size bytes, over the $max_bytes byte cap"
fi

if grep -Fq -e 'ghp_' -e 'gho_' -e 'ghs_' -e 'github_pat_' -e 'xai-' -e 'sk-' -- "$comment"; then
  fail_closed "COMMENT.md holds a secret-like token prefix"
fi
if grep -Eq -- '-----BEGIN [A-Za-z0-9 ]*PRIVATE KEY-----' "$comment"; then
  fail_closed "COMMENT.md holds a PEM private-key header"
fi
if grep -Eqi -- 'https?://' "$comment"; then
  fail_closed "COMMENT.md holds an external URL"
fi
if grep -Fq -- '@' "$comment"; then
  fail_closed "COMMENT.md holds an at sign"
fi

# One run posts at most one comment per pull request. The scan keeps the
# last matching state, so a pending line followed by a posted line for the
# same repository and pull request counts as a success and fails closed.
# A record for another repository or pull request is ignored, because one
# run folder may serve more than one checkout.
#
# The record is append-only. The pending marker is written before the gh
# post, so a crash leaves a visible incomplete attempt rather than a
# silent retry.
record_state=""
if [ -f "$record" ]; then
  while IFS=$'\t' read -r r_state r_repo r_pr r_url; do
    [ -n "${r_state:-}" ] || continue
    [ "$r_repo" = "$repo" ] || continue
    [ "$r_pr" = "$pr" ] || continue
    case "$r_state" in
      posted)
        if [ -n "${r_url:-}" ]; then
          record_state=posted
        else
          record_state=pending
        fi
        ;;
      pending) record_state=pending ;;
    esac
  done < "$record"
fi
case "$record_state" in
  posted) fail_closed "a comment was already posted for $repo#$pr in this run" ;;
  pending) fail_closed "an earlier attempt for $repo#$pr did not finish; refusing to retry" ;;
esac

# The gh presence check comes after the local checks, so a body that would
# never pass still reports the body failure. A missing gh, a failed draft
# read, and a failed post all exit 3. The draft read asks for isDraft only,
# and anything other than a clean true answer fails closed.
#
if ! command -v gh >/dev/null 2>&1; then
  gh_error "gh is required"
fi

gh_err="$(mktemp "${TMPDIR:-/tmp}/post-review-comment.XXXXXX")" ||
  gh_error "could not create a temporary file"
trap 'rm -f "$gh_err"' EXIT
trap 'rm -f "$gh_err"; exit 129' HUP
trap 'rm -f "$gh_err"; exit 130' INT
trap 'rm -f "$gh_err"; exit 143' TERM

if ! draft_json="$(gh pr view "$pr" --repo "$repo" --json isDraft </dev/null 2>"$gh_err")"; then
  err_line=""
  IFS= read -r err_line < "$gh_err" || true
  gh_error "gh pr view failed for $repo#$pr: $err_line"
fi
compact="$(printf '%s' "$draft_json" | tr -d '[:space:]')"
case "$compact" in
  \{*\}) ;;
  *) gh_error "could not read the isDraft JSON for $repo#$pr" ;;
esac
case "$compact" in
  *'"isDraft":true'*) ;;
  *'"isDraft":false'*) fail_closed "pull request is not a draft: $repo#$pr" ;;
  *) gh_error "could not read the isDraft JSON for $repo#$pr" ;;
esac

# Write the pending marker first, then post. The post is one new issue
# comment, not a review event. The URL that gh prints is the only proof of
# success, so a post that returns no URL exits 3 without recording one.
#
printf 'pending\t%s\t%s\t\n' "$repo" "$pr" >> "$record"

if ! post_out="$(gh pr comment "$pr" --repo "$repo" --body-file "$comment" </dev/null 2>"$gh_err")"; then
  err_line=""
  IFS= read -r err_line < "$gh_err" || true
  gh_error "gh pr comment failed for $repo#$pr: $err_line"
fi

url=""
while IFS= read -r line; do
  if [ -n "$line" ]; then
    url="$line"
    break
  fi
done <<EOF
$post_out
EOF
case "$url" in
  http://*|https://*) ;;
  *) gh_error "gh pr comment returned no comment URL for $repo#$pr" ;;
esac

printf 'posted\t%s\t%s\t%s\n' "$repo" "$pr" "$url" >> "$record"
printf '%s\n' "$url"
exit 0
