# Gate decision table G1 to G7

Use this table to decide, before and during one implementation job, whether the
development loop may continue. Each gate has a local input, a PASS condition,
and the action to take when PASS does not hold.

The table is for a coding agent and an operator. It needs no network and no
secrets. Ambiguous judgments use [`RUBRIC.md`](RUBRIC.md). The human pass is
[`CHECKLIST.md`](CHECKLIST.md).

## How to read a row

- **Input** is the local fact the gate needs.
- **PASS** is the only state that lets the loop continue unchanged.
- **Other** is the routing state when PASS does not hold. Some gates route to a
  judgment instead of a hard stop.
- **Action** is what the agent or operator does next.

## Machine table

| Gate | Name | Input | PASS | Other | Action |
| --- | --- | --- | --- | --- | --- |
| G1 | Checkout and worktree lock | Expected branch, required paths under `~/agy-work/<alias>`, count of open jobs and PRs | Branch and paths match, and the worktree/checkout lock holds: 1 PR / 1 Issue at a time for this job | Any mismatch, or a second active job | Do not start. Send a one-line FYI. Fix the checkout or close the other job first. |
| G2 | Soft-deny | Consecutive empty soft-deny count; current model lane | Count is under 2, or the run already switched to OpenCode | Empty soft-deny occurred twice in a row | Stop. Switch to OpenCode Flash. Never widen Allow. Report the exact command and reason. |
| G3 | Lock and matching constraint | Diff kind | Diff is only a lockfile plus the matching constraint file, so Argon SKIP applies as light review | Anything else: route to Argon-need judgment with tier A of the rubric. This is not an Argon skip. | Lock only: record the light-review skip. Else: label Argon need with tier A before review. |
| G4 | Draft | PR state and whether the operator explicitly said ready | PR is a draft, or it is ready and the operator explicitly said ready | Ready without an explicit operator instruction | Create or convert the pull request to draft. |
| G5 | Vulnerability silence | OSV, Dependabot, or other vulnerability findings | No finding is silently ignored | A finding is dropped without a recorded decision | Block and report the finding with its source. |
| G6 | RETRO ingest | `pr-merged` event plus an Issue comment whose first line is `## RETRO` | Marker present, so the ingest path may run | Marker absent | Stay quiet: v1 silence, no invented retro. Wait for a later marker. |
| G7 | One job | Count of implementation jobs and pull requests in this loop | 1 implementation job equals 1 PR | A second job or a second PR is requested | Refuse the new job, or send a completion report only. |

## Gate notes

### G1: checkout and worktree lock

G1 is the hard preflight. A failure means do not start. The worktree lock is a
job rule, not a git feature: one pull request and one Issue stay active for this
job, and a second job waits until the first closes.

### G2: soft-deny

A soft-deny is a permission refusal, `unknown_command`, or `unsupported_tool`
result. Stop and report the exact command and reason. An empty reply twice in a
row is the same signal. Use OpenCode Flash at that point. Do not widen Allow to
get past the refusal.

### G3: lock and matching constraint

G3 has a fixed orientation:

- Diff is only a lockfile plus the matching constraint file: Argon SKIP, light
  review.
- Any other diff: go to Argon-need judgment with tier A of the rubric, not
  Argon skip.

Do not describe the second branch as "Argon gate out" or "Argon skip". A
non-pass in G3 is a judgment about the first review, not permission to remove
the review. Keep re-review separate under item 2 of the rubric.

### G4: draft

Draft is the default. A ready pull request needs an explicit operator
instruction in the current job, not an inference from a merged earlier job.

### G5: vulnerability silence

Every OSV, Dependabot, or other vulnerability finding gets a recorded decision:
fix, accepted risk, or not applicable. Silence is not a decision.

### G6: RETRO ingest

G6 only opens the ingest path when the marker is present. Absent marker is not a
failure to repair. v1 stays quiet and does not invent a retro, a rule line, or a
memory write.

### G7: one job

One implementation job produces one pull request. A new request during an open
job gets a refusal or a completion report, not a second branch of work.

## Floors

These floors hold across every gate:

- Empty soft-deny twice: switch to OpenCode.
- No Allow widening mid-run.
- Draft pull request by default.
- No vulnerability silence.
- `## RETRO` absent: stay quiet.
- 1 job equals 1 PR.

## Named checks

[`../../scripts/dev-loop-gate.sh`](../../scripts/dev-loop-gate.sh) prints the
G1 to G7 table by default. It can also run one named check, so a single local
rule can gate a pull request without the full table.

```bash
scripts/dev-loop-gate.sh --check <id> [--strict] [--repo <root>] [--config <path>]
```

- `--check <id>` runs only that check and skips the G1 to G7 table.
  `line-cap` and `deploy-hash` exist today. Other ids, including `all`, exit 2
  with a message that the check is not implemented. Later checks will be added
  under the same flag.
- `--strict` turns advisory FAIL rows into a non-zero exit. Without it, a FAIL
  row is printed but the exit code stays 0, the same advisory spirit as G2 to
  G7.
- `--repo <root>` points the check at any git work tree. The default is the
  work tree of the current directory. All git calls run with `git -C`. Passing
  `--repo` with something that is not a git work tree exits 2.
- `--config <path>` reads a gate config. The default is
  [`gate.config.json`](gate.config.json) next to this file, resolved from the
  script location, so `--repo` can point at another checkout. A missing default
  config means a 500-line cap with no exceptions.

The default table needs neither a git work tree nor an installed `git`: outside
one it prints the usual G1 to G7 rows and reports the branch as `unknown`. Only
a named check requires both.

Exit codes:

| Code | Meaning |
| --- | --- |
| 0 | Pass, or an advisory FAIL without `--strict` |
| 1 | FAIL under `--strict`, or a G1 failure in the table |
| 2 | Usage error, unknown check, invalid config, or a `--repo` that is not a git work tree |
| 3 | A required command is missing (`git`, `jq`, or `curl`) while running a named check, or the deploy-hash library cannot be read |

### line-cap

`--check line-cap` lists tracked Markdown files with
`git ls-files -z -- '*.md'` and counts newlines the way `wc -l` does. Each file
is compared with its cap: the first matching exception cap, otherwise
`line_cap.default`. Untracked files are ignored.

The check prints one FAIL row per over-cap file, then one summary row. With
`--strict`, any over-cap file exits 1.

### deploy-hash

`--check deploy-hash` waits for a deployed asset hash to change. It reads a
public URL and compares one value with a baseline that the operator recorded
before the deploy. The helper never runs a deploy or a smoke test.

Record a baseline before the deploy, then wait after it:

```bash
baseline="$(scripts/dev-loop-gate.sh --check deploy-hash \
  --url https://example.com/ --print-current)"
# deploy here
scripts/dev-loop-gate.sh --check deploy-hash \
  --url https://example.com/ --baseline "$baseline"
```

Flags:

| Flag | Meaning |
| --- | --- |
| `--url <URL>` | Required. Must start with `https://` or `http://`. |
| `--source html\|etag` | Value source. Default `html`. |
| `--baseline <value>` | Value recorded before the deploy. Required unless `--print-current` is used. |
| `--timeout-sec <n>` | Wait limit in seconds. Default 600. |
| `--interval-sec <n>` | Poll interval in seconds. Default 15. |
| `--bundle-pattern <ERE>` | Asset pattern for the `html` source. The default matches a hashed asset such as `assets/app-1a2b3c4d.js`. |
| `--print-current` | Fetch once, print the value on stdout, and exit. |

These flags work only with `--check deploy-hash`. Any other use exits 2.

`--print-current` exits 0 and prints one value. It exits 3 when the value
cannot be read. Wait mode prints one PASS row when the value differs from the
baseline. Elapsed time is the sum of the poll intervals. At the timeout it
prints one FAIL row:
`no change after <n>s; do not run the live smoke yet`. Fetch errors are retried
until the timeout. When every attempt fails, the FAIL row names the source
error. Without `--strict` a FAIL row exits 0; with `--strict` it exits 1.

Sources:

- `html` fetches the page and takes the first match of the bundle pattern,
  sorted and unique. A page with no match counts as a fetch failure.
- `etag` sends a HEAD request and reads the `ETag` header. Quotes and a `W/`
  prefix are removed.

The helper sends no credentials, cookies, or custom auth headers, and it never
reads a token environment variable.

To add a source, define `deploy_hash_source_<name>` in
[`../../scripts/lib/deploy-hash.sh`](../../scripts/lib/deploy-hash.sh). It takes
the URL as its only argument, prints one value on stdout, and returns non-zero
on failure. Then pass `--source <name>`.

`DEV_LOOP_SLEEP_CMD` replaces the sleep command. It is a test hook; keep the
default outside tests.

`deploy-hash` is not a CI check. A live smoke after a deploy still needs the
maintainer's separate approval.

### gate.config.json

```json
{
  "line_cap": {
    "default": 500,
    "exceptions": []
  }
}
```

- `default` is a positive integer line cap.
- `exceptions` is an ordered list. The first matching entry wins.
- An entry has exactly one of `path` (an exact repository-relative path) or
  `pattern` (an anchored ERE), plus a positive integer `cap` and a non-empty
  one-line `reason`.
- A `pattern` must start with `^` and end with `$`. Do not use broad globs such
  as `.*` or `**`.
- Ship the repository with `exceptions: []`. The cap is a guardrail, not an
  allowlist.

Invalid config exits 2 with a message naming the failing field.

## Related

- [`RUBRIC.md`](RUBRIC.md): two-tier labels behind the ambiguous rows.
- [`CHECKLIST.md`](CHECKLIST.md): the one-page operator pass.
- [`../retro/README.md`](../retro/README.md): RETRO marker and ingest contract.
