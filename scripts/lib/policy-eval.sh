#!/usr/bin/env bash
# Cedar-like policy evaluator for the dev loop gate.
# Sourced by the gate libraries and by scripts/policy-eval.sh. It reads
# policy/rules as data; it does not run the Cedar engine.
set -u

policy_eval_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
policy_eval_default_file="$policy_eval_lib_dir/../../policy/rules"

policy_eval_ids=()
policy_eval_effects=()
policy_eval_principals=()
policy_eval_actions=()
policy_eval_resources=()
policy_eval_matches=()
policy_eval_cases=()
policy_eval_when_conds=()
policy_eval_when_counts=()
policy_eval_when_eres=()
policy_eval_labels=()

policy_eval_loaded=0
policy_eval_attr_list=()
policy_eval_attrs=""
policy_eval_attr_value=""
# Callers that source this library read these after a decision or meta dump.
# shellcheck disable=SC2034
policy_eval_effect=""
# shellcheck disable=SC2034
policy_eval_rule=""
# shellcheck disable=SC2034
policy_eval_mcr_line_cap=""
# shellcheck disable=SC2034
policy_eval_mcr_deny_patterns=""
# shellcheck disable=SC2034
policy_eval_mcr_allow_patterns=""

policy_eval_fail() {
  printf 'policy-eval: %s\n' "$1" >&2
  return 1
}

policy_eval_append_rule() {
  local id="$1" effect="$2" principal="$3" action="$4" resource="$5"
  local rmatch="$6" rcase="$7" whens="$8" ere="$9" label="${10}"
  local i count cond

  if [ -z "$id" ]; then
    policy_eval_fail "policy record is missing id"
    return 1
  fi
  if [ -z "$effect" ]; then
    policy_eval_fail "policy rule $id is missing effect"
    return 1
  fi
  if [ -z "$action" ]; then
    policy_eval_fail "policy rule $id is missing action"
    return 1
  fi
  case "$effect" in
    permit | forbid) ;;
    *)
      policy_eval_fail "policy rule $id has an invalid effect: $effect"
      return 1
      ;;
  esac
  i=0
  while [ "$i" -lt "${#policy_eval_ids[@]}" ]; do
    if [ "${policy_eval_ids[$i]}" = "$id" ]; then
      policy_eval_fail "duplicate policy rule id: $id"
      return 1
    fi
    i=$((i + 1))
  done
  count=0
  if [ -n "$whens" ]; then
    while IFS= read -r cond; do
      [ -n "$cond" ] || continue
      count=$((count + 1))
    done <<EOF
$whens
EOF
  fi
  i=${#policy_eval_ids[@]}
  policy_eval_ids[i]="$id"
  policy_eval_effects[i]="$effect"
  policy_eval_principals[i]="$principal"
  policy_eval_actions[i]="$action"
  policy_eval_resources[i]="$resource"
  policy_eval_matches[i]="$rmatch"
  policy_eval_cases[i]="$rcase"
  policy_eval_when_conds[i]="$whens"
  policy_eval_when_counts[i]="$count"
  policy_eval_when_eres[i]="$ere"
  policy_eval_labels[i]="$label"
}

policy_eval_load() {
  local file="${1:-}"
  local line key value lineno=0
  local cur_id="" cur_effect="" cur_principal="" cur_action="" cur_resource=""
  local cur_match="" cur_case="" cur_ere="" cur_label="" cur_whens=""
  local have=0

  if [ -z "$file" ]; then
    if [ -n "${POLICY_RULES:-}" ]; then
      file="$POLICY_RULES"
    else
      file="$policy_eval_default_file"
    fi
  fi
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    policy_eval_fail "cannot read policy file: $file"
    return 1
  fi

  policy_eval_ids=()
  policy_eval_effects=()
  policy_eval_principals=()
  policy_eval_actions=()
  policy_eval_resources=()
  policy_eval_matches=()
  policy_eval_cases=()
  policy_eval_when_conds=()
  policy_eval_when_counts=()
  policy_eval_when_eres=()
  policy_eval_labels=()
  policy_eval_loaded=1

  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    case "$line" in
      '')
        if [ "$have" = 1 ]; then
          policy_eval_append_rule "$cur_id" "$cur_effect" "$cur_principal" \
            "$cur_action" "$cur_resource" "$cur_match" "$cur_case" \
            "$cur_whens" "$cur_ere" "$cur_label" || return 1
          cur_id=""; cur_effect=""; cur_principal=""; cur_action=""
          cur_resource=""; cur_match=""; cur_case=""; cur_ere=""
          cur_label=""; cur_whens=""
          have=0
        fi
        continue
        ;;
      '#'*)
        continue
        ;;
    esac
    case "$line" in
      *=*) ;;
      *)
        policy_eval_fail "$file:$lineno: expected key=value"
        return 1
        ;;
    esac
    key="${line%%=*}"
    value="${line#*=}"
    case "$key" in
      id) cur_id="$value" ;;
      effect) cur_effect="$value" ;;
      principal) cur_principal="$value" ;;
      action) cur_action="$value" ;;
      resource) cur_resource="$value" ;;
      match) cur_match="$value" ;;
      "case") cur_case="$value" ;;
      when)
        if [ -z "$cur_whens" ]; then
          cur_whens="$value"
        else
          cur_whens="$cur_whens
$value"
        fi
        ;;
      when_ere) cur_ere="$value" ;;
      label) cur_label="$value" ;;
      *)
        policy_eval_fail "$file:$lineno: unknown key: $key"
        return 1
        ;;
    esac
    have=1
  done < "$file"

  if [ "$have" = 1 ]; then
    policy_eval_append_rule "$cur_id" "$cur_effect" "$cur_principal" \
      "$cur_action" "$cur_resource" "$cur_match" "$cur_case" \
      "$cur_whens" "$cur_ere" "$cur_label" || return 1
  fi
}

policy_eval_ensure_loaded() {
  if [ "${policy_eval_loaded:-0}" = 1 ]; then
    return 0
  fi
  policy_eval_load "${POLICY_RULES:-$policy_eval_default_file}" || return 1
}

policy_eval_attr_get() {
  local want="$1" entry rest

  policy_eval_attr_value=""
  if [ "${#policy_eval_attr_list[@]}" -gt 0 ]; then
    for entry in "${policy_eval_attr_list[@]}"; do
      case "$entry" in
        "$want"=*)
          policy_eval_attr_value="${entry#*=}"
          return 0
          ;;
      esac
    done
    return 1
  fi
  case " ${policy_eval_attrs:-} " in
    *" $want="*)
      rest="${policy_eval_attrs#*"$want="}"
      case "$want" in
        text) policy_eval_attr_value="$rest" ;;
        *) policy_eval_attr_value="${rest%% *}" ;;
      esac
      return 0
      ;;
  esac
  return 1
}

policy_eval_cond_holds() {
  local cond="$1"
  local key op val pre tmp cand pos bestpos=-1

  for cand in '>=' '<=' '!=' '>' '<' '='; do
    case "$cond" in
      *"$cand"*) ;;
      *) continue ;;
    esac
    pre="${cond%%"$cand"*}"
    pos=${#pre}
    if [ "$bestpos" -lt 0 ] || [ "$pos" -lt "$bestpos" ]; then
      bestpos=$pos
      op="$cand"
    fi
  done
  [ -n "$op" ] || return 1
  key="${cond%%"$op"*}"
  [ -n "$key" ] || return 1
  tmp="${cond#"$key"}"
  val="${tmp#"$op"}"
  policy_eval_attr_get "$key" || return 1
  case "$op" in
    '=') [ "$policy_eval_attr_value" = "$val" ] ;;
    '!=') [ "$policy_eval_attr_value" != "$val" ] ;;
    '>' | '>=' | '<' | '<=')
      case "$policy_eval_attr_value" in
        '' | *[!0-9]*) return 1 ;;
      esac
      case "$val" in
        '' | *[!0-9]*) return 1 ;;
      esac
      case "$op" in
        '>') [ "$policy_eval_attr_value" -gt "$val" ] ;;
        '>=') [ "$policy_eval_attr_value" -ge "$val" ] ;;
        '<') [ "$policy_eval_attr_value" -lt "$val" ] ;;
        '<=') [ "$policy_eval_attr_value" -le "$val" ] ;;
      esac
      ;;
    *) return 1 ;;
  esac
}

policy_eval_rule_matches() {
  local idx="$1" action="$2" resource="$3"
  local principal rmatch rcase cur pat cond ere

  [ "${policy_eval_actions[$idx]}" = "$action" ] || return 1
  principal="${policy_eval_principals[$idx]}"
  if [ -n "$principal" ] && [ "$principal" != "*" ]; then
    return 1
  fi
  rmatch="${policy_eval_matches[$idx]}"
  [ -n "$rmatch" ] || rmatch=glob
  [ "$rmatch" = glob ] || return 1
  rcase="${policy_eval_cases[$idx]}"
  [ -n "$rcase" ] || rcase=sensitive
  case "$rcase" in
    lower) cur="$(printf '%s' "$resource" | LC_ALL=C tr '[:upper:]' '[:lower:]')" ;;
    *) cur="$resource" ;;
  esac
  pat="${policy_eval_resources[$idx]}"
  set -f
  # shellcheck disable=SC2254
  case "$cur" in
    $pat) ;;
    *) set +f; return 1 ;;
  esac
  set +f

  if [ "${policy_eval_when_counts[$idx]}" -gt 0 ]; then
    while IFS= read -r cond; do
      [ -n "$cond" ] || continue
      policy_eval_cond_holds "$cond" || return 1
    done <<EOF
${policy_eval_when_conds[$idx]}
EOF
  fi

  ere="${policy_eval_when_eres[$idx]}"
  if [ -n "$ere" ]; then
    policy_eval_attr_get text || return 1
    printf '%s\n' "$policy_eval_attr_value" | LC_ALL=C grep -Eq -- "$ere" || return 1
  fi
  return 0
}

policy_eval_decide() {
  local action="$1" resource="$2" i first_forbid first_permit

  policy_eval_ensure_loaded || return 1
  first_forbid=""
  first_permit=""
  i=0
  while [ "$i" -lt "${#policy_eval_ids[@]}" ]; do
    if policy_eval_rule_matches "$i" "$action" "$resource"; then
      case "${policy_eval_effects[$i]}" in
        forbid)
          if [ -z "$first_forbid" ]; then
            first_forbid="${policy_eval_ids[$i]}"
          fi
          ;;
        permit)
          if [ -z "$first_permit" ]; then
            first_permit="${policy_eval_ids[$i]}"
          fi
          ;;
      esac
      if [ -n "$first_forbid" ]; then
        break
      fi
    fi
    i=$((i + 1))
  done

  if [ -n "$first_forbid" ]; then
    # shellcheck disable=SC2034
    policy_eval_effect=DENY
    # shellcheck disable=SC2034
    policy_eval_rule="$first_forbid"
    return 1
  fi
  if [ -n "$first_permit" ]; then
    # shellcheck disable=SC2034
    policy_eval_effect=ALLOW
    # shellcheck disable=SC2034
    policy_eval_rule="$first_permit"
    return 0
  fi
  # shellcheck disable=SC2034
  policy_eval_effect=DENY
  # shellcheck disable=SC2034
  policy_eval_rule=default.deny
  return 1
}

policy_eval_print_mcr_meta() {
  local i id cond cap deny allow

  policy_eval_ensure_loaded || return 1
  cap=""
  deny=""
  allow=""
  i=0
  while [ "$i" -lt "${#policy_eval_ids[@]}" ]; do
    id="${policy_eval_ids[$i]}"
    if [ "$id" = mcr.line-cap ] && [ -n "${policy_eval_when_conds[$i]}" ]; then
      while IFS= read -r cond; do
        case "$cond" in
          changed_lines\>*)
            cap="${cond#changed_lines>}"
            break
            ;;
        esac
      done <<EOF
${policy_eval_when_conds[$i]}
EOF
    fi
    if [ "${policy_eval_effects[$i]}" = forbid ] &&
      [ "${policy_eval_actions[$i]}" = skip-model-check ]; then
      case "$id" in
        mcr.deny.*)
          if [ -z "$deny" ]; then
            deny="${policy_eval_resources[$i]}"
          else
            deny="$deny ${policy_eval_resources[$i]}"
          fi
          ;;
      esac
    fi
    if [ "${policy_eval_effects[$i]}" = permit ] &&
      [ "${policy_eval_actions[$i]}" = skip-model-check ] &&
      [ "${policy_eval_when_counts[$i]}" = 0 ]; then
      if [ -z "$allow" ]; then
        allow="${policy_eval_resources[$i]}"
      else
        allow="$allow ${policy_eval_resources[$i]}"
      fi
    fi
    i=$((i + 1))
  done
  # shellcheck disable=SC2034
  policy_eval_mcr_line_cap="$cap"
  # shellcheck disable=SC2034
  policy_eval_mcr_deny_patterns="$deny"
  # shellcheck disable=SC2034
  policy_eval_mcr_allow_patterns="$allow"
  printf 'Line cap: %s\n' "$cap"
  printf 'Deny list: %s\n' "$deny"
  printf 'Allow list: %s\n' "$allow"
}

policy_eval_list_forbids() {
  local action="$1" i

  policy_eval_ensure_loaded || return 1
  i=0
  while [ "$i" -lt "${#policy_eval_ids[@]}" ]; do
    if [ "${policy_eval_effects[$i]}" = forbid ] &&
      [ "${policy_eval_actions[$i]}" = "$action" ]; then
      printf '%s\t%s\t%s\n' "${policy_eval_ids[$i]}" \
        "${policy_eval_when_eres[$i]}" "${policy_eval_labels[$i]}"
    fi
    i=$((i + 1))
  done
}
