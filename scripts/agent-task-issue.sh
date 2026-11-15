#!/usr/bin/env bash
# Prepare a coding-agent task as a GitHub Issue. A bot renders and validates
# the issue body, then prints the handoff line. The issue is the single task
# spec, regardless of which allowed agent later runs it. This script never
# launches agy.
#
# Creating an issue is the only state-changing path, other than the optional
# --create-label flag. The agent-task and agent:<name> labels must already
# exist unless --create-label is passed.
set -euo pipefail

script="agent-task-issue"

# Lowercase allowlist. Unknown or mixed-case values fail closed.
allowed_agents="agy opencode goat cursor"

usage() {
  cat <<'USAGE'
Usage: scripts/agent-task-issue.sh --agent NAME --repo OWNER/REPO --title TEXT --file PATH
       scripts/agent-task-issue.sh --agent NAME --title TEXT --goal TEXT --context-links TEXT
                                --scope TEXT --steps TEXT --acceptance TEXT
                                [--model TEXT] [--constraints TEXT] --result PATH

Prepare a coding-agent task as a GitHub Issue. The issue is the single task
spec before any allowed agent works on it. For agy, the maintainer runs the
issue by hand; bots never launch agy.

Options:
  --agent NAME         Required. One of: agy, opencode, goat, cursor.
  --model TEXT         Model name used in the Agent and model section when not
                       using --file. Combined as "NAME / TEXT".
  --file PATH          Read the issue body from a filled copy of
                       templates/agent-task-issue.md.
  --goal TEXT          Goal section when not using --file.
  --context-links TEXT Context links section when not using --file.
  --scope TEXT         Scope In-Out section when not using --file.
  --steps TEXT         Steps or review focus section when not using --file.
  --acceptance TEXT    Acceptance criteria and output format section when not
                       using --file.
  --constraints TEXT   Constraints section when not using --file. Defaults to
                       the standard rules when omitted.
  --result PATH        Where to write the result section when not using --file.
  --title TEXT         Issue title. Required to create an issue. Optional with
                       --dry-run.
  --repo OWNER/REPO    Target repository. Defaults to AGENT_TASK_REPO, then to
                       ${XDG_CONFIG_HOME:-$HOME/.config}/agent-ops-kit/agent-task-repo.
  --result-path PATH   Override the path printed in the handoff line. Defaults
                       to the first non-empty, non-comment line of the Where to
                       write the result section.
  --dry-run            Print the rendered body and call no gh command.
  --create-label       Create any missing agent-task or agent:<name> label.
  -h, --help           Print this help and exit.

The body must use these headings in order: Agent and model, Goal, Context
links, Scope In-Out, Steps or review focus, Acceptance criteria and output
format, Constraints, and Where to write the result. Every section must be
filled and no FILL_ME marker may remain.

Exit codes: 0 success, 1 invalid body or missing label, 2 usage error, missing
gh, or a gh failure.
USAGE
}

usage_error() {
  printf '%s: %s\n' "$script" "$1" >&2
  exit 2
}

agent_allowed() {
  local name="$1"
  local item

  for item in $allowed_agents; do
    if [ "$item" = "$name" ]; then
      return 0
    fi
  done
  return 1
}

file_path=""
have_file=0
title_arg=""
have_title=0
repo_arg=""
have_repo=0
result_override=""
have_result_override=0
dry_run=0
create_label=0
agent_arg=""
have_agent=0
model_arg=""
have_model=0

goal_arg=""
have_goal=0
context_arg=""
have_context=0
scope_arg=""
have_scope=0
steps_arg=""
have_steps=0
acceptance_arg=""
have_acceptance=0
constraints_arg=""
have_constraints=0
result_arg=""
have_result=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --agent)
      [ "$#" -ge 2 ] || usage_error "--agent needs a name"
      agent_arg="$2"
      have_agent=1
      shift 2
      ;;
    --agent=*)
      agent_arg="${1#--agent=}"
      have_agent=1
      shift
      ;;
    --model)
      [ "$#" -ge 2 ] || usage_error "--model needs text"
      model_arg="$2"
      have_model=1
      shift 2
      ;;
    --model=*)
      model_arg="${1#--model=}"
      have_model=1
      shift
      ;;
    --file)
      [ "$#" -ge 2 ] || usage_error "--file needs a path"
      file_path="$2"
      have_file=1
      shift 2
      ;;
    --file=*)
      file_path="${1#--file=}"
      have_file=1
      shift
      ;;
    --goal)
      [ "$#" -ge 2 ] || usage_error "--goal needs text"
      goal_arg="$2"
      have_goal=1
      shift 2
      ;;
    --goal=*)
      goal_arg="${1#--goal=}"
      have_goal=1
      shift
      ;;
    --context-links)
      [ "$#" -ge 2 ] || usage_error "--context-links needs text"
      context_arg="$2"
      have_context=1
      shift 2
      ;;
    --context-links=*)
      context_arg="${1#--context-links=}"
      have_context=1
      shift
      ;;
    --scope)
      [ "$#" -ge 2 ] || usage_error "--scope needs text"
      scope_arg="$2"
      have_scope=1
      shift 2
      ;;
    --scope=*)
      scope_arg="${1#--scope=}"
      have_scope=1
      shift
      ;;
    --steps)
      [ "$#" -ge 2 ] || usage_error "--steps needs text"
      steps_arg="$2"
      have_steps=1
      shift 2
      ;;
    --steps=*)
      steps_arg="${1#--steps=}"
      have_steps=1
      shift
      ;;
    --acceptance)
      [ "$#" -ge 2 ] || usage_error "--acceptance needs text"
      acceptance_arg="$2"
      have_acceptance=1
      shift 2
      ;;
    --acceptance=*)
      acceptance_arg="${1#--acceptance=}"
      have_acceptance=1
      shift
      ;;
    --constraints)
      [ "$#" -ge 2 ] || usage_error "--constraints needs text"
      constraints_arg="$2"
      have_constraints=1
      shift 2
      ;;
    --constraints=*)
      constraints_arg="${1#--constraints=}"
      have_constraints=1
      shift
      ;;
    --result)
      [ "$#" -ge 2 ] || usage_error "--result needs a path"
      result_arg="$2"
      have_result=1
      shift 2
      ;;
    --result=*)
      result_arg="${1#--result=}"
      have_result=1
      shift
      ;;
    --title)
      [ "$#" -ge 2 ] || usage_error "--title needs text"
      title_arg="$2"
      have_title=1
      shift 2
      ;;
    --title=*)
      title_arg="${1#--title=}"
      have_title=1
      shift
      ;;
    --repo)
      [ "$#" -ge 2 ] || usage_error "--repo needs an owner/repo value"
      repo_arg="$2"
      have_repo=1
      shift 2
      ;;
    --repo=*)
      repo_arg="${1#--repo=}"
      have_repo=1
      shift
      ;;
    --result-path)
      [ "$#" -ge 2 ] || usage_error "--result-path needs a path"
      result_override="$2"
      have_result_override=1
      shift 2
      ;;
    --result-path=*)
      result_override="${1#--result-path=}"
      have_result_override=1
      shift
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    --create-label)
      create_label=1
      shift
      ;;
    *)
      usage_error "unknown argument: $1"
      ;;
  esac
done

if [ "$have_agent" -eq 0 ] || [ -z "$agent_arg" ]; then
  usage_error "--agent is required and must be one of: $allowed_agents"
fi
if ! agent_allowed "$agent_arg"; then
  usage_error "unknown agent: $agent_arg (allowed: $allowed_agents)"
fi
agent="$agent_arg"
agent_label="agent:$agent"

if [ "$have_repo" -eq 1 ] && [ -z "$repo_arg" ]; then
  usage_error "--repo needs an owner/repo value"
fi

repo=""
if [ "$have_repo" -eq 1 ]; then
  repo="$repo_arg"
elif [ -n "${AGENT_TASK_REPO:-}" ]; then
  repo="$AGENT_TASK_REPO"
else
  repo_config="${XDG_CONFIG_HOME:-${HOME:-}/.config}/agent-ops-kit/agent-task-repo"
  if [ -f "$repo_config" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line#"${line%%[![:space:]]*}"}"
      line="${line%"${line##*[![:space:]]}"}"
      case "$line" in
        ''|'#'*) continue ;;
      esac
      repo="$line"
      break
    done < "$repo_config"
  fi
fi

if [ -z "$repo" ]; then
  usage_error "no target repository; pass --repo OWNER/REPO, set AGENT_TASK_REPO, or write one owner/repo line to ${XDG_CONFIG_HOME:-${HOME:-}/.config}/agent-ops-kit/agent-task-repo"
fi

if ! [[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
  usage_error "target repository must be owner/repo: $repo"
fi

if [ "$have_title" -eq 1 ] && [ -z "$title_arg" ] && [ "$dry_run" -eq 0 ]; then
  usage_error "--title needs text"
fi

if [ "$have_file" -eq 1 ]; then
  if [ -z "$file_path" ] || [ ! -f "$file_path" ] || [ ! -r "$file_path" ]; then
    usage_error "cannot read --file: ${file_path:-empty}"
  fi
fi

# Trim leading and trailing blank lines. Inner blank lines and indentation are
# kept so the body keeps its shape.
trim_text() {
  printf '%s\n' "$1" | awk '
    { lines[NR] = $0 }
    END {
      first = 1
      last = NR
      while (first <= last && lines[first] ~ /^[ \t]*$/) first++
      while (last >= first && lines[last] ~ /^[ \t]*$/) last--
      for (i = first; i <= last; i++) print lines[i]
    }'
}

# Strip single-line HTML comments before the emptiness check.
section_has_content() {
  local text="$1"
  local stripped

  stripped="$(printf '%s\n' "$text" | sed -e 's/<!--[^>]*-->//g')"
  printf '%s' "$stripped" | grep -q '[^[:space:]]'
}

has_placeholder() {
  case "$1" in
    *FILL_ME*) return 0 ;;
    *) return 1 ;;
  esac
}

validate_section() {
  local name="$1"
  local text="$2"

  if ! section_has_content "$text"; then
    printf '%s: missing or empty section: %s\n' "$script" "$name" >&2
    exit 1
  fi
  if has_placeholder "$text"; then
    printf '%s: leftover placeholder in section: %s\n' "$script" "$name" >&2
    exit 1
  fi
}

# Parse a filled template into f_* variables by the exact ## headings.
parse_sections() {
  local path="$1"
  local line current=""

  f_agent=""
  f_goal=""
  f_context=""
  f_scope=""
  f_steps=""
  f_acceptance=""
  f_constraints=""
  f_result=""

  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '## Agent and model') current=agent ;;
      '## Goal') current=goal ;;
      '## Context links') current=context ;;
      '## Scope In-Out') current=scope ;;
      '## Steps or review focus') current=steps ;;
      '## Acceptance criteria and output format') current=acceptance ;;
      '## Constraints') current=constraints ;;
      '## Where to write the result') current=result ;;
      '## '*) current="" ;;
      *)
        case "$current" in
          agent) f_agent="$f_agent$line"$'\n' ;;
          goal) f_goal="$f_goal$line"$'\n' ;;
          context) f_context="$f_context$line"$'\n' ;;
          scope) f_scope="$f_scope$line"$'\n' ;;
          steps) f_steps="$f_steps$line"$'\n' ;;
          acceptance) f_acceptance="$f_acceptance$line"$'\n' ;;
          constraints) f_constraints="$f_constraints$line"$'\n' ;;
          result) f_result="$f_result$line"$'\n' ;;
        esac
        ;;
    esac
  done < "$path"
}

agent_section=""
goal=""
context=""
scope=""
steps=""
acceptance=""
constraints=""
result=""

if [ "$have_file" -eq 1 ]; then
  if has_placeholder "$(cat "$file_path")"; then
    printf '%s: leftover placeholder in --file: %s\n' "$script" "$file_path" >&2
    exit 1
  fi
  parse_sections "$file_path"
  if [ "$have_model" -eq 1 ]; then
    if [ -z "$model_arg" ]; then
      usage_error "--model needs text"
    fi
    agent_section="$agent / $model_arg"
  else
    agent_section="$f_agent"
  fi
  if [ "$have_goal" -eq 0 ]; then goal="$f_goal"; else goal="$goal_arg"; fi
  if [ "$have_context" -eq 0 ]; then context="$f_context"; else context="$context_arg"; fi
  if [ "$have_scope" -eq 0 ]; then scope="$f_scope"; else scope="$scope_arg"; fi
  if [ "$have_steps" -eq 0 ]; then steps="$f_steps"; else steps="$steps_arg"; fi
  if [ "$have_acceptance" -eq 0 ]; then acceptance="$f_acceptance"; else acceptance="$acceptance_arg"; fi
  if [ "$have_constraints" -eq 0 ]; then constraints="$f_constraints"; else constraints="$constraints_arg"; fi
  if [ "$have_result" -eq 0 ]; then result="$f_result"; else result="$result_arg"; fi
else
  if [ "$have_model" -eq 1 ]; then
    if [ -z "$model_arg" ]; then
      usage_error "--model needs text"
    fi
    agent_section="$agent / $model_arg"
  else
    agent_section="$agent"
  fi
  goal="$goal_arg"
  context="$context_arg"
  scope="$scope_arg"
  steps="$steps_arg"
  acceptance="$acceptance_arg"
  if [ "$have_constraints" -eq 1 ]; then
    constraints="$constraints_arg"
  else
    constraints='- Do not merge; the maintainer merges.
- Do not change secrets or credentials.
- Work in a separate worktree.'
  fi
  result="$result_arg"
fi

agent_section="$(trim_text "$agent_section")"
goal="$(trim_text "$goal")"
context="$(trim_text "$context")"
scope="$(trim_text "$scope")"
steps="$(trim_text "$steps")"
acceptance="$(trim_text "$acceptance")"
constraints="$(trim_text "$constraints")"
result="$(trim_text "$result")"

validate_section "Agent and model" "$agent_section"
validate_section "Goal" "$goal"
validate_section "Context links" "$context"
validate_section "Scope In-Out" "$scope"
validate_section "Steps or review focus" "$steps"
validate_section "Acceptance criteria and output format" "$acceptance"
validate_section "Constraints" "$constraints"
validate_section "Where to write the result" "$result"

body="$(printf '## Agent and model\n\n%s\n\n## Goal\n\n%s\n\n## Context links\n\n%s\n\n## Scope In-Out\n\n%s\n\n## Steps or review focus\n\n%s\n\n## Acceptance criteria and output format\n\n%s\n\n## Constraints\n\n%s\n\n## Where to write the result\n\n%s\n' \
  "$agent_section" "$goal" "$context" "$scope" "$steps" "$acceptance" "$constraints" "$result")"

if has_placeholder "$body"; then
  printf '%s: leftover placeholder in the rendered body\n' "$script" >&2
  exit 1
fi

if [ "$dry_run" -eq 1 ]; then
  printf '%s\n' "$body"
  exit 0
fi

if [ "$have_title" -eq 0 ] || [ -z "$title_arg" ]; then
  usage_error "--title is required to create an issue"
fi

if has_placeholder "$title_arg"; then
  printf '%s: leftover placeholder in --title\n' "$script" >&2
  exit 1
fi

# Resolve the result path before any gh call. The first non-empty, non-comment
# line of the section is used unless --result-path overrides it.
resolve_result_path() {
  printf '%s\n' "$1" | sed -e 's/<!--[^>]*-->//g' | awk '
    {
      line = $0
      sub(/^[ \t]+/, "", line)
      sub(/[ \t]+$/, "", line)
      if (line == "" || line ~ /^#/) next
      print line
      exit
    }'
}

if [ "$have_result_override" -eq 1 ]; then
  result_path="$(printf '%s\n' "$result_override" | awk '
    {
      line = $0
      sub(/^[ \t]+/, "", line)
      sub(/[ \t]+$/, "", line)
      if (line == "") next
      print line
      exit
    }')"
else
  result_path="$(resolve_result_path "$result")"
fi

if [ -z "$result_path" ]; then
  printf '%s: could not resolve the result path; pass --result-path or fill the Where to write the result section\n' "$script" >&2
  exit 1
fi
if has_placeholder "$result_path"; then
  printf '%s: leftover placeholder in the result path\n' "$script" >&2
  exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
  usage_error "gh is required to create an issue"
fi

if ! labels="$(gh label list --repo "$repo" --limit 200 --json name)"; then
  printf '%s: gh label list failed for %s\n' "$script" "$repo" >&2
  exit 2
fi

label_exists() {
  local name="$1"
  printf '%s' "$labels" | grep -Eq "\"name\"[[:space:]]*:[[:space:]]*\"$name\""
}

have_task_label=0
have_agent_label=0
if label_exists "agent-task"; then
  have_task_label=1
fi
if label_exists "$agent_label"; then
  have_agent_label=1
fi

if [ "$have_task_label" -eq 0 ] || [ "$have_agent_label" -eq 0 ]; then
  if [ "$create_label" -eq 0 ]; then
    printf '%s: missing label in %s:' "$script" "$repo" >&2
    if [ "$have_task_label" -eq 0 ]; then
      printf ' agent-task' >&2
    fi
    if [ "$have_agent_label" -eq 0 ]; then
      printf ' %s' "$agent_label" >&2
    fi
    printf '; pass --create-label to create missing labels\n' >&2
    exit 1
  fi
  if [ "$have_task_label" -eq 0 ]; then
    if ! gh label create agent-task --repo "$repo" --description "Coding-agent task" >/dev/null; then
      printf '%s: gh label create failed for agent-task in %s\n' "$script" "$repo" >&2
      exit 2
    fi
  fi
  if [ "$have_agent_label" -eq 0 ]; then
    if ! gh label create "$agent_label" --repo "$repo" --description "Assigned coding agent: $agent" >/dev/null; then
      printf '%s: gh label create failed for %s in %s\n' "$script" "$agent_label" "$repo" >&2
      exit 2
    fi
  fi
fi

if ! issue_url="$(gh issue create --repo "$repo" --title "$title_arg" --body "$body" --label agent-task --label "$agent_label")"; then
  printf '%s: gh issue create failed for %s\n' "$script" "$repo" >&2
  exit 2
fi

issue_url="$(printf '%s\n' "$issue_url" | awk 'NF { print; exit }')"
if [ -z "$issue_url" ]; then
  printf '%s: gh issue create returned no issue URL\n' "$script" >&2
  exit 2
fi

printf '%s\n' "$issue_url"
printf 'Read %s and do exactly what it says; write the result to %s\n' "$issue_url" "$result_path"
if [ "$agent" = "agy" ]; then
  printf 'This agy task must be run manually by the maintainer; bots never launch agy.\n'
fi
exit 0
