#!/usr/bin/env bash
# Tests for scripts/agents/goat/run with a stub agent binary only. No test can
# start a real session: the stub sits first on PATH and GOAT_CMD points at it.
# Bash 3.2 compatible.
# shellcheck disable=SC2016 # literal Markdown fences and jq programs
set -u

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
adapter="$repo_root/scripts/agents/goat/run"
launcher="$repo_root/scripts/agent-launch.sh"

pass=0
fail=0
work_tmp="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$work_tmp"' EXIT

ok() {
  pass=$((pass + 1))
  printf 'PASS %s\n' "$1"
}

bad() {
  fail=$((fail + 1))
  printf 'FAIL %s: %s\n' "$1" "$2"
}

# The adapter runs the agent under env -i, so the stub cannot read test
# variables. Its control files live at fixed paths baked in here.
ctl="$work_tmp/ctl"
mkdir -p "$ctl" "$work_tmp/bin"
cat >"$work_tmp/bin/fake-goat" <<SH
#!/bin/sh
: >"$ctl/called"
for a in "\$@"; do printf '%s\n' "\$a"; done >"$ctl/argv"
env | sed 's/=.*//' | sort >"$ctl/env-names"
printf '%s\n' "\$PATH" >"$ctl/path"
pwd -P >"$ctl/cwd"
if [ -f .commandcode/settings.local.json ]; then
  cp .commandcode/settings.local.json "$ctl/settings-seen"
fi
if [ -f "$ctl/write" ]; then
  while IFS= read -r p; do
    mkdir -p "\$(dirname "\$p")"
    printf 'written\n' >"\$p"
  done <"$ctl/write"
fi
if [ -f "$ctl/out" ]; then
  cat "$ctl/out"
fi
if [ -f "$ctl/leak" ]; then
  printf 'leak: %s\n' "\$COMMAND_CODE_API_KEY" >&2
fi
if [ -f "$ctl/exit" ]; then
  printf 'stub failure line\n' >&2
  exit "\$(cat "$ctl/exit")"
fi
exit 0
SH
chmod +x "$work_tmp/bin/fake-goat"

secret="fake-secret-value-123"
out=""
err=""
status=0

reset_ctl() {
  rm -f "$ctl"/*
}

# set_result <text file> [model-id]: the stub prints model request events
# with that id, then one result event. The default id matches the --model
# the older tests pass.
set_result() {
  local id="${2:-example/model-1}"
  {
    jq -cn --arg m "$id" '{type: "event", event: {type: "model_request_start", model: $m}}'
    jq -cn --arg m "$id" '{type: "event", event: {type: "model_request_end", model: $m}}'
    jq -cn --rawfile t "$1" '{type: "result", finalText: $t}'
  } >"$ctl/out"
}

run_adapter() {
  out="$(PATH="$work_tmp/bin:$work_tmp/sentinel-bin:$PATH" GOAT_CMD=fake-goat COMMAND_CODE_API_KEY="$secret" \
    GH_TOKEN=gh-should-not-pass "$adapter" "$@" 2>"$work_tmp/stderr")"
  status=$?
  err="$(cat "$work_tmp/stderr")"
}

expect_status() {
  if [ "$status" -eq "$2" ]; then
    ok "$1"
  else
    bad "$1" "expected exit $2, got $status; out: $out err: $err"
  fi
}

expect_text() {
  case "$2" in
    *"$3"*) ok "$1" ;;
    *) bad "$1" "missing: $3" ;;
  esac
}

expect_no_text() {
  case "$2" in
    *"$3"*) bad "$1" "unexpected: $3" ;;
    *) ok "$1" ;;
  esac
}

expect_not_called() {
  if [ -e "$ctl/called" ]; then
    bad "$1" "the agent was started"
  else
    ok "$1"
  fi
}

git_c() {
  git -c user.name=t -c user.email=t@example.invalid "$@"
}

main_repo="$work_tmp/main"
mkdir -p "$main_repo/docs" "$main_repo/src"
git -C "$main_repo" init -q -b main 2>/dev/null || {
  git -C "$main_repo" init -q
  git -C "$main_repo" symbolic-ref HEAD refs/heads/main
}
printf 'one\ntwo\nthree\n' >"$main_repo/docs/a.md"
printf 'x\n' >"$main_repo/src/b.txt"
git -C "$main_repo" add .
git_c -C "$main_repo" commit -q -m init
wt="$work_tmp/wt"
git -C "$main_repo" worktree add -q -b feat/topic "$wt"
brief="$work_tmp/brief.md"
printf 'Change docs/a.md.\n' >"$brief"
head0="$(git -C "$wt" rev-parse HEAD)"

reset_wt() {
  git -C "$wt" reset -q --hard "$head0"
  git -C "$wt" clean -qfdx
}

printf '== usage ==\n'
run_adapter --help
expect_status "1: --help exits 0" 0
expect_text "1: --help names the modes" "$out" "patch"
expect_text "1: --help documents GOAT_TIMEOUT" "$out" "GOAT_TIMEOUT"
reset_ctl
run_adapter --model m -- "$wt" "$brief"
expect_status "1: missing --mode exits 2" 2
run_adapter --mode patch -- "$wt" "$brief"
expect_status "1: missing --model exits 2" 2
run_adapter --mode shell --model m -- "$wt" "$brief"
expect_status "1: unknown mode exits 2" 2
run_adapter --mode patch --model m --bogus -- "$wt" "$brief"
expect_status "1: unknown flag exits 2" 2
run_adapter --mode patch --model m -- "$wt"
expect_status "1: patch without a brief exits 2" 2
run_adapter --mode review --model m -- "$wt" "$brief"
expect_status "1: review without a result file exits 2" 2
run_adapter --mode write --model m -- "$wt" "$brief"
expect_status "1: write without a scope exits 2" 2
expect_not_called "1: no usage error starts the agent"

printf '== dry run ==\n'
reset_ctl
run_adapter --mode patch --model example/model-1 --dry-run -- "$wt" "$brief"
expect_status "2: patch dry-run exits 0" 0
expect_text "2: prints the command" "$out" "GOAT_COMMAND="
expect_text "2: model from the caller" "$out" "--model example/model-1"
expect_text "2: no auto update" "$out" "--no-auto-update"
expect_text "2: no session on disk" "$out" "--no-session"
expect_text "2: bounded turns" "$out" "--max-turns 30"
expect_text "2: json output" "$out" "--output-format json"
expect_no_text "2: patch never passes --yolo" "$out" "--yolo"
expect_no_text "2: the key value is never printed" "$out$err" "$secret"
expect_text "2: the key is reported as set" "$out" "COMMAND_CODE_API_KEY=<set>"
expect_no_text "2: no GitHub token in the child env" "$out" "GH_TOKEN"
expect_not_called "2: dry-run starts nothing"
run_adapter --mode review --model example/model-1 --dry-run -- "$wt" "$brief" "$work_tmp/r.md"
expect_status "2: review dry-run exits 0" 0
expect_no_text "2: review never passes --yolo" "$out" "--yolo"
run_adapter --mode write --model example/model-1 --dry-run -- "$wt" "$brief" docs
expect_status "2: write dry-run exits 0" 0
expect_text "2: write passes --yolo" "$out" "--yolo"
expect_text "2: write prints the scope" "$out" "GOAT_SCOPE=docs"
expect_text "2: write prints the deny list" "$out" '"Shell"'
common_abs="$(cd "$main_repo" && cd "$(git rev-parse --git-common-dir)" && pwd -P)"
expect_text "2: the deny list covers the git directory" "$out" "Edit(/$common_abs/**)"
expect_text "2: the deny list reads hidden home entries" "$out" "/.*/**)"
if [ -e "$wt/.commandcode" ]; then
  bad "2: write dry-run writes no settings" ".commandcode exists"
else
  ok "2: write dry-run writes no settings"
fi
GOAT_MAX_TURNS=7 run_adapter --mode patch --model m --dry-run -- "$wt" "$brief"
expect_text "2: GOAT_MAX_TURNS is honoured" "$out" "--max-turns 7"
GOAT_MAX_TURNS=x run_adapter --mode patch --model m --dry-run -- "$wt" "$brief"
expect_status "2: non-numeric GOAT_MAX_TURNS exits 2" 2
run_adapter --mode patch --model m --dry-run -- "$wt" --dry-run
expect_status "2: a brief named --dry-run after -- is a value" 2
expect_text "2: that value is checked as a file" "$err" "--dry-run"

printf '== refusals before the run ==\n'
reset_ctl
out="$(PATH="$work_tmp/bin:$PATH" GOAT_CMD=fake-goat COMMAND_CODE_API_KEY='' \
  "$adapter" --mode patch --model m -- "$wt" "$brief" 2>"$work_tmp/stderr")"
status=$?
err="$(cat "$work_tmp/stderr")"
expect_status "3: an empty key exits 2" 2
expect_text "3: the key message has a fix hint" "$err" "COMMAND_CODE_API_KEY is not set"
out="$(env -u COMMAND_CODE_API_KEY PATH="$work_tmp/bin:$PATH" GOAT_CMD=fake-goat \
  "$adapter" --mode patch --model m -- "$wt" "$brief" 2>/dev/null)"
status=$?
expect_status "3: a missing key exits 2" 2
mkdir -p "$work_tmp/plain"
run_adapter --mode patch --model m -- "$work_tmp/plain" "$brief"
expect_status "3: a directory outside git exits 2" 2
ln -s "$wt" "$work_tmp/wt-link"
run_adapter --mode patch --model m -- "$work_tmp/wt-link" "$brief"
expect_status "3: a symlinked worktree exits 2" 2
run_adapter --mode patch --model m -- "$wt" "$work_tmp/missing.md"
expect_status "3: a missing brief exits 2" 2
ln -s "$brief" "$work_tmp/brief-link.md"
run_adapter --mode patch --model m -- "$wt" "$work_tmp/brief-link.md"
expect_status "3: a symlinked brief exits 2" 2
expect_not_called "3: no refusal starts the agent"

printf '== patch mode ==\n'
diff_ok="$work_tmp/ok.diff"
cat >"$diff_ok" <<'DIFF'
diff --git a/docs/a.md b/docs/a.md
--- a/docs/a.md
+++ b/docs/a.md
@@ -1,3 +1,3 @@
 one
-two
+TWO
 three
DIFF
{
  printf 'Here is the change.\n\n```diff\n'
  cat "$diff_ok"
  printf '```\n'
} >"$work_tmp/text-ok"

reset_ctl
reset_wt
set_result "$work_tmp/text-ok"
run_adapter --mode patch --model example/model-1 -- "$wt" "$brief" docs-sweep
expect_status "4: a clean diff applies and the gate passes" 0
expect_text "4: reports the applied files" "$out" "APPLIED 1"
expect_text "4: the change is in the tree" "$(cat "$wt/docs/a.md")" "TWO"
if [ "$(git -C "$wt" rev-parse HEAD)" = "$head0" ] && [ -z "$(git -C "$wt" diff --cached --name-only)" ]; then
  ok "4: nothing is committed or staged"
else
  bad "4: nothing is committed or staged" "HEAD moved or index changed"
fi
expect_text "4: the agent ran in the worktree" "$(cat "$ctl/cwd")" "$wt"
names="$(tr '\n' ' ' <"$ctl/env-names")"
for allowed in COMMAND_CODE_API_KEY HOME LANG PATH TERM TMPDIR; do
  expect_text "4: child env has $allowed" "$names" "$allowed"
done
extra="$(grep -vxE 'COMMAND_CODE_API_KEY|HOME|LANG|PATH|TERM|TMPDIR|PWD|SHLVL|_|OLDPWD' "$ctl/env-names" | tr '\n' ' ')"
if [ -z "$extra" ]; then
  ok "4: child env holds only the allowed variables"
else
  bad "4: child env holds only the allowed variables" "extra: $extra"
fi
argv="$(cat "$ctl/argv")"
expect_no_text "4: patch argv has no --yolo" "$argv" "--yolo"
expect_no_text "4: patch argv has no permission bypass" "$argv" "dangerously"
expect_text "4: the prompt carries the brief" "$argv" "Change docs/a.md."
expect_text "4: the prompt forbids edits" "$argv" "Do not edit files"
expect_no_text "4: the key never reaches the output" "$out$err" "$secret"
expect_no_text "4: the child PATH drops the caller's other folders" "$(cat "$ctl/path")" "sentinel-bin"

reset_ctl
mkdir -p "$wt/.commandcode"
run_adapter --mode patch --model m -- "$wt" "$brief"
expect_status "4: an existing .commandcode exits 2 in patch mode" 2
rmdir "$wt/.commandcode"
for header in 'diff --git x/docs/a.md y/docs/a.md' 'diff --git "a/docs/a.md" "b/docs/a.md"'; do
  reset_ctl
  printf '```diff\n%s\n--- a/docs/a.md\n+++ b/docs/a.md\n@@ -1 +1 @@\n-one\n+ONE\n```\n' "$header" >"$work_tmp/text-header"
  set_result "$work_tmp/text-header"
  run_adapter --mode patch --model m -- "$wt" "$brief"
  expect_status "4: header '$header' exits 2" 2
done

reset_ctl
reset_wt
printf 'No change needed.\n' >"$work_tmp/text-none"
set_result "$work_tmp/text-none"
run_adapter --mode patch --model m -- "$wt" "$brief"
expect_status "5: no diff block exits 2" 2
expect_text "5: says there is no diff" "$err" "no diff block"

reset_ctl
{
  cat "$work_tmp/text-ok"
  printf '\n'
  cat "$work_tmp/text-ok"
} >"$work_tmp/text-two"
set_result "$work_tmp/text-two"
run_adapter --mode patch --model m -- "$wt" "$brief"
expect_status "5: two diff blocks exit 2" 2

reset_ctl
printf '```diff\nthis is not a diff\n```\n' >"$work_tmp/text-bad"
set_result "$work_tmp/text-bad"
run_adapter --mode patch --model m -- "$wt" "$brief"
expect_status "5: a malformed diff exits 2" 2

for evil in '../escape.txt' '.git/config' '/etc/x' 'docs/../../x' '.commandcode/settings.json'; do
  reset_ctl
  {
    printf '```diff\ndiff --git a/%s b/%s\nnew file mode 100644\n--- /dev/null\n+++ b/%s\n@@ -0,0 +1 @@\n+x\n```\n' \
      "$evil" "$evil" "$evil"
  } >"$work_tmp/text-evil"
  set_result "$work_tmp/text-evil"
  run_adapter --mode patch --model m -- "$wt" "$brief"
  expect_status "5: a diff touching $evil exits 2" 2
  expect_text "5: names the escaping path $evil" "$err" "outside the worktree"
done
if [ -z "$(git -C "$wt" status --porcelain)" ]; then
  ok "5: refused diffs leave the tree clean"
else
  bad "5: refused diffs leave the tree clean" "$(git -C "$wt" status --porcelain)"
fi

reset_ctl
printf '```diff\ndiff --git a/docs/link b/docs/link\nnew file mode 120000\n--- /dev/null\n+++ b/docs/link\n@@ -0,0 +1 @@\n+../../outside\n\\ No newline at end of file\n```\n' >"$work_tmp/text-symlink"
set_result "$work_tmp/text-symlink"
run_adapter --mode patch --model m -- "$wt" "$brief"
expect_status "5: a diff adding a symlink exits 2" 2
reset_ctl
printf '```diff\ndiff --git a/docs/a.md b/docs/a.md\nsimilarity index 100%%\nrename from docs/a.md\nrename to ../a.md\n```\n' >"$work_tmp/text-rename"
set_result "$work_tmp/text-rename"
run_adapter --mode patch --model m -- "$wt" "$brief"
expect_status "5: a rename out of the worktree exits 2" 2

reset_ctl
reset_wt
set_result "$work_tmp/text-ok"
printf '.commandcode/taste/taste.md\n' >"$ctl/write"
run_adapter --mode patch --model m -- "$wt" "$brief"
expect_status "5: a run that leaves agent state still applies" 0
if [ -e "$wt/.commandcode" ]; then
  bad "5: agent state in the worktree is removed" ".commandcode remains"
else
  ok "5: agent state in the worktree is removed"
fi

reset_ctl
reset_wt
sed 's/^-two$/-zwei/' "$work_tmp/text-ok" >"$work_tmp/text-stale"
set_result "$work_tmp/text-stale"
run_adapter --mode patch --model m -- "$wt" "$brief"
expect_status "6: git apply --check failure exits 2" 2
expect_text "6: says nothing was applied" "$err" "nothing applied"
expect_text "6: the file is unchanged" "$(cat "$wt/docs/a.md")" "two"

reset_ctl
reset_wt
{
  printf '```diff\ndiff --git a/docs/long.md b/docs/long.md\nnew file mode 100644\n--- /dev/null\n+++ b/docs/long.md\n@@ -0,0 +1,600 @@\n'
  awk 'BEGIN { for (i = 0; i < 600; i++) print "+line" }'
  printf '```\n'
} >"$work_tmp/text-long"
set_result "$work_tmp/text-long"
run_adapter --mode patch --model m -- "$wt" "$brief" line-cap
expect_status "7: a gate failure exits 1" 1
expect_text "7: names the failing gate" "$err" "gate line-cap failed"
if [ -f "$wt/docs/long.md" ]; then
  ok "7: the applied diff is left for inspection"
else
  bad "7: the applied diff is left for inspection" "file missing"
fi

reset_ctl
reset_wt
set_result "$work_tmp/text-ok"
printf '3\n' >"$ctl/exit"
run_adapter --mode patch --model m -- "$wt" "$brief"
expect_status "8: an agent failure exits 1" 1
expect_text "8: reports the agent exit" "$err" "agent exited 3"

reset_ctl
: >"$ctl/out"
run_adapter --mode patch --model m -- "$wt" "$brief"
expect_status "8: no final text exits 1" 1

printf '== review mode ==\n'
reset_ctl
reset_wt
printf 'VERDICT: PASS\n' >"$work_tmp/text-review"
set_result "$work_tmp/text-review"
result="$work_tmp/review.md"
run_adapter --mode review --model example/model-1 -- "$wt" "$brief" "$result"
expect_status "9: review exits 0" 0
first="$(head -n 1 "$result")"
expect_text "9: first line is the Model line" "$first" "Model: example/model-1"
expect_text "9: the review text follows" "$(cat "$result")" "VERDICT: PASS"
GOAT_MODEL_LINE="Example 1 (example/model-1) (Example / Agent)" \
  run_adapter --mode review --model example/model-1 -- "$wt" "$brief" "$result"
expect_text "9: GOAT_MODEL_LINE wins" "$(head -n 1 "$result")" "Model: Example 1 (example/model-1) (Example / Agent)"
ln -s "$work_tmp/elsewhere.md" "$work_tmp/review-link.md"
run_adapter --mode review --model m -- "$wt" "$brief" "$work_tmp/review-link.md"
expect_status "9: a symlinked result file exits 2" 2
expect_no_text "9: review argv has no --yolo" "$(cat "$ctl/argv")" "--yolo"
printf '== recorded model id ==\n'
reset_ctl
reset_wt
printf 'VERDICT: PASS\n' >"$work_tmp/text-review-id"
set_result "$work_tmp/text-review-id" "moonshotai/Kimi-K3.1-Pro"
result="$work_tmp/review-id.md"
rm -f "$result" "$result.model-id"
run_adapter --mode review --model other/requested -- "$wt" "$brief" "$result"
expect_status "23: a review with a recorded id exits 0" 0
expect_text "23: the Model line uses the recorded id" "$(head -n 1 "$result")" \
  "Model: moonshotai/Kimi-K3.1-Pro (Command Code / GOAT)"
expect_text "23: the sidecar holds the exact id" "$(cat "$result.model-id")" "moonshotai/Kimi-K3.1-Pro"
expect_text "23: stdout prints the exact MODEL line" "$out" "MODEL=moonshotai/Kimi-K3.1-Pro"
expect_no_text "23: the id is not case folded" "$out$(cat "$result")" "moonshotai/kimi-k3.1-pro"

reset_ctl
reset_wt
set_result "$work_tmp/text-ok" "moonshotai/Kimi-K3.1-Pro"
GOAT_KEEP_RUN=1 run_adapter --mode patch --model other/requested -- "$wt" "$brief"
expect_status "23: a patch with a recorded id exits 0" 0
expect_text "23: patch prints the exact MODEL line" "$out" "MODEL=moonshotai/Kimi-K3.1-Pro"
diff_out="$(printf '%s\n' "$out" | sed -n 's/^DIFF=//p')"
kept_dir="$(dirname "$diff_out")"
expect_text "23: the run folder records the exact id" "$(cat "$kept_dir/recorded-model-id")" "moonshotai/Kimi-K3.1-Pro"
if [ -n "$diff_out" ]; then
  rm -rf "$kept_dir"
fi

reset_ctl
reset_wt
jq -cn --rawfile t "$work_tmp/text-review-id" '{type: "result", finalText: $t}' >"$ctl/out"
result="$work_tmp/review-noid.md"
rm -f "$result" "$result.model-id"
run_adapter --mode review --model example/model-1 -- "$wt" "$brief" "$result"
expect_status "24: no model id in the output exits 1" 1
expect_text "24: says no single id" "$err" "no single model id"
if [ -f "$result" ]; then
  bad "24: no result is written without a model id" "result exists"
else
  ok "24: no result is written without a model id"
fi

reset_ctl
reset_wt
jq -cn --rawfile t "$work_tmp/text-ok" '{type: "result", finalText: $t}' >"$ctl/out"
run_adapter --mode patch --model example/model-1 -- "$wt" "$brief"
expect_status "24: a patch with no model id exits 1" 1
expect_text "24: the patch tree is unchanged" "$(cat "$wt/docs/a.md")" "two"

reset_ctl
reset_wt
{
  jq -cn --arg m example/model-1 '{type: "event", event: {type: "model_request_start", model: $m}}'
  jq -cn --arg m example/model-2 '{type: "event", event: {type: "model_request_end", model: $m}}'
  jq -cn --rawfile t "$work_tmp/text-review-id" '{type: "result", finalText: $t}'
} >"$ctl/out"
result="$work_tmp/review-mixed.md"
rm -f "$result" "$result.model-id"
run_adapter --mode review --model example/model-1 -- "$wt" "$brief" "$result"
expect_status "24: two different ids exit 1" 1

reset_ctl
{
  jq -cn --arg m "moonshotai/Kimi-K3.1-Pro" '{type: "event", event: {type: "model_request_start", model: $m}}'
  jq -cn --arg m "moonshotai/kimi-k3.1-pro" '{type: "event", event: {type: "model_request_end", model: $m}}'
  jq -cn --rawfile t "$work_tmp/text-review-id" '{type: "result", finalText: $t}'
} >"$ctl/out"
result="$work_tmp/review-case.md"
rm -f "$result" "$result.model-id"
run_adapter --mode review --model example/model-1 -- "$wt" "$brief" "$result"
expect_status "24: a case-only difference in ids exits 1" 1

reset_ctl
reset_wt
set_result "$work_tmp/text-review-id" "moonshotai/Kimi-K3.1-Pro"
result="$work_tmp/review-refuse.md"
rm -f "$result" "$result.model-id"
GOAT_MODEL_LINE="Example (other/model) (Example / Agent)" \
  run_adapter --mode review --model example/model-1 -- "$wt" "$brief" "$result"
expect_status "25: GOAT_MODEL_LINE without the recorded id exits 2" 2
expect_text "25: says what is missing" "$err" "recorded model id"
if [ -f "$result" ]; then
  bad "25: no result is written on a refused GOAT_MODEL_LINE" "result exists"
else
  ok "25: no result is written on a refused GOAT_MODEL_LINE"
fi

reset_ctl
set_result "$work_tmp/text-review-id" "moonshotai/Kimi-K3.1-Pro"
result="$work_tmp/review-line.md"
rm -f "$result" "$result.model-id"
GOAT_MODEL_LINE="Kimi (moonshotai/Kimi-K3.1-Pro) (Command Code / GOAT)" \
  run_adapter --mode review --model example/model-1 -- "$wt" "$brief" "$result"
expect_status "25: GOAT_MODEL_LINE with the exact id exits 0" 0
expect_text "25: the caller's label wins" "$(head -n 1 "$result")" \
  "Model: Kimi (moonshotai/Kimi-K3.1-Pro) (Command Code / GOAT)"

printf '== write mode refusals ==\n'
reset_ctl
reset_wt
set_result "$work_tmp/text-review"
run_adapter --mode write --model m -- "$main_repo" "$brief" docs
expect_status "10: the main checkout exits 2" 2
expect_text "10: asks for a linked worktree" "$err" "linked worktree"
printf 'dirty\n' >"$wt/untracked.txt"
run_adapter --mode write --model m -- "$wt" "$brief" docs
expect_status "10: a dirty tree exits 2" 2
rm -f "$wt/untracked.txt"
git -C "$main_repo" worktree add -q "$work_tmp/wt-detached" --detach
run_adapter --mode write --model m -- "$work_tmp/wt-detached" "$brief" docs
expect_status "10: a detached HEAD exits 2" 2
git -C "$main_repo" branch -q master
git -C "$main_repo" worktree add -q "$work_tmp/wt-master" master
run_adapter --mode write --model m -- "$work_tmp/wt-master" "$brief" docs
expect_status "10: the default branch exits 2" 2
mkdir -p "$wt/.commandcode"
run_adapter --mode write --model m -- "$wt" "$brief" docs
expect_status "10: an existing .commandcode exits 2" 2
rmdir "$wt/.commandcode"
for scope in '..' '/abs' '.' '.git' '.git/hooks' 'docs/../..' '.commandcode' '' 'docs*' 'd?cs' '/'; do
  run_adapter --mode write --model m -- "$wt" "$brief" "$scope"
  expect_status "10: scope '$scope' exits 2" 2
done
expect_not_called "10: no write refusal starts the agent"

git -C "$main_repo" remote add origin "$work_tmp/nowhere"
run_adapter --mode write --model m -- "$wt" "$brief" docs
expect_status "10: origin without origin/HEAD exits 2" 2
expect_text "10: says how to set it" "$err" "git remote set-head origin --auto"
git -C "$main_repo" update-ref refs/remotes/origin/feat/topic "$head0"
git -C "$main_repo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/feat/topic
run_adapter --mode write --model m -- "$wt" "$brief" docs
expect_status "10: the remote default branch exits 2" 2
git -C "$main_repo" remote remove origin
ln -s ../.. "$wt/docs/up"
git -C "$wt" add docs/up
git_c -C "$wt" commit -q -m link
run_adapter --mode write --model m -- "$wt" "$brief" docs
expect_status "10: a scope holding a tracked symlink exits 2" 2
reset_wt
expect_not_called "10: no write refusal starts the agent (2)"

printf '== write mode scope gate ==\n'
reset_ctl
reset_wt
printf 'docs/new.md\n' >"$ctl/write"
set_result "$work_tmp/text-review"
run_adapter --mode write --model m -- "$wt" "$brief" docs/
expect_status "11: an in-scope change exits 0" 0
expect_text "11: reports the change" "$out" "CHANGED 1"
expect_text "11: write argv passes --yolo" "$(cat "$ctl/argv")" "--yolo"
expect_text "11: the agent saw the deny settings" "$(cat "$ctl/settings-seen" 2>/dev/null)" '"Shell"'
expect_text "11: the deny settings cover .git" "$(cat "$ctl/settings-seen" 2>/dev/null)" ".git/**"
if [ -e "$wt/.commandcode" ]; then
  bad "11: the generated settings are removed" ".commandcode remains"
else
  ok "11: the generated settings are removed"
fi
if [ "$(git -C "$wt" rev-parse HEAD)" = "$head0" ]; then
  ok "11: nothing is committed"
else
  bad "11: nothing is committed" "HEAD moved"
fi
extra="$(grep -vxE 'COMMAND_CODE_API_KEY|HOME|LANG|PATH|TERM|TMPDIR|PWD|SHLVL|_|OLDPWD' "$ctl/env-names" | tr '\n' ' ')"
if [ -z "$extra" ]; then
  ok "11: write child env holds only the allowed variables"
else
  bad "11: write child env holds only the allowed variables" "extra: $extra"
fi

reset_ctl
reset_wt
printf 'docs/ok.md\nsrc/evil.txt\n' >"$ctl/write"
set_result "$work_tmp/text-review"
run_adapter --mode write --model m -- "$wt" "$brief" docs
expect_status "12: an out-of-scope change exits 1" 1
expect_text "12: names the out-of-scope path" "$out$err" "SCOPE FAIL src/evil.txt"
expect_text "12: in-scope paths pass" "$out$err" "SCOPE PASS docs/ok.md"
if [ -f "$wt/src/evil.txt" ]; then
  ok "12: the tree is left for inspection"
else
  bad "12: the tree is left for inspection" "file removed"
fi

reset_ctl
reset_wt
common="$(cd "$main_repo" && cd "$(git rev-parse --git-common-dir)" && pwd -P)"
mkdir -p "$common/info"
printf '*.log\n' >>"$common/info/exclude"
printf 'old\n' >"$wt/src/pre.log"
printf 'docs/ok.md\nsrc/new.log\n' >"$ctl/write"
set_result "$work_tmp/text-review"
run_adapter --mode write --model m -- "$wt" "$brief" docs
expect_status "12: a new ignored file out of scope exits 1" 1
expect_text "12: names the ignored path" "$out$err" "SCOPE FAIL src/new.log"
expect_no_text "12: an ignored file from before the run is not reported" "$out$err" "src/pre.log"
rm -f "$wt/src/pre.log" "$wt/src/new.log"
printf '' >"$common/info/exclude"

reset_ctl
reset_wt
printf 'docs/ok.md\n%s/hooks/post-checkout\n' "$common_abs" >"$ctl/write"
set_result "$work_tmp/text-review"
run_adapter --mode write --model m -- "$wt" "$brief" docs
expect_status "12: a change in the git directory exits 1" 1
expect_text "12: names the git directory" "$out$err" "git directory changed"
rm -f "$common_abs/hooks/post-checkout"

reset_ctl
reset_wt
printf 'docsx/near.md\n' >"$ctl/write"
set_result "$work_tmp/text-review"
run_adapter --mode write --model m -- "$wt" "$brief" docs
expect_status "12: a sibling prefix is not in scope" 1

reset_ctl
reset_wt
set_result "$work_tmp/text-review"
run_adapter --mode write --model m -- "$wt" "$brief" docs
expect_status "12: no change exits 1" 1
expect_text "12: says nothing changed" "$err" "changed nothing"

printf '== case-insensitive dot folders ==\n'
reset_ctl
reset_wt
for evil in '.COMMANDCODE/settings.local.json' '.Git/config'; do
  reset_ctl
  printf '```diff\ndiff --git a/%s b/%s\nnew file mode 100644\n--- /dev/null\n+++ b/%s\n@@ -0,0 +1 @@\n+x\n```\n' \
    "$evil" "$evil" "$evil" >"$work_tmp/text-case"
  set_result "$work_tmp/text-case"
  run_adapter --mode patch --model m -- "$wt" "$brief"
  expect_status "15: a diff touching $evil exits 2" 2
  expect_text "15: names the refusing path $evil" "$err" "outside the worktree"
done
if [ -z "$(git -C "$wt" status --porcelain)" ]; then
  ok "15: refused case variants leave the tree clean"
else
  bad "15: refused case variants leave the tree clean" "$(git -C "$wt" status --porcelain)"
fi
reset_ctl
reset_wt
for scope in '.COMMANDCODE' '.Git/hooks'; do
  run_adapter --mode write --model m -- "$wt" "$brief" "$scope"
  expect_status "15: write scope '$scope' exits 2" 2
done
expect_not_called "15: no case-variant scope starts the agent"

printf '== home read deny ==\n'
reset_ctl
mkdir -p "$work_tmp/home"
home_phys="$(cd "$work_tmp/home" && pwd -P)"
HOME="$work_tmp/home" run_adapter --mode write --model m --dry-run -- "$wt" "$brief" docs
expect_status "16: write dry-run with a home exits 0" 0
expect_text "16: the deny list reads every hidden home entry" "$out" "Read(/$home_phys/.*)"
expect_text "16: the deny list reads the hidden home subtree" "$out" "Read(/$home_phys/.*/**)"
expect_text "16: the deny list reads the home Library" "$out" "/Library/**)"

printf '== git directory content gate ==\n'
reset_ctl
reset_wt
printf 'docs/ok.md\n%s/refs/heads/sneaky\n' "$common_abs" >"$ctl/write"
set_result "$work_tmp/text-review"
run_adapter --mode write --model m -- "$wt" "$brief" docs
expect_status "17: a changed ref exits 1" 1
expect_text "17: names the changed git directory" "$out$err" "git directory changed"
rm -f "$common_abs/refs/heads/sneaky"

reset_ctl
reset_wt
index_path="$(cd "$wt" && cd "$(git rev-parse --git-dir)" && pwd -P)/index"
cp "$index_path" "$work_tmp/index-backup"
printf 'docs/ok.md\n%s\n' "$index_path" >"$ctl/write"
set_result "$work_tmp/text-review"
run_adapter --mode write --model m -- "$wt" "$brief" docs
expect_status "17: a changed worktree index exits 1" 1
expect_text "17: names the changed index" "$out$err" "git directory changed"
cp "$work_tmp/index-backup" "$index_path"
reset_wt

printf '== .commandcode inspection ==\n'
reset_ctl
reset_wt
printf 'docs/ok.md\n.commandcode/hooks.json\n' >"$ctl/write"
set_result "$work_tmp/text-review"
run_adapter --mode write --model m -- "$wt" "$brief" docs
expect_status "18: an extended .commandcode exits 1" 1
expect_text "18: reports the .commandcode change" "$out" "SCOPE FAIL .commandcode"
if [ -f "$wt/.commandcode/hooks.json" ]; then
  ok "18: the changed .commandcode is left for inspection"
else
  bad "18: the changed .commandcode is left for inspection" "folder removed"
fi
rm -rf "$wt/.commandcode"

reset_ctl
reset_wt
printf 'docs/ok.md\n.commandcode/taste/notes.md\n' >"$ctl/write"
set_result "$work_tmp/text-review"
run_adapter --mode write --model m -- "$wt" "$brief" docs
expect_status "18: the CLI taste state is allowed" 0
if [ -e "$wt/.commandcode" ]; then
  bad "18: the allowed .commandcode is removed" "folder remains"
else
  ok "18: the allowed .commandcode is removed"
fi

printf '== key redaction ==\n'
reset_ctl
reset_wt
touch "$ctl/leak"
printf '3\n' >"$ctl/exit"
set_result "$work_tmp/text-ok"
run_adapter --mode patch --model m -- "$wt" "$brief"
expect_status "19: a failing agent that leaks the key exits 1" 1
expect_no_text "19: the leaked key is not printed" "$out$err" "$secret"
expect_text "19: the leaked key is redacted" "$out$err" "<redacted>"

reset_ctl
reset_wt
printf 'Key is %s\n' "$secret" >"$work_tmp/text-leak"
set_result "$work_tmp/text-leak"
result="$work_tmp/review-leak.md"
run_adapter --mode review --model m -- "$wt" "$brief" "$result"
expect_status "19: a review echoing the key exits 1" 1
expect_no_text "19: the review refusal does not print the key" "$out$err" "$secret"
if [ -f "$result" ]; then
  expect_no_text "19: the key is not written to the result" "$(cat "$result")" "$secret"
fi
rm -f "$result"

printf '== pre-existing ignored files ==\n'
reset_ctl
reset_wt
common="$(cd "$main_repo" && cd "$(git rev-parse --git-common-dir)" && pwd -P)"
mkdir -p "$common/info"
printf '*.log\n' >>"$common/info/exclude"
printf 'old\n' >"$wt/src/pre.log"
printf 'docs/ok.md\nsrc/pre.log\n' >"$ctl/write"
set_result "$work_tmp/text-review"
run_adapter --mode write --model m -- "$wt" "$brief" docs
expect_status "20: an out-of-scope pre-existing ignored file exits 1" 1
expect_text "20: names the changed ignored file" "$out$err" "SCOPE FAIL src/pre.log"
rm -f "$wt/src/pre.log"
printf '' >"$common/info/exclude"

reset_ctl
reset_wt
mkdir -p "$common/info"
printf '*.log\n' >>"$common/info/exclude"
printf 'old\n' >"$wt/docs/pre.log"
printf 'docs/ok.md\ndocs/pre.log\n' >"$ctl/write"
set_result "$work_tmp/text-review"
run_adapter --mode write --model m -- "$wt" "$brief" docs
expect_status "20: an in-scope pre-existing ignored file exits 0" 0
rm -f "$wt/docs/ok.md" "$wt/docs/pre.log"
printf '' >"$common/info/exclude"

printf '== kit hygiene ==\n'
# Comment lines and refusal messages ("never passed", "Do not pass") are
# documentation, not launches.
hits="$(grep -rnE --exclude='*.md' -- '--yolo|dangerously-skip-permissions|permission-mode[ =]yolo' \
  "$repo_root/scripts" "$repo_root/templates" 2>/dev/null |
  grep -v -e '^[^:]*/scripts/agents/goat/run:' -e '^[^:]*/scripts/tests/' |
  grep -vE '^[^:]*:[0-9]+: *#' | grep -vE 'never|Do not' || true)"
if [ -z "$hits" ]; then
  ok "13: only the goat adapter passes --yolo"
else
  bad "13: only the goat adapter passes --yolo" "$hits"
fi
yolo_lines="$(grep -c -- '--yolo' "$adapter")"
if [ "$yolo_lines" -ge 1 ] && grep -- '--yolo' "$adapter" | grep -qv '^ *#'; then
  ok "13: the adapter holds the write-mode --yolo"
else
  bad "13: the adapter holds the write-mode --yolo" "$yolo_lines lines"
fi

printf '== rename and copy intent-to-add ==\n'
reset_ctl
reset_wt
{
  printf '```diff\n'
  cat <<'DIFF'
diff --git a/docs/a.md b/docs/moved.md
similarity index 100%
rename from docs/a.md
rename to docs/moved.md
DIFF
  printf '```\n'
} >"$work_tmp/text-rename"
set_result "$work_tmp/text-rename"
run_adapter --mode patch --model m -- "$wt" "$brief"
expect_status "21: a rename applies" 0
moved="$(git -C "$wt" ls-files -- docs/moved.md)"
if [ "$moved" = "docs/moved.md" ]; then
  ok "21: the rename target is tracked"
else
  bad "21: the rename target is tracked" "got: $moved"
fi

reset_ctl
reset_wt
{
  printf '```diff\n'
  cat <<'DIFF'
diff --git a/src/b.txt b/src/copied.txt
similarity index 100%
copy from src/b.txt
copy to src/copied.txt
DIFF
  printf '```\n'
} >"$work_tmp/text-copy"
set_result "$work_tmp/text-copy"
run_adapter --mode patch --model m -- "$wt" "$brief"
expect_status "21: a copy applies" 0
copied="$(git -C "$wt" ls-files -- src/copied.txt)"
if [ "$copied" = "src/copied.txt" ]; then
  ok "21: the copy target is tracked"
else
  bad "21: the copy target is tracked" "got: $copied"
fi

reset_ctl
reset_wt
{
  printf '```diff\n'
  cat <<'DIFF'
diff --git a/docs/a.md b/docs/edited.md
similarity index 66%
rename from docs/a.md
rename to docs/edited.md
--- a/docs/a.md
+++ b/docs/edited.md
@@ -1,3 +1,3 @@
 one
-two
+TWO
 three
DIFF
  printf '```\n'
} >"$work_tmp/text-rename-edit"
set_result "$work_tmp/text-rename-edit"
run_adapter --mode patch --model m -- "$wt" "$brief"
expect_status "21: a rename with a change applies" 0
edited="$(git -C "$wt" ls-files -- docs/edited.md)"
if [ "$edited" = "docs/edited.md" ]; then
  ok "21: the changed rename target is tracked"
else
  bad "21: the changed rename target is tracked" "got: $edited"
fi

reset_ctl
reset_wt
{
  printf '```diff\n'
  cat <<'DIFF'
diff --git a/docs/a*.md b/docs/a*.md
new file mode 100644
--- /dev/null
+++ b/docs/a*.md
@@ -0,0 +1 @@
+x
DIFF
  printf '```\n'
} >"$work_tmp/text-glob"
set_result "$work_tmp/text-glob"
run_adapter --mode patch --model m -- "$wt" "$brief"
expect_status "21: a new file with a glob character applies" 0
glob_path="$(git -C "$wt" ls-files -- ':(literal)docs/a*.md')"
if [ "$glob_path" = "docs/a*.md" ]; then
  ok "21: a new file with a glob character is tracked"
else
  bad "21: a new file with a glob character is tracked" "got: $glob_path"
fi

reset_ctl
reset_wt
{
  printf '```diff\n'
  cat <<'DIFF'
diff --git a/docs/sub/x.md b/docs/sub/x.md
new file mode 100644
--- /dev/null
+++ b/docs/sub/x.md
@@ -0,0 +1 @@
+x
DIFF
  printf '```\n'
} >"$work_tmp/text-subdir"
set_result "$work_tmp/text-subdir"
run_adapter --mode patch --model m -- "$wt" "$brief"
expect_status "21: a new file in a new subdirectory applies" 0
sub_tracked="$(git -C "$wt" ls-files -- docs/sub/x.md)"
if [ "$sub_tracked" = "docs/sub/x.md" ]; then
  ok "21: the new subdirectory file is tracked"
else
  bad "21: the new subdirectory file is tracked" "got: $sub_tracked"
fi

printf '== new files in the git directories ==\n'
git_abs="$(cd "$wt" && cd "$(git rev-parse --git-dir)" && pwd -P)"
for planted in "$common_abs/planted-top" "$git_abs/MERGE_HEAD" "$common_abs/objects/info/alternates"; do
  reset_ctl
  reset_wt
  printf 'docs/ok.md\n%s\n' "$planted" >"$ctl/write"
  set_result "$work_tmp/text-review"
  run_adapter --mode write --model m -- "$wt" "$brief" docs
  expect_status "22: a new file $(basename "$planted") in a git directory exits 1" 1
  expect_text "22: a new file $(basename "$planted") names the changed git directory" "$out$err" "git directory changed"
  rm -f "$planted"
done

reset_ctl
reset_wt
printf 'docs/ok.md\n%s/hooks/post-merge\n' "$common_abs" >"$ctl/write"
set_result "$work_tmp/text-review"
run_adapter --mode write --model m -- "$wt" "$brief" docs
expect_status "22: a new hook file post-merge exits 1" 1
expect_text "22: a new hook file post-merge names the changed git directory" "$out$err" "git directory changed"
rm -f "$common_abs/hooks/post-merge"

reset_ctl
reset_wt
printf 'docs/ok.md\n%s/logs/planted-log\n' "$common_abs" >"$ctl/write"
set_result "$work_tmp/text-review"
run_adapter --mode write --model m -- "$wt" "$brief" docs
expect_status "22: a new file under logs exits 1" 1
expect_text "22: a new file under logs names the changed git directory" "$out$err" "git directory changed"
rm -f "$common_abs/logs/planted-log"

reset_ctl
reset_wt
ln -s /nonexistent-target "$common_abs/planted-link"
printf 'docs/ok.md\n' >"$ctl/write"
set_result "$work_tmp/text-review"
run_adapter --mode write --model m -- "$wt" "$brief" docs
expect_status "22: a pre-existing symlink in the git directory does not fail a clean run" 0
rm -f "$common_abs/planted-link"
reset_ctl
reset_wt
printf 'docs/ok.md\n' >"$ctl/write"
set_result "$work_tmp/text-review"
run_adapter --mode write --model m -- "$wt" "$brief" docs
expect_status "22: a clean write run still exits 0" 0

printf '== through agent-launch ==\n'
reset_ctl
out="$(AGENT_OPS_KIT_CONFIG="$repo_root/templates/agent-config.example.json" \
  PATH="$work_tmp/bin:$PATH" "$launcher" --lane coding --as bot --dry-run -- "$wt" "$brief" 2>"$work_tmp/stderr")"
status=$?
err="$(cat "$work_tmp/stderr")"
expect_status "14: the coding lane dry-runs the goat entry" 0
expect_text "14: the command runs the goat adapter" "$out" "scripts/agents/goat/run"
expect_text "14: in patch mode" "$out" "--mode patch"
model_id="$(jq -r '[.lanes.coding.entries[] | select(.agent == "goat")][0].model' \
  "$repo_root/templates/agent-config.example.json")"
expect_text "14: with the configured model id" "$out" "--model $model_id"
expect_not_called "14: the launcher dry-run starts nothing"

printf 'goat adapter tests: %s passed, %s failed\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
  exit 1
fi
exit 0
