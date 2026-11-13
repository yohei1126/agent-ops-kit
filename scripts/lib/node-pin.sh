#!/usr/bin/env bash
# node-pin check for scripts/dev-loop-gate.sh.
# Sourced by the gate script, never run on its own. It expects row() and repo
# to come from the caller.
set -u

# The caller initializes these before sourcing; the defaults keep shellcheck
# and set -u happy when the file is linted alone.
repo="${repo:-}"

node_pin_state=""
node_pin_action=""

# node_pin_trim <value>
# Prints <value> without leading or trailing whitespace.
node_pin_trim() {
  local value="$1"

  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

# node_pin_dotted <value>
# True for a dotted numeric version such as 22 or 22.11.0.
node_pin_dotted() {
  case "$1" in
    ''|.*|*.|*..*|*[!0-9.]*) return 1 ;;
    *[0-9]*) return 0 ;;
    *) return 1 ;;
  esac
}

# node_pin_nvmrc_value <file>
# Prints the first meaningful .nvmrc line with comments and whitespace removed.
node_pin_nvmrc_value() {
  local line=""

  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="$(node_pin_trim "$line")"
    if [ -n "$line" ]; then
      printf '%s' "$line"
      return 0
    fi
  done < "$1"
  return 0
}

# node_pin_major <source> <value>
# Prints the pinned major and returns 0 for a single pin. Returns 1 when the
# value is a range, an alias, or anything else that does not name one major.
node_pin_major() {
  local source="$1"
  local value="$2"

  if [ "$source" = "nvmrc" ]; then
    case "$value" in
      v*) value="${value#v}" ;;
    esac
  else
    case "$value" in
      '^'*|'~'*|'='*) value="${value#?}" ;;
    esac
    case "$value" in
      *.[xX]) value="${value%.*}" ;;
    esac
  fi
  if ! node_pin_dotted "$value"; then
    return 1
  fi
  printf '%s' "${value%%.*}"
  return 0
}

# node_pin_version_major <version>
# Prints the major from a `node -v` value such as v26.1.0.
node_pin_version_major() {
  local value="$1"

  case "$value" in
    v*) value="${value#v}" ;;
  esac
  if ! node_pin_dotted "$value"; then
    return 1
  fi
  printf '%s' "${value%%.*}"
}

# node_pin_workflow_hard <file>
# True when any actions/setup-node step in <file> sets node-version: without
# node-version-file:. Plain POSIX awk so macOS awk and mawk both work.
node_pin_workflow_hard() {
  awk '
    function indent(s) {
      match(s, /^ */)
      return RLENGTH
    }
    function flush() {
      if (in_step && uses_node && has_version && !has_file) {
        found = 1
      }
      in_step = 0
      uses_node = 0
      has_version = 0
      has_file = 0
    }
    {
      line = $0
      quiet = (line ~ /^[[:space:]]*$/) || (line ~ /^[[:space:]]*#/)
      if (line ~ /^[[:space:]]*-[[:space:]]/) {
        flush()
        in_step = 1
        step_indent = indent(line)
      } else if (in_step && !quiet && indent(line) <= step_indent) {
        flush()
      }
      if (in_step && !quiet) {
        if (line ~ /^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*actions\/setup-node(@|[[:space:]]|$)/) {
          uses_node = 1
        }
        if (line ~ /^[[:space:]]*node-version-file[[:space:]]*:/) {
          has_file = 1
        } else if (line ~ /^[[:space:]]*node-version[[:space:]]*:/) {
          has_version = 1
        }
      }
    }
    END {
      flush()
      exit (found ? 0 : 1)
    }
  ' "$1"
}

# node_pin_workflow_hits <root>
# Prints the repository-relative workflow files that hard-code node-version.
node_pin_workflow_hits() {
  local root="$1"
  local file rel hits=""

  for file in "$root"/.github/workflows/*.yml "$root"/.github/workflows/*.yaml; do
    [ -f "$file" ] || continue
    node_pin_workflow_hard "$file" || continue
    rel="${file#"$root"/}"
    if [ -z "$hits" ]; then
      hits="$rel"
    else
      hits="$hits, $rel"
    fi
  done
  printf '%s' "$hits"
}

# node_pin_evaluate <root>
# Sets node_pin_state and node_pin_action from the files at <root>.
# A repository without a pin file is SKIP, never FAIL.
node_pin_evaluate() {
  local root="$1"
  local source=""
  local pin_value=""
  local pin_major=""
  local pin_hint=""
  local hits=""
  local local_major=""
  local node_v=""

  if [ -f "$root/.nvmrc" ]; then
    pin_value="$(node_pin_nvmrc_value "$root/.nvmrc")"
    if [ -n "$pin_value" ]; then
      source="nvmrc"
    fi
  fi

  if [ -z "$source" ] && [ -f "$root/package.json" ]; then
    if ! command -v jq >/dev/null 2>&1; then
      node_pin_state=SKIP
      node_pin_action="jq is needed to read engines.node; install jq or add .nvmrc."
      return 0
    fi
    if ! pin_value="$(jq -r 'if (.engines | type) == "object" then (.engines.node // empty) else empty end' "$root/package.json" 2>/dev/null)"; then
      node_pin_state=SKIP
      node_pin_action="package.json is not valid JSON; cannot read engines.node."
      return 0
    fi
    if [ -n "$pin_value" ]; then
      source="engines"
    fi
  fi

  if [ -z "$source" ]; then
    node_pin_state=SKIP
    node_pin_action="no .nvmrc or engines.node; Node is not pinned."
    return 0
  fi

  if ! pin_major="$(node_pin_major "$source" "$pin_value")"; then
    node_pin_state=SKIP
    if [ "$source" = "engines" ]; then
      node_pin_action="engines.node ($pin_value) is not a single major; Node is not pinned."
    else
      node_pin_action=".nvmrc ($pin_value) is not a single major; Node is not pinned."
    fi
    return 0
  fi

  if [ "$source" = "nvmrc" ]; then
    pin_hint=".nvmrc"
  else
    pin_hint="package.json"
  fi

  hits="$(node_pin_workflow_hits "$root")"
  if [ -n "$hits" ]; then
    node_pin_state=FAIL
    node_pin_action="$hits: setup-node sets node-version; use node-version-file: $pin_hint."
    return 0
  fi

  if ! command -v node >/dev/null 2>&1; then
    node_pin_state=FAIL
    node_pin_action="node is not on PATH; install Node $pin_major to match the pin."
    return 0
  fi

  node_v="$(node -v 2>/dev/null)" || node_v=""
  local_major="$(node_pin_version_major "$node_v")" || local_major=""
  if [ -z "$local_major" ]; then
    node_pin_state=FAIL
    node_pin_action="node -v did not report a major; install Node $pin_major."
    return 0
  fi

  if [ "$local_major" != "$pin_major" ]; then
    node_pin_state=FAIL
    node_pin_action="local Node $local_major != pin $pin_major; run tests with npx -y node@$pin_major or nvm use."
    return 0
  fi

  node_pin_state=PASS
  node_pin_action="Continue."
}

# run_node_pin
# Prints the node-pin table for --check node-pin and returns 1 on FAIL. FAIL is
# always an exit 1, with or without --strict.
run_node_pin() {
  local root="${repo:-$PWD}"

  row Gate Name Status Action
  row ---- ------------------------------ ------ ------
  node_pin_evaluate "$root"
  row NP node-pin "$node_pin_state" "$node_pin_action"
  if [ "$node_pin_state" = FAIL ]; then
    printf 'dev-loop-gate: node-pin: %s\n' "$node_pin_action" >&2
    return 1
  fi
  return 0
}
