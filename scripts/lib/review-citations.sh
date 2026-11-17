#!/usr/bin/env bash
# review-citations named check for scripts/dev-loop-gate.sh.
# Sourced by the gate script, never run on its own. It expects row(), repo,
# expect_head_arg, and comment_arg to come from the caller.
set -u

repo="${repo:-}"
expect_head_arg="${expect_head_arg:-}"
comment_arg="${comment_arg:-}"

run_review_citations() {
  local head_sha short text count bad
  local word path cite start end lines
  local lead_chars trail_chars cite_re words

  if [ -z "$comment_arg" ]; then
    printf 'dev-loop-gate: --comment is required for review-citations\n' >&2
    exit 2
  fi
  if [ -z "$expect_head_arg" ]; then
    printf 'dev-loop-gate: --expect-head is required for review-citations\n' >&2
    exit 2
  fi
  if [ ! -f "$comment_arg" ] || [ ! -r "$comment_arg" ]; then
    printf 'dev-loop-gate: cannot read --comment file: %s\n' "$comment_arg" >&2
    exit 2
  fi

  row Gate Name Status Action
  row ---- ------------------------------ ------ ------

  head_sha="$(git -C "$repo" rev-parse HEAD 2>/dev/null || true)"
  short="${head_sha:0:7}"
  if [ -z "$head_sha" ] || [ "${head_sha#"$expect_head_arg"}" = "$head_sha" ]; then
    row RC checkout FAIL "checkout is at $short; check out the reviewed head"
    exit 1
  fi

  text="$(cat "$comment_arg")"
  lead_chars='`([{"'\''<'
  trail_chars=']`)}"'\''>.,;:!?'
  cite_re='^(([A-Za-z0-9_.-]+/)*[A-Za-z0-9_.-]+)(:L?([0-9]+)(-L?([0-9]+))?|#L([0-9]+)(-L?([0-9]+))?)'

  # shellcheck disable=SC2016
  words="$(printf '%s\n' "$text" | awk -v lead="$lead_chars" -v trail="$trail_chars" '
    {
      for (i = 1; i <= NF; i++) {
        w = $i
        sub("^[" lead "]+", "", w)
        sub("[" trail "]+$", "", w)
        if (w ~ /:\/\//) continue
        if (w != "") print w
      }
    }')"

  count=0
  bad=0
  while IFS= read -r word; do
    [ -n "$word" ] || continue
    case "$word" in
      ./*) word="${word#./}" ;;
    esac
    if [[ ! "$word" =~ $cite_re ]]; then
      continue
    fi
    path="${BASH_REMATCH[1]}"
    cite="${BASH_REMATCH[0]}"
    case "$path" in
      */*) ;;
      ?*.*) ;;
      *) continue ;;
    esac
    count=$((count + 1))
    if [ -n "${BASH_REMATCH[4]}" ]; then
      start="${BASH_REMATCH[4]}"
      end="${BASH_REMATCH[6]}"
    else
      start="${BASH_REMATCH[7]}"
      end="${BASH_REMATCH[9]}"
    fi
    start=$((10#$start))
    if [ -n "$end" ]; then
      end=$((10#$end))
    fi
    if [ "$(git -C "$repo" cat-file -t "HEAD:$path" 2>/dev/null)" != blob ]; then
      row RC "$cite" FAIL "$cite: not a tracked file at $short; cite a path that exists in the PR head"
      bad=$((bad + 1))
      continue
    fi
    lines="$(git -C "$repo" show "HEAD:$path" 2>/dev/null | awk 'END{print NR}')"
    case "$lines" in ''|*[!0-9]*) lines=0 ;; esac
    if [ "$start" -eq 0 ]; then
      row RC "$cite" FAIL "$cite: line 0 is not a valid line; cite a line that exists or drop the line number"
      bad=$((bad + 1))
      continue
    fi
    if [ -n "$end" ] && [ "$end" -lt "$start" ]; then
      row RC "$cite" FAIL "$cite: reversed range; write the lower line first"
      bad=$((bad + 1))
      continue
    fi
    if [ "$start" -gt "$lines" ]; then
      row RC "$cite" FAIL "$cite: line $start is past the end ($lines lines at $short); cite a line that exists or drop the line number"
      bad=$((bad + 1))
      continue
    fi
    if [ -n "$end" ] && [ "$end" -gt "$lines" ]; then
      row RC "$cite" FAIL "$cite: line $end is past the end ($lines lines at $short); cite a line that exists or drop the line number"
      bad=$((bad + 1))
      continue
    fi
  done <<EOF
$words
EOF

  if [ "$count" -eq 0 ]; then
    row RC review-citations PASS "0 citations; nothing to check"
    return 0
  fi
  if [ "$bad" -gt 0 ]; then
    row RC review-citations FAIL "$count citations, $bad bad"
    return 1
  fi
  row RC review-citations PASS "$count citations, 0 bad"
  return 0
}
