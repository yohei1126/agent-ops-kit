#!/usr/bin/env bash
# review-citations named check for scripts/dev-loop-gate.sh.
# Sourced by the gate script, never run on its own. It expects row(), repo,
# expect_head_arg, and comment_arg to come from the caller.
set -u

repo="${repo:-}"
expect_head_arg="${expect_head_arg:-}"
comment_arg="${comment_arg:-}"

usage_review_citations() {
  cat <<'EOF'
usage: dev-loop-gate.sh --check review-citations --comment <file>
                        --expect-head <sha> [--repo <checkout>]

--comment (a readable regular file) and --expect-head are required.
--repo must be checked out at --expect-head, so citations resolve against
the head the review saw. Hex case in --expect-head does not matter.

Accepted citation forms:
  path:N
  path:N-M
  path:LN-LM
  path:N,M-P          (comma lists; each range is checked)
  path:N:column       (optional column suffix is ignored)
  path#LN-LM

URLs (any word containing ://) are skipped. A file tracked at HEAD is a
citation whatever its name (Makefile:3, .gitignore:2). An untracked word
counts only when it looks like a path, with a slash or a source or doc
extension such as .sh or .md; other words such as host:443 are prose.

Each bad citation prints one RC FAIL row, and a summary row counts them.
Line counts come from git show HEAD:<path>, not the work tree, so local
edits do not change the result. A comment with no citations passes with
one row saying so.

FAIL action                                          When
not a tracked file at <head>                         The path is not a file in the HEAD commit
line N is past the end (M lines at <head>)           A cited line is beyond the file's last line
line 0 is not a valid line                           A citation of line 0
reversed range                                       A range such as :20-10

Any FAIL exits 1, and so does a checkout at another head.

Exit codes:
  0  pass
  1  any FAIL, or a checkout at another head
  2  usage error (missing or unreadable --comment, or a missing, non-hex,
     or shorter than 7 --expect-head)
  3  git missing (shared gate precondition)
EOF
}

run_review_citations() {
  local head_sha short text count bad
  local word path cite start end lines specs spec
  local lead_chars trail_chars cite_re words

  if [ -z "$comment_arg" ]; then
    printf 'dev-loop-gate: --comment is required for review-citations\n' >&2
    exit 2
  fi
  if [ -z "$expect_head_arg" ]; then
    printf 'dev-loop-gate: --expect-head is required for review-citations\n' >&2
    exit 2
  fi
  case "$expect_head_arg" in
    *[!0-9a-fA-F]*)
      printf 'dev-loop-gate: --expect-head must be a hex SHA prefix\n' >&2
      exit 2
      ;;
  esac
  if [ "${#expect_head_arg}" -lt 7 ]; then
    printf 'dev-loop-gate: --expect-head needs at least 7 characters\n' >&2
    exit 2
  fi
  expect_head_arg="$(printf '%s' "$expect_head_arg" | tr 'A-F' 'a-f')"
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
  # Markdown emphasis (*, _, ~) and quotes around a citation are stripped.
  lead_chars='`([{"'\''<*_~'
  trail_chars=']`)}"'\''>.,;:!?*_~'
  # path:N, path:N-M, path:LN-LM, comma lists (path:3,9-12), an optional
  # :column suffix, and path#LN or path#LN-LM. Anchored at both ends, so a
  # trailing ,420 is checked as its own line, not dropped.
  cite_re='^(([A-Za-z0-9_.-]+/)*[A-Za-z0-9_.-]+)(:(L?[0-9]+(-L?[0-9]+)?(,L?[0-9]+(-L?[0-9]+)?)*)(:[0-9]+)?|#(L[0-9]+(-L?[0-9]+)?))$'

  # shellcheck disable=SC2016
  words="$(printf '%s\n' "$text" | awk -v lead="$lead_chars" -v trail="$trail_chars" '
    {
      # A Markdown link [label](a/b.sh:3) yields its target as a word.
      gsub(/\]\(/, " ")
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
    specs="${BASH_REMATCH[4]}"
    if [ -z "$specs" ]; then
      specs="${BASH_REMATCH[9]}"
    fi
    # A tracked file at HEAD is a citation whatever its name (Makefile:3,
    # .gitignore:2). An untracked word is one only when it looks like a path:
    # it has a slash or a source or doc extension. Anything else (host:port,
    # step:1) is prose.
    if [ "$(git -C "$repo" cat-file -t "HEAD:$path" 2>/dev/null)" != blob ]; then
      case "$path" in
        */* | *.sh | *.bash | *.md | *.json | *.yml | *.yaml | *.toml | *.txt | \
          *.js | *.mjs | *.cjs | *.ts | *.tsx | *.jsx | *.py | *.go | *.rs | \
          *.html | *.css)
          count=$((count + 1))
          row RC "$cite" FAIL "$cite: not a tracked file at $short; cite a path that exists in the PR head"
          bad=$((bad + 1))
          ;;
      esac
      continue
    fi
    count=$((count + 1))
    lines="$(git -C "$repo" show "HEAD:$path" 2>/dev/null | awk 'END{print NR}')"
    case "$lines" in '' | *[!0-9]*) lines=0 ;; esac
    specs="${specs//L/}"
    for spec in ${specs//,/ }; do
      start="${spec%%-*}"
      end=""
      case "$spec" in
        *-*) end="${spec#*-}" ;;
      esac
      start=$((10#$start))
      if [ -n "$end" ]; then
        end=$((10#$end))
      fi
      if [ "$start" -eq 0 ]; then
        row RC "$cite" FAIL "$cite: line 0 is not a valid line; cite a line that exists or drop the line number"
        bad=$((bad + 1))
        break
      fi
      if [ -n "$end" ] && [ "$end" -lt "$start" ]; then
        row RC "$cite" FAIL "$cite: reversed range; write the lower line first"
        bad=$((bad + 1))
        break
      fi
      if [ -n "$end" ] && [ "$end" -gt "$start" ]; then
        start="$end"
      fi
      if [ "$start" -gt "$lines" ]; then
        row RC "$cite" FAIL "$cite: line $start is past the end ($lines lines at $short); cite a line that exists or drop the line number"
        bad=$((bad + 1))
        break
      fi
    done
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
