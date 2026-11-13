#!/usr/bin/env bash
# Pre-launch settings check for scripts/agy-review-launch.sh.
# Sourced by the launcher, never run on its own. Provides:
#
#   agy_settings_check <settings.json> <run-dir>
#
# Returns 0 when every path-bearing entry in .permissions.allow[] resolves
# inside <run-dir>, 1 on any failure with a message on stderr, and 2 on a wrong
# argument count.
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
    printf 'agy-review-launch: settings: allow entry "" is empty; name(argument) entries required\n' >&2
    return 1
  fi

  if ! [[ "$entry" =~ $entry_re ]]; then
    printf 'agy-review-launch: settings: allow entry %s is not a strict name(argument) entry\n' "$entry" >&2
    return 1
  fi

  tool="${entry%%(*}"
  arg="${entry#*(}"
  arg="${arg%\)}"

  if [ -z "$arg" ]; then
    if [ "$tool" = "command" ]; then
      printf 'agy-review-launch: settings: %s has an empty command argument\n' "$entry" >&2
    else
      printf 'agy-review-launch: settings: %s has no path argument\n' "$entry" >&2
    fi
    return 1
  fi

  # command(...) runs a program; it does not name a write path.
  if [ "$tool" = "command" ]; then
    return 0
  fi

  case "$arg" in
    *'*'* | *'?'* | *'['*)
      printf 'agy-review-launch: settings: %s uses a wildcard; allow exact paths only\n' "$entry" >&2
      return 1
      ;;
  esac

  if ! resolved="$(agy_physical_path "$arg" "$run_real")"; then
    printf 'agy-review-launch: settings: cannot resolve %s (%s)\n' "$entry" "$arg" >&2
    return 1
  fi
  if agy_path_inside "$resolved" "$run_real"; then
    return 0
  fi
  printf 'agy-review-launch: settings: %s resolves to %s outside run folder %s\n' \
    "$entry" "$resolved" "$run_real" >&2
  return 1
}

# agy_settings_check <settings.json> <run-dir>
agy_settings_check() {
  local settings="${1:-}"
  local run="${2:-}"
  local run_real entry total lines bad

  if [ "$#" -ne 2 ] || [ -z "$settings" ] || [ -z "$run" ]; then
    printf 'agy-review-launch: settings: usage: agy_settings_check <settings.json> <run-dir>\n' >&2
    return 2
  fi
  if [ ! -f "$settings" ]; then
    printf 'agy-review-launch: settings: settings file not found: %s\n' "$settings" >&2
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    printf 'agy-review-launch: settings: jq is required to read %s\n' "$settings" >&2
    return 1
  fi
  if ! jq -e . "$settings" >/dev/null 2>&1; then
    printf 'agy-review-launch: settings: invalid JSON: %s\n' "$settings" >&2
    return 1
  fi
  if ! jq -e '(((.permissions // null) | type) == "object") and (((.permissions.allow // null) | type) == "array")' \
    "$settings" >/dev/null 2>&1; then
    printf 'agy-review-launch: settings: missing or non-array .permissions.allow: %s\n' "$settings" >&2
    return 1
  fi
  bad="$(jq -r '[.permissions.allow[] | select(type != "string") | tojson] | first // empty' \
    "$settings" 2>/dev/null || true)"
  if [ -n "$bad" ]; then
    printf 'agy-review-launch: settings: allow entry %s is not a string\n' "$bad" >&2
    return 1
  fi
  total="$(jq -r '.permissions.allow | length' "$settings")"
  if [ "$total" -eq 0 ]; then
    printf 'agy-review-launch: settings: allow list is empty ([]): %s\n' "$settings" >&2
    return 1
  fi
  lines="$(jq -r '.permissions.allow[]' "$settings" | wc -l | tr -d '[:space:]')"
  if [ "$total" != "$lines" ]; then
    printf 'agy-review-launch: settings: an allow entry contains a newline: %s\n' "$settings" >&2
    return 1
  fi
  if [ ! -d "$run" ]; then
    printf 'agy-review-launch: settings: run folder not found: %s\n' "$run" >&2
    return 1
  fi
  if ! run_real="$(agy_physical_path "$run")"; then
    printf 'agy-review-launch: settings: cannot resolve run folder: %s\n' "$run" >&2
    return 1
  fi

  while IFS= read -r entry; do
    if ! agy_settings_check_entry "$entry" "$run_real"; then
      return 1
    fi
  done < <(jq -r '.permissions.allow[]' "$settings")

  return 0
}
