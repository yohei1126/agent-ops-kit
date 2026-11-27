# Development loop rules

Rules distilled from retrospectives of agent-driven coding, review,
verification, and deployment. They guide operators, domain bots, and coding
lanes across task planning, review gates, live verification, and release
hygiene.

## How lessons are placed

When turning a retrospective into an operational lesson, prefer in order:

1. **Fix the setup**: address the underlying tool, permission, or configuration
   directly.
2. **Encode a mechanical check**: add or update a gate script, CI check, or
   verification checklist (see [`GATES.md`](../templates/dev-loop/GATES.md)).
3. **General rule or skill**: encode the practice in a shared rule or reusable
   skill.
4. **Assistant memory last**: use assistant memory as a last resort, always
   recording its source.

Write the general principle, not the story. Hard limits also belong in each
bot's description, because copying a bot copies its description but not its
memory.

## Planning and briefs

Follow these rules when preparing plans and briefs for coding lanes:

- **Edge-case table for routines and ingest contracts**: plans for routines or
  ingest contracts include an edge-case table: multiple locations, edits and
  replacements, day and window boundaries, failure notification, and no-op
  conditions. Aim for one batch of fixes, each with its decision attached,
  approved by the operator in one round-trip.
- **Expected checkout state**: issues that change stateful launcher or lane
  behavior state the expected checkout state before and after the job: branch,
  HEAD, clean tree, and cleanup target.
- **Update affected gate tests in the same pass**: when a gate is added, the
  coding spec lists the existing tests that pass through that path so they are
  updated in the same pass.
- **Immediate decision cards on contract questions**: when review raises a
  contract or configuration decision, send the operator one decision card
  immediately, recommended option first, rather than waiting for the fix pass.
  Close superseded cards explicitly.
- **Fail-closed auth and live contract verification**: verify real service
  behavior with contract tests before writing runbook acceptance criteria. Auth
  and identity acceptance is fail-closed from the first draft. Live acceptance
  gets a one-screen preflight (real IDs set, evidence arguments ready) and a
  separate operator approval.
- **Verified example outputs**: example outputs in plans (orderings, row counts)
  come only from a real run or a fixture; otherwise label them "example
  (unverified)".
- **Topic lock and locale assets**: start implementation only after the topic or
  subject is locked; a plan before the lock is fine. Public demo or UI assets
  ship in every supported locale (at least label and description) and the brief
  says so.
- **Default review targets to open pull request**: review points that arrive
  without a target default to the open pull request under discussion; confirm the
  target in one line before opening a new issue or touching another repository.
- **Doc-role rules in briefs**: docs briefs carry the doc-role rules from the
  first pass: README is high-level for humans and tool-agnostic, AGENTS.md is
  high-level for agents, CONTRIBUTING.md holds contributor steps, details go in
  `docs/`, with no duplication. A docs file at its line cap is split in the same
  change.

## Review gate

Apply automated reviews and follow-up routing according to these standards:

- **Automatic first model review on critical paths**: start a first model
  review automatically, without asking, once deterministic checks pass
  (`--check review-ready --help`). Which paths require a review is
  `--check model-check-required --help`.
- **Coding model fixes and transparency**: findings are fixed by a coding
  model. Review results name the model used.
- **Targeted re-review**: no re-review by default; re-review only unresolved
  blocker or major findings on the assigned model (freshness is enforced by
  `--check model-check-fresh --help`), and send nits to a cheap lane.
- **Fix on harm**: do not fix minor findings until they cause real harm.
  Comment-only nits never block merge; batch them into the next docs pull
  request.
- **Findings become tests**: a review finding turns into a deterministic CI
  test, not only prose, so the same defect cannot return.
- **Merge the base branch, do not rebase**: merge the base branch into an open
  pull request branch and drop merge-conflict comment lines to keep history.
- **Skip a re-check only narrowly**: after a conflict resolution, skip the
  re-check only when the resolution touched tests alone and CI is green.
- **Review while still a draft**: G4 enforces draft state; see
  `scripts/dev-loop-gate.sh --help`. After deterministic checks
  (`--check review-ready --help`), post one Argon review before announcing
  the pull request.
- **Docs-only pull requests**: deterministic checks are the main gate, then
  at most one Argon review.
- **Light review for lockfile and constraint pairs**: G3 routes
  lockfile-plus-constraint diffs to fixed checks; see
  [`GATES.md`](../templates/dev-loop/GATES.md). Never silence a vulnerability
  (G5).

## Verification and completion reports

Verify deliverables thoroughly before presenting completion reports:

- **Scripted browser acceptance**: acceptance checks that need a real browser
  (GPU features, in-browser models, CSP, downloads) run from the start as a
  repository script driving a headed browser with a clean profile on the
  workstation. Hand a manual check to the operator only when the script cannot
  run, and assume they may be on a phone.
- **Wait for deployed asset before live tests**: wait until the served asset
  matches the merged build; see `--check deploy-hash --help`.
- **Re-fetch live pull request state**: completion reports re-fetch pull request
  state (draft, mergeability, CI) right before reporting; never reuse state from
  creation time.
- **Operator owns draft and ready transitions**: agents never change a pull
  request's draft or ready state; the operator owns it, and every coding brief
  says so.

## Deploy and publish setup

Follow these operational requirements for deployment and release pipelines:

- **Verify UI flows at planning time**: at planning time, verify the target
  platform's UI flow against official docs or the live dashboard. The settings
  table names which UI screen each value goes in and whether a config file is
  required.
- **Publish checklists and registry options**: publish checklists carry, from
  the first draft, a table of the recommended value for every registry UI option
  (for example trusted publishing on, two-factor required, long-lived tokens
  disallowed) plus the publish mode the script actually assumes, verified in
  code before recommending a different UI setting.
- **Git-connected serverless builds**: for Git-connected serverless builds: the
  platform's Git app is installed on the organization that owns the
  repository; preview builds need both the config block and the dashboard
  toggle; reading build logs from automation needs a read-scoped API token,
  which only the operator creates.
