#!/usr/bin/env bash
# Deterministic, fail-closed pre-post scope filter for model-check comments.
# Reads a comment body, the pull request diff (or --diff) and/or an explicit
# --scope path list, and either passes unchanged, drops out-of-scope minor/nit
# findings with a Scope note, or refuses (exit 1).
set -euo pipefail

script="review-scope"

case "$-" in
  *x*)
    printf '%s: refusing to run with shell xtrace on; it would print values\n' "$script" >&2
    exit 2
    ;;
esac
case "${SHELLOPTS:-}" in
  *xtrace*)
    printf '%s: refusing to run with shell xtrace on; it would print values\n' "$script" >&2
    exit 2
    ;;
esac

usage() {
  cat <<'USAGE'
Usage: scripts/review-scope.sh --comment FILE
         [--repo OWNER/REPO --pr N | --diff FILE] [--scope FILE]
         [--out FILE | --in-place] [--sidecar FILE] [-h|--help]

Filter or refuse a model-check comment whose citations fall outside the pull
request's changed paths or a caller-declared path scope. Deterministic only;
never calls a model and never posts.

Options:
  --comment FILE     Comment markdown file to check. Required.
  --repo OWNER/REPO  Repository holding the pull request (paired with --pr).
  --pr N             Pull request number, positive integer (paired with --repo).
  --diff FILE        Unified diff file to use instead of calling gh pr diff.
  --scope FILE       Caller-declared path scope file (one path per line;
                     blank lines and # comments ignored). Combined with the
                     diff when --repo/--pr or --diff is also given.
  --out FILE         Write the unchanged or rewritten body to FILE.
  --in-place         Overwrite --comment with the rewritten body when items
                     are dropped.
  --sidecar FILE     Write machine-readable decision metadata to FILE.
  -h, --help         Print this help and exit.

Recognised citation forms (matching review-citations):
  path:N             path:N-M            path:LN[-LM]
  path:N,M-P         path:N:column       path#LN[-LM]
  [label](path:N)    ./path:N (leading ./ stripped)
URLs (*://*) are skipped. Tokens without / or . (such as host:443 or step:1)
are treated as prose unless listed in the diff or scope.

Scope policy (fail closed):
  - Findings are parsed from list items or severity-prefixed lines (blocker,
    major, minor, nit). If a Findings: header claims > 0 findings and the
    parsed count does not match, or a finding lacks a severity, the comment
    is unparsable and refused (exit 1).
  - A finding with no recognised citation fails closed (refused, exit 1),
    because its scope cannot be verified.
  - A finding with any out-of-scope citation:
      * blocker or major -> refused (exit 1, nothing written to --out).
      * minor or nit     -> dropped from --out with a Scope note appended,
                            unless all findings would be dropped (refused,
                            exit 1).
  - Out-of-scope citations in non-finding prose are refused (exit 1).
  - Unreadable, missing, or empty diff or scope fails closed (exit 1 or 3).

Exit codes:
  0  in scope (unchanged, or rewritten with minor/nit drops recorded)
  1  refused by scope check, unparsable comment, or empty/unreadable diff/scope
  2  usage error
  3  gh is missing or gh pr diff failed
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

comment_file=""
repo=""
pr=""
diff_file=""
scope_file=""
out_file=""
in_place=0
sidecar_file=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --comment)
      [ "$#" -ge 2 ] || usage_error "--comment needs a file"
      comment_file="$2"
      shift 2
      ;;
    --comment=*)
      comment_file="${1#--comment=}"
      shift
      ;;
    --repo)
      [ "$#" -ge 2 ] || usage_error "--repo needs an owner/repo value"
      repo="$2"
      shift 2
      ;;
    --repo=*)
      repo="${1#--repo=}"
      shift
      ;;
    --pr)
      [ "$#" -ge 2 ] || usage_error "--pr needs a positive integer"
      pr="$2"
      shift 2
      ;;
    --pr=*)
      pr="${1#--pr=}"
      shift
      ;;
    --diff)
      [ "$#" -ge 2 ] || usage_error "--diff needs a file"
      diff_file="$2"
      shift 2
      ;;
    --diff=*)
      diff_file="${1#--diff=}"
      shift
      ;;
    --scope)
      [ "$#" -ge 2 ] || usage_error "--scope needs a file"
      scope_file="$2"
      shift 2
      ;;
    --scope=*)
      scope_file="${1#--scope=}"
      shift
      ;;
    --out)
      [ "$#" -ge 2 ] || usage_error "--out needs a file"
      out_file="$2"
      shift 2
      ;;
    --out=*)
      out_file="${1#--out=}"
      shift
      ;;
    --in-place)
      in_place=1
      shift
      ;;
    --sidecar)
      [ "$#" -ge 2 ] || usage_error "--sidecar needs a file"
      sidecar_file="$2"
      shift 2
      ;;
    --sidecar=*)
      sidecar_file="${1#--sidecar=}"
      shift
      ;;
    *)
      usage_error "unknown argument: $1"
      ;;
  esac
done

[ -n "$comment_file" ] || usage_error "--comment is required"
if [ "$in_place" -eq 1 ] && [ -n "$out_file" ]; then
  usage_error "--in-place and --out cannot be used together"
fi
if [ -n "$repo" ] && [ -z "$pr" ]; then
  usage_error "--repo requires --pr"
fi
if [ -n "$pr" ] && [ -z "$repo" ]; then
  usage_error "--pr requires --repo"
fi
if [ -n "$diff_file" ] && [ -n "$repo" ]; then
  usage_error "--diff cannot be combined with --repo/--pr"
fi
if [ -z "$diff_file" ] && [ -z "$repo" ] && [ -z "$scope_file" ]; then
  usage_error "provide --repo/--pr, --diff, or --scope"
fi

if [ -n "$repo" ]; then
  if ! [[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
    usage_error "--repo must be owner/repo: $repo"
  fi
  case "$pr" in
    ''|*[!0-9]*) usage_error "--pr must be a positive integer: ${pr:-empty}" ;;
  esac
  pr=$((10#$pr))
  [ "$pr" -gt 0 ] || usage_error "--pr must be a positive integer: $pr"
fi

[ ! -L "$comment_file" ] || fail_closed "--comment must not be a symlink: $comment_file"
[ -f "$comment_file" ] && [ -r "$comment_file" ] || fail_closed "--comment is missing or unreadable: $comment_file"

if [ -n "$out_file" ] && [ -L "$out_file" ]; then
  fail_closed "--out must not be a symlink: $out_file"
fi
if [ -n "$sidecar_file" ] && [ -L "$sidecar_file" ]; then
  fail_closed "--sidecar must not be a symlink: $sidecar_file"
fi

# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/review-scope.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/review-scope.sh"

tmp_diff=""
tmp_err=""
tmp_out=""

# shellcheck disable=SC2317,SC2329
cleanup() {
  [ -z "$tmp_diff" ] || rm -f "$tmp_diff" 2>/dev/null || true
  [ -z "$tmp_err" ] || rm -f "$tmp_err" 2>/dev/null || true
  [ -z "$tmp_out" ] || rm -f "$tmp_out" 2>/dev/null || true
}
trap cleanup EXIT

allowed_paths=""

if [ -n "$repo" ]; then
  command -v gh >/dev/null 2>&1 || gh_error "gh is required"
  tmp_diff="$(mktemp "${TMPDIR:-/tmp}/review-scope.diff.XXXXXX")" || gh_error "could not create temporary file"
  tmp_err="$(mktemp "${TMPDIR:-/tmp}/review-scope.err.XXXXXX")" || gh_error "could not create temporary file"
  if ! gh pr diff "$pr" --repo "$repo" </dev/null >"$tmp_diff" 2>"$tmp_err"; then
    err_line=""
    IFS= read -r err_line < "$tmp_err" || true
    gh_error "gh pr diff failed for $repo#$pr: $err_line"
  fi
  diff_file="$tmp_diff"
fi

if [ -n "$diff_file" ]; then
  [ ! -L "$diff_file" ] || fail_closed "--diff must not be a symlink: $diff_file"
  diff_paths="$(review_scope_diff_paths "$diff_file")" ||
    fail_closed "unreadable or empty diff: $diff_file"
  allowed_paths="$diff_paths"
fi

if [ -n "$scope_file" ]; then
  [ ! -L "$scope_file" ] || fail_closed "--scope must not be a symlink: $scope_file"
  scope_paths="$(review_scope_read_scope_file "$scope_file")" ||
    fail_closed "unreadable or empty scope file: $scope_file"
  if [ -z "$allowed_paths" ]; then
    allowed_paths="$scope_paths"
  else
    allowed_paths="$allowed_paths"$'\n'"$scope_paths"
  fi
fi

target_out="$out_file"
if [ "$in_place" -eq 1 ]; then
  tmp_out="$(mktemp "${TMPDIR:-/tmp}/review-scope.out.XXXXXX")" || fail_closed "could not create temporary file"
  target_out="$tmp_out"
fi

status="$(review_scope_apply "$comment_file" "$allowed_paths" "$target_out" "$sidecar_file" "$script")" || exit 1

if [ "$in_place" -eq 1 ] && [ "$status" = "rewritten" ]; then
  mv "$tmp_out" "$comment_file"
  tmp_out=""
fi

exit 0
