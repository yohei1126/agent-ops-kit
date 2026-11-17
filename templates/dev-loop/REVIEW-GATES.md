# Review gates

Two named checks of [`../../scripts/dev-loop-gate.sh`](../../scripts/dev-loop-gate.sh)
guard the model review loop. Both are deterministic and call no model.

- `review-ready` runs before a review starts. A model review is the most
  expensive step in the loop, so it should never spend its budget on a red
  build, a moving head, or a rule a script can check.
- `review-citations` runs before a review comment is posted. A comment that
  cites `path:line` for a line that does not exist at the reviewed head sends
  the author to the wrong place.

## Design decisions

- **Fail closed, not advisory.** Unlike the G2 to G7 rows, any FAIL exits 1
  even without `--strict`. A review that starts on a red head, or a comment
  that points at a missing line, is wasted work, so there is no advisory
  mode to forget.
- **No model.** These checks settle only what a script can decide: CI, the
  head, named rules, and whether a cited line exists. The reviewer spends
  its turn on design and correctness.
- **Evidence is settled once.** On PASS, `review-ready` writes a machine
  evidence block for the brief so the reviewer does not re-run the same
  checks. The launcher exports that block when a lane opts into the
  preflight.
- **Citations are checked against HEAD.** The comment is resolved against
  the reviewed commit, not the work tree, so local edits cannot make a
  missing line look valid.

## How to run them

```bash
scripts/dev-loop-gate.sh --check review-ready --help
scripts/dev-loop-gate.sh --check review-citations --help
scripts/agent-launch.sh --help
```

The first two print the flags, rows, accepted citation forms, and exit
codes, from the scripts themselves. The launcher help covers the preflight
flags for lanes that opt in with `"preflight": "review-ready"`.
