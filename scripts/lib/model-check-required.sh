#!/usr/bin/env bash
# model-check-required named check for scripts/dev-loop-gate.sh.
# Sourced by the gate script, never run on its own. It expects row(), repo,
# and run_table from the caller.
#
# Decide whether a model review may be skipped. The first failing rule decides
# REQUIRED, the fail-closed direction. It always exits 0 when it prints a
# decision, so a caller that ignores the row never skips.
set -u

repo="${repo:-}"

mcr_line_cap=150
mcr_deny_patterns=".github/* *auth* *secret* *token* *credential* *permission* *launch* *settings* *security* .env* */.env* scripts/agents/* scripts/templates/* scripts/quota/* scripts/dev-loop-gate.sh scripts/lib/* scripts/tests/test_model_check_required.sh scripts/tests/test_dev_loop_gate.sh templates/dev-loop/* prompts/* *agent-config* *model-ids*"
mcr_allow_patterns="docs/*.md README.md scripts/README.md"

# Prints the one decision row and removes the temporary diff file.
mcr_finish() {
  row MC model-check-required "$1" "$2"
  if [ -n "${mcr_tmp:-}" ]; then
    rm -f "$mcr_tmp"
  fi
  return 0
}

# True when the lowercased path matches one deny pattern.
mcr_deny_path() {
  local LC_ALL=C
  local lower pat

  lower="$(printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
  set -f
  # shellcheck disable=SC2086
  for pat in $mcr_deny_patterns; do
    # shellcheck disable=SC2254
    case "$lower" in
      $pat) set +f; return 0 ;;
    esac
  done
  set +f
  return 1
}

# True when the path is on the allow list, including the script rule.
mcr_allow_path() {
  local LC_ALL=C
  local path mb name rest test_rel pat

  path="$1"
  mb="$2"
  set -f
  # shellcheck disable=SC2086
  for pat in $mcr_allow_patterns; do
    # shellcheck disable=SC2254
    case "$path" in
      $pat) set +f; return 0 ;;
    esac
  done
  set +f

  case "$path" in
    scripts/tests/test_*.sh)
      rest="${path#scripts/tests/}"
      case "$rest" in
        */*) return 1 ;;
      esac
      if ! git -C "$repo" cat-file -e "$mb:$path" 2>/dev/null; then
        return 1
      fi
      return 0
      ;;
    scripts/*.sh)
      rest="${path#scripts/}"
      ;;
    *) return 1 ;;
  esac
  case "$rest" in
    */*) return 1 ;;
  esac
  name="${rest%.sh}"
  [ -n "$name" ] || return 1
  test_rel="scripts/tests/test_${name//-/_}.sh"
  git -C "$repo" cat-file -e "$mb:$path" 2>/dev/null || return 1
  git -C "$repo" cat-file -e "$mb:$test_rel" 2>/dev/null || return 1
  git -C "$repo" cat-file -e "HEAD:$test_rel" 2>/dev/null
}

usage_model_check_required() {
  cat <<'EOF'
usage: dev-loop-gate.sh --check model-check-required [--repo <root>] [--strict]

Decide whether the model review may be skipped. It prints one MC decision row,
REQUIRED or SKIP, and exits 0 whenever it prints a row, with or without
--strict. The base is DEV_LOOP_BASE, default origin/main; the diff is
merge-base(BASE, HEAD) to HEAD.

The first failing rule decides REQUIRED, in this order:
 1. the base does not resolve
 2. there is no merge base with the base
 3. the work tree has uncommitted changes
 4. the diff cannot be read, or the diff is empty
 5. a path has a character outside A-Za-z0-9._/-
 6. a path is on the deny list, matched on the lowercased path
 7. a path is a symlink, a submodule, has another mode change, or is
    a deleted path outside docs/
 8. a path is not on the allow list
 9. a script and its paired test changed together
10. a change is binary, a test loses lines, or the added plus deleted
    lines exceed the cap
11. the default G1 to G7 table fails under strict

Exit codes: 0 whenever a decision row is printed, 2 when the path is not a
git work tree or a usage error, 3 when git is missing.
EOF
  printf 'Line cap: %s\n' "$mcr_line_cap"
  printf 'Deny list: %s\n' "$mcr_deny_patterns"
  printf 'Allow list: %s\n' "$mcr_allow_patterns"
  cat <<'EOF'
A script scripts/<name>.sh is allowed only when both the script and
scripts/tests/test_<name>.sh exist at the merge base and the test still
exists at HEAD, with every - in <name> replaced by _. A test
scripts/tests/test_<name>.sh is allowed only when it exists at the merge
base and the change adds lines without deleting any. A script and its
paired test changed in the same diff are always REQUIRED.
EOF
}

# Runs the default table with strict on and restores the caller's strict flag.
# Returns run_table's status, so any FAIL in the default table is visible.
mcr_run_table_strict() {
  local strict_before="${strict:-0}"
  local status

  strict=1
  run_table
  status=$?
  strict="$strict_before"
  return "$status"
}

# True when the path is one of the changed paths.
mcr_path_listed() {
  local want="$1"
  local n="$2"
  local j=0

  while [ "$j" -lt "$n" ]; do
    if [ "${mcr_paths[$j]}" = "$want" ]; then
      return 0
    fi
    j=$((j + 1))
  done
  return 1
}

run_model_check_required() {
  local LC_ALL=C
  local base mb status_out raw_out numstat_out line rest tab
  local old_mode new_mode raw_path added deleted npath path
  local i npaths files total name
  local mcr_tmp=""
  local mcr_paths

  base="${DEV_LOOP_BASE:-origin/main}"

  row Gate Name Status Action
  row ---- ------------------------------ ------ ------

  if ! git -C "$repo" rev-parse --verify --quiet "$base^{commit}" >/dev/null 2>&1; then
    mcr_finish REQUIRED "base not found: $base"
    return 0
  fi
  if ! mb="$(git -C "$repo" merge-base "$base" HEAD 2>/dev/null)" || [ -z "$mb" ]; then
    mcr_finish REQUIRED "no merge base with $base"
    return 0
  fi
  if ! status_out="$(git -C "$repo" status --porcelain --untracked-files=all 2>/dev/null)" ||
    [ -n "$status_out" ]; then
    mcr_finish REQUIRED "uncommitted changes"
    return 0
  fi

  mcr_tmp="$(mktemp "${TMPDIR:-/tmp}/model-check-required.XXXXXX")" || {
    printf 'dev-loop-gate: cannot create a temp file for model-check-required\n' >&2
    exit 3
  }
  if ! git -C "$repo" diff --name-only --no-renames -z "$mb" HEAD >"$mcr_tmp" 2>/dev/null; then
    mcr_finish REQUIRED "cannot read diff"
    return 0
  fi
  if [ ! -s "$mcr_tmp" ]; then
    mcr_finish REQUIRED "empty diff"
    return 0
  fi

  mcr_paths=()
  npaths=0
  while IFS= read -r -d '' path; do
    mcr_paths[npaths]="$path"
    npaths=$((npaths + 1))
  done <"$mcr_tmp"

  rm -f "$mcr_tmp"
  mcr_tmp=""

  i=0
  while [ "$i" -lt "$npaths" ]; do
    path="${mcr_paths[$i]}"
    case "$path" in
      *[!A-Za-z0-9._/-]*)
        mcr_finish REQUIRED "unusual path"
        return 0
        ;;
    esac
    i=$((i + 1))
  done

  i=0
  while [ "$i" -lt "$npaths" ]; do
    path="${mcr_paths[$i]}"
    if mcr_deny_path "$path"; then
      mcr_finish REQUIRED "deny-listed path: $path"
      return 0
    fi
    i=$((i + 1))
  done

  if ! raw_out="$(git -C "$repo" diff --raw --no-renames "$mb" HEAD 2>/dev/null)"; then
    mcr_finish REQUIRED "cannot read diff"
    return 0
  fi
  tab="$(printf '\t')"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    rest="${line#:}"
    old_mode="${rest%% *}"
    rest="${rest#* }"
    new_mode="${rest%% *}"
    rest="${rest#* }"
    rest="${rest#* }"
    rest="${rest#* }"
    raw_path="${rest#*"$tab"}"
    if [ "$new_mode" = 000000 ]; then
      case "$raw_path" in
        docs/*) ;;
        *)
          mcr_finish REQUIRED "deleted file: $raw_path"
          return 0
          ;;
      esac
    fi
    if [ "$old_mode" = 120000 ] || [ "$new_mode" = 120000 ] ||
      [ "$old_mode" = 160000 ] || [ "$new_mode" = 160000 ]; then
      mcr_finish REQUIRED "mode change: $raw_path"
      return 0
    fi
    if [ "$old_mode" != 000000 ] && [ "$new_mode" != 000000 ] &&
      [ "$old_mode" != "$new_mode" ]; then
      mcr_finish REQUIRED "mode change: $raw_path"
      return 0
    fi
  done <<EOF_RAW
$raw_out
EOF_RAW

  i=0
  while [ "$i" -lt "$npaths" ]; do
    path="${mcr_paths[$i]}"
    if ! mcr_allow_path "$path" "$mb"; then
      mcr_finish REQUIRED "not on allow list: $path"
      return 0
    fi
    i=$((i + 1))
  done

  i=0
  while [ "$i" -lt "$npaths" ]; do
    path="${mcr_paths[$i]}"
    case "$path" in
      scripts/*.sh) rest="${path#scripts/}" ;;
      *) rest="" ;;
    esac
    case "$rest" in
      ""|*/*) ;;
      *)
        name="${rest%.sh}"
        if [ -n "$name" ] &&
          mcr_path_listed "scripts/tests/test_${name//-/_}.sh" "$npaths"; then
          mcr_finish REQUIRED "script and its test changed together: $path"
          return 0
        fi
        ;;
    esac
    i=$((i + 1))
  done

  if ! numstat_out="$(git -C "$repo" diff --numstat --no-renames "$mb" HEAD 2>/dev/null)"; then
    mcr_finish REQUIRED "cannot read diff"
    return 0
  fi
  files=0
  total=0
  while IFS="$tab" read -r added deleted npath; do
    [ -n "$npath" ] || continue
    if [ "$added" = "-" ] || [ "$deleted" = "-" ]; then
      mcr_finish REQUIRED "binary change: $npath"
      return 0
    fi
    case "$npath" in
      scripts/tests/*)
        if [ "$deleted" -gt 0 ]; then
          mcr_finish REQUIRED "test lines removed: $npath"
          return 0
        fi
        ;;
    esac
    files=$((files + 1))
    total=$((total + added + deleted))
  done <<EOF_NUMSTAT
$numstat_out
EOF_NUMSTAT

  if [ "$total" -gt "$mcr_line_cap" ]; then
    mcr_finish REQUIRED "$total changed lines over cap $mcr_line_cap"
    return 0
  fi

  if ! ( mcr_run_table_strict ) >/dev/null 2>&1; then
    mcr_finish REQUIRED "default gate table has a FAIL"
    return 0
  fi

  mcr_finish SKIP "$files files, $total lines; allow list, deny list, cap, and default gates pass"
  return 0
}
