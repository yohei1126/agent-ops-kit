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

# set_result <text file>: the stub prints one result event with that text.
set_result() {
  jq -cn --rawfile t "$1" '{type: "result", finalText: $t}' >"$ctl/out"
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
expect_text "2: the deny list covers ssh keys" "$out" "/.ssh/**)"
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

for evil in '../escape.txt' '.git/config' '/etc/x' 'docs/../../x'; do
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
for scope in '..' '/abs' '.' '.git' '.git/hooks' 'docs/../..' '.commandcode' ''; do
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
