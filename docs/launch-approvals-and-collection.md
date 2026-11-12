# Launch approvals and handoff collection

Gate every local launch on an operator-facing choice card, keep Allow
lists narrow, and collect each `agy` handoff in one Mac shell call. The
workstation setup and brief rules stay in
[`workstation-handoffs.md`](workstation-handoffs.md).

## Prefer card-style launch confirmation over growing Allow lists

Gate whether a workstation handoff starts with an operator-facing choice card
(or an equivalent one-tap confirmation). Expanding fine-grained Allow rules for
every new command is a weak primary control.

### Prefer a named choice card

When Grok Bot (or another orchestrator) prepares local work, present a short
card naming the deliverable, proposed lane, and one-sentence reason: run with
`agy`, run with `agent`, queue an agent job or human task, or cancel.

### Keep Allow lists narrow

Treat Auto-review Allow lists and Antigravity `permissions.allow` as a narrow
safety net for unattended tools the operator already trusts in that workspace.
Leave launch-class decisions on the choice card. Keep Ask-first confirmation
for destructive git operations, external sends, deletes outside the project
directory, and purchases.

### Orchestrator flow: propose, pick, then launch

1. Propose the matching lane and a short reason.
2. Wait for the operator to pick on the card (or cancel).
3. Launch only after that pick, unless standing permission covers that class.
4. For durable or deferred work that surfaces mid-conversation, queue human
   tasks in the task app and agent jobs in the private job hub instead of
   starting silently (see
   [Track human tasks in the task app and agent jobs in a private job hub](cast-and-routing.md#3-track-human-tasks-in-the-task-app-and-agent-jobs-in-a-private-job-hub)).

Choice cards decide whether to start. Scoped permissions and checkout locks
still apply during execution.

### Reduce local approval prompts

Keep **Grok local-execution approval** distinct from **Antigravity
`permissions.allow`**. Every workstation `Shell` call that Grok Bot sends with a
registered `machineId` can trigger a Grok local-execution approval card, even
when Antigravity CLI (`agy`) already has `permissions.allow` and
`trustedWorkspaces` configured on the workstation.

Configure Grok local execution and batch workstation calls to reduce prompt churn:

- **Narrow Allow for fixed checkout roots**: prefer a narrow Allow rule for Grok
  local execution scoped strictly to `~/agy-work` (and `~/agent-work` when local
  agent runs are used). Scoping to these roots lets routine status checks, brief
  file copies, script launches, and log reads proceed without raising an
  approval card on every call.
- **Keep Ask-first for sensitive operations**: never expand Allow to arbitrary
  local `Shell` commands or "always allow everything". Retain Ask-first
  confirmation for destructive git operations, external sends, deletes outside
  the project directory, and purchases. This Grok approval policy remains
  separate from Antigravity `permissions.allow` and headless soft-deny handling.
- **Batch workstation calls by phase**: combine pre-launch checks, brief writes,
  launch, and log inspection into as few `Shell` calls as practical (ideally
  `prepare`, `launch`, and `collect-result`). For `agy` documentation, call
  [`scripts/agy-docs-launch.sh`](../scripts/agy-docs-launch.sh) to start the
  worker and [`scripts/agy-docs-collect.sh`](../scripts/agy-docs-collect.sh) to
  inspect PID, git status, open PRs, and logs (see
  [`scripts/README.md`](../scripts/README.md)):

  ```bash
  ~/agy-work/grok-bot-ops/scripts/agy-docs-launch.sh <repo> ~/agy-inbox/<brief>.txt [stem] [model]
  ~/agy-work/grok-bot-ops/scripts/agy-docs-collect.sh <repo> [stem]
  ```

- **Confirm heavy launches once and rely on event signals**: gate heavy runs on
  an operator-facing choice card. After launch, wait for an event or callback
  signal instead of polling workstation shells or logs in a tight loop (see
  [Prefer event-driven completion over polling](cast-and-routing.md#prefer-event-driven-completion-over-polling)).
  Run `agy-docs-collect.sh` once after that signal to collect results.
- **Never auto-approve all local `Shell` calls to fix prompt fatigue**: do not
  expand Grok Auto-review Allow rules to cover arbitrary local commands, and
  never pass `--dangerously-skip-permissions` inside wrapper scripts.

### Prepare agy docs briefs without long Mac heredocs

Keep brief prep fast and low-approval with three rules that align with the
`prepare` → `launch` → `collect-result` phases above:

1. **Write long briefs on the Grok box, then copy them to the workstation**:
   create the Markdown brief under a box path such as
   `/workspace/agy-briefs/<brief>.md`, then use Grok's `CopyFromBox` into
   `~/agy-inbox/` on the registered workstation. Do **not** put a large
   heredoc (`cat <<'EOF' …`) into a workstation `Shell(machineId=…)` call.
   Local-execution approval can refuse or stall payloads that are too long to
   show for review.
2. **Reuse parent-provided facts instead of re-scanning the Mac**: if the
   parent chat or handoff already includes inventory, absolute path lists,
   trial tables, or log excerpts, embed those facts in the brief. Re-scan the
   workstation only for **missing** facts. Ideal prep before
   [`scripts/agy-docs-launch.sh`](../scripts/agy-docs-launch.sh) is one or two
   short Mac `Shell` calls plus `CopyFromBox`, not a chain of inventory
   commands that each raise an approval card.
3. **Split status language for brief prep versus worker launch**: say
   **「brief 準備中」** while the brief is still being written or copied, and
   **「agy 起動済み (PID=…, log=…)」** only after
   `agy-docs-launch.sh` (or an equivalent launch) has recorded a PID and log
   path. When the operator asks whether the worker started, answer from
   PID/log presence, not a vague "working".

After the brief file exists under `~/agy-inbox/`, prefer the launch and collect
wrappers in [`scripts/README.md`](../scripts/README.md) so launch and result
collection each stay one workstation `Shell` call.

### Unstructured and multimodal offload

Route **images, short videos, PDF understanding, and long messy logs** to
Antigravity CLI (`agy`, Gemini multimodal) when the work is understanding or
summarizing unstructured media. Grok Bot **routes** (absolute paths, brief,
done criteria) and returns a short summary; do not spend Grok tokens on large
binaries or OCR when `agy` can read the media directly.

Verified headless pattern:

```bash
agy --add-dir <media-dir> --add-dir <other-dir> -p "… @/absolute/path/to/file …"
```

- Prefer `@` absolute paths plus `--add-dir` for the directories that hold the
  media. Interactive Ctrl+V paste remains valid for official media types when
  the operator is supervising a live session.
- Read-only multimodal review may `--add-dir` media outside `~/agy-work`.
  **Writes** still stay under path-scoped `~/agy-work/<repo>` only (see
  [Fixed checkout roots](workstation-handoffs.md#fixed-checkout-roots)).
- Keep the same safety boundaries as other docs-lane handoffs: card-style
  launch confirmation, one `argv`-style command per `RunCommand`, soft-deny
  stop-and-report, no mid-run allow widen, and no
  `--dangerously-skip-permissions` (see
  [Prefer card-style launch confirmation](#prefer-card-style-launch-confirmation-over-growing-allow-lists)
  and [Headless agy soft-deny handling](#headless-agy-soft-deny-handling)).

### Headless agy soft-deny handling

Stop immediately and report the exact command or tool when a headless `agy -p`
run hits a permission denial or unsupported tool error; never widen permissions
mid-run.

Configure briefs and permissions for unattended Print mode (`agy -p`) with four
constraints in mind:

- **Path-scoped permissions remain limited**: `write_file(~/agy-work)` and
  `trustedWorkspaces` are required for `agy -p`, but do not authorize every tool
  alias or shell command. Actions needing interactive confirmation are soft-denied.
- **Interactive review modes soft-deny in Print mode**: policies such as
  `toolPermission=request-review` cause soft-denials because headless runs
  cannot prompt the operator.
- **Keep docs-lane briefs `write_file`-only**: do not ask `agy` to run git,
  `gh`, shell commands, or linters (including `npm` or `npx` lint). Grok Bot
  runs git and the draft PR at collect (see
  [Collect agy handoffs in one Mac shell](#collect-agy-handoffs-in-one-mac-shell-and-keep-reporting-thin)).
  If a worker must run a command, use one already in the allow list. Run one
  `argv`-style command per `RunCommand` call without shell chaining (see
  [Issue one command per tool call in headless CLI handoffs](workstation-handoffs.md#issue-one-command-per-tool-call-in-headless-cli-handoffs)).
- **Review allow-list changes offline after a stop**: on `soft-deny` or
  unsupported tool errors, stop and report the exact command and reason. Review
  and update allow rules offline before re-running.

## Collect agy handoffs in one Mac shell and keep reporting thin

Retrospective source: an earlier hub operations pull request.

### Keep these splits

- **`agy` is `write_file`-only.** Briefs for `agy` docs work never ask it to
  run git, `gh`, shell commands, or linters. `agy` writes the files; Grok Bot
  owns git and the draft pull request.
- **Grok Bot owns git and the draft PR.** After the handoff, Grok Bot runs the
  collect step: status, add, commit, push, and `gh pr create --draft` (or a
  follow-up commit on the open draft PR).
- **`.agy-facts/` stays out of commits.** Stage explicit paths; never add
  `.agy-facts/`.
- **End-to-end runs are not accuracy evaluation.** An e2e pass shows the
  pipeline ran. It does not measure answer quality. Report them separately.

### Rules

1. **One Epic comment after an Issue digest.** When an Issue digest posts to the
   hub and the work has an Epic, leave one comment on the Epic that states the
   phase and the scope now on `main`. In the same pass, fix stale owner paths
   (for example `<old-owner>/...` links that moved to `<new-owner>/...`).
2. **Collect includes commit and push.** Collect under `~/agy-work/<repo>` after
   a handoff means commit and push too, with `.agy-facts/` excluded. Keep
   Ask-first for destructive git operations, outbound sends, and deletes outside
   the project directory.
3. **One Mac shell for collect, then a one-line report.** Run collect as one
   workstation `Shell` call (status → add → commit → push → `gh pr`). Send one
   line to the operator and the ops channel with the PR URL. Skip mid-job chat.
   Coding goes to spare `agy` Claude headroom (see
   [`agy-quota-and-coding-lanes.md`](agy-quota-and-coding-lanes.md#coding-lane-order));
   Grok Bot does collect and final judgment.

See also: [`docs/agy-quota-and-coding-lanes.md`](agy-quota-and-coding-lanes.md),
[`docs/zenn-ja-writing-lane.md`](zenn-ja-writing-lane.md),
[`docs/opencode-thrift.md`](opencode-thrift.md).
