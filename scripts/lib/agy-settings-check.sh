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
# - command(...) entries are not paths and are skipped.
# - write_file entries must carry a path and no wildcard.
# - Other name(arg) entries whose argument starts with /, ~, or . or contains /
#   are treated as paths.
# - A leading ~ expands against $HOME. The deepest existing ancestor is
#   resolved with cd -P/pwd -P so symlinks are followed, then the remaining
#   components are normalized lexically so .. cannot hide an escape.
# - Inside means equal to the run dir or under it by path component. The prefix
#   test never accepts /runs/ab for /runs/a.
#
# Compatible with macOS bash 3.2 and Linux bash 5, and safe under set -u.

set -u

# agy_lexical_normalize <absolute-path>
# Prints the path with empty and "." components dropped and ".." applied
# lexically. ".." never climbs above "/". No filesystem access.
agy_lexical_normalize() {
  local rest out comp

  rest="${1:-}"
  out=""
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
      '' | .) ;;
      ..) out="${out%/*}" ;;
      *) out="$out/$comp" ;;
    esac
  done
  if [ -z "$out" ]; then
    printf '/\n'
  else
    printf '%s\n' "$out"
  fi
}

# agy_physical_path <path> [base-dir]
# Prints the physical absolute path for <path>. Relative paths resolve against
# [base-dir], defaulting to the current directory. Returns 1 for an empty path
# or the unsupported ~user form.
agy_physical_path() {
  local target base target_dir rest comp

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

  # Strip trailing slashes so the last component is a real name.
  while [ "$target" != "/" ] && [ "${target%/}" != "$target" ]; do
    target="${target%/}"
  done

  # Walk up to the deepest existing directory ancestor, remembering the rest.
  target_dir="$target"
  rest=""
  while [ ! -d "$target_dir" ]; do
    comp="${target_dir##*/}"
    target_dir="${target_dir%/*}"
    if [ -z "$target_dir" ]; then
      target_dir="/"
    fi
    if [ -z "$rest" ]; then
      rest="$comp"
    else
      rest="$comp/$rest"
    fi
  done

  if ! base="$(cd -P -- "$target_dir" && pwd -P)"; then
    return 1
  fi
  if [ -z "$rest" ]; then
    agy_lexical_normalize "$base"
  else
    agy_lexical_normalize "$base/$rest"
  fi
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

  case "$entry" in
    *'('*')'*)
      tool="${entry%%(*}"
      arg="${entry#*(}"
      arg="${arg%\)}"
      ;;
    *)
      printf 'agy-review-launch: settings: allow entry %s has no name(argument) form\n' "$entry" >&2
      return 1
      ;;
  esac

  # command(...) runs a program; it does not name a write path.
  if [ "$tool" = "command" ]; then
    return 0
  fi

  case "$entry" in
    *'*'*)
      printf 'agy-review-launch: settings: %s uses a wildcard; allow exact paths only\n' "$entry" >&2
      return 1
      ;;
  esac

  if [ "$tool" = "write_file" ] && [ -z "$arg" ]; then
    printf 'agy-review-launch: settings: %s has no path argument\n' "$entry" >&2
    return 1
  fi

  if [ "$tool" != "write_file" ]; then
    case "$arg" in
      /* | '~'* | .* | */*) ;;
      *) return 0 ;;
    esac
  fi

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
    if [ -z "$entry" ]; then
      continue
    fi
    if ! agy_settings_check_entry "$entry" "$run_real"; then
      return 1
    fi
  done < <(jq -r '.permissions.allow[]' "$settings")

  return 0
}
