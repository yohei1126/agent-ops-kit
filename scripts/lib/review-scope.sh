#!/usr/bin/env bash
# Deterministic, fail-closed pre-post scope filter for model-check comments.
# Sourced by scripts/review-scope.sh and scripts/post-review-comment.sh.
# Keeps bash 3.2 compatibility (no associative arrays, no ${var,,}).

# Extract changed paths from a unified diff file into one path per line.
# Returns 0 on success (at least one diff header and one path), 1 on
# unreadable or empty diff.
review_scope_diff_paths() {
  local diff_file="$1"
  [ -f "$diff_file" ] && [ -r "$diff_file" ] || return 1

  local parsed
  parsed="$(awk '
    BEGIN { saw_diff = 0 }
    /^diff --git / {
      saw_diff = 1
      if (match($0, /^diff --git a\/[^ ]+ b\/[^ ]+$/)) {
        line = substr($0, 14)
        sp = index(line, " b/")
        if (sp > 0) {
          p1 = substr(line, 1, sp - 1)
          p2 = substr(line, sp + 3)
          if (p1 != "") paths[p1] = 1
          if (p2 != "") paths[p2] = 1
        }
      }
      next
    }
    /^--- a\// {
      p = substr($0, 7)
      gsub(/^"/, "", p); gsub(/"$/, "", p)
      if (p != "") paths[p] = 1
      next
    }
    /^\+\+\+ b\// {
      p = substr($0, 7)
      gsub(/^"/, "", p); gsub(/"$/, "", p)
      if (p != "") paths[p] = 1
      next
    }
    /^rename from / {
      p = substr($0, 13)
      if (p != "") paths[p] = 1
      next
    }
    /^rename to / {
      p = substr($0, 11)
      if (p != "") paths[p] = 1
      next
    }
    /^copy to / {
      p = substr($0, 9)
      if (p != "") paths[p] = 1
      next
    }
    /^Binary files a\/.+ and b\/.+ differ$/ {
      line = substr($0, 16)
      sub(/ differ$/, "", line)
      sp = index(line, " and b/")
      if (sp > 0) {
        p1 = substr(line, 1, sp - 1)
        p2 = substr(line, sp + 7)
        if (p1 != "") paths[p1] = 1
        if (p2 != "") paths[p2] = 1
      }
      next
    }
    END {
      if (!saw_diff) exit 1
      count = 0
      for (p in paths) {
        print p
        count++
      }
      if (count == 0) exit 1
    }
  ' "$diff_file")" || return 1

  [ -n "$parsed" ] || return 1
  printf '%s\n' "$parsed"
}

# Read caller-declared scope paths from a regular file (one path per line,
# blank lines and # comments ignored). Returns 1 if missing, symlink,
# unreadable, or empty.
review_scope_read_scope_file() {
  local scope_file="$1"
  [ ! -L "$scope_file" ] || return 1
  [ -f "$scope_file" ] && [ -r "$scope_file" ] || return 1

  local line count=0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    # Trim leading/trailing whitespace.
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    case "$line" in
      '' | \#*) continue ;;
      ./*) line="${line#./}" ;;
    esac
    [ -n "$line" ] || continue
    printf '%s\n' "$line"
    count=$((count + 1))
  done < "$scope_file"

  [ "$count" -gt 0 ] || return 1
}

# Check if a path is in a newline-separated list of allowed paths.
review_scope_path_allowed() {
  local needle="$1"
  local allowed_list="$2"
  local item
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    if [ "$item" = "$needle" ]; then
      return 0
    fi
  done <<EOF
$allowed_list
EOF
  return 1
}

# Extract path citations from a text block, one path per line.
# Uses the same citation grammar as scripts/lib/review-citations.sh.
review_scope_extract_paths() {
  local text="$1"
  local allowed_list="$2"
  local lead_chars trail_chars cite_re words word path

  lead_chars='`([{"'\''<*_~'
  trail_chars=']`)}"'\''>.,;:!?*_~'
  cite_re='^(([A-Za-z0-9_.-]+/)*[A-Za-z0-9_.-]+)(:(L?[0-9]+(-L?[0-9]+)?(,L?[0-9]+(-L?[0-9]+)?)*)(:[0-9]+)?|#(L[0-9]+(-L?[0-9]+)?))$'

  # shellcheck disable=SC2016
  words="$(printf '%s\n' "$text" | awk -v lead="$lead_chars" -v trail="$trail_chars" '
    {
      gsub(/\]\(/, " ")
      for (i = 1; i <= NF; i++) {
        w = $i
        sub("^[" lead "]+", "", w)
        sub("[" trail "]+$", "", w)
        if (w ~ /:\/\//) continue
        if (w != "") print w
      }
    }')"

  while IFS= read -r word; do
    [ -n "$word" ] || continue
    case "$word" in
      ./*) word="${word#./}" ;;
    esac
    if [[ ! "$word" =~ $cite_re ]]; then
      continue
    fi
    path="${BASH_REMATCH[1]}"
    if review_scope_path_allowed "$path" "$allowed_list"; then
      printf '%s\n' "$path"
      continue
    fi
    # Match path-like tokens (with / or .) so prose like host:443 or step:1
    # is not mistaken for a citation.
    case "$path" in
      */* | *.*) printf '%s\n' "$path" ;;
    esac
  done <<EOF
$words
EOF
}

# Classify a finding header line's severity: blocker, major, minor, nit, or "".
review_scope_finding_severity() {
  local lower_line="$1"
  local rest=""
  case "$lower_line" in
    -[[:space:]]* | \*[[:space:]]* | +[[:space:]]*)
      rest="${lower_line#?}"
      rest="${rest#"${rest%%[![:space:]]*}"}"
      ;;
    [0-9]*.[[:space:]]*)
      rest="${lower_line#*.}"
      rest="${rest#"${rest%%[![:space:]]*}"}"
      ;;
    *)
      rest="$lower_line"
      ;;
  esac

  case "$rest" in
    blocker[:\ \(-]* | '[blocker]'* | '**blocker**'* | '(blocker)'*)
      printf 'blocker\n'
      ;;
    major[:\ \(-]* | '[major]'* | '**major**'* | '(major)'*)
      printf 'major\n'
      ;;
    minor[:\ \(-]* | '[minor]'* | '**minor**'* | '(minor)'*)
      printf 'minor\n'
      ;;
    nit[:\ \(-]* | '[nit]'* | '**nit**'* | '(nit)'*)
      printf 'nit\n'
      ;;
    *)
      printf '\n'
      ;;
  esac
}

# Filter or refuse a comment body against allowed_paths.
# Args:
#   $1 comment_file
#   $2 allowed_paths (newline-separated)
#   $3 out_file (optional; receives unchanged or rewritten body on exit 0)
#   $4 sidecar_file (optional; receives machine record of decision)
#   $5 err_prefix (e.g. "review-scope" or "post-review-comment")
# Outputs status on stdout: "unchanged", "rewritten", or "" on failure.
# Exit codes: 0 ok (unchanged or rewritten), 1 refused / unparsable.
review_scope_apply() {
  local comment_file="$1"
  local allowed_paths="$2"
  local out_file="${3:-}"
  local sidecar_file="${4:-}"
  local err_prefix="${5:-review-scope}"

  if [ -L "$comment_file" ] || [ ! -f "$comment_file" ] || [ ! -r "$comment_file" ]; then
    printf '%s: comment file missing, symlink, or unreadable: %s\n' "$err_prefix" "$comment_file" >&2
    return 1
  fi

  local -a raw_lines=()
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    raw_lines+=("${line%$'\r'}")
  done < "$comment_file"

  local n_lines="${#raw_lines[@]}"
  if [ "$n_lines" -eq 0 ]; then
    printf '%s: comment file is empty\n' "$err_prefix" >&2
    return 1
  fi

  local -a block_kind=()
  local -a block_sev=()
  local -a block_start=()
  local -a block_end=()
  local claimed_total=-1
  local findings_line_idx=-1
  local i=0

  while [ "$i" -lt "$n_lines" ]; do
    line="${raw_lines[$i]}"
    local lower
    lower="$(printf '%s' "$line" | tr '[:upper:]' '[:lower:]')"

    if [[ "$lower" =~ ^findings:[[:space:]]*(.+)$ ]]; then
      local f_rest="${BASH_REMATCH[1]}"
      local f_sum=0
      local f_tok
      for f_tok in blocker major minor nit; do
        if [[ "$f_rest" =~ ([0-9]+)[[:space:]]+$f_tok ]]; then
          f_sum=$((f_sum + 10#${BASH_REMATCH[1]}))
        fi
      done
      claimed_total="$f_sum"
      findings_line_idx="$i"
      block_kind+=("prose")
      block_sev+=("")
      block_start+=("$i")
      block_end+=("$i")
      i=$((i + 1))
      continue
    fi

    local is_list=0
    case "$line" in
      -[[:space:]]* | \*[[:space:]]* | +[[:space:]]*) is_list=1 ;;
      [0-9]*)
        if [[ "$line" =~ ^[0-9]+\.[[:space:]]+ ]]; then
          is_list=1
        fi
        ;;
    esac

    local sev=""
    sev="$(review_scope_finding_severity "$lower")"

    if [ -n "$sev" ] || [ "$is_list" -eq 1 ]; then
      local start_idx="$i"
      local end_idx="$i"
      local j=$((i + 1))
      while [ "$j" -lt "$n_lines" ]; do
        local next_line="${raw_lines[$j]}"
        case "$next_line" in
          '') break ;;
          \#* | -[[:space:]]* | \*[[:space:]]* | +[[:space:]]*) break ;;
          [0-9]*)
            if [[ "$next_line" =~ ^[0-9]+\.[[:space:]]+ ]]; then
              break
            fi
            ;;
        esac
        local next_lower
        next_lower="$(printf '%s' "$next_line" | tr '[:upper:]' '[:lower:]')"
        case "$next_lower" in
          findings:* | verdict:*) break ;;
        esac
        if [ -n "$(review_scope_finding_severity "$next_lower")" ]; then
          break
        fi
        case "$next_line" in
          [[:space:]]*) end_idx="$j" ;;
          *) break ;;
        esac
        j=$((j + 1))
      done

      local block_text=""
      local k="$start_idx"
      while [ "$k" -le "$end_idx" ]; do
        block_text="$block_text${raw_lines[$k]}"$'\n'
        k=$((k + 1))
      done

      if [ -n "$sev" ]; then
        block_kind+=("finding")
        block_sev+=("$sev")
        block_start+=("$start_idx")
        block_end+=("$end_idx")
      else
        local list_cites
        list_cites="$(review_scope_extract_paths "$block_text" "$allowed_paths")"
        if [ -n "$list_cites" ] || [ "$claimed_total" -gt 0 ]; then
          printf '%s: unparsable finding without severity at line %d\n' "$err_prefix" "$((start_idx + 1))" >&2
          return 1
        fi
        block_kind+=("prose")
        block_sev+=("")
        block_start+=("$start_idx")
        block_end+=("$end_idx")
      fi
      i=$((end_idx + 1))
      continue
    fi

    block_kind+=("prose")
    block_sev+=("")
    block_start+=("$i")
    block_end+=("$i")
    i=$((i + 1))
  done

  local parsed_findings=0
  local b=0
  local n_blocks="${#block_kind[@]}"
  while [ "$b" -lt "$n_blocks" ]; do
    if [ "${block_kind[$b]}" = "finding" ]; then
      parsed_findings=$((parsed_findings + 1))
    fi
    b=$((b + 1))
  done

  if [ "$claimed_total" -gt 0 ] && [ "$parsed_findings" -ne "$claimed_total" ]; then
    printf '%s: comment claims %d finding(s) but parsed %d; refusing unparsable comment\n' \
      "$err_prefix" "$claimed_total" "$parsed_findings" >&2
    return 1
  fi

  local -a block_keep=()
  local kept_findings=0
  local dropped_minor=0
  local dropped_nit=0
  local drop_notes=""
  local refused_reason=""

  b=0
  while [ "$b" -lt "$n_blocks" ]; do
    local kind="${block_kind[$b]}"
    local sev="${block_sev[$b]}"
    local s_idx="${block_start[$b]}"
    local e_idx="${block_end[$b]}"
    local text=""
    local k="$s_idx"
    while [ "$k" -le "$e_idx" ]; do
      text="$text${raw_lines[$k]}"$'\n'
      k=$((k + 1))
    done

    local cites=""
    cites="$(review_scope_extract_paths "$text" "$allowed_paths")"

    if [ "$kind" = "prose" ]; then
      local p
      while IFS= read -r p; do
        [ -n "$p" ] || continue
        if ! review_scope_path_allowed "$p" "$allowed_paths"; then
          refused_reason="out-of-scope citation in prose: $p"
          break
        fi
      done <<EOF
$cites
EOF
      if [ -n "$refused_reason" ]; then
        break
      fi
      block_keep+=(1)
    else
      if [ -z "$cites" ]; then
        refused_reason="finding ($sev) has no recognised citation; failing closed"
        break
      fi
      local oos_path=""
      local p
      while IFS= read -r p; do
        [ -n "$p" ] || continue
        if ! review_scope_path_allowed "$p" "$allowed_paths"; then
          oos_path="$p"
          break
        fi
      done <<EOF
$cites
EOF

      if [ -n "$oos_path" ]; then
        case "$sev" in
          blocker | major)
            refused_reason="out-of-scope $sev finding cites $oos_path"
            break
            ;;
          minor | nit)
            block_keep+=(0)
            if [ "$sev" = "minor" ]; then
              dropped_minor=$((dropped_minor + 1))
            else
              dropped_nit=$((dropped_nit + 1))
            fi
            if [ -z "$drop_notes" ]; then
              drop_notes="$sev at $oos_path"
            else
              drop_notes="$drop_notes, $sev at $oos_path"
            fi
            ;;
        esac
      else
        block_keep+=(1)
        kept_findings=$((kept_findings + 1))
      fi
    fi
    b=$((b + 1))
  done

  local dropped_total=$((dropped_minor + dropped_nit))

  if [ -n "$refused_reason" ]; then
    if [ -n "$sidecar_file" ]; then
      printf 'decision=refused\nreason=%s\n' "$refused_reason" > "$sidecar_file"
    fi
    printf '%s: %s\n' "$err_prefix" "$refused_reason" >&2
    return 1
  fi

  if [ "$dropped_total" -gt 0 ] && [ "$kept_findings" -eq 0 ]; then
    refused_reason="all $dropped_total finding(s) were out of scope ($drop_notes); nothing left to post"
    if [ -n "$sidecar_file" ]; then
      printf 'decision=refused\nreason=%s\n' "$refused_reason" > "$sidecar_file"
    fi
    printf '%s: %s\n' "$err_prefix" "$refused_reason" >&2
    return 1
  fi

  if [ "$dropped_total" -eq 0 ]; then
    if [ -n "$out_file" ] && [ "$out_file" != "$comment_file" ]; then
      cp "$comment_file" "$out_file"
    fi
    if [ -n "$sidecar_file" ]; then
      printf 'decision=unchanged\ndropped=0\n' > "$sidecar_file"
    fi
    printf 'unchanged\n'
    return 0
  fi

  # Rewrite the body without dropped findings, updating the Findings: summary
  # line if present and appending a short machine note.
  local rewritten=""
  local prev_blank=0
  b=0
  while [ "$b" -lt "$n_blocks" ]; do
    if [ "${block_keep[$b]}" -eq 0 ]; then
      b=$((b + 1))
      continue
    fi
    local s_idx="${block_start[$b]}"
    local e_idx="${block_end[$b]}"
    local k="$s_idx"
    while [ "$k" -le "$e_idx" ]; do
      local out_line="${raw_lines[$k]}"
      if [ "$k" -eq "$findings_line_idx" ]; then
        if [ "$dropped_minor" -gt 0 ] && [[ "$out_line" =~ ^(.*[^0-9])([0-9]+)([[:space:]]+[Mm][Ii][Nn][Oo][Rr].*)$ ]]; then
          local nmin=$((10#${BASH_REMATCH[2]} - dropped_minor))
          [ "$nmin" -ge 0 ] || nmin=0
          out_line="${BASH_REMATCH[1]}$nmin${BASH_REMATCH[3]}"
        fi
        if [ "$dropped_nit" -gt 0 ] && [[ "$out_line" =~ ^(.*[^0-9])([0-9]+)([[:space:]]+[Nn][Ii][Tt].*)$ ]]; then
          local nnit=$((10#${BASH_REMATCH[2]} - dropped_nit))
          [ "$nnit" -ge 0 ] || nnit=0
          out_line="${BASH_REMATCH[1]}$nnit${BASH_REMATCH[3]}"
        fi
      fi
      if [ -z "$out_line" ]; then
        if [ "$prev_blank" -eq 1 ]; then
          k=$((k + 1))
          continue
        fi
        prev_blank=1
      else
        prev_blank=0
      fi
      rewritten="$rewritten$out_line"$'\n'
      k=$((k + 1))
    done
    b=$((b + 1))
  done

  rewritten="${rewritten}"$'\n'"Scope note: dropped $dropped_total out-of-scope finding(s) ($drop_notes)."$'\n'

  if [ -n "$out_file" ]; then
    printf '%s' "$rewritten" > "$out_file"
  fi
  if [ -n "$sidecar_file" ]; then
    printf 'decision=rewritten\ndropped=%d\ndropped_items=%s\n' "$dropped_total" "$drop_notes" > "$sidecar_file"
  fi
  printf 'rewritten\n'
  return 0
}
