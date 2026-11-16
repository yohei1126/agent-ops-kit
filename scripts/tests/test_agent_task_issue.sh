#!/usr/bin/env bash
# Tests for scripts/agent-task-issue.sh.
# Uses a fake gh on PATH. No network and no real repository.
set -u

script_name="agent-task-issue"
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
check="$repo_root/scripts/agent-task-issue.sh"
fixtures="$repo_root/scripts/tests/fixtures/agent-task-issue"

pass=0
fail=0
work_tmp="$(mktemp -d)"
home_tmp="$work_tmp/home"
xdg_tmp="$work_tmp/xdg"
fake_bin="$work_tmp/bin"
argv_file="$work_tmp/argv"
err_file="$work_tmp/stderr"
config_file="$xdg_tmp/agent-ops-kit/agent-task-repo"

mkdir -p "$home_tmp" "$xdg_tmp" "$fake_bin"
: > "$argv_file"
: > "$err_file"

trap 'rm -rf "$work_tmp"' EXIT

unset AGENT_TASK_REPO PUBLIC_TERMS_NO_RG

# The fake gh records its argv and returns canned answers. Tests drive the
# label lookups and issue URL through environment variables.
cat > "$fake_bin/gh" <<'EOF'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${AGENT_TASK_TEST_ARGV:-/dev/null}"
if [ "${AGENT_TASK_GH_FAIL:-0}" = 1 ]; then
  printf 'gh: boom\n' >&2
  exit 1
fi
agent="${AGENT_TASK_AGENT:-agy}"
case "${1:-} ${2:-}" in
  "label list")
    if [ "${AGENT_TASK_LABEL_LIST_HIDES:-0}" = 1 ]; then
      printf '[]\n'
      exit 0
    fi
    items=""
    if [ "${AGENT_TASK_HAS_TASK_LABEL:-1}" = 1 ]; then
      items="${items}{\"name\":\"agent-task\"}"
    fi
    if [ "${AGENT_TASK_HAS_AGENT_LABEL:-1}" = 1 ]; then
      [ -z "$items" ] || items="${items},"
      items="${items}{\"name\":\"agent:${agent}\"}"
    fi
    printf '[%s]\n' "$items"
    exit 0
    ;;
  "api "*)
    label="${2##*/}"
    case "$label" in
      agent-task)
        wanted="${AGENT_TASK_HAS_TASK_LABEL:-1}"
        ;;
      "agent:${agent}"|"agent%3A${agent}")
        wanted="${AGENT_TASK_HAS_AGENT_LABEL:-1}"
        ;;
      *)
        wanted=0
        ;;
    esac
    if [ "$wanted" = 1 ]; then
      printf '{"name":"%s"}\n' "$label"
      exit 0
    fi
    printf 'gh: Not Found (HTTP 404)\n' >&2
    exit 1
    ;;
  "label create")
    printf 'Created label %s\n' "${3:-}"
    exit 0
    ;;
  "issue create")
    printf '%s\n' "${AGENT_TASK_ISSUE_URL:-https://github.com/example-org/example-repo/issues/42}"
    exit 0
    ;;
esac
printf 'gh: unexpected call: %s\n' "$*" >&2
exit 1
EOF
chmod +x "$fake_bin/gh"

ok() {
  pass=$((pass + 1))
  printf 'PASS %s\n' "$1"
}

bad() {
  fail=$((fail + 1))
  printf 'FAIL %s: %s\n' "$1" "$2"
}

expect_status() {
  if [ "$status" -eq "$2" ]; then
    ok "$1"
  else
    bad "$1" "expected exit $2, got $status; stderr: $err"
  fi
}

expect_out() {
  case "$out" in
    *"$2"*) ok "$1" ;;
    *) bad "$1" "stdout missing: $2" ;;
  esac
}

expect_no_out() {
  case "$out" in
    *"$2"*) bad "$1" "stdout should not contain: $2" ;;
    *) ok "$1" ;;
  esac
}

expect_err() {
  case "$err" in
    *"$2"*) ok "$1" ;;
    *) bad "$1" "stderr missing: $2" ;;
  esac
}

expect_line() {
  if printf '%s\n' "$out" | grep -Fxq -- "$2"; then
    ok "$1"
  else
    bad "$1" "stdout missing exact line: $2"
  fi
}

expect_argv_has() {
  if grep -Fq -- "$2" "$argv_file"; then
    ok "$1"
  else
    bad "$1" "argv missing: $2"
  fi
}

expect_argv_never() {
  if grep -Fq -- "$2" "$argv_file"; then
    bad "$1" "argv should not contain: $2"
  else
    ok "$1"
  fi
}

expect_argv_calls() {
  local actual

  actual="$(wc -l < "$argv_file" | tr -d ' ')"
  if [ "$actual" -eq "$2" ]; then
    ok "$1"
  else
    bad "$1" "argv has $actual calls, expected $2"
  fi
}

expect_argv_order() {
  local first second

  first="$(grep -nF -- "$2" "$argv_file" | head -n 1 | cut -d: -f1)"
  second="$(grep -nF -- "$3" "$argv_file" | head -n 1 | cut -d: -f1)"
  if [ -n "$first" ] && [ -n "$second" ] && [ "$first" -lt "$second" ]; then
    ok "$1"
  else
    bad "$1" "expected '$2' before '$3'"
  fi
}

# Link only the named commands into a fresh directory. A PATH built from that
# directory alone keeps the real gh out of reach.
make_tool_path() {
  local dir="$1"
  shift
  local tool found

  mkdir -p "$dir"
  for tool in "$@"; do
    found="$(command -v "$tool" 2>/dev/null || true)"
    if [ -n "$found" ]; then
      ln -s "$found" "$dir/$tool"
    fi
  done
}

has_task_label=1
has_agent_label=1
agent_name=agy
issue_url="https://github.com/example-org/example-repo/issues/42"
gh_fail=0
label_list_hides=0
repo_env=""
check_path="$fake_bin:$PATH"

run_check() {
  : > "$argv_file"
  : > "$err_file"
  out="$(env HOME="$home_tmp" \
    XDG_CONFIG_HOME="$xdg_tmp" \
    PATH="$check_path" \
    AGENT_TASK_REPO="$repo_env" \
    AGENT_TASK_TEST_ARGV="$argv_file" \
    AGENT_TASK_HAS_TASK_LABEL="$has_task_label" \
    AGENT_TASK_HAS_AGENT_LABEL="$has_agent_label" \
    AGENT_TASK_AGENT="$agent_name" \
    AGENT_TASK_LABEL_LIST_HIDES="$label_list_hides" \
    AGENT_TASK_ISSUE_URL="$issue_url" \
    AGENT_TASK_GH_FAIL="$gh_fail" \
    /bin/bash "$check" "$@" 2>"$err_file")"
  status=$?
  err="$(cat "$err_file")"
}

clear_config() {
  rm -f "$config_file"
}

write_config() {
  mkdir -p "$(dirname "$config_file")"
  printf '%s\n' "$1" > "$config_file"
}

# Scan the checkout for denylist terms. This covers scripts as well as docs and
# avoids invoking git, so it works on a plain checkout. Prefer rg, fall back to
# grep -F -f when rg is missing or PUBLIC_TERMS_NO_RG is 1.
scan_public_terms() {
  local root="$1"
  local denylist="$2"
  local terms="$work_tmp/public-terms.txt"
  local file status found rg_status

  if [ ! -d "$root" ] || [ ! -f "$denylist" ]; then
    printf '%s: scan needs a directory and a denylist\n' "$script_name" >&2
    return 2
  fi

  awk '
    {
      line = $0
      sub(/^[ \t]+/, "", line)
      sub(/[ \t]+$/, "", line)
      if (line == "" || line ~ /^#/) next
      print line
    }' "$denylist" > "$terms"

  if [ ! -s "$terms" ]; then
    return 0
  fi

  if [ "${PUBLIC_TERMS_NO_RG:-0}" != 1 ] && command -v rg >/dev/null 2>&1; then
    rg_status=0
    found="$(rg --hidden -g '!.git/**' -g '!**/node_modules/**' \
      -F -f "$terms" --files-with-matches -- "$root" 2>"$work_tmp/rg.err")" ||
      rg_status=$?
    case "$rg_status" in
      0)
        printf '%s\n' "$found" >&2
        return 1
        ;;
      1)
        return 0
        ;;
      *)
        cat "$work_tmp/rg.err" >&2
        return 2
        ;;
    esac
  fi

  found=0
  while IFS= read -r file; do
    grep -IFq -f "$terms" -- "$file"
    status=$?
    case "$status" in
      0)
        printf '%s\n' "$file" >&2
        found=1
        ;;
      1) ;;
      *)
        printf '%s: cannot scan %s\n' "$script_name" "$file" >&2
        return 2
        ;;
    esac
  done < <(find "$root" -type f ! -path '*/.git/*' ! -path '*/node_modules/*')

  if [ "$found" -eq 1 ]; then
    return 1
  fi
  return 0
}

printf '== body validation ==\n'

run_check --agent agy --repo example-org/example-repo --title "Review change" \
  --file "$fixtures/missing-section.md"
expect_status "1: missing required section exits non-zero" 1
expect_err "1: missing section names Goal" "missing or empty section: Goal"
expect_argv_calls "1: missing section never calls gh" 0

run_check --agent agy --repo example-org/example-repo --title "Review change" \
  --file "$fixtures/placeholder.md"
expect_status "2: leftover placeholder exits non-zero" 1
expect_err "2: leftover placeholder is named" "leftover placeholder"
expect_argv_calls "2: leftover placeholder never calls gh" 0

run_check --agent agy --repo example-org/example-repo --title "Review change" \
  --file "$fixtures/multiline-comment-goal.md"
expect_status "1b: comment-only Goal exits non-zero" 1
expect_err "1b: comment-only Goal is named" "missing or empty section: Goal"
expect_argv_calls "1b: comment-only Goal never calls gh" 0

run_check --agent agy --repo example-org/example-repo --file "$fixtures/filled.md" --dry-run
expect_status "1c: a truly filled file still passes dry run" 0
expect_out "1c: filled dry run prints the Goal content" \
  "Summarize the change for the reviewer."
expect_argv_calls "1c: filled dry run calls no gh command" 0

printf '== agent validation ==\n'

run_check --repo example-org/example-repo --title "Review change" \
  --file "$fixtures/filled.md" --dry-run
expect_status "2b: missing --agent exits non-zero" 2
expect_err "2b: missing --agent names the flag" "--agent is required"
expect_argv_calls "2b: missing --agent never calls gh" 0

run_check --agent unknown --repo example-org/example-repo --title "Review change" \
  --file "$fixtures/filled.md" --dry-run
expect_status "2c: unknown agent exits non-zero" 2
expect_err "2c: unknown agent is named" "unknown agent: unknown"
expect_argv_calls "2c: unknown agent never calls gh" 0

run_check --agent Agy --repo example-org/example-repo --title "Review change" \
  --file "$fixtures/filled.md" --dry-run
expect_status "2d: mixed-case agent exits non-zero" 2
expect_err "2d: mixed-case agent is rejected" "unknown agent: Agy"
expect_argv_calls "2d: mixed-case agent never calls gh" 0

run_check --agent agy --repo example-org/example-repo --title "Review change" \
  --file "$fixtures/filled-opencode.md"
expect_status "2e: --file agent mismatch exits non-zero" 1
expect_err "2e: --file agent mismatch names the section value" '"opencode"'
expect_err "2e: --file agent mismatch names the flag value" '"agy"'
expect_argv_calls "2e: --file agent mismatch never calls gh" 0

run_check --agent opencode --repo example-org/example-repo --file \
  "$fixtures/filled-opencode.md" --model example-model --dry-run
expect_status "2f: --model keeps the file agent section matching" 0
expect_out "2f: --model rewrites the Agent and model line" "opencode / example-model"
expect_argv_calls "2f: --model dry run calls no gh command" 0

printf '== dry run ==\n'

run_check --agent agy --repo example-org/example-repo --file "$fixtures/filled.md" --dry-run
expect_status "3: dry run with a filled body exits 0" 0
expect_out "3: dry run prints the Agent and model heading" "## Agent and model"
expect_out "3: dry run prints the Goal heading" "## Goal"
expect_out "3: dry run prints the Context links heading" "## Context links"
expect_out "3: dry run prints the Scope In-Out heading" "## Scope In-Out"
expect_out "3: dry run prints the Steps or review focus heading" "## Steps or review focus"
expect_out "3: dry run prints the Acceptance criteria and output format heading" \
  "## Acceptance criteria and output format"
expect_out "3: dry run prints the Constraints heading" "## Constraints"
expect_out "3: dry run prints the Where to write the result heading" \
  "## Where to write the result"
expect_out "3: dry run prints the Agent and model content" "agy / example-model"
expect_out "3: dry run prints the Goal content" \
  "Summarize the change for the reviewer."
expect_out "3: dry run prints the Context links content" "example-org/example-repo"
expect_out "3: dry run prints the Scope In-Out content" "Review the listed files."
expect_out "3: dry run prints the Steps or review focus content" \
  "Read the pull request and list risks by severity."
expect_out "3: dry run prints the Acceptance criteria and output format content" \
  "VERDICT"
expect_out "3: dry run prints the Constraints content" "Do not merge"
expect_out "3: dry run prints the Where to write the result content" \
  "/tmp/agent-task-result.md"
expect_argv_calls "3: dry run calls no gh command" 0

printf '== create ==\n'

has_task_label=1
has_agent_label=1
agent_name=agy
run_check --agent agy --repo example-org/example-repo --title "Review change" \
  --file "$fixtures/filled.md"
expect_status "4: successful create exits 0" 0
expect_argv_has "4: issue create is called" "issue create"
expect_argv_has "4: issue create uses the task label" "--label agent-task"
expect_argv_has "4: issue create uses the agent label" "--label agent:agy"
expect_argv_has "4: issue create uses the title" "--title Review change"
expect_argv_has "4: issue create uses the repo" "--repo example-org/example-repo"
expect_argv_never "4: existing labels are not created again" "label create"

printf '== label handling ==\n'

has_task_label=0
has_agent_label=0
agent_name=agy
run_check --agent agy --repo example-org/example-repo --title "Review change" \
  --file "$fixtures/filled.md"
expect_status "5: missing labels without --create-label exits non-zero" 1
expect_err "5: missing labels name agent-task" "agent-task"
expect_err "5: missing labels name agent:agy" "agent:agy"
expect_err "5: missing labels suggest the flag" "--create-label"
expect_argv_never "5: missing labels never create an issue" "issue create"
expect_argv_never "5: missing labels never create a label" "label create"
expect_argv_calls "5: missing labels only look up labels" 2

has_task_label=0
has_agent_label=0
run_check --agent agy --repo example-org/example-repo --title "Review change" \
  --file "$fixtures/filled.md" --create-label
expect_status "6: missing labels with --create-label exits 0" 0
expect_argv_has "6: label create is called for agent-task" "label create agent-task"
expect_argv_has "6: label create is called for agent:agy" "label create agent:agy"
expect_argv_has "6: issue create follows" "issue create"
expect_argv_order "6: label create runs before issue create" "label create" "issue create"

has_task_label=1
has_agent_label=0
run_check --agent agy --repo example-org/example-repo --title "Review change" \
  --file "$fixtures/filled.md" --create-label
expect_status "6b: only the missing agent label is created" 0
expect_argv_has "6b: missing agent label is created" "label create agent:agy"
expect_argv_never "6b: existing task label is not created" "label create agent-task"
expect_argv_has "6b: issue create still runs" "issue create"

has_task_label=1
has_agent_label=1
label_list_hides=1
run_check --agent agy --repo example-org/example-repo --title "Review change" \
  --file "$fixtures/filled.md"
expect_status "6c: direct label lookup is not capped at 200" 0
expect_argv_has "6c: task label is looked up directly" \
  "api repos/example-org/example-repo/labels/agent-task"
expect_argv_has "6c: agent label lookup encodes the colon" \
  "api repos/example-org/example-repo/labels/agent%3Aagy"
expect_argv_never "6c: label lookup does not request a page limit" "--limit"
expect_argv_never "6c: found labels are not created again" "label create"
expect_argv_has "6c: issue create still runs" "issue create"
label_list_hides=0

printf '== handoff line and agy notice ==\n'

has_task_label=1
has_agent_label=1
agent_name=agy
run_check --agent agy --repo example-org/example-repo --title "Review change" \
  --file "$fixtures/filled.md"
expected_handoff="Read $issue_url and do exactly what it says; write the result to /tmp/agent-task-result.md"
expect_status "7: create for the handoff line exits 0" 0
expect_line "7: issue URL is printed" "$issue_url"
expect_line "7: handoff line is exact" "$expected_handoff"
expect_line "7: agy notice is printed" \
  "This agy task must be run manually by the maintainer; bots never launch agy."

agent_name=opencode
has_task_label=1
has_agent_label=1
run_check --agent opencode --repo example-org/example-repo --title "Review change" \
  --file "$fixtures/filled-opencode.md"
expect_status "7b: opencode create exits 0" 0
expect_line "7b: handoff line is printed for opencode" "$expected_handoff"
expect_no_out "7b: agy notice is not printed for opencode" \
  "This agy task must be run manually by the maintainer; bots never launch agy."
expect_argv_has "7b: opencode uses the agent label" "--label agent:opencode"
expect_argv_has "7b: opencode still uses the task label" "--label agent-task"

agent_name=agy
has_task_label=1
has_agent_label=1
run_check --agent agy --repo example-org/example-repo --title "Review change" \
  --file "$fixtures/multiline-comment-result.md"
expect_status "7c: multi-line comment before the result path exits 0" 0
expect_line "7c: multi-line comment keeps the real result path in the handoff line" \
  "$expected_handoff"
expect_no_out "7c: the handoff line never contains an HTML comment opener" "<!--"

printf '== repository selection ==\n'

has_task_label=1
has_agent_label=1
agent_name=agy
repo_env="env-org/env-repo"
write_config "# a comment

cfg-org/cfg-repo"
run_check --agent agy --repo flag-org/flag-repo --title "Review change" \
  --file "$fixtures/filled.md"
expect_status "8: --repo wins over env and config" 0
expect_argv_has "8: --repo value reaches gh" "--repo flag-org/flag-repo"
expect_argv_never "8: env repo is not used when --repo is set" "env-org/env-repo"
expect_argv_never "8: config repo is not used when --repo is set" "cfg-org/cfg-repo"

repo_env="env-org/env-repo"
run_check --agent agy --title "Review change" --file "$fixtures/filled.md"
expect_status "8: env repo is used when --repo is absent" 0
expect_argv_has "8: env repo reaches gh" "--repo env-org/env-repo"
expect_argv_never "8: config repo loses to env" "cfg-org/cfg-repo"

repo_env=""
run_check --agent agy --title "Review change" --file "$fixtures/filled.md"
expect_status "8: config repo is used when flag and env are absent" 0
expect_argv_has "8: config repo reaches gh" "--repo cfg-org/cfg-repo"

clear_config
run_check --agent agy --title "Review change" --file "$fixtures/filled.md"
expect_status "8: missing repo target exits 2" 2
expect_err "8: missing repo explains the sources" "no target repository"
expect_argv_calls "8: missing repo never calls gh" 0

run_check --agent agy --repo not-a-slug --title "Review change" --file "$fixtures/filled.md"
expect_status "8: a malformed repo exits 2" 2
expect_err "8: a malformed repo names the shape" "owner/repo"
expect_argv_calls "8: a malformed repo never calls gh" 0

printf '== usage and paths ==\n'

run_check --help
expect_status "9: --help exits 0" 0
expect_out "9: --help prints usage" "Usage: scripts/agent-task-issue.sh"
expect_argv_calls "9: --help never calls gh" 0

has_task_label=1
has_agent_label=1
agent_name=agy
run_check --agent agy --repo example-org/example-repo --file "$fixtures/filled.md"
expect_status "9: missing title exits 2" 2
expect_err "9: missing title names the flag" "--title is required"
expect_argv_calls "9: missing title never calls gh" 0

run_check --agent agy --repo example-org/example-repo --title "Review change" \
  --file "$fixtures/filled.md" --result-path /tmp/override-result.md
expect_status "9: result path override exits 0" 0
expect_line "9: result path override reaches the handoff line" \
  "Read $issue_url and do exactly what it says; write the result to /tmp/override-result.md"
expect_line "9: override still prints the agy notice" \
  "This agy task must be run manually by the maintainer; bots never launch agy."

run_check --agent agy --repo example-org/example-repo --title "Review change" \
  --file "$fixtures/filled.md" --result-path ""
expect_status "9: unresolved result path exits non-zero" 1
expect_err "9: unresolved result path fails closed" "could not resolve the result path"
expect_argv_calls "9: unresolved result path never calls gh" 0

run_check --repo example-org/example-repo --bogus
expect_status "9: unknown flag exits 2" 2
expect_err "9: unknown flag is named" "unknown argument: --bogus"
expect_argv_calls "9: unknown flag never calls gh" 0

run_check --agent goat --repo example-org/example-repo --dry-run \
  --goal "Review the change." \
  --context-links "Branch review-change." \
  --scope "In: review. Out: no code changes." \
  --steps "List risks by severity." \
  --acceptance "Start with Model: <name/id> and add a VERDICT." \
  --model example-model \
  --result "/tmp/flags-result.md"
expect_status "9: section flags assemble a dry-run body" 0
expect_out "9: section flags print the Agent and model line" "goat / example-model"
expect_out "9: section flags print the Constraints default" \
  "Do not merge; the maintainer merges."
expect_out "9: section flags print the result path" "/tmp/flags-result.md"
expect_argv_calls "9: section flags never call gh" 0

has_task_label=1
has_agent_label=1
agent_name=agy
run_check --agent=agy --repo=example-org/example-repo --title=Review \
  --file="$fixtures/filled.md"
expect_status "9: --flag=value forms exit 0" 0
expect_argv_has "9: --repo= reaches gh" "--repo example-org/example-repo"
expect_argv_has "9: --title= reaches gh" "--title Review"
expect_argv_has "9: --agent= reaches the agent label" "--label agent:agy"

printf '== missing gh ==\n'

make_tool_path "$work_tmp/no-gh" bash sh sed awk grep cat
check_path="$work_tmp/no-gh"
has_task_label=1
has_agent_label=1
agent_name=agy
run_check --agent agy --repo example-org/example-repo --title "Review change" \
  --file "$fixtures/filled.md"
expect_status "10: missing gh exits 2" 2
expect_err "10: missing gh is named" "gh is required"
expect_argv_calls "10: missing gh never calls gh" 0

run_check --agent agy --repo example-org/example-repo --file "$fixtures/filled.md" --dry-run
expect_status "10: dry run does not need gh" 0
expect_out "10: dry run without gh prints the body" "## Goal"
expect_argv_calls "10: dry run without gh calls no gh" 0
check_path="$fake_bin:$PATH"

printf '== public term check ==\n'

mkdir -p "$work_tmp/planted/docs" "$work_tmp/planted/scripts"
printf 'notes\nsecret-internal-hub\n' > "$work_tmp/planted/docs/note.md"
printf 'ExamplePersonName\n' > "$work_tmp/planted/scripts/run.sh"
if scan_public_terms "$work_tmp/planted" "$fixtures/denylist.txt" 2>/dev/null; then
  bad "11: a planted hit fails" "scan exited 0"
else
  ok "11: a planted hit fails"
fi

mkdir -p "$work_tmp/clean/docs" "$work_tmp/clean/scripts"
printf 'nothing to see here\n' > "$work_tmp/clean/docs/note.md"
printf 'echo clean\n' > "$work_tmp/clean/scripts/run.sh"
if scan_public_terms "$work_tmp/clean" "$fixtures/denylist.txt" 2>/dev/null; then
  ok "11: a clean tree passes"
else
  bad "11: a clean tree passes" "scan exited non-zero"
fi

mkdir -p "$work_tmp/planted-script/scripts"
printf 'ExamplePersonName\n' > "$work_tmp/planted-script/scripts/run.sh"
if scan_public_terms "$work_tmp/planted-script" "$fixtures/denylist.txt" 2>/dev/null; then
  bad "11: a hit in a script fails" "scan exited 0"
else
  ok "11: a hit in a script fails"
fi

PUBLIC_TERMS_NO_RG=1
if scan_public_terms "$work_tmp/planted" "$fixtures/denylist.txt" 2>/dev/null; then
  bad "11: grep fallback fails a planted hit" "scan exited 0"
else
  ok "11: grep fallback fails a planted hit"
fi
if scan_public_terms "$work_tmp/clean" "$fixtures/denylist.txt" 2>/dev/null; then
  ok "11: grep fallback passes a clean tree"
else
  bad "11: grep fallback passes a clean tree" "scan exited non-zero"
fi
unset PUBLIC_TERMS_NO_RG

clean_term="$(printf '%s' 'absent-public' '-term-93841')"
printf '%s\n' "$clean_term" > "$work_tmp/clean-denylist.txt"
if scan_public_terms "$repo_root" "$work_tmp/clean-denylist.txt" 2>/dev/null; then
  ok "11: the tracked tree passes a clean denylist"
else
  bad "11: the tracked tree passes a clean denylist" "scan found a term"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -ne 0 ]; then
  exit 1
fi
exit 0
