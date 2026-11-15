#!/usr/bin/env bash
# Per-run settings generation and pre-launch settings check shared by
# scripts/agy-review-launch.sh and scripts/agy-docs-launch.sh. Sourced by a
# launcher, never run on its own. Provides:
#
#   agy_settings_generate <template> <out-file> <run-dir>
#   agy_settings_check <settings.json> <run-dir>
#
# agy_settings_generate writes <out-file> from <template>, replacing every
# @RUN_DIR@ with <run-dir>. It never reads any other settings file.
#
# agy_settings_check returns 0 when every path-bearing entry in
# .permissions.allow[] resolves inside <run-dir>, 1 on any failure with a
# message on stderr, and 2 on a wrong argument count.
#
# Messages start with $agy_settings_tag (default agy-settings). A launcher sets
# it before sourcing so messages name the launcher.
#
# Rules:
# - .permissions.allow must hold at least one entry, and no entry may be empty.
# - Every entry must have the strict shape name(arg): the tool name matches
#   [A-Za-z_][A-Za-z0-9_-]*, and arg holds no "(" or ")". Anything else, such
#   as a bare tool name or trailing text after the closing ")", fails.
# - command(...) entries are not paths, but still need a non-empty argument.
# - Every other argument is a path. An empty argument fails, and so does a
#   glob character (*, ?, or [).
# - A leading ~ expands against $HOME. Every component is then resolved on
#   disk in order: a symlink at any position (file, directory, or dangling) is
#   read and its target is spliced in, so it cannot hide an escape. A symlink
#   loop fails the check.
# - Inside means equal to the run dir or under it by path component. The prefix
#   test never accepts /runs/ab for /runs/a.
#
# Compatible with macOS bash 3.2 and Linux bash 5, and safe under set -u.

set -u

agy_settings_tag="${agy_settings_tag:-agy-settings}"

# agy_physical_path <path> [base-dir]
# Prints the physical absolute path for <path>. Relative paths resolve against
# [base-dir], defaulting to the current directory. Returns 1 for an empty path,
# the unsupported ~user form, an unreadable symlink target, or a symlink loop.
#
# Resolution walks the path one component at a time from "/". `cur` always
# holds an already resolved prefix, so ".." pops it physically. A symlink at
# $cur/$comp is read with plain readlink (no -f), and its target is spliced in
# front of the remaining components: an absolute target restarts from "/", a
# relative one is relative to `cur`. Missing components and regular files are
# appended literally; a later ".." still pops them and later components are
# checked against disk again.
agy_physical_path() {
  local target base rest comp cur next hops=0
  local max_hops=40

  target="${1:-}"
  base="${2:-$PWD}"
  if [ -z "$target" ]; then
    return 1
  fi
  case "$target" in
    \~) target="$HOME" ;;
    \~/*)
      # Drop the leading "~/" and re-root the rest at $HOME.
      target="$HOME/${target#??}"
      ;;
    \~*) return 1 ;;
  esac
  case "$target" in
    /*) ;;
    *) target="$base/$target" ;;
  esac
  case "$target" in
    /*) ;;
    *) target="$PWD/$target" ;;
  esac

  cur="/"
  rest="$target"
  while [ -n "$rest" ]; do
    case "$rest" in
      */*)
        comp="${rest%%/*}"
        rest="${rest#*/}"
        ;;
      *)
        comp="$rest"
        rest=""
        ;;
    esac
    case "$comp" in
      '' | .) continue ;;
      ..)
        if [ "$cur" != "/" ]; then
          cur="${cur%/*}"
          if [ -z "$cur" ]; then
            cur="/"
          fi
        fi
        continue
        ;;
    esac

    if [ "$cur" = "/" ]; then
      next="/$comp"
    else
      next="$cur/$comp"
    fi

    if [ -L "$next" ]; then
      hops=$((hops + 1))
      if [ "$hops" -gt "$max_hops" ]; then
        return 1
      fi
      if ! target="$(readlink "$next")"; then
        return 1
      fi
      if [ -z "$target" ]; then
        return 1
      fi
      case "$target" in
        /*) cur="/" ;;
      esac
      if [ -n "$rest" ]; then
        rest="$target/$rest"
      else
        rest="$target"
      fi
      continue
    fi

    cur="$next"
  done
  printf '%s\n' "$cur"
}

# agy_path_inside <candidate> <root>
# True when candidate equals root or sits under it by path component.
agy_path_inside() {
  local candidate="$1"
  local root="$2"

  if [ "$root" = "/" ]; then
    case "$candidate" in
      /*) return 0 ;;
      *) return 1 ;;
    esac
  fi
  if [ "$candidate" = "$root" ]; then
    return 0
  fi
  case "$candidate" in
    "$root"/*) return 0 ;;
  esac
  return 1
}

# agy_settings_check_entry <entry> <resolved-run-dir>
# Checks one allow entry. Returns non-zero with a stderr message on failure.
agy_settings_check_entry() {
  local entry="$1"
  local run_real="$2"
  local tool arg resolved
  # Strict name(arg) shape. The pattern lives in a variable (unquoted at use)
  # so bash 3.2 and bash 5 agree on it; the bracket forms keep "(" and ")"
  # literal in both.
  local entry_re='^[A-Za-z_][A-Za-z0-9_-]*[(][^()]*[)]$'

  if [ -z "$entry" ]; then
    printf '%s: settings: allow entry "" is empty; name(argument) entries required\n' "$agy_settings_tag" >&2
    return 1
  fi

  if ! [[ "$entry" =~ $entry_re ]]; then
    printf '%s: settings: allow entry %s is not a strict name(argument) entry\n' "$agy_settings_tag" "$entry" >&2
    return 1
  fi

  tool="${entry%%(*}"
  arg="${entry#*(}"
  arg="${arg%\)}"

  if [ -z "$arg" ]; then
    if [ "$tool" = "command" ]; then
      printf '%s: settings: %s has an empty command argument\n' "$agy_settings_tag" "$entry" >&2
    else
      printf '%s: settings: %s has no path argument\n' "$agy_settings_tag" "$entry" >&2
    fi
    return 1
  fi

  # command(...) runs a program; it does not name a write path.
  if [ "$tool" = "command" ]; then
    return 0
  fi

  case "$arg" in
    *'*'* | *'?'* | *'['*)
      printf '%s: settings: %s uses a wildcard; allow exact paths only\n' "$agy_settings_tag" "$entry" >&2
      return 1
      ;;
  esac

  if ! resolved="$(agy_physical_path "$arg" "$run_real")"; then
    printf '%s: settings: cannot resolve %s (%s)\n' "$agy_settings_tag" "$entry" "$arg" >&2
    return 1
  fi
  if agy_path_inside "$resolved" "$run_real"; then
    return 0
  fi
  printf '%s: settings: %s resolves to %s outside run folder %s\n' "$agy_settings_tag" \
    "$entry" "$resolved" "$run_real" >&2
  return 1
}

# agy_settings_check <settings.json> <run-dir>
agy_settings_check() {
  local settings="${1:-}"
  local run="${2:-}"
  local run_real entry total lines bad

  if [ "$#" -ne 2 ] || [ -z "$settings" ] || [ -z "$run" ]; then
    printf '%s: settings: usage: agy_settings_check <settings.json> <run-dir>\n' "$agy_settings_tag" >&2
    return 2
  fi
  if [ -L "$settings" ]; then
    printf '%s: settings: refusing symlinked settings file: %s\n' "$agy_settings_tag" "$settings" >&2
    return 1
  fi
  if [ ! -f "$settings" ]; then
    printf '%s: settings: settings file not found: %s\n' "$agy_settings_tag" "$settings" >&2
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    printf '%s: settings: jq is required to read %s\n' "$agy_settings_tag" "$settings" >&2
    return 1
  fi
  if ! jq -e . "$settings" >/dev/null 2>&1; then
    printf '%s: settings: invalid JSON: %s\n' "$agy_settings_tag" "$settings" >&2
    return 1
  fi
  if ! jq -e '(((.permissions // null) | type) == "object") and (((.permissions.allow // null) | type) == "array")' \
    "$settings" >/dev/null 2>&1; then
    printf '%s: settings: missing or non-array .permissions.allow: %s\n' "$agy_settings_tag" "$settings" >&2
    return 1
  fi
  bad="$(jq -r '[.permissions.allow[] | select(type != "string") | tojson] | first // empty' \
    "$settings" 2>/dev/null || true)"
  if [ -n "$bad" ]; then
    printf '%s: settings: allow entry %s is not a string\n' "$agy_settings_tag" "$bad" >&2
    return 1
  fi
  total="$(jq -r '.permissions.allow | length' "$settings")"
  if [ "$total" -eq 0 ]; then
    printf '%s: settings: allow list is empty ([]): %s\n' "$agy_settings_tag" "$settings" >&2
    return 1
  fi
  lines="$(jq -r '.permissions.allow[]' "$settings" | wc -l | tr -d '[:space:]')"
  if [ "$total" != "$lines" ]; then
    printf '%s: settings: an allow entry contains a newline: %s\n' "$agy_settings_tag" "$settings" >&2
    return 1
  fi
  if [ ! -d "$run" ]; then
    printf '%s: settings: run folder not found: %s\n' "$agy_settings_tag" "$run" >&2
    return 1
  fi
  if ! run_real="$(agy_physical_path "$run")"; then
    printf '%s: settings: cannot resolve run folder: %s\n' "$agy_settings_tag" "$run" >&2
    return 1
  fi

  while IFS= read -r entry; do
    if ! agy_settings_check_entry "$entry" "$run_real"; then
      return 1
    fi
  done < <(jq -r '.permissions.allow[]' "$settings")

  return 0
}

# agy_settings_generate <template> <out-file> <run-dir>
# Writes <out-file> from <template>, replacing every @RUN_DIR@ with <run-dir>
# (pass the resolved physical path). The output goes to a temp file beside
# <out-file> first, is checked as JSON, and is then moved into place, so a
# failure never leaves a partial file. Refuses a symlinked <out-file> or temp
# file, and a <run-dir> holding a quote, backslash, parenthesis, wildcard, or
# control character. Returns 0 on success, 1 on failure with a message on
# stderr, and 2 on a wrong argument count. Run agy_settings_check on the result
# before launch.
agy_settings_generate() {
  local template="${1:-}"
  local out="${2:-}"
  local run_real="${3:-}"
  local out_dir escaped tmp

  if [ "$#" -ne 3 ] || [ -z "$template" ] || [ -z "$out" ] || [ -z "$run_real" ]; then
    printf '%s: settings: usage: agy_settings_generate <template> <out-file> <run-dir>\n' \
      "$agy_settings_tag" >&2
    return 2
  fi
  if [ ! -r "$template" ]; then
    printf '%s: missing settings template: %s\n' "$agy_settings_tag" "$template" >&2
    return 1
  fi
  if [ -L "$out" ]; then
    printf '%s: refusing symlinked settings file: %s\n' "$agy_settings_tag" "$out" >&2
    return 1
  fi
  # The path is spliced into JSON strings and name(arg) entries. Refuse any
  # character that could end the string, add an entry, or act as a glob.
  case "$run_real" in
    *'"'* | *\\* | *'('* | *')'* | *'*'* | *'?'* | *'['* | *[[:cntrl:]]*)
      printf '%s: settings: refusing run folder path with a quote, backslash, parenthesis, wildcard, or control character: %s\n' \
        "$agy_settings_tag" "$run_real" >&2
      return 1
      ;;
  esac
  case "$out" in
    */*) out_dir="${out%/*}" ;;
    *) out_dir="." ;;
  esac
  if [ -z "$out_dir" ]; then
    out_dir="/"
  fi

  escaped="$(printf '%s' "$run_real" | sed 's/[\\&|]/\\&/g')"
  if ! tmp="$(mktemp "$out_dir/.agy-settings.XXXXXX")"; then
    printf '%s: failed to create a settings temp file in %s\n' "$agy_settings_tag" "$out_dir" >&2
    return 1
  fi
  if [ -L "$tmp" ]; then
    rm -f -- "$tmp"
    printf '%s: refusing symlinked settings temp file: %s\n' "$agy_settings_tag" "$tmp" >&2
    return 1
  fi
  if ! sed "s|@RUN_DIR@|$escaped|g" "$template" >"$tmp"; then
    rm -f -- "$tmp"
    printf '%s: failed to generate %s\n' "$agy_settings_tag" "$out" >&2
    return 1
  fi
  if ! jq -e . "$tmp" >/dev/null 2>&1; then
    rm -f -- "$tmp"
    printf '%s: generated settings is not valid JSON: %s\n' "$agy_settings_tag" "$out" >&2
    return 1
  fi
  if ! mv -f -- "$tmp" "$out"; then
    rm -f -- "$tmp"
    printf '%s: failed to move generated settings into %s\n' "$agy_settings_tag" "$out" >&2
    return 1
  fi
  return 0
}
