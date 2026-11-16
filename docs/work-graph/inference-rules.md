# Inference rules

Rules read open issues and open pull requests fetched at view time. Each list
is ordered. The first matching rule wins. A later implementation must follow
the same order and must not add a rule that changes an earlier match.

## Inputs

- Open issues that are not pull requests.
- Open pull requests, with draft flag, review decision, mergeable state,
  reviews, and checks.
- Links between issues and pull requests.

A pull request is linked to an issue when either holds:

- The pull request title or body holds a closing keyword (`close`, `closes`,
  `closed`, `fix`, `fixes`, `fixed`, `resolve`, `resolves`, `resolved`)
  followed by the issue number.
- The issue timeline holds a cross-reference event for that pull request.

Use one link pass per view render. Do not write a link back to GitHub.

An open issue with an open linked pull request is not rendered as its own row.
The open pull request row covers it.

## Stage rules: first match wins

Apply S1 and S2 to open issues. Apply S3 to S11 to open pull requests.

| Order | Condition | Stage |
| --- | --- | --- |
| S1 | Open issue with a merged linked pull request and no open linked pull request | `post_merge` |
| S2 | Open issue with no open linked pull request | `planning` |
| S3 | Open draft pull request | `implementation` |
| S4 | Open non-draft pull request with `mergeable_state` of `dirty` | `verification` |
| S5 | Open non-draft pull request with review decision `CHANGES_REQUESTED` | `changes_requested` |
| S6 | Open non-draft pull request with at least one failing check | `verification` |
| S7 | Open non-draft pull request with at least one pending check | `verification` |
| S8 | Open non-draft pull request with no submitted review | `first_review` |
| S9 | Open non-draft pull request with a submitted review that is not an approval | `first_review` |
| S10 | Open non-draft pull request with an approving review | `merge_ready` |
| S11 | Any other open artifact | `first_review` |

A check is failing when its conclusion is `FAILURE`, `TIMED_OUT`, `STALE`,
`ACTION_REQUIRED`, or `STARTUP_FAILURE`. A check is pending when it has not
completed, or its status is `QUEUED` or `IN_PROGRESS`.

A submitted review is any review with state `APPROVED`, `CHANGES_REQUESTED`,
or `COMMENTED`. A pending review request is not a submitted review. An
approving review means GitHub's aggregate review decision is `APPROVED`.

`mergeable_state` of `unknown` matches no stage rule. It is not a conflict.

## Block rules: first match wins

Apply B1 to B3 to open issues. Apply B4 to B14 to open pull requests.

| Order | Condition | Block | Waits on |
| --- | --- | --- | --- |
| B1 | Open issue with a merged linked pull request and no open linked pull request | `retro_pending` | The maintainer |
| B2 | Open issue with no open linked pull request and a closed unmerged linked pull request | `rework_needed` | The pull request author |
| B3 | Open issue with no open linked pull request | `no_pr_yet` | The assignee when set, else the maintainer |
| B4 | Open draft pull request | `draft_in_progress` | The pull request author |
| B5 | Open non-draft pull request with `mergeable_state` of `dirty` | `merge_conflict` | The pull request author |
| B6 | Open non-draft pull request with review decision `CHANGES_REQUESTED` | `changes_requested` | The pull request author |
| B7 | Open non-draft pull request with at least one failing check | `checks_failing` | The pull request author |
| B8 | Open non-draft pull request with at least one pending check | `checks_pending` | CI, then the pull request author |
| B9 | Open non-draft pull request with no review requested and no submitted review | `review_not_routed` | The maintainer |
| B10 | Open non-draft pull request with a review requested and no submitted review | `review_pending` | The requested reviewers |
| B11 | Open non-draft pull request approved, with `mergeable_state` of `blocked` or `behind` | `merge_gated` | The maintainer |
| B12 | Open non-draft pull request approved, with `mergeable_state` of `clean` | `awaiting_merge` | The maintainer |
| B13 | Open non-draft pull request approved, with `mergeable_state` of `unknown` | `mergeability_unknown` | The maintainer |
| B14 | Any other open artifact | `review_followup` | The maintainer |

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
