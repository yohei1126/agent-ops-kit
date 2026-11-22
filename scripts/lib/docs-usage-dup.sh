#!/usr/bin/env bash
# docs-usage-dup named check for scripts/dev-loop-gate.sh.
# Sourced by the gate script, never run on its own. It expects row(), repo,
# and strict from the caller.
set -u

repo="${repo:-}"
strict="${strict:-0}"

if ! command -v row >/dev/null 2>&1; then
  row() { printf '%-4s %-30s %-6s %s\n' "$1" "$2" "$3" "$4"; }
fi

docs_usage_dup_allow='<!-- docs-usage-dup:allow -->'
docs_usage_dup_end='<!-- docs-usage-dup:end -->'

# The help surface is an explicit list. A missing path is skipped, so a repo
# without an optional script does not fail the check.
docs_usage_dup_sources() {
  cat <<'EOF'
scripts/dev-loop-gate.sh
scripts/dev-loop-gate.sh --check review-ready --help
scripts/dev-loop-gate.sh --check review-citations --help
scripts/dev-loop-gate.sh --check model-check-fresh --help
scripts/agent-launch.sh
scripts/agent-task-issue.sh
scripts/agents/agy/run
scripts/agents/agy/collect
scripts/agents/agy/quota
scripts/agents/goat/run
scripts/agy-docs-launch.sh
scripts/agy-docs-collect.sh
scripts/agy-review-launch.sh
scripts/dependabot-red-prs.sh
scripts/rate-limit-check.sh
scripts/work-graph.sh
scripts/worker-deploy.sh
scripts/policy-eval.sh
EOF
}

# Normalize one line stream: drop fences, then backticks, table pipes, heading
# markers, and list markers. Collapse whitespace and fold case for compare.
docs_usage_dup_normalize() {
  LC_ALL=C awk '
    {
      line = $0
      if (line ~ /^[ \t]*(```+|~~~+)/) { print ""; next }
      gsub(/`/, "", line)
      gsub(/\|/, " ", line)
      sub(/^[ \t]*#+[ \t]+/, "", line)
      sub(/^[ \t]*[-*+][ \t]+/, "", line)
      sub(/^[ \t]*[0-9][.)][ \t]+/, "", line)
      gsub(/[ \t]+/, " ", line)
      sub(/^ /, "", line)
      sub(/ $/, "", line)
      print tolower(line)
    }
  ' "$1"
}

docs_usage_dup_sig_len() {
  printf '%s' "$1" | LC_ALL=C tr -cd 'A-Za-z0-9' | wc -c | tr -d ' '
}

# Print "<char>:<count>" when the line opens or closes a fence.
docs_usage_dup_fence_run() {
  local line="$1"
  local i=0
  local ch
  local n=0

  while [ "$i" -lt "${#line}" ] && [ "${line:$i:1}" = " " ]; do
    i=$((i + 1))
  done
  ch="${line:$i:1}"
  case "$ch" in
    '`' | '~') ;;
    *) return 1 ;;
  esac
  while [ "${line:$((i + n)):1}" = "$ch" ]; do
    n=$((n + 1))
  done
  [ "$n" -ge 3 ] || return 1
  printf '%s:%s\n' "$ch" "$n"
}

# Copy a doc to <dst>, blanking marker lines and excused regions or blocks.
docs_usage_dup_filter() {
  local src="$1"
  local dst="$2"
  local line line_trim end_line i j n open len run ch found_end

  dud_raw=()
  while IFS= read -r line || [ -n "$line" ]; do
    dud_raw[${#dud_raw[@]}]="$line"
  done < "$src"
  n=${#dud_raw[@]}
  dud_exc=()
  i=0
  while [ "$i" -lt "$n" ]; do
    dud_exc[i]=0
    i=$((i + 1))
  done

  i=0
  while [ "$i" -lt "$n" ]; do
    line="${dud_raw[i]}"
    line_trim="$line"
    line_trim="${line_trim#"${line_trim%%[![:space:]]*}"}"
    line_trim="${line_trim%"${line_trim##*[![:space:]]}"}"
    if [ "$line_trim" = "$docs_usage_dup_end" ]; then
      dud_exc[i]=1
      i=$((i + 1))
      continue
    fi
    if [ "$line_trim" = "$docs_usage_dup_allow" ]; then
      dud_exc[i]=1
      found_end=-1
      j=$((i + 1))
      while [ "$j" -lt "$n" ]; do
        end_line="${dud_raw[j]}"
        end_line="${end_line#"${end_line%%[![:space:]]*}"}"
        end_line="${end_line%"${end_line##*[![:space:]]}"}"
        if [ "$end_line" = "$docs_usage_dup_end" ]; then
          found_end=$j
          break
        fi
        j=$((j + 1))
      done
      if [ "$found_end" -ge 0 ]; then
        j=$((i + 1))
        while [ "$j" -le "$found_end" ]; do
          dud_exc[j]=1
          j=$((j + 1))
        done
        i=$((found_end + 1))
        continue
      fi
      # No end marker: excuse the next fenced block.
      j=$((i + 1))
      while [ "$j" -lt "$n" ]; do
        case "${dud_raw[j]}" in
          *[![:space:]]*) break ;;
        esac
        dud_exc[j]=1
        j=$((j + 1))
      done
      if [ "$j" -lt "$n" ]; then
        run="$(docs_usage_dup_fence_run "${dud_raw[j]}")" || run=""
        if [ -n "$run" ]; then
          open="${run%%:*}"
          len="${run#*:}"
          dud_exc[j]=1
          j=$((j + 1))
          while [ "$j" -lt "$n" ]; do
            dud_exc[j]=1
            run="$(docs_usage_dup_fence_run "${dud_raw[j]}")" || run=""
            if [ -n "$run" ]; then
              ch="${run%%:*}"
              if [ "$ch" = "$open" ] && [ "${run#*:}" -ge "$len" ]; then
                j=$((j + 1))
                break
              fi
            fi
            j=$((j + 1))
          done
        fi
      fi
      i=$j
      continue
    fi
    i=$((i + 1))
  done

  i=0
  while [ "$i" -lt "$n" ]; do
    if [ "${dud_exc[i]}" = 1 ]; then
      printf '\n'
    else
      printf '%s\n' "${dud_raw[i]}"
    fi
    i=$((i + 1))
  done > "$dst"
}

# Pull the help exit-code paragraph, if the help has one.
docs_usage_dup_exit_text() {
  local file="$1"
  local out=""
  local insec=0
  local line

  while IFS= read -r line; do
    if [ "$insec" = 0 ]; then
      case "$line" in
        "exit codes:"* | "exit code:"*)
          insec=1
          out="$line"
          ;;
      esac
    else
      [ -n "$line" ] || break
      out="$out $line"
    fi
  done < "$file"
  printf '%s\n' "$out"
}

# Build the doc lines used for ordered matching, with 1-based line numbers.
docs_usage_dup_doc_lines() {
  local i=1
  local line

  dud_dtext=()
  dud_dline=()
  while [ "$i" -le "${#dud_norm[@]}" ]; do
    line="${dud_norm[$((i - 1))]}"
    if [ -n "$line" ]; then
      if printf '%s\n' "$line" | LC_ALL=C grep -qx '[-=: ]*'; then
        i=$((i + 1))
        continue
      fi
      dud_dtext[${#dud_dtext[@]}]="$line"
      dud_dline[${#dud_dline[@]}]="$i"
    fi
    i=$((i + 1))
  done
}

# Print the line of the first run of 3 pasted help lines, if any.
docs_usage_dup_pasted_hit() {
  local hf="$1"
  local hl sig n_h n_d i j k run found first

  dud_hlines=()
  while IFS= read -r hl; do
    [ -n "$hl" ] || continue
    sig="$(docs_usage_dup_sig_len "$hl")"
    [ "$sig" -ge 16 ] || continue
    dud_hlines[${#dud_hlines[@]}]="$hl"
  done < "$hf"
  n_h=${#dud_hlines[@]}
  [ "$n_h" -ge 3 ] || return 1
  n_d=${#dud_dtext[@]}
  i=0
  while [ "$i" -lt "$n_h" ]; do
    run=0
    j=0
    k=$i
    first=""
    while [ "$k" -lt "$n_h" ]; do
      hl="${dud_hlines[k]}"
      found=0
      while [ "$j" -lt "$n_d" ]; do
        case "${dud_dtext[j]}" in
          *"$hl"*)
            found=1
            break
            ;;
        esac
        j=$((j + 1))
      done
      [ "$found" = 1 ] || break
      if [ "$run" = 0 ]; then
        first="${dud_dline[j]}"
      fi
      j=$((j + 1))
      run=$((run + 1))
      if [ "$run" -ge 3 ]; then
        printf '%s\n' "$first"
        return 0
      fi
      k=$((k + 1))
    done
    i=$((i + 1))
  done
  return 1
}

# Print the line of a full help usage line in the doc, if any.
docs_usage_dup_usage_hit() {
  local hf="$1"
  local hl rest i line

  while IFS= read -r hl; do
    case "$hl" in
      "usage: "*)
        rest="${hl#usage: }"
        i=0
        while [ "$i" -lt "${#dud_norm[@]}" ]; do
          line="${dud_norm[i]}"
          i=$((i + 1))
          case "$line" in
            "usage: "*)
              case "${line#usage: }" in
                *"$rest")
                  printf '%s\n' "$i"
                  return 0
                  ;;
              esac
              ;;
          esac
        done
        ;;
    esac
  done < "$hf"
  return 1
}

# Print the line of a restated exit-code mapping, if any.
docs_usage_dup_exit_hit() {
  local help="$1"
  local i j n line region dline tokens count
  local c0 c1 c2 c3 doc_words words w overlap

  n=${#dud_norm[@]}
  i=0
  while [ "$i" -lt "$n" ]; do
    line="${dud_norm[i]}"
    case "$line" in
      *"exit codes"* | *"exit code"*)
        region=""
        j=$i
        while [ "$j" -lt "$n" ] && [ "$j" -le $((i + 15)) ]; do
          region="$region ${dud_norm[j]}"
          j=$((j + 1))
        done

        j=$i
        while [ "$j" -lt "$n" ] && [ "$j" -le $((i + 15)) ]; do
          dline="${dud_norm[j]}"
          if [ "${#dline}" -ge 40 ]; then
            case "$help" in
              *"$dline"*)
                printf '%s\n' "$((j + 1))"
                return 0
                ;;
            esac
          fi
          j=$((j + 1))
        done

        tokens=" $(printf '%s' "$region" | LC_ALL=C tr -cs 'A-Za-z0-9' ' ') "
        c0=0
        c1=0
        c2=0
        c3=0
        case "$tokens" in *" 0 "*) c0=1 ;; esac
        case "$tokens" in *" 1 "*) c1=1 ;; esac
        case "$tokens" in *" 2 "*) c2=1 ;; esac
        case "$tokens" in *" 3 "*) c3=1 ;; esac
        count=$((c0 + c1 + c2 + c3))
        if [ "$count" -ge 3 ]; then
          doc_words="$(printf '%s' "$region" | LC_ALL=C tr -cs 'A-Za-z0-9' '\n' | LC_ALL=C tr '[:upper:]' '[:lower:]')"
          words="$(printf '%s' "$help" | LC_ALL=C tr -cs 'A-Za-z0-9' '\n' | LC_ALL=C tr '[:upper:]' '[:lower:]' | awk 'length($0) >= 6' | sort -u)"
          overlap=0
          while IFS= read -r w; do
            [ -n "$w" ] || continue
            case "$w" in
              about | above | after | again | against | being | below | between | could | shall | should | their | there | these | those | which | while | where | would)
                continue
                ;;
            esac
            if printf '%s\n' "$doc_words" | LC_ALL=C grep -qxF -- "$w"; then
              overlap=$((overlap + 1))
              if [ "$overlap" -ge 2 ]; then
                printf '%s\n' "$((i + 1))"
                return 0
              fi
            fi
          done <<EOF
$words
EOF
        fi
        ;;
    esac
    i=$((i + 1))
  done
  return 1
}

run_docs_usage_dup() {
  local tmp raw norm path spec rel k line
  local checked=0
  local hits=0
  local hit=0
  local reason=""
  local hit_line=""
  local label=""
  local state=""
  local action=""

  row Gate Name Status Action
  row ---- ------------------------------ ------ ------

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/docs-usage-dup.XXXXXX")" || {
    printf 'dev-loop-gate: could not create a temporary directory\n' >&2
    return 1
  }

  dud_help_norm=()
  dud_help_label=()
  dud_help_exit=()
  while IFS= read -r spec; do
    [ -n "$spec" ] || continue
    # The list is fixed and has no spaces in a path.
    # shellcheck disable=SC2086
    set -- $spec
    rel="$1"
    shift
    if [ ! -f "$repo/$rel" ]; then
      continue
    fi
    k=${#dud_help_norm[@]}
    raw="$tmp/help.$k"
    norm="$tmp/help.$k.norm"
    if [ "$#" -eq 0 ]; then
      ( cd "$repo" && "${BASH:-bash}" "$rel" --help ) >"$raw" 2>&1 || true
    else
      ( cd "$repo" && "${BASH:-bash}" "$rel" "$@" ) >"$raw" 2>&1 || true
    fi
    docs_usage_dup_normalize "$raw" > "$norm"
    dud_help_norm[${#dud_help_norm[@]}]="$norm"
    dud_help_label[${#dud_help_label[@]}]="$rel"
    dud_help_exit[${#dud_help_exit[@]}]="$(docs_usage_dup_exit_text "$norm")"
  done < <(docs_usage_dup_sources)

  while IFS= read -r -d '' path; do
    if [ ! -f "$repo/$path" ]; then
      continue
    fi
    checked=$((checked + 1))
    raw="$tmp/doc.raw"
    norm="$tmp/doc.norm"
    docs_usage_dup_filter "$repo/$path" "$raw"
    docs_usage_dup_normalize "$raw" > "$norm"
    dud_norm=()
    while IFS= read -r line || [ -n "$line" ]; do
      dud_norm[${#dud_norm[@]}]="$line"
    done < "$norm"
    docs_usage_dup_doc_lines

    hit=0
    reason=""
    hit_line=""
    k=0
    while [ "$k" -lt "${#dud_help_norm[@]}" ]; do
      label="${dud_help_label[k]}"
      if [ "$hit" = 0 ]; then
        if hit_line="$(docs_usage_dup_pasted_hit "${dud_help_norm[k]}")"; then
          hit=1
          reason="pasted help text from $label"
        fi
      fi
      if [ "$hit" = 0 ]; then
        if hit_line="$(docs_usage_dup_usage_hit "${dud_help_norm[k]}")"; then
          hit=1
          reason="usage line from $label"
        fi
      fi
      if [ "$hit" = 0 ] && [ -n "${dud_help_exit[k]}" ]; then
        if hit_line="$(docs_usage_dup_exit_hit "${dud_help_exit[k]}")"; then
          hit=1
          reason="exit-code restatement from $label"
        fi
      fi
      if [ "$hit" = 1 ]; then
        break
      fi
      k=$((k + 1))
    done

    if [ "$hit" = 1 ]; then
      row DU "$path:$hit_line" FAIL "$reason"
      hits=$((hits + 1))
    fi
  done < <(git -C "$repo" ls-files -z -- '*.md')

  rm -rf "$tmp"

  if [ "$hits" -gt 0 ]; then
    state=FAIL
  else
    state=PASS
  fi
  action="$checked files, $hits hits"
  row DU docs-usage-dup "$state" "$action"

  if [ "$hits" -gt 0 ] && [ "$strict" = 1 ]; then
    return 1
  fi
  return 0
}
