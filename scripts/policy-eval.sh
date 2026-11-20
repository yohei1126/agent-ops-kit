#!/usr/bin/env bash
# Evaluate one decision against the Cedar-like policy data in policy/rules.
# This is the command-line wrapper around scripts/lib/policy-eval.sh.
set -euo pipefail

self_dir="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/policy-eval.sh
. "$self_dir/lib/policy-eval.sh"

script="policy-eval"

usage() {
  cat <<'USAGE'
usage: scripts/policy-eval.sh --action <action> --resource <path> [--attr key=value]...
       scripts/policy-eval.sh --print-mcr-meta [--policy <file>]
       scripts/policy-eval.sh --list-forbids --action <action> [--policy <file>]
       scripts/policy-eval.sh -h|--help

Evaluate one action and resource against the policy data in policy/rules. The
default policy file is resolved from this script's directory, not from the
current work tree; POLICY_RULES overrides it when --policy is omitted.

Rules are evaluated in file order. The default decision is deny. A matching
forbid wins over any matching permit: the first matching forbid decides, else
the first matching permit, else default.deny.

Stdout for a decision is one line, either:
  ALLOW <rule-id>
  DENY <rule-id>

Options:
  --action <action>   Action to check. Required for a decision and for
                      --list-forbids.
  --resource <path>   Resource path to check. Required for a decision.
  --attr key=value    Attribute for a when condition. Repeatable. The value is
                      everything after the first =.
  --policy <file>     Policy file to load. Default: policy/rules next to this
                      script, or POLICY_RULES.
  --print-mcr-meta    Print the line cap, deny list, and allow list used by
                      model-check-required.
  --list-forbids      Print id<TAB>when_ere<TAB>label for every forbid rule
                      with the given action.
  -h, --help          Print this help and exit.

Exit codes: 0 ALLOW or meta/list output, 1 DENY, 2 usage error, 3 policy file
missing or invalid.
USAGE
}

usage_error() {
  printf '%s: %s\n' "$script" "$1" >&2
  exit 2
}

action=""
resource=""
policy=""
have_action=0
have_resource=0
have_policy=0
mode="decide"
attr_count=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --action)
      [ "$#" -ge 2 ] || usage_error "--action needs a value"
      [ -n "$2" ] || usage_error "--action needs a non-empty value"
      action="$2"
      have_action=1
      shift 2
      ;;
    --action=*)
      action="${1#--action=}"
      [ -n "$action" ] || usage_error "--action needs a non-empty value"
      have_action=1
      shift
      ;;
    --resource)
      [ "$#" -ge 2 ] || usage_error "--resource needs a value"
      [ -n "$2" ] || usage_error "--resource needs a non-empty value"
      resource="$2"
      have_resource=1
      shift 2
      ;;
    --resource=*)
      resource="${1#--resource=}"
      [ -n "$resource" ] || usage_error "--resource needs a non-empty value"
      have_resource=1
      shift
      ;;
    --attr)
      [ "$#" -ge 2 ] || usage_error "--attr needs key=value"
      case "$2" in
        *=*) ;;
        *) usage_error "--attr needs key=value: $2" ;;
      esac
      policy_eval_attr_list[attr_count]="$2"
      attr_count=$((attr_count + 1))
      shift 2
      ;;
    --attr=*)
      case "${1#--attr=}" in
        *=*) ;;
        *) usage_error "--attr needs key=value: ${1#--attr=}" ;;
      esac
      policy_eval_attr_list[attr_count]="${1#--attr=}"
      attr_count=$((attr_count + 1))
      shift
      ;;
    --policy)
      [ "$#" -ge 2 ] || usage_error "--policy needs a value"
      [ -n "$2" ] || usage_error "--policy needs a non-empty value"
      policy="$2"
      have_policy=1
      shift 2
      ;;
    --policy=*)
      policy="${1#--policy=}"
      [ -n "$policy" ] || usage_error "--policy needs a non-empty value"
      have_policy=1
      shift
      ;;
    --print-mcr-meta)
      mode="meta"
      shift
      ;;
    --list-forbids)
      mode="list"
      shift
      ;;
    *)
      usage_error "unknown argument: $1"
      ;;
  esac
done

if [ "$have_policy" = 1 ]; then
  policy_eval_load "$policy" || exit 3
fi

if [ "$mode" = meta ]; then
  policy_eval_print_mcr_meta || exit 3
  exit 0
fi

if [ "$mode" = list ]; then
  [ "$have_action" = 1 ] || usage_error "--action is required"
  policy_eval_list_forbids "$action" || exit 3
  exit 0
fi

[ "$have_action" = 1 ] || usage_error "--action is required"
[ "$have_resource" = 1 ] || usage_error "--resource is required"

policy_eval_attrs=""
policy_eval_ensure_loaded || exit 3
status=0
if policy_eval_decide "$action" "$resource"; then
  status=0
else
  status=$?
fi
printf '%s %s\n' "$policy_eval_effect" "$policy_eval_rule"
exit "$status"
