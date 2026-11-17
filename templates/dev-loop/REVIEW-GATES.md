# Review gates

Two named checks of [`../../scripts/dev-loop-gate.sh`](../../scripts/dev-loop-gate.sh)
guard the model review loop. Both are deterministic and fail closed: any FAIL
row exits 1, with or without `--strict`. Neither calls a model.

- `review-ready` runs before a review starts. A model review is the most
  expensive step in the loop, so it should never spend its budget on a red
  build, a moving head, or a rule a script can check.
- `review-citations` runs before a review comment is posted. A comment that
  cites `path:line` for a line that does not exist at the reviewed head sends
  the author to the wrong place.

## review-ready

```bash
scripts/dev-loop-gate.sh --check review-ready --pr <n> --expect-head <sha> \
  [--gh-repo <owner/repo>] [--repo <checkout>] [--test-log <path>] \
  [--evidence-out <path>]
```

`--pr` and `--expect-head` are required (or `DEV_LOOP_PR` and
`DEV_LOOP_EXPECT_HEAD` when the flag is absent). The check reads
`gh pr view <n> --json headRefOid,statusCheckRollup` and prints `RR` rows:

| Row | PASS when | FAIL action |
| --- | --- | --- |
| `head` | The live PR head starts with `--expect-head` | Re-read the PR and pass the current head |
| `checkout` | `--repo` is checked out at that head | Check out the PR head before review |
| `ci` | Every check run is `COMPLETED` with `SUCCESS`, `NEUTRAL`, or `SKIPPED`, and every status context is `SUCCESS` | Names the failing or pending checks |
| one row per named check | `--strict --check <id>` passes on the checkout | Run that check and fix its rows |
| `review-ready` | No row failed | Number of failed rows |

No reported checks is a FAIL: wait for CI before review. A `STALE` or any
other conclusion counts as failing. The `checkout` row also fails when tracked
files have uncommitted changes, because the named checks read the work tree.
The named checks default to `line-cap docs-sweep prose-dashes md-links
model-ids`; a default id this kit version does not implement yet is a `SKIP`
row, so the list can name checks that land later. `DEV_LOOP_REVIEW_READY_CHECKS`
overrides the list, and there an unknown id is a FAIL, so a typo never turns a
check off.

On PASS, `--evidence-out <path>` gets a `## Machine evidence (settled; do not
re-check)` block: the full head SHA, each CI check with its conclusion, the
rows above, and the last 40 lines of `--test-log` when given. On FAIL nothing
is written. A symlinked evidence path exits 2.

Exit codes: 0 pass, 1 any FAIL, 2 usage error (missing `--pr` or
`--expect-head`, unreadable `--test-log`, symlinked `--evidence-out`), 3 `gh`
or `jq` missing, a `gh` failure, or unreadable `gh` output.

### Launcher preflight

A lane in the agent config can set `"preflight": "review-ready"` (the only
accepted value). [`../../scripts/agent-launch.sh`](../../scripts/agent-launch.sh)
then requires `--pr <n>` and `--expect-head <sha>` for that lane (missing:
exit 2) and runs the check before any agent starts, with `--repo` set to
`--checkout <path>` or the current directory and `--test-log <path>` passed
through, and `--gh-repo <owner/repo>` when the pull request lives in another
repository than the checkout's remote. A FAIL exits 1 with `no agent started`. On PASS the evidence path is
exported as `AGENT_LAUNCH_EVIDENCE`, and the agy adapter appends the block to
the run's `BRIEF.md` once, so the reviewer reads the settled facts instead of
re-checking them. `--dry-run` runs the preflight and prints
`PREFLIGHT=review-ready PASS` and `EVIDENCE=<path>`. The evidence folder stays
in `TMPDIR` after a PASS as a record of what the review was told. The example config sets
the preflight on the `review` and `security-review` lanes.

## review-citations

```bash
scripts/dev-loop-gate.sh --check review-citations --comment <file> \
  --expect-head <sha> [--repo <checkout>]
```

The check reads the comment file and finds citations of the forms `path:N`,
`path:N-M`, `path:LN-LM`, comma lists such as `path:3,9-12` (each line is
checked), an optional `:column` suffix, and `path#LN-LM`. URLs are skipped. A
file tracked at HEAD is a citation whatever its name (`Makefile:3`,
`.gitignore:2`). An untracked word counts only when it looks like a path, with
a slash or a source or doc extension such as `.sh` or `.md`; other words such
as `host:443` are prose. `--repo` must be
checked out at `--expect-head`, so the citations are resolved against the head
the review saw. Each bad citation prints one `RC` FAIL row, and a summary row
counts all of them:

| FAIL action | When |
| --- | --- |
| `not a tracked file at <head>` | The path is not a file in the HEAD commit |
| `line N is past the end (M lines at <head>)` | A cited line is beyond the file's last line |
| `line 0 is not a valid line` | A citation of line 0 |
| `reversed range` | A range such as `:20-10` |

Line counts come from `git show HEAD:<path>`, not the work tree, so local edits
do not change the result. A comment with no citations passes with one row
saying so. Any FAIL exits 1, and so does a checkout at another head. A missing
or unreadable comment file, or a missing, non-hex, or shorter than 7
`--expect-head`, exits 2. Hex case does not matter.
