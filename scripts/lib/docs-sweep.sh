#!/usr/bin/env bash
# docs-sweep named check for scripts/dev-loop-gate.sh.
# Sourced by the gate script, never run on its own. It expects row(), repo,
# strict, and docs_exceptions_blob to come from the caller.
set -u

# The caller initializes these before sourcing; the defaults keep shellcheck
# and set -u happy when the file is linted alone.
repo="${repo:-}"
strict="${strict:-0}"
docs_exceptions_blob="${docs_exceptions_blob:-}"

docs_phase_re='phase[ -]?[0-9]'
docs_link_re='github\.com/[^ )]*/(issues|pull)/|/issues/[0-9]|/pull/[0-9]'

docs_hits=0

# docs_excused <path> <line> <rule>
# True when an exception for this exact path covers the rule and line.
docs_excused() {
  local path="$1"
  local line="$2"
  local rule="$3"
  local e_path e_pattern e_rules

  [ -n "$docs_exceptions_blob" ] || return 1

  while IFS=$'\x1f' read -r e_path e_pattern e_rules; do
    [ "$e_path" = "$path" ] || continue
    case ",$e_rules," in
      *",$rule,"*) ;;
      *) continue ;;
    esac
    if [ -z "$e_pattern" ]; then
      return 0
    fi
    if printf '%s\n' "$line" | grep -Eq -- "$e_pattern"; then
      return 0
    fi
  done <<EOF
$docs_exceptions_blob
EOF
  return 1
}

# docs_name_terms_file <list path>
# Prints a temporary file holding only real terms from the list.
docs_name_terms_file() {
  local list="$1"
  local tmp term trimmed

  tmp="$(mktemp "${TMPDIR:-/tmp}/dev-loop-name.XXXXXX")" || return 1
  while IFS= read -r term || [ -n "$term" ]; do
    trimmed="${term#"${term%%[![:space:]]*}"}"
    case "$trimmed" in
      ''|'#'*) continue ;;
    esac
    printf '%s\n' "$trimmed" >> "$tmp"
  done < "$list"
  printf '%s\n' "$tmp"
}

docs_scan_regex() {
  local path="$1"
  local rule="$2"
  local regex="$3"
  local reason="$4"
  local icase="$5"
  local hit lineno line

  while IFS= read -r hit; do
    lineno="${hit%%:*}"
    line="${hit#*:}"
    [ -n "$lineno" ] || continue
    if docs_excused "$path" "$line" "$rule"; then
      continue
    fi
    row DS "$path:$lineno" FAIL "$rule: $reason"
    docs_hits=$((docs_hits + 1))
  done < <(
    if [ "$icase" = 1 ]; then
      grep -inE -- "$regex" "$repo/$path" 2>/dev/null
    else
      grep -nE -- "$regex" "$repo/$path" 2>/dev/null
    fi
  )
}

docs_scan_names() {
  local path="$1"
  local terms_file="$2"
  local hit lineno line

  while IFS= read -r hit; do
    lineno="${hit%%:*}"
    line="${hit#*:}"
    [ -n "$lineno" ] || continue
    if docs_excused "$path" "$line" name; then
      continue
    fi
    row DS "$path:$lineno" FAIL "name: local name term"
    docs_hits=$((docs_hits + 1))
  done < <(grep -inF -f "$terms_file" -- "$repo/$path" 2>/dev/null)
}

run_docs_sweep() {
  local checked=0
  local path
  local name_list terms_file=""
  local name_skip="" state action

  load_config docs-sweep
  docs_hits=0

  row Gate Name Status Action
  row ---- ------------------------------ ------ ------

  name_list="${DEV_LOOP_NAME_LIST:-${XDG_CONFIG_HOME:-${HOME:-}/.config}/agent-ops-kit/docs-name-list}"
  if [ -z "$name_list" ] || [ ! -f "$name_list" ]; then
    name_skip="no local name list"
  else
    terms_file="$(docs_name_terms_file "$name_list")" || terms_file=""
    if [ -z "$terms_file" ] || [ ! -s "$terms_file" ]; then
      name_skip="no local name terms"
    fi
  fi

  while IFS= read -r -d '' path; do
    if [ ! -f "$repo/$path" ]; then
      continue
    fi
    checked=$((checked + 1))
    docs_scan_regex "$path" phase "$docs_phase_re" "phase label in prose" 1
    docs_scan_regex "$path" link "$docs_link_re" "GitHub issue or pull link" 0
    if [ -n "$terms_file" ] && [ -s "$terms_file" ]; then
      docs_scan_names "$path" "$terms_file"
    fi
  done < <(git -C "$repo" ls-files -z -- '*.md')

  if [ -n "$terms_file" ]; then
    rm -f "$terms_file"
  fi
  if [ -n "$name_skip" ]; then
    row DS name-list SKIP "$name_skip"
  fi

  if [ "$docs_hits" -gt 0 ]; then
    state=FAIL
  else
    state=PASS
  fi
  action="$checked files, $docs_hits hits"
  row DS summary "$state" "$action"

  if [ "$docs_hits" -gt 0 ] && [ "$strict" = 1 ]; then
    return 1
  fi
  return 0
}
