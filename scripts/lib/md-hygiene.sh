#!/usr/bin/env bash
# Markdown hygiene named checks for scripts/dev-loop-gate.sh.
# Sourced by the gate script, never run on its own. It expects row(), repo,
# and strict from the caller.
set -u

repo="${repo:-}"
strict="${strict:-0}"

mdh_em_dash=$'\xe2\x80\x94'
mdh_en_dash=$'\xe2\x80\x93'

mdh_strip_code() {
  LC_ALL=C awk '
    function fence_run(s,   i, ch, n) {
      i = 1
      while (i <= 3 && substr(s, i, 1) == " ") i++
      ch = substr(s, i, 1)
      if (ch != "`" && ch != "~") return 0
      n = 0
      while (substr(s, i + n, 1) == ch) n++
      if (n < 3) return 0
      f_ch = ch
      f_n = n
      f_rest = substr(s, i + n)
      return 1
    }
    function strip_inline(s,   out, i, n, j, m, found, ch) {
      out = ""
      i = 1
      while (i <= length(s)) {
        ch = substr(s, i, 1)
        if (ch != "`") {
          out = out ch
          i++
          continue
        }
        n = 0
        while (substr(s, i + n, 1) == "`") n++
        j = i + n
        found = 0
        while (j <= length(s)) {
          if (substr(s, j, 1) == "`") {
            m = 0
            while (substr(s, j + m, 1) == "`") m++
            if (m == n) {
              found = 1
              break
            }
            j += m
          } else {
            j++
          }
        }
        if (found) {
          i = j + n
        } else {
          out = out substr(s, i, n)
          i += n
        }
      }
      return out
    }
    BEGIN {
      in_fence = 0
      open_ch = ""
      open_n = 0
    }
    {
      line = $0
      if (in_fence) {
        if (fence_run(line) && f_ch == open_ch && f_n >= open_n) {
          in_fence = 0
        }
        print ""
        next
      }
      if (fence_run(line) && !(f_ch == "`" && index(f_rest, "`") > 0)) {
        open_ch = f_ch
        open_n = f_n
        in_fence = 1
        print ""
        next
      }
      print strip_inline(line)
    }
  ' "$1"
}

mdh_anchors() {
  LC_ALL=C awk '
    function fence_run(s,   i, ch, n) {
      i = 1
      while (i <= 3 && substr(s, i, 1) == " ") i++
      ch = substr(s, i, 1)
      if (ch != "`" && ch != "~") return 0
      n = 0
      while (substr(s, i + n, 1) == ch) n++
      if (n < 3) return 0
      f_ch = ch
      f_n = n
      f_rest = substr(s, i + n)
      return 1
    }
    function drop_links(s,   out, p, q, b, k, head) {
      out = ""
      while ((p = index(s, "](")) > 0) {
        head = substr(s, 1, p - 1)
        b = 0
        for (k = length(head); k >= 1; k--) {
          if (substr(head, k, 1) == "[") {
            b = k
            break
          }
        }
        if (b == 0) {
          out = out substr(s, 1, p + 1)
          s = substr(s, p + 2)
          continue
        }
        q = index(substr(s, p + 2), ")")
        if (q == 0) {
          out = out s
          return out
        }
        out = out substr(s, 1, b - 1) substr(s, b + 1, p - b - 1)
        s = substr(s, p + 2 + q)
      }
      out = out s
      return out
    }
    function ascii_lower(s,   out, i, c, n, up, lo) {
      up = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
      lo = "abcdefghijklmnopqrstuvwxyz"
      out = ""
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        n = index(up, c)
        if (n > 0) out = out substr(lo, n, 1)
        else out = out c
      }
      return out
    }
    function drop_punct(s,   out, i, c, punct) {
      punct = "!\"#$%&()*+,./:;<=>?@[\\]^`{|}~" sprintf("%c", 39)
      out = ""
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (index(punct, c) == 0) out = out c
      }
      return out
    }
    function slugify(s,   out) {
      out = drop_links(s)
      gsub(/`/, "", out)
      out = ascii_lower(out)
      out = drop_punct(out)
      sub(/^ +/, "", out)
      sub(/ +$/, "", out)
      gsub(/ /, "-", out)
      return out
    }
    function unique_slug(s,   cand, n) {
      cand = s
      n = 0
      while (cand in seen) {
        n++
        cand = s "-" n
      }
      seen[cand] = 1
      return cand
    }
    function heading_text(s,   i, h, j, rest, k) {
      i = 1
      while (i <= 3 && substr(s, i, 1) == " ") i++
      if (substr(s, i, 1) != "#") return ""
      h = 0
      while (substr(s, i + h, 1) == "#") h++
      if (h < 1 || h > 6) return ""
      j = i + h
      if (substr(s, j, 1) != " " && substr(s, j, 1) != "\t") return ""
      while (substr(s, j, 1) == " " || substr(s, j, 1) == "\t") j++
      rest = substr(s, j)
      sub(/[ \t]+$/, "", rest)
      k = length(rest)
      while (k > 0 && substr(rest, k, 1) == "#") k--
      if (k < length(rest)) {
        if (k == 0) {
          rest = ""
        } else if (substr(rest, k, 1) == " " || substr(rest, k, 1) == "\t") {
          rest = substr(rest, 1, k)
          sub(/[ \t]+$/, "", rest)
        }
      }
      return rest
    }
    function html_anchor(tag,   v) {
      while (match(tag, /(name|id)="[^"]+"/)) {
        v = substr(tag, RSTART, RLENGTH)
        sub(/^[^=]*="/, "", v)
        sub(/"$/, "", v)
        if (v != "") print v
        tag = substr(tag, RSTART + RLENGTH)
      }
    }
    function collect_html(s,   pos, p, start, q, tag, c) {
      pos = 1
      while ((p = index(substr(s, pos), "<a")) > 0) {
        start = pos + p - 1
        c = substr(s, start + 2, 1)
        if (c != " " && c != "\t" && c != ">" && c != "/") {
          pos = start + 2
          continue
        }
        q = index(substr(s, start), ">")
        if (q == 0) return
        tag = substr(s, start, q)
        html_anchor(tag)
        pos = start + q
      }
    }
    BEGIN {
      in_fence = 0
      open_ch = ""
      open_n = 0
    }
    {
      line = $0
      if (in_fence) {
        if (fence_run(line) && f_ch == open_ch && f_n >= open_n) in_fence = 0
        next
      }
      if (fence_run(line) && !(f_ch == "`" && index(f_rest, "`") > 0)) {
        open_ch = f_ch
        open_n = f_n
        in_fence = 1
        next
      }
      collect_html(line)
      text = heading_text(line)
      if (text != "") {
        slug = slugify(text)
        if (slug != "") print unique_slug(slug)
      }
    }
  ' "$1"
}

mdh_collect_links() {
  local path="$1"

  LC_ALL=C awk -v curfile="$path" '
    function norm_path(base_dir, p,   full, n, parts, i, depth, out, seg) {
      if (substr(p, 1, 1) == "/") full = p
      else if (base_dir == "") full = p
      else full = base_dir "/" p
      n = split(full, parts, "/")
      depth = 0
      for (i = 1; i <= n; i++) {
        seg = parts[i]
        if (seg == "" || seg == ".") continue
        if (seg == "..") {
          if (depth == 0) {
            outside = 1
            return ""
          }
          depth--
        } else {
          stack[++depth] = seg
        }
      }
      out = ""
      for (i = 1; i <= depth; i++) {
        if (i > 1) out = out "/"
        out = out stack[i]
      }
      return out
    }
    function emit(lineno, raw,   t, cut, p, anchor, norm) {
      t = raw
      if (substr(t, 1, 1) == "<" && substr(t, length(t), 1) == ">") {
        t = substr(t, 2, length(t) - 2)
      }
      cut = 0
      p = index(t, " ")
      if (p > 0) cut = p
      p = index(t, "\t")
      if (p > 0 && (cut == 0 || p < cut)) cut = p
      if (cut > 0) t = substr(t, 1, cut - 1)
      if (t == "") return
      if (t ~ /^[A-Za-z][A-Za-z0-9+.-]*:/) return
      if (substr(t, 1, 2) == "//") return
      anchor = ""
      p = index(t, "#")
      if (p > 0) {
        anchor = substr(t, p + 1)
        t = substr(t, 1, p - 1)
      }
      gsub(/%20/, " ", t)
      outside = 0
      if (t == "") norm = curfile
      else norm = norm_path(base, t)
      printf "%s\037%s\037%s\037%s\n", lineno, norm, anchor, outside
    }
    function ref_target(s,   i, rest) {
      i = 1
      while (i <= 3 && substr(s, i, 1) == " ") i++
      rest = substr(s, i)
      if (substr(rest, 1, 1) != "[") return ""
      if (!match(rest, /^\[[^]]+\]:/)) return ""
      rest = substr(rest, RLENGTH + 1)
      if (!match(rest, /^[ \t]+/)) return ""
      rest = substr(rest, RLENGTH + 1)
      if (!match(rest, /^[^ \t]+/)) return ""
      return substr(rest, 1, RLENGTH)
    }
    BEGIN {
      base = curfile
      if (index(base, "/") > 0) sub(/\/[^\/]*$/, "", base)
      else base = ""
    }
    {
      line = $0
      lineno = NR
      pos = 1
      while (pos <= length(line)) {
        rel = index(substr(line, pos), "](")
        if (rel == 0) break
        p = pos + rel - 1
        rel = index(substr(line, p + 2), ")")
        if (rel == 0) break
        emit(lineno, substr(line, p + 2, rel - 1))
        pos = p + rel + 2
      }
      target = ref_target(line)
      if (target != "") emit(lineno, target)
    }
  '
}

run_prose_dashes() {
  local checked=0
  local hits=0
  local path hit lineno

  row Gate Name Status Action
  row ---- ------------------------------ ------ ------

  while IFS= read -r -d '' path; do
    if [ ! -f "$repo/$path" ]; then
      continue
    fi
    checked=$((checked + 1))

    while IFS= read -r hit; do
      [ -n "$hit" ] || continue
      lineno="${hit%%:*}"
      row PD "$path:$lineno" FAIL "em dash in prose; use a comma, colon, period, or parentheses (CONTRIBUTING.md)"
      hits=$((hits + 1))
    done < <(mdh_strip_code "$repo/$path" | LC_ALL=C grep -nF -- "$mdh_em_dash" 2>/dev/null)

    while IFS= read -r hit; do
      [ -n "$hit" ] || continue
      lineno="${hit%%:*}"
      row PD "$path:$lineno" FAIL "en dash in prose; write 'to' for ranges, else a comma, colon, or period (CONTRIBUTING.md)"
      hits=$((hits + 1))
    done < <(mdh_strip_code "$repo/$path" | LC_ALL=C grep -nF -- "$mdh_en_dash" 2>/dev/null)
  done < <(git -C "$repo" ls-files -z -- '*.md')

  if [ "$hits" -gt 0 ]; then
    row PD prose-dashes FAIL "$checked files, $hits hits"
  else
    row PD prose-dashes PASS "$checked files, $hits hits"
  fi

  if [ "$hits" -gt 0 ] && [ "$strict" = 1 ]; then
    return 1
  fi
  return 0
}

run_md_links() {
  local checked=0
  local links=0
  local hits=0
  local path
  local lineno resolved anchor outside
  local anchor_lc anchors

  row Gate Name Status Action
  row ---- ------------------------------ ------ ------

  while IFS= read -r -d '' path; do
    if [ ! -f "$repo/$path" ]; then
      continue
    fi
    checked=$((checked + 1))

    while IFS=$'\037' read -r lineno resolved anchor outside; do
      [ -n "$lineno" ] || continue
      links=$((links + 1))

      if [ "$outside" = 1 ]; then
        row ML "$path:$lineno" FAIL "points outside the repository; link to a path inside the kit"
        hits=$((hits + 1))
        continue
      fi

      if [ ! -e "$repo/$resolved" ]; then
        row ML "$path:$lineno" FAIL "target not found: $resolved; update the link to the file's current path"
        hits=$((hits + 1))
        continue
      fi

      if [ -n "$anchor" ] && [ -f "$repo/$resolved" ]; then
        case "$resolved" in
          *.md)
            # ASCII-only on purpose: GitHub slugs keep non-ASCII bytes as they are.
            # shellcheck disable=SC2018,SC2019
            anchor_lc="$(printf '%s' "$anchor" | LC_ALL=C tr 'A-Z' 'a-z')"
            anchors="$(mdh_anchors "$repo/$resolved")"
            if ! printf '%s\n' "$anchors" | LC_ALL=C grep -qxF -- "$anchor_lc"; then
              row ML "$path:$lineno" FAIL "no heading #$anchor in $resolved; use the heading slug (lowercase, punctuation dropped, spaces as -)"
              hits=$((hits + 1))
            fi
            ;;
        esac
      fi
    done < <(mdh_strip_code "$repo/$path" | mdh_collect_links "$path")
  done < <(git -C "$repo" ls-files -z -- '*.md')

  if [ "$hits" -gt 0 ]; then
    row ML md-links FAIL "$checked files, $links links checked, $hits hits"
  else
    row ML md-links PASS "$checked files, $links links checked, $hits hits"
  fi

  if [ "$hits" -gt 0 ] && [ "$strict" = 1 ]; then
    return 1
  fi
  return 0
}
