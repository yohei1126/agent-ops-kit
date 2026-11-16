# Inference rules

Rules read open issues and open pull requests fetched at view time. Each list
is ordered. The first matching rule wins. A later implementation must follow
the same order and must not add a rule that changes an earlier match.

## Inputs

- Open issues that are not pull requests.
- Open pull requests, with author, draft flag, aggregate review decision,
  mergeable state, submitted reviews, and checks.
- Closing links between issues and pull requests.

A pull request is a closing link to an issue when either holds:

- The pull request title or body holds a closing keyword (`close`, `closes`,
  `closed`, `fix`, `fixes`, `fixed`, `resolve`, `resolves`, `resolved`)
  followed by the issue number.
- The issue timeline holds a closing event for that pull request, such as a
  cross-reference whose `will_close_target` is true, or a close event whose
  closer is that pull request.

A plain mention or any other cross-reference is a mention link, not a closing
link. A mention link may be described in a view, but no rule uses it, and it
cannot trigger `post_merge` or `retro_pending`.

Use one link pass per view render. Do not write a link back to GitHub.

An open issue with an open closing link is not rendered as its own row. The
open pull request row covers it.

## Stage rules: first match wins

Apply S1 and S2 to open issues. Apply S3 to S10 to open pull requests.

| Order | Condition | Stage |
| --- | --- | --- |
| S1 | Open issue with a merged closing link and no open closing link | `post_merge` |
| S2 | Open issue with no open closing link | `planning` |
| S3 | Open draft pull request | `implementation` |
| S4 | Open non-draft pull request with `mergeable_state` of `dirty` | `verification` |
| S5 | Open non-draft pull request with aggregate review decision `CHANGES_REQUESTED` | `changes_requested` |
| S6 | Open non-draft pull request with at least one failing check | `verification` |
| S7 | Open non-draft pull request with at least one pending check | `verification` |
| S8 | Open non-draft pull request with no submitted review | `first_review` |
| S9 | Open non-draft pull request with submitted reviews and no approving review | `first_review` |
| S10 | Open non-draft pull request with an approving review | `merge_ready` |

S9 matches submitted reviews of any state, including `APPROVED`, so an
approved pull request that also holds a `COMMENTED` review still reaches S10.
The aggregate review decision decides approval, not the presence of a single
review.

There is no catch-all stage rule. S1 and S2 cover every open issue, and S3 to
S10 cover every open pull request, so a defensive fallback would be
unreachable. Do not add one.

A check is failing when its conclusion is `FAILURE`, `TIMED_OUT`, `STALE`,
`ACTION_REQUIRED`, or `STARTUP_FAILURE`. A check is pending when it has not
completed, or its status is `QUEUED` or `IN_PROGRESS`.

A submitted review is any review with state `APPROVED`, `CHANGES_REQUESTED`,
or `COMMENTED`. A pending review request is not a submitted review. For every
rule and note in this module, `approval` and `approving review` mean GitHub's
aggregate review decision is `APPROVED`, never the presence of one review.

`mergeable_state` of `unknown` matches no stage rule. It is not a conflict.

## Block rules: first match wins

Apply B1 to B3 to open issues. Apply B4 to B14 to open pull requests.

| Order | Condition | Block | Waits on |
| --- | --- | --- | --- |
| B1 | Open issue with a merged closing link and no open closing link | `retro_pending` | The maintainer |
| B2 | Open issue with no open closing link and a closed unmerged closing link | `rework_needed` | The pull request author |
| B3 | Open issue with no open closing link | `no_pr_yet` | The assignee when set, else the maintainer |
| B4 | Open draft pull request | `draft_in_progress` | The pull request author |
| B5 | Open non-draft pull request with `mergeable_state` of `dirty` | `merge_conflict` | The pull request author |
| B6 | Open non-draft pull request with aggregate review decision `CHANGES_REQUESTED` | `changes_requested` | The pull request author |
| B7 | Open non-draft pull request with at least one failing check | `checks_failing` | The pull request author |
| B8 | Open non-draft pull request with at least one pending check | `checks_pending` | CI, then the pull request author |
| B9 | Open non-draft pull request with no review requested and no submitted review | `review_not_routed` | The maintainer |
| B10 | Open non-draft pull request with a review requested and no submitted review | `review_pending` | The requested reviewers |
| B11 | Open non-draft pull request approved, with `mergeable_state` of `blocked` or `behind` | `merge_gated` | The maintainer |
| B12 | Open non-draft pull request approved, with `mergeable_state` of `clean` | `awaiting_merge` | The maintainer |
| B13 | Open non-draft pull request approved, with `mergeable_state` of `unknown` | `mergeability_unknown` | The maintainer |
| B14 | Any other open artifact | `review_followup` | The maintainer |

B14 is a defensive fallback. It catches an open artifact that no earlier rule
matched, such as a non-draft pull request with a submitted review that asked
for no change and still has an unresolved merge state. Keep it as a guard, not
as the expected block for the common cases above.

B4 always waits on the pull request author. A draft pull request appears to
wait on the maintainer only when the maintainer is also its author, or when the
actors column shows the maintainer. See [`limits.md`](limits.md) for why draft
state alone can look like a maintainer wait.

Two notes fix the meaning of the mergeable state:

- B5 matches `dirty` only. `unknown` is not a conflict and falls through to a
  later rule.
- `unstable` is not a conflict. It usually appears with pending checks, which
  match B7 or B8 earlier.

## Worked ordering example

An open, non-draft pull request with a merge conflict and a failing check
matches B5, so the block is `merge_conflict`. Its stage is S4, so the stage is
`verification`. A pull request with changes requested and a failing check
matches B6, so the block is `changes_requested`, not `checks_failing`.

## Related

- [`views.md`](views.md): columns and the wait-start mapping.
- [`stage-mapping.md`](stage-mapping.md): stage names mapped to existing
  development-process steps.
