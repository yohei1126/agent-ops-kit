#!/usr/bin/env bash
# npm-ci check for scripts/dev-loop-gate.sh.
# Sourced by the gate script, never run on its own. It expects row() and repo
# to come from the caller.
set -u

# The caller initializes these before sourcing; the defaults keep shellcheck
# and set -u happy when the file is linted alone.
repo="${repo:-}"

npm_ci_state=""
npm_ci_action=""

# npm_ci_evaluate <root>
# Sets npm_ci_state and npm_ci_action from the files at <root>.
# Only package-lock.json at the root is in scope. A missing node_modules beside
# it is a hard stop; an empty node_modules still passes.
npm_ci_evaluate() {
  local root="$1"

  if [ ! -f "$root/package-lock.json" ]; then
    npm_ci_state=SKIP
    npm_ci_action="no package-lock.json; npm is not in use."
  elif [ -d "$root/node_modules" ]; then
    npm_ci_state=PASS
    npm_ci_action="Continue."
  else
    npm_ci_state=FAIL
    npm_ci_action="package-lock.json without node_modules; run npm ci first."
  fi
}

# npm_ci_default_root
# Root for the default G1 to G7 table: the resolved --repo work tree, else the
# work tree of the current directory, else the current directory. The table
# keeps working outside git, so this never fails.
npm_ci_default_root() {
  local root=""

  if [ -n "$repo" ]; then
    printf '%s' "$repo"
    return 0
  fi
  if command -v git >/dev/null 2>&1; then
    root="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null)" || root=""
  fi
  if [ -z "$root" ]; then
    root="$PWD"
  fi
  printf '%s' "$root"
}

# run_npm_ci
# Prints the npm-ci table for --check npm-ci and returns 1 on FAIL. FAIL is
# always an exit 1, with or without --strict.
run_npm_ci() {
  local root="${repo:-$PWD}"

  row Gate Name Status Action
  row ---- ------------------------------ ------ ------
  npm_ci_evaluate "$root"
  row NM npm-ci "$npm_ci_state" "$npm_ci_action"
  if [ "$npm_ci_state" = FAIL ]; then
    printf 'dev-loop-gate: npm-ci: package-lock.json at %s needs node_modules; run npm ci\n' "$root" >&2
    return 1
  fi
  return 0
}
