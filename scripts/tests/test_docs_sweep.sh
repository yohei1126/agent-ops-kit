#!/usr/bin/env bash
# Tests for scripts/dev-loop-gate.sh --check docs-sweep.
# Local temp git repos only, no network.
set -u

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
gate="$repo_root/scripts/dev-loop-gate.sh"

pass=0
fail=0
work_tmp="$(mktemp -d)"
err_file="$work_tmp/stderr"
: > "$err_file"

test_home="$work_tmp/home"
mkdir -p "$test_home/.config"

out=""
err=""
status=0

trap 'rm -rf "$work_tmp"' EXIT

unset DEV_LOOP_NAME_LIST
unset DEV_LOOP_BRANCH DEV_LOOP_ALIAS DEV_LOOP_REQUIRED_PATH \
  DEV_LOOP_SOFT_DENY_COUNT DEV_LOOP_MODEL_LANE DEV_LOOP_DIFF_KIND \
  DEV_LOOP_PR_STATE DEV_LOOP_OPERATOR_READY DEV_LOOP_VULN_SILENT \
  DEV_LOOP_RETRO_MARKER DEV_LOOP_OPEN_JOBS DEV_LOOP_OPEN_PRS

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

expect_regex() {
  if printf '%s\n' "$out" | grep -Eq "$2"; then
    ok "$1"
  else
    bad "$1" "stdout missing line matching: $2"
  fi
}

expect_no_regex() {
  if printf '%s\n' "$out" | grep -Eq "$2"; then
    bad "$1" "stdout should not match: $2"
  else
    ok "$1"
  fi
}

expect_no_out() {
  case "$out" in
    *"$2"*) bad "$1" "stdout should not contain: $2" ;;
    *) ok "$1" ;;
  esac
}

expect_no_quote() {
  if printf '%s\n' "$out" | grep -q '"'; then
    bad "$1" "stdout contains a double quote"
  else
    ok "$1"
  fi
}

make_repo() {
  local dir
  dir="$(mktemp -d "$work_tmp/repo.XXXXXX")/repo"
  mkdir -p "$dir/docs"
  git -C "$dir" init -q
  printf '%s\n' "$dir"
}

track() {
  local dir="$1"
  shift
  git -C "$dir" add "$@"
}

run_gate() {
  local dir="$1"
  shift
  : > "$err_file"
  out="$(cd "$dir" && HOME="$test_home" XDG_CONFIG_HOME="$test_home/.config" \
    "$@" 2>"$err_file")"
  status=$?
  err="$(cat "$err_file")"
}

cfg_with() {
  local file="$1"
  local exceptions="$2"
  cat > "$file" <<JSON
{"line_cap":{"default":500,"exceptions":[]},"docs_sweep":{"exceptions":$exceptions}}
JSON
}

printf '== rules ==\n'

phase_repo="$(make_repo)"
cat > "$phase_repo/docs/a.md" <<'MD'
# Title
Phase 2 work starts.
phase-out stays.
phases stay.
PHASE-7 also starts.
MD
track "$phase_repo" docs/a.md

run_gate "$repo_root" bash "$gate" --repo "$phase_repo" --check docs-sweep
expect_status "1: phase hits are advisory" 0
expect_regex "1: phase row for Phase 2" "^DS +docs/a\.md:2 +FAIL +phase: "
expect_regex "1: phase row for PHASE-7" "^DS +docs/a\.md:5 +FAIL +phase: "
expect_no_regex "1: phase-out is not a hit" "^DS +docs/a\.md:3 "
expect_no_regex "1: phases is not a hit" "^DS +docs/a\.md:4 "
expect_out "1: phase summary counts two hits" "1 files, 2 hits"
expect_no_quote "1: phase rows have no double quote"

run_gate "$repo_root" bash "$gate" --repo "$phase_repo" --check docs-sweep --strict
expect_status "2: phase hits fail under strict" 1

link_repo="$(make_repo)"
cat > "$link_repo/docs/links.md" <<'MD'
# Links
See https://github.com/acme/widgets/issues/12.
See https://github.com/acme/widgets/pull/34.
See /pull/12.
Uppercase GITHUB.COM/A/B/ISSUES/9 stays quiet.
MD
track "$link_repo" docs/links.md

run_gate "$repo_root" bash "$gate" --repo "$link_repo" --check docs-sweep
expect_status "3: link hits are advisory" 0
expect_regex "3: GitHub issue link is a hit" "^DS +docs/links\.md:2 +FAIL +link: "
expect_regex "3: GitHub pull link is a hit" "^DS +docs/links\.md:3 +FAIL +link: "
expect_regex "3: relative pull link is a hit" "^DS +docs/links\.md:4 +FAIL +link: "
expect_no_regex "3: uppercase link host is not a hit" "^DS +docs/links\.md:5 "
expect_out "3: link summary counts three hits" "1 files, 3 hits"

clean_repo="$(make_repo)"
printf '# Clean\nNothing to see.\n' > "$clean_repo/docs/clean.md"
track "$clean_repo" docs/clean.md

run_gate "$repo_root" bash "$gate" --repo "$clean_repo" --check docs-sweep --strict
expect_status "4: clean repo passes under strict" 0
expect_regex "4: clean summary passes" "^DS +summary +PASS +1 files, 0 hits$"

untracked_repo="$(make_repo)"
printf '# Clean\nNothing to see.\n' > "$untracked_repo/docs/clean.md"
printf 'Phase 9 untracked.\n' > "$untracked_repo/docs/draft.md"
track "$untracked_repo" docs/clean.md

run_gate "$repo_root" bash "$gate" --repo "$untracked_repo" --check docs-sweep
expect_status "5: untracked hit is ignored" 0
expect_no_out "5: untracked path is not reported" "docs/draft.md"
expect_out "5: only tracked file counted" "1 files, 0 hits"

space_repo="$(make_repo)"
printf 'Phase 3 in a spaced path.\n' > "$space_repo/docs/with space.md"
track "$space_repo" "docs/with space.md"

run_gate "$repo_root" bash "$gate" --repo "$space_repo" --check docs-sweep
expect_status "6: path with a space is advisory" 0
expect_regex "6: path with a space is reported" "^DS +docs/with space\.md:1 +FAIL +phase: "

printf '== exceptions ==\n'

whole_cfg="$work_tmp/whole.json"
cfg_with "$whole_cfg" '[{"path":"docs/ledger.md","reason":"evidence ledger"}]'

whole_repo="$(make_repo)"
cat > "$whole_repo/docs/ledger.md" <<'MD'
Phase 4 evidence.
https://github.com/acme/widgets/pull/9
MD
printf 'Phase 5 elsewhere.\n' > "$whole_repo/docs/other.md"
track "$whole_repo" docs/ledger.md docs/other.md

run_gate "$repo_root" bash "$gate" --repo "$whole_repo" --check docs-sweep --config "$whole_cfg"
expect_status "7: whole-file exception leaves advisory exit" 0
expect_no_out "7: excepted file has no rows" "docs/ledger.md"
expect_regex "7: other file still fails" "^DS +docs/other\.md:1 +FAIL +phase: "

solo_cfg="$work_tmp/solo.json"
cat > "$solo_cfg" <<'JSON'
{"docs_sweep":{"exceptions":[{"path":"docs/ledger.md","reason":"evidence ledger"}]}}
JSON

run_gate "$repo_root" bash "$gate" --repo "$whole_repo" --check docs-sweep --config "$solo_cfg"
expect_status "7: docs-sweep config without line_cap works" 0
expect_no_out "7: solo config excuses the ledger" "docs/ledger.md"
run_gate "$repo_root" bash "$gate" --repo "$whole_repo" --check line-cap --config "$solo_cfg"
expect_status "7: line-cap still requires line_cap in config" 2

line_cfg="$work_tmp/line.json"
cfg_with "$line_cfg" '[{"path":"docs/mixed.md","pattern":"^Phase 1 legacy row$","reason":"legacy ledger row"}]'

line_repo="$(make_repo)"
cat > "$line_repo/docs/mixed.md" <<'MD'
Phase 1 legacy row
Phase 2 new row
MD
track "$line_repo" docs/mixed.md

run_gate "$repo_root" bash "$gate" --repo "$line_repo" --check docs-sweep --config "$line_cfg" --strict
expect_status "8: anchored exception still fails on other lines" 1
expect_no_regex "8: excepted line is gone" "^DS +docs/mixed\.md:1 "
expect_regex "8: other line still fails" "^DS +docs/mixed\.md:2 +FAIL +phase: "
expect_out "8: one hit remains" "1 files, 1 hits"

rule_cfg="$work_tmp/rules.json"
cfg_with "$rule_cfg" '[{"path":"docs/rules.md","pattern":"^Phase 6 see https://github[.]com/a/b/issues/1$","rules":["link"],"reason":"example link only"}]'

rules_repo="$(make_repo)"
printf 'Phase 6 see https://github.com/a/b/issues/1\n' > "$rules_repo/docs/rules.md"
track "$rules_repo" docs/rules.md

run_gate "$repo_root" bash "$gate" --repo "$rules_repo" --check docs-sweep --config "$rule_cfg"
expect_status "9: rule-limited exception is advisory" 0
expect_regex "9: phase still fails" "^DS +docs/rules\.md:1 +FAIL +phase: "
expect_no_regex "9: link is excused" "FAIL +link: "
expect_out "9: one hit remains" "1 files, 1 hits"

printf '== config errors ==\n'

err_repo="$(make_repo)"
printf 'Phase 1\n' > "$err_repo/docs/a.md"
track "$err_repo" docs/a.md

bad_reason="$work_tmp/bad-reason.json"
cfg_with "$bad_reason" '[{"path":"docs/a.md"}]'

bad_glob="$work_tmp/bad-glob.json"
cfg_with "$bad_glob" '[{"path":"docs/*.md","reason":"glob"}]'

bad_anchor="$work_tmp/bad-anchor.json"
cfg_with "$bad_anchor" '[{"path":"docs/a.md","pattern":"Phase 1","reason":"unanchored"}]'

bad_rule="$work_tmp/bad-rule.json"
cfg_with "$bad_rule" '[{"path":"docs/a.md","rules":["phase","bogus"],"reason":"unknown rule"}]'

run_gate "$repo_root" bash "$gate" --repo "$err_repo" --check docs-sweep --config "$bad_reason"
expect_status "10: missing reason exits 2" 2
run_gate "$repo_root" bash "$gate" --repo "$err_repo" --check docs-sweep --config "$bad_glob"
expect_status "10: glob path exits 2" 2
run_gate "$repo_root" bash "$gate" --repo "$err_repo" --check docs-sweep --config "$bad_anchor"
expect_status "10: unanchored pattern exits 2" 2
run_gate "$repo_root" bash "$gate" --repo "$err_repo" --check docs-sweep --config "$bad_rule"
expect_status "10: unknown rule exits 2" 2

printf '== local name list ==\n'

run_gate "$repo_root" bash "$gate" --repo "$clean_repo" --check docs-sweep --strict
expect_status "11: missing default name list exits 0" 0
expect_regex "11: missing list row skips" "^DS +name-list +SKIP +no local name list$"

run_gate "$repo_root" env DEV_LOOP_NAME_LIST="$work_tmp/no-such-list" \
  bash "$gate" --repo "$clean_repo" --check docs-sweep --strict
expect_status "11: explicit missing list exits 0" 0
expect_regex "11: explicit missing list skips" "^DS +name-list +SKIP +no local name list$"

name_repo="$(make_repo)"
printf 'The Zorblax queue runs nightly.\n' > "$name_repo/docs/name.md"
track "$name_repo" docs/name.md

fake_list="$work_tmp/name-list"
printf '# local terms\n\nZorblax\n' > "$fake_list"

run_gate "$repo_root" env DEV_LOOP_NAME_LIST="$fake_list" \
  bash "$gate" --repo "$name_repo" --check docs-sweep --strict
expect_status "12: fake name term fails under strict" 1
expect_regex "12: name hit row is generic" "^DS +docs/name\.md:1 +FAIL +name: "
expect_no_out "12: name term is not printed" "Zorblax"

ignored_repo="$(make_repo)"
printf '#Zorblax note\nNothing else.\n' > "$ignored_repo/docs/comment.md"
track "$ignored_repo" docs/comment.md

comment_list="$work_tmp/comment-list"
printf '#Zorblax\n\n' > "$comment_list"

run_gate "$repo_root" env DEV_LOOP_NAME_LIST="$comment_list" \
  bash "$gate" --repo "$ignored_repo" --check docs-sweep --strict
expect_status "13: comment and blank list lines are ignored" 0
expect_out "13: ignored terms produce no hits" "1 files, 0 hits"

mkdir -p "$test_home/.config/agent-ops-kit"
printf 'Zorblax\n' > "$test_home/.config/agent-ops-kit/docs-name-list"
run_gate "$repo_root" bash "$gate" --repo "$name_repo" --check docs-sweep --strict
expect_status "14: default name list path is used" 1
rm -f "$test_home/.config/agent-ops-kit/docs-name-list"

printf '== invocation ==\n'

run_gate "$work_tmp" bash "$gate" --repo "$phase_repo" --check docs-sweep
expect_status "15: --repo works from another cwd" 0
expect_regex "15: --repo from another cwd reports hits" "^DS +docs/a\.md:2 +FAIL +phase: "

run_gate "$repo_root" bash "$gate"
expect_status "16: no-arg table exits 0" 0
for id in G1 G2 G3 G4 G5 G6 G7; do
  if printf '%s\n' "$out" | grep -q "^$id "; then
    ok "16: table still has $id row"
  else
    bad "16: table still has $id row" "no $id row in stdout"
  fi
done
expect_no_regex "16: no-arg table has no DS rows" "^DS "

run_gate "$repo_root" env DEV_LOOP_NAME_LIST="$work_tmp/no-such-list" \
  bash "$gate" --strict --check docs-sweep
expect_status "17: this repo passes strict docs-sweep" 0
expect_regex "17: this repo summary passes" "^DS +summary +PASS +[0-9]+ files, 0 hits$"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -ne 0 ]; then
  exit 1
fi
exit 0
