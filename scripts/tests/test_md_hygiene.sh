#!/usr/bin/env bash
# Tests for scripts/dev-loop-gate.sh --check prose-dashes and --check md-links.
# Local temp git repos only, no network.
set -u

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
gate="$repo_root/scripts/dev-loop-gate.sh"

pass=0
fail=0
work_tmp="$(mktemp -d)"
err_file="$work_tmp/stderr"
: > "$err_file"

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

expect_err() {
  case "$err" in
    *"$2"*) ok "$1" ;;
    *) bad "$1" "stderr missing: $2" ;;
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
  out="$(cd "$dir" && "$@" 2>"$err_file")"
  status=$?
  err="$(cat "$err_file")"
}

printf '== prose-dashes ==\n'

clean_repo="$(make_repo)"
printf '# Clean\nNo punctuation problem here.\n' > "$clean_repo/docs/clean.md"
track "$clean_repo" docs/clean.md

run_gate "$repo_root" bash "$gate" --repo "$clean_repo" --check prose-dashes --strict
expect_status "P1: clean prose passes under strict" 0
expect_regex "P1: clean prose summary passes" "^PD +prose-dashes +PASS +1 files, 0 hits$"

dash_repo="$(make_repo)"
{
  printf '# Dash\n'
  printf 'An em \xe2\x80\x94 dash.\n'
  printf 'An en \xe2\x80\x93 dash.\n'
  printf 'Both \xe2\x80\x94 and \xe2\x80\x93 here.\n'
} > "$dash_repo/docs/dash.md"
track "$dash_repo" docs/dash.md

run_gate "$repo_root" bash "$gate" --repo "$dash_repo" --check prose-dashes
expect_status "P2: dash rows are advisory without strict" 0
expect_regex "P2: em dash row carries the rule text" "^PD +docs/dash\.md:2 +FAIL +em dash in prose; use a comma, colon, period, or parentheses \(CONTRIBUTING\.md\)$"
expect_regex "P2: en dash row carries the rule text" "^PD +docs/dash\.md:3 +FAIL +en dash in prose; write 'to' for ranges, else a comma, colon, or period \(CONTRIBUTING\.md\)$"
expect_out "P2: summary counts both kinds on one line" "1 files, 4 hits"

run_gate "$repo_root" bash "$gate" --repo "$dash_repo" --check prose-dashes --strict
expect_status "P3: dash rows fail under strict" 1

code_repo="$(make_repo)"
{
  printf '# Code\n'
  printf '```\n'
  printf 'A \xe2\x80\x94 B\n'
  printf '```\n'
  printf '~~~text\n'
  printf 'C \xe2\x80\x93 D\n'
  printf '~~~\n'
  # shellcheck disable=SC2016
  printf 'Inline `E \xe2\x80\x94 F` and `G \xe2\x80\x93 H`.\n'
} > "$code_repo/docs/code.md"
track "$code_repo" docs/code.md

run_gate "$repo_root" bash "$gate" --repo "$code_repo" --check prose-dashes --strict
expect_status "P4: fenced and inline code dashes are ignored" 0
expect_out "P4: code repo has no prose hits" "1 files, 0 hits"

untracked_repo="$(make_repo)"
printf '# Clean\nNothing to see.\n' > "$untracked_repo/docs/clean.md"
printf 'An em \xe2\x80\x94 dash.\n' > "$untracked_repo/docs/draft.md"
track "$untracked_repo" docs/clean.md

run_gate "$repo_root" bash "$gate" --repo "$untracked_repo" --check prose-dashes --strict
expect_status "P5: untracked Markdown is ignored" 0
expect_no_out "P5: untracked path is not reported" "docs/draft.md"
expect_out "P5: only tracked file counted" "1 files, 0 hits"

printf '== md-links ==\n'

link_repo="$(make_repo)"
printf '# A\nSee [b](b.md).\n' > "$link_repo/docs/a.md"
printf '# B\n' > "$link_repo/docs/b.md"
track "$link_repo" docs/a.md docs/b.md

run_gate "$repo_root" bash "$gate" --repo "$link_repo" --check md-links --strict
expect_status "L1: valid relative link passes" 0
expect_regex "L1: link summary counts the file and link" "^ML +md-links +PASS +2 files, 1 links checked, 0 hits$"

missing_repo="$(make_repo)"
printf '# A\n[x](gone.md)\n' > "$missing_repo/docs/a.md"
track "$missing_repo" docs/a.md

run_gate "$repo_root" bash "$gate" --repo "$missing_repo" --check md-links
expect_status "L2: missing file is advisory without strict" 0
expect_regex "L2: missing file row names the resolved path" "^ML +docs/a\.md:2 +FAIL +target not found: docs/gone\.md; update the link to the file's current path$"

run_gate "$repo_root" bash "$gate" --repo "$missing_repo" --check md-links --strict
expect_status "L3: missing file fails under strict" 1

anchor_repo="$(make_repo)"
printf '# A\n[ok](b.md#intro)\n[bad](b.md#missing)\n' > "$anchor_repo/docs/a.md"
printf '# B\n## Intro\n' > "$anchor_repo/docs/b.md"
track "$anchor_repo" docs/a.md docs/b.md

run_gate "$repo_root" bash "$gate" --repo "$anchor_repo" --check md-links
expect_status "L4: anchor rows are advisory without strict" 0
expect_no_regex "L4: valid heading anchor is quiet" "^ML +docs/a\.md:2 "
expect_regex "L4: missing heading anchor fails" "^ML +docs/a\.md:3 +FAIL +no heading #missing in docs/b\.md; use the heading slug \(lowercase, punctuation dropped, spaces as -\)$"

self_repo="$(make_repo)"
cat > "$self_repo/docs/self.md" <<'MD'
# Self
## Target here
[go](#target-here)
[bad](#no-such)
MD
track "$self_repo" docs/self.md

run_gate "$repo_root" bash "$gate" --repo "$self_repo" --check md-links
expect_status "L5: same-file anchors are advisory without strict" 0
expect_no_regex "L5: same-file valid anchor is quiet" "^ML +docs/self\.md:3 "
expect_regex "L5: same-file missing anchor fails" "^ML +docs/self\.md:4 +FAIL +no heading #no-such in docs/self\.md; "

dup_repo="$(make_repo)"
cat > "$dup_repo/docs/dup.md" <<'MD'
# Dup
## Intro
[a](#intro)
[b](#intro-1)
## Intro
MD
track "$dup_repo" docs/dup.md

run_gate "$repo_root" bash "$gate" --repo "$dup_repo" --check md-links --strict
expect_status "L6: duplicate heading suffix anchor passes" 0
expect_regex "L6: duplicate heading counts both links" "^ML +md-links +PASS +1 files, 2 links checked, 0 hits$"

slug_repo="$(make_repo)"
cat > "$slug_repo/docs/slug.md" <<'MD'
# Slug
## Use `--strict` (CI only)
[go](#use---strict-ci-only)
MD
track "$slug_repo" docs/slug.md

run_gate "$repo_root" bash "$gate" --repo "$slug_repo" --check md-links --strict
expect_status "L7: punctuation and inline code slug passes" 0
expect_regex "L7: slug heading counts one link" "^ML +md-links +PASS +1 files, 1 links checked, 0 hits$"

dir_repo="$(make_repo)"
mkdir -p "$dir_repo/docs/sub"
printf '# Keep\n' > "$dir_repo/docs/sub/keep.md"
cat > "$dir_repo/docs/index.md" <<'MD'
# Index
[dir](sub/)
MD
track "$dir_repo" docs/index.md docs/sub/keep.md

run_gate "$repo_root" bash "$gate" --repo "$dir_repo" --check md-links --strict
expect_status "L8: directory target passes" 0
expect_out "L8: directory target counted" "2 files, 1 links checked, 0 hits"

img_repo="$(make_repo)"
printf '' > "$img_repo/docs/pic.png"
cat > "$img_repo/docs/a.md" <<'MD'
# Image
![alt](pic.png)
MD
track "$img_repo" docs/a.md docs/pic.png

run_gate "$repo_root" bash "$gate" --repo "$img_repo" --check md-links --strict
expect_status "L9: image target passes" 0
expect_out "L9: image target counted" "1 files, 1 links checked, 0 hits"

ref_repo="$(make_repo)"
cat > "$ref_repo/docs/a.md" <<'MD'
# Ref
[ref]: gone.md
MD
track "$ref_repo" docs/a.md

run_gate "$repo_root" bash "$gate" --repo "$ref_repo" --check md-links
expect_status "L10: reference definition row is advisory" 0
expect_regex "L10: reference definition missing target fails" "^ML +docs/a\.md:2 +FAIL +target not found: docs/gone\.md; "

ext_repo="$(make_repo)"
cat > "$ext_repo/docs/a.md" <<'MD'
# Ext
[web](https://example.com/x)
[mail](mailto:a@example.invalid)
[proto](//example.com/x)
[ftp](ftp://example.com/x)
MD
track "$ext_repo" docs/a.md

run_gate "$repo_root" bash "$gate" --repo "$ext_repo" --check md-links --strict
expect_status "L11: external targets are skipped" 0
expect_out "L11: external targets are not counted" "1 files, 0 links checked, 0 hits"

code_link_repo="$(make_repo)"
cat > "$code_link_repo/docs/a.md" <<'MD'
# Code
```
[x](gone.md)
```
Inline `[y](gone.md)`.
MD
track "$code_link_repo" docs/a.md

run_gate "$repo_root" bash "$gate" --repo "$code_link_repo" --check md-links --strict
expect_status "L12: fenced and inline code links are ignored" 0
expect_out "L12: code links are not counted" "1 files, 0 links checked, 0 hits"

outside_repo="$(make_repo)"
printf '# Out\n[out](../../outside.md)\n' > "$outside_repo/docs/a.md"
track "$outside_repo" docs/a.md

run_gate "$repo_root" bash "$gate" --repo "$outside_repo" --check md-links
expect_status "L13: climb above the root is advisory" 0
expect_regex "L13: climb above the root fails" "^ML +docs/a\.md:2 +FAIL +points outside the repository; link to a path inside the kit$"

root_repo="$(make_repo)"
printf '# A\n[root](/docs/b.md)\n' > "$root_repo/docs/a.md"
printf '# B\n' > "$root_repo/docs/b.md"
track "$root_repo" docs/a.md docs/b.md

run_gate "$repo_root" bash "$gate" --repo "$root_repo" --check md-links --strict
expect_status "L14: root-relative path resolves from the repo root" 0
expect_out "L14: root-relative link counted" "2 files, 1 links checked, 0 hits"

space_repo="$(make_repo)"
cat > "$space_repo/docs/a.md" <<'MD'
# Space
[space](with%20space.md)
MD
printf '# Space file\n' > "$space_repo/docs/with space.md"
track "$space_repo" docs/a.md "docs/with space.md"

run_gate "$repo_root" bash "$gate" --repo "$space_repo" --check md-links --strict
expect_status "L15: percent-encoded space resolves" 0
expect_out "L15: percent-encoded link counted" "2 files, 1 links checked, 0 hits"

script_repo="$(make_repo)"
printf '# Script\n[script](run.sh#L10)\n' > "$script_repo/docs/a.md"
printf '#!/bin/sh\n' > "$script_repo/docs/run.sh"
track "$script_repo" docs/a.md docs/run.sh

run_gate "$repo_root" bash "$gate" --repo "$script_repo" --check md-links --strict
expect_status "L16: anchor on a non-Markdown file is not checked" 0
expect_out "L16: non-Markdown anchor link counted" "1 files, 1 links checked, 0 hits"

printf '== invocation ==\n'

run_gate "$repo_root" bash "$gate" --check no-such
expect_status "I1: unknown check exits 2" 2
expect_err "I1: unknown check lists the implemented ids" "unknown check: no-such (implemented: agent-git, line-cap, npm-ci, node-pin, docs-sweep, docs-usage-dup, prose-dashes, md-links, model-ids, pr-state, review-ready, review-citations, deploy-hash, model-check-required, model-check-fresh)"

run_gate "$repo_root" bash "$gate" --help
expect_status "I2: --help exits 0" 0
expect_out "I2: --help lists agent-git" "agent-git"
expect_out "I2: --help lists prose-dashes" "prose-dashes"
expect_out "I2: --help lists md-links" "md-links"
expect_out "I2: --help lists docs-usage-dup" "docs-usage-dup"

printf '== markdown include/exclude ==\n'

scope_repo="$(make_repo)"
mkdir -p "$scope_repo/docs/transcripts" "$scope_repo/sources"
printf '# Editorial\nClean prose.\n' > "$scope_repo/docs/editorial.md"
printf '# Editorial Bad\nAn em \xe2\x80\x94 dash and [bad](missing.md).\n' > "$scope_repo/docs/editorial-bad.md"
printf '# Transcript\nAn em \xe2\x80\x94 dash and [bad](missing.md).\n' > "$scope_repo/docs/transcripts/run.md"
printf '# Source\nAn em \xe2\x80\x94 dash and [bad](missing.md).\n' > "$scope_repo/sources/bib.md"
track "$scope_repo" docs/editorial.md docs/editorial-bad.md docs/transcripts/run.md sources/bib.md

# Default scan without markdown config still covers every tracked *.md.
run_gate "$repo_root" bash "$gate" --repo "$scope_repo" --check prose-dashes --strict
expect_status "S1: default scan covers all tracked md (prose-dashes fails)" 1
expect_out "S1: default scan checks 4 files" "4 files, 3 hits"

# Exclude skips source and transcript paths and leaves editorial Markdown checked.
exclude_cfg="$work_tmp/md-exclude.json"
cat > "$exclude_cfg" <<'JSON'
{
  "markdown": {
    "exclude": ["docs/transcripts/", "sources/"]
  }
}
JSON
run_gate "$repo_root" bash "$gate" --repo "$scope_repo" --config "$exclude_cfg" --check prose-dashes --strict
expect_status "S2: exclude skips transcripts and sources, editorial still fails" 1
expect_out "S2: exclude checks 2 editorial files" "2 files, 1 hits"
expect_no_out "S2: transcript path not reported" "docs/transcripts/run.md"
expect_no_out "S2: source path not reported" "sources/bib.md"

run_gate "$repo_root" bash "$gate" --repo "$scope_repo" --config "$exclude_cfg" --check md-links --strict
expect_status "S2b: md-links respects exclude" 1
expect_out "S2b: md-links checks 2 editorial files" "2 files, 1 links checked, 1 hits"

# Include limits the scan set to clean editorial docs only.
include_cfg="$work_tmp/md-include.json"
cat > "$include_cfg" <<'JSON'
{
  "markdown": {
    "include": ["docs/editorial.md"]
  }
}
JSON
run_gate "$repo_root" bash "$gate" --repo "$scope_repo" --config "$include_cfg" --check prose-dashes --strict
expect_status "S3: include limits scan set to clean file" 0
expect_out "S3: include checks 1 file" "1 files, 0 hits"

run_gate "$repo_root" bash "$gate" --repo "$scope_repo" --config "$include_cfg" --check md-links --strict
expect_status "S3b: md-links respects include" 0
expect_out "S3b: md-links checks 1 file" "1 files, 0 links checked, 0 hits"

# Combined include + narrow exclude + tight anchored ERE.
combo_cfg="$work_tmp/md-combo.json"
cat > "$combo_cfg" <<'JSON'
{
  "markdown": {
    "include": ["docs/"],
    "exclude": ["docs/transcripts/", "^docs/editorial-bad\\.md$"]
  }
}
JSON
run_gate "$repo_root" bash "$gate" --repo "$scope_repo" --config "$combo_cfg" --check prose-dashes --strict
expect_status "S4: include + narrow exclude + anchored ERE passes" 0
expect_out "S4: only docs/editorial.md checked" "1 files, 0 hits"

# Invalid, broad, or overlapping patterns fail closed (exit 2) and check nothing.
for bad_name in broad_star broad_doublestar unanchored_glob leading_slash traversal overlap_exact overlap_prefix bad_regex; do
  bad_cfg="$work_tmp/md-bad-$bad_name.json"
  case "$bad_name" in
    broad_star)       printf '{"markdown":{"exclude":["^docs/.*$"]}}\n' > "$bad_cfg" ;;
    broad_doublestar) printf '{"markdown":{"exclude":["docs/**"]}}\n' > "$bad_cfg" ;;
    unanchored_glob)  printf '{"markdown":{"include":["docs/*.md"]}}\n' > "$bad_cfg" ;;
    leading_slash)    printf '{"markdown":{"exclude":["/docs/"]}}\n' > "$bad_cfg" ;;
    traversal)        printf '{"markdown":{"exclude":["../docs/"]}}\n' > "$bad_cfg" ;;
    overlap_exact)    printf '{"markdown":{"include":["docs/"],"exclude":["docs/"]}}\n' > "$bad_cfg" ;;
    overlap_prefix)   printf '{"markdown":{"include":["docs/transcripts/"],"exclude":["docs/"]}}\n' > "$bad_cfg" ;;
    bad_regex)        printf '{"markdown":{"exclude":["^[unclosed$"]}}\n' > "$bad_cfg" ;;
  esac
  run_gate "$repo_root" bash "$gate" --repo "$scope_repo" --config "$bad_cfg" --check prose-dashes --strict
  expect_status "S5 ($bad_name): invalid pattern exits 2" 2
  expect_no_out "S5 ($bad_name): checks nothing on stdout" "PD "
done

printf '== kit self-check ==\n'

run_gate "$repo_root" bash "$gate" --repo "$repo_root" --strict --check prose-dashes
expect_status "K1: kit passes strict prose-dashes" 0
expect_regex "K1: kit prose summary passes" "^PD +prose-dashes +PASS "

run_gate "$repo_root" bash "$gate" --repo "$repo_root" --strict --check md-links
expect_status "K2: kit passes strict md-links" 0
expect_regex "K2: kit link summary passes" "^ML +md-links +PASS "

printf '\n%d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -ne 0 ]; then
  exit 1
fi
exit 0
