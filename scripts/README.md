# Workstation wrapper scripts for headless `agy` handoffs

Use [`agy-docs-launch.sh`](agy-docs-launch.sh) and
[`agy-docs-collect.sh`](agy-docs-collect.sh) to collapse a workstation
documentation handoff into one `Shell` call for launch and one `Shell` call for
collection. Batching by phase reduces Grok local-execution approval cards
without widening Auto-review Allow lists or Antigravity permissions.

See [`../docs/workstation-handoffs.md`](../docs/workstation-handoffs.md) for the
full workstation handoff rules.

## Run launch and collection in two workstation shell calls

Write long briefs on the Grok box and `CopyFromBox` them into `$HOME/agy-inbox/`
instead of a large Mac heredoc (see
[Prepare agy docs briefs without long Mac heredocs](../docs/launch-approvals-and-collection.md#prepare-agy-docs-briefs-without-long-mac-heredocs)).
Call one workstation `Shell` per phase after the brief exists under
`$HOME/agy-inbox/`:

1. **Launch (`agy-docs-launch.sh`)**: validates that `<repo>` is a plain
   basename, verifies that `$HOME/agy-work/<repo>` exists and resolves inside
   `$HOME/agy-work`, verifies that `<brief-path>` resolves inside
   `$HOME/agy-inbox/`, resolves the model (default `gemini-3.8-flash-medium`;
   overridden by the optional 4th argument, `AGY_DOCS_MODEL`, or `AGY_MODEL`),
   generates per-run settings (see
   [Docs launches generate per-run settings](#docs-launches-generate-per-run-settings)),
   starts `agy --project "$HOME/agy-work/<repo>" --model "$model" --settings
   <settings> -p`, writes `$HOME/agy-inbox/<stem>.pid`, `<stem>-stdout.log`,
   and `<stem>-stderr.log`, and waits for the run to finish (see
   [Shared launch retry](#shared-launch-retry)). Operators who need a
   detached session can run the launcher itself under a terminal multiplexer
   or `nohup`.

   ```bash
   scripts/agy-docs-launch.sh <repo> ~/agy-inbox/<brief>.txt [log-stem] [model]
   ```

   The script defaults to Gemini 3.8 Flash (`gemini-3.8-flash-medium`) because
   larger models exhaust Individual quota (429) more quickly. Override the
   model via the 4th argument, the `AGY_DOCS_MODEL` environment variable, or
   `AGY_MODEL` (resolved in that order).

2. **Collect (`agy-docs-collect.sh`)**: inspects the recorded PID file (or falls
   back to process lookup), prints `git status -sb`, current branch, the last
   three commits, up to five open pull requests via `gh pr list`, and the last
   80 lines of the stdout and stderr logs.

   ```bash
   scripts/agy-docs-collect.sh <repo> [log-stem]
   ```

## Review launches generate per-run settings

[`agy-review-launch.sh`](agy-review-launch.sh) prepares a model-review run
folder and writes its `settings.json` on every launch from
[`templates/agy-review-settings.json`](templates/agy-review-settings.json). The
template has one variable, `@RUN_DIR@`, and the launcher replaces it with the
resolved physical run folder path, so a copied settings file cannot point at an
older run.

```bash
scripts/agy-review-launch.sh <run-name> <repo-checkout> <brief-path> [model]
```

Flow:

1. `<run-name>` must be a plain token (`[A-Za-z0-9._-]+`, not `.` or `..`, no
   leading `-`). The run folder is `$HOME/agy-work/runs/<run-name>`; the
   launcher refuses a symlinked folder or one that resolves outside that root.
2. `<repo-checkout>` must exist and resolve inside `$HOME/agy-work`.
   `<brief-path>` must be readable; when it is not already `<run>/BRIEF.md`,
   the launcher copies it there.
3. The launcher regenerates `<run>/settings.json` from the template and
   overwrites any existing file. It never reads settings from another run
   folder.
4. [`lib/agy-settings-check.sh`](lib/agy-settings-check.sh) parses
   `.permissions.allow[]` and fails when an entry is empty, is not a strict
   `name(argument)` entry with one parenthesis-free argument, or resolves
   outside the run folder, including escapes through `..` or a symlink. Every
   non-`command` argument is treated as a path; wildcards, an empty allow list,
   a non-string entry, invalid JSON, or a symlinked settings file also fail.
5. After the check passes, a launch refuses a symlinked `settings.json`,
   `BRIEF.md`, generated settings temp file, `agy.log`, `agy.stderr.log`, or
   `agy.pid`. It then starts `agy` with cwd set to the run folder and writes
   those three files. Idle-sleep wrapping and the single automatic relaunch
   are provided by the shared helper (see
   [Shared launch retry](#shared-launch-retry)).

Use `--dry-run` to create the run folder and settings, run the check, and print
the command (including `caffeinate -i` when the wrapper would be used) without
starting `agy`. Use `--check-settings <settings.json> <run-dir>` to run only
the check on an existing file. Neither flag waits or retries, and neither has
side effects beyond the folder and settings already created for the dry run.

The launch keeps the existing guarantees: no
`--dangerously-skip-permissions`, no edits to global Antigravity settings, and
`--settings` stays session-only. The model defaults to `gemini-4-argon-medium`;
the fourth argument or `AGY_REVIEW_MODEL` overrides it.

## Docs launches generate per-run settings

[`agy-docs-launch.sh`](agy-docs-launch.sh) uses the same generation and check
as the review launcher, from [`lib/agy-settings-check.sh`](lib/agy-settings-check.sh).
The write root is the resolved checkout `$HOME/agy-work/<repo>`:

1. On every launch it writes `$HOME/agy-inbox/<stem>.settings.json` from
   [`templates/agy-docs-settings.json`](templates/agy-docs-settings.json),
   replacing `@RUN_DIR@` with the checkout path. It overwrites any existing
   file, never reads settings from another run, and never writes into the
   checkout, so `git status` stays clean.
2. The check from step 4 above runs with the checkout as the run folder. An
   entry that points at another checkout, or escapes through `..` or a
   symlink, fails before launch with a message that names the entry and its
   resolved path.
3. The launcher refuses a symlinked checkout, settings file, settings temp
   file, PID file, or log file, and a checkout path that holds a quote,
   backslash, parenthesis, wildcard, or control character. It then passes the
   file as `--settings`, which stays session-only. Idle-sleep wrapping and
   the single automatic relaunch are provided by the shared helper (see
   [Shared launch retry](#shared-launch-retry)). The launcher now waits for
   the worker; that is a contract change from the earlier fire-and-forget
   `nohup` start.

The template allows `write_file` on the checkout plus the same read-only
commands as the review template. It narrows what a docs worker may do and never
widens an allow list; run `git` and `gh` steps outside the worker. The usage
signature and printed lines stay the same, plus a new `SETTINGS=` line.

## Shared launch retry

[`agy-review-launch.sh`](agy-review-launch.sh) and
[`agy-docs-launch.sh`](agy-docs-launch.sh) both source
[`lib/agy-launch-run.sh`](lib/agy-launch-run.sh). The helper owns idle-sleep
wrapping and the single automatic relaunch budget; that logic must not live
in only one of the two launchers.

- On macOS (`uname -s` is `Darwin`), when `caffeinate` is on `PATH`, the
  helper holds an idle-sleep assertion with `caffeinate -i` for the lifetime
  of `agy` (Apple `caffeinate(8)`). On Linux, or when `caffeinate` is
  missing, `agy` starts unwrapped; a missing binary is not an error.
- The helper waits for the run. It retries **exactly once, in total**, when
  stdout is empty (0 bytes or missing), when stderr contains the official
  headless auto-deny notice (`headless mode cannot prompt for`), or when
  both stdout and stderr stop growing for `AGY_LAUNCH_STALL_SECONDS`
  (default 900 seconds; set to `0` to disable) while the child PID is still
  alive (`kill -0` only; the helper never inspects process arguments). The
  stall fallback is conservative: official headless mode auto-denies tools
  that need approval and exits rather than hanging on a prompt. A second
  empty, auto-deny, or stall result exits 1 (fail closed) and asks the
  operator to inspect the logs. Do not add allow-rules or pass
  `--dangerously-skip-permissions`.
- An auto-deny or stall retry appends this instruction to a new brief file
  and leaves the original brief unchanged: "use simple commands one at a
  time; no pipes, no redirects, no regex special characters." A generic
  empty-output retry does not append that instruction.
- Empty stdout is still 0 bytes or missing. Whitespace-only counts as
  non-empty. A non-empty review log without a `VERDICT` line is a review
  quality issue, not a launch failure, and does not retry.
- **A relaunch consumes model quota again.** Treat the automatic retry as a
  second paid/quota run, not a free restart.
- The helper never edits that run's `settings.json`, never widens an allow
  list, never touches global Antigravity/agy settings, and never reads or
  writes secrets.

## Safety boundaries remain unchanged

Keep every existing launch confirmation and permission boundary in place when
using the wrapper scripts:

- **Choice cards still gate heavy launches**: the operator confirms on the chat
  choice card or widget before Grok Bot invokes `agy-docs-launch.sh`.
- **No permission escalation**: no launcher passes
  `--dangerously-skip-permissions`, edits the global Antigravity
  `settings.json`, or widens Grok Auto-review Allow rules. The per-run settings
  only narrow the session.
- **Headless soft-deny still stops the worker**: if the `agy -p` worker hits a
  `soft-deny`, `unknown_command`, or `unsupported_tool` error, it stops and
  reports the exact command and reason so the operator can review permissions
  offline.
- **One `argv`-style command per worker tool call**: inside the `agy` session,
  the worker must still issue one simple command per `RunCommand` tool call and
  keep `git` and `gh` invocations separate.

## Local gate checks

[`dev-loop-gate.sh`](dev-loop-gate.sh) prints the G1 to G7 table and runs the
`line-cap` and `docs-sweep` checks. The table also runs an `npm-ci` preflight
that fails when `package-lock.json` sits beside a missing `node_modules`;
`--check npm-ci` runs that rule alone. A `node-pin` preflight fails when the
local Node major or a workflow departs from the `.nvmrc` or `engines.node`
pin; `--check node-pin` runs that rule alone. The script also runs a `pr-state`
check that reads one pull request through `gh`, and a `deploy-hash` check that
waits for a deployed asset to change. `pr-state` and `deploy-hash` are the
networked paths. See
[`../templates/dev-loop/GATES.md`](../templates/dev-loop/GATES.md#named-checks).

[`dependabot-red-prs.sh`](dependabot-red-prs.sh) is the read-only weekly
hygiene check for open Dependabot pull requests. It flags a pull request whose
checks are red or that has stayed open longer than `--days` (default 3), and it
never comments, closes, rebases, or merges. See
[`../docs/security-audit-lanes.md`](../docs/security-audit-lanes.md#flag-red-dependabot-pull-requests-weekly).

[`work-graph.sh`](work-graph.sh) prints two read-only views of stuck work; run
`scripts/work-graph.sh --help` for its output and options.

## Prepare a coding-agent task issue

Use [`agent-task-issue.sh`](agent-task-issue.sh) when a bot must write a
coding, review, or docs task as a GitHub Issue before any coding agent
works on it. The issue is the single task spec. For `agy`, the maintainer
hands the issue over and runs it by hand; bots never launch `agy`.

```bash
scripts/agent-task-issue.sh --agent opencode --repo OWNER/REPO \
  --title "..." --file path/to/filled.md
```

Copy [`../templates/agent-task-issue.md`](../templates/agent-task-issue.md),
fill every placeholder, and pass the filled copy with `--file`, or pass the
section flags instead. `--agent` is required and must be one of the allowed
agent names. `--dry-run` prints the rendered body and calls no `gh` command.
The target repository comes from `--repo`, `AGENT_TASK_REPO`, or the local
`agent-ops-kit/agent-task-repo` config file. Creating a missing `agent-task` or
`agent:<name>` label requires `--create-label`; without that flag the script
fails and creates nothing.

## Check rate limiting on one URL

[`rate-limit-check.sh`](rate-limit-check.sh) sends a sequential burst to one URL
and reports whether the limit is enforced. Use `--mode enforce` to require a
429 with a `Retry-After` inside the window, or `--mode detect` to fail when
every response succeeds on a route that should be limited. The script sends no
credentials, cookies, or custom auth headers, and it never follows redirects.
A live URL run stays a manual step; tests use a local fixture server.

```bash
scripts/rate-limit-check.sh --base-url https://example.com \
  --path /health --limit 100 --window 60 --mode detect
```

Exit codes: 0 pass, 1 check failed (including transport errors), 2 usage error,
3 curl missing. The Durable Object limiter it verifies lives in
[`../templates/workers-do-rate-limiter/`](../templates/workers-do-rate-limiter/README.md).

## Deploy a Worker through one shared script

[`worker-deploy.sh`](worker-deploy.sh) runs the preflight and the deploy for one
Worker, so a maintainer machine and the reusable workflow execute the same
steps. The preflight runs `npm ci`, a typecheck, the package tests, and
`npx --no-install wrangler deploy --dry-run`. Deploy mode repeats the preflight,
then runs `npx --no-install wrangler deploy`, prints `version_id=<id>` on stdout,
and appends the same line to `GITHUB_OUTPUT` when that file is set.

```bash
scripts/worker-deploy.sh --dir <worker-dir> --mode preflight
scripts/worker-deploy.sh --dir <worker-dir> --mode deploy
```

The optional post-deploy smoke and rate-limit hook stay off by default. The
script refuses shell xtrace and redacts token, secret, password, and key values
from all child output. Exit codes: 0 okay, 1 preflight, deploy, smoke, or hook
failure, 2 usage error, 3 required command missing. See
[`../docs/worker-deploy.md`](../docs/worker-deploy.md) for the reusable workflow,
token wiring, concurrency, and rollback.
