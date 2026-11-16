# Views

Two read-only views answer two questions. Both are computed at one view time
from GitHub facts. No view writes to GitHub.

## View 1: what is stuck

One row per open artifact with an inferred block.

| Column | GitHub fact | Deterministic rule |
| --- | --- | --- |
| `repo` | Repository full name | `owner/name`, exactly as GitHub returns it. |
| `artifact` | Issue or pull request | `repo#issue-<n>` or `repo#pr-<n>`. |
| `stage` | Inferred Process | First matching stage rule in [`inference-rules.md`](inference-rules.md). |
| `block` | Inferred Block | First matching block rule in [`inference-rules.md`](inference-rules.md). |
| `actors` | Assignees, author, requested reviewers, last three commenters | Ordered unique list, described below. |
| `wait_started_at` | Event time for the block | Per-block table below. A missing value falls back to the artifact `updated_at` and is marked approximate. |
| `wait_duration` | View time minus `wait_started_at` | Whole hours. Render `<d>d <h>h` when at least one day, else `<h>h`. |

Row order is `wait_duration` descending, then `repo` ascending, then
`artifact` ascending.

### Actors

Build one ordered list and de-duplicate by login, keeping the first position:

1. Assignees, in GitHub order.
2. The issue author or the pull request author.
3. Requested reviewers, in request order.
4. The authors of the last three comments, oldest to newest.

A bot account is shown as GitHub returns it. A missing role name is not
invented.

### Wait start

| Block | `wait_started_at` source |
| --- | --- |
| `retro_pending` | `merged_at` of the linked pull request. |
| `rework_needed` | `closed_at` of the latest closed unmerged linked pull request. |
| `no_pr_yet` | `created_at` of the issue. |
| `draft_in_progress` | `created_at` of the pull request, or the draft conversion time when the timeline holds it. |
| `merge_conflict` | `updated_at` of the pull request. |
| `changes_requested` | `submitted_at` of the latest `CHANGES_REQUESTED` review. |
| `checks_failing` | `completed_at` of the earliest currently failing check. |
| `checks_pending` | `started_at` of the earliest pending check, else the pull request `updated_at`. |
| `review_not_routed` | Time the pull request became non-draft when known, else its `created_at`. |
| `review_pending` | Time of the earliest review request when known, else the pull request `updated_at`. |
| `merge_gated` | `updated_at` of the pull request. |
| `awaiting_merge` | `updated_at` of the pull request. |
| `mergeability_unknown` | `updated_at` of the pull request. |
| `review_followup` | `submitted_at` of the latest review, else the pull request `updated_at`. |

The timestamps are UTC and use ISO 8601. `wait_started_at` is an approximation
(see [`limits.md`](limits.md)).

## View 2: what to resolve first

View 2 groups View 1 rows by resolution. One row per resolution. A group can
hold more than one block.

| Column | Deterministic rule |
| --- | --- |
| `resolution` | The fixed resolution mapped from the block, using the table below. |
| `block` | Distinct block names in the group, sorted by row count descending, then name ascending, joined with a comma and a space. |
| `items` | Number of View 1 rows in the group. |
| `max_wait` | Largest `wait_duration` in the group, in the same format as View 1. |
| `artifacts` | Artifact ids in the group, ordered by `wait_duration` descending, then `artifact` ascending, joined with a comma and a space. |

Row order is `items` descending, then `max_wait` descending, then `resolution`
ascending.

## Resolution map

| Resolution | Blocks |
| --- | --- |
| `assign_or_start` | `no_pr_yet` |
| `author_finish` | `draft_in_progress` |
| `author_fix` | `rework_needed`, `merge_conflict`, `changes_requested`, `checks_failing`, `checks_pending` |
| `route_or_finish_review` | `review_not_routed`, `review_pending`, `review_followup` |
| `maintainer_merge` | `merge_gated`, `mergeability_unknown`, `awaiting_merge` |
| `close_or_record_retro` | `retro_pending` |

## View time

Both views use one `view_time`, recorded when the fetch starts. `wait_duration`
is `view_time` minus `wait_started_at`, truncated to whole hours. Do not use
the local clock per row.

[`seed-data.md`](seed-data.md) shows both views with a fixed view time and
fictional data.
