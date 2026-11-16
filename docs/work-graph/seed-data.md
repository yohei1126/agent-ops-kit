# Fictional seed data

All names, repositories, numbers, actors, decisions, and timestamps here are
invented. They illustrate the two views only. Nothing here describes a real
issue, pull request, decision, or person.

View time: `2026-11-16T12:00:00Z`.

## View 1: what is stuck

Rows are ordered by `wait_duration` descending, then `repo`, then `artifact`.

| repo | artifact | stage | block | actors | wait_started_at | wait_duration |
| --- | --- | --- | --- | --- | --- | --- |
| `example/widgets` | `example/widgets#issue-12` | `planning` | `no_pr_yet` | `maintainer-example` | `2026-11-02T09:00:00Z` | 14d 3h |
| `example/docs-site` | `example/docs-site#issue-9` | `post_merge` | `retro_pending` | `maintainer-example` | `2026-11-09T12:00:00Z` | 7d 0h |
| `example/widgets` | `example/widgets#pr-31` | `implementation` | `draft_in_progress` | `builder-bot-example` | `2026-11-10T14:00:00Z` | 5d 22h |
| `example/widgets` | `example/widgets#pr-28` | `changes_requested` | `changes_requested` | `builder-bot-example`, `reviewer-example` | `2026-11-12T08:00:00Z` | 4d 4h |
| `example/widgets` | `example/widgets#pr-26` | `merge_ready` | `awaiting_merge` | `maintainer-example` | `2026-11-13T11:00:00Z` | 3d 1h |
| `example/docs-site` | `example/docs-site#pr-44` | `verification` | `checks_failing` | `builder-bot-example` | `2026-11-14T16:00:00Z` | 1d 20h |
| `example/docs-site` | `example/docs-site#pr-47` | `first_review` | `review_not_routed` | `builder-bot-example`, `maintainer-example` | `2026-11-15T10:00:00Z` | 1d 2h |
| `example/widgets` | `example/widgets#pr-25` | `verification` | `merge_conflict` | `builder-bot-example` | `2026-11-15T18:00:00Z` | 18h |

## View 2: what to resolve first

Rows are ordered by `items` descending, then `max_wait` descending, then
`resolution`.

| resolution | block | items | max_wait | artifacts |
| --- | --- | --- | --- | --- |
| `author_fix` | `changes_requested`, `checks_failing`, `merge_conflict` | 3 | 4d 4h | `example/widgets#pr-28`, `example/docs-site#pr-44`, `example/widgets#pr-25` |
| `assign_or_start` | `no_pr_yet` | 1 | 14d 3h | `example/widgets#issue-12` |
| `close_or_record_retro` | `retro_pending` | 1 | 7d 0h | `example/docs-site#issue-9` |
| `author_finish` | `draft_in_progress` | 1 | 5d 22h | `example/widgets#pr-31` |
| `maintainer_merge` | `awaiting_merge` | 1 | 3d 1h | `example/widgets#pr-26` |
| `route_or_finish_review` | `review_not_routed` | 1 | 1d 2h | `example/docs-site#pr-47` |

## How to read the example

- `author_fix` comes first because it holds the most rows. Its largest wait is
  4d 4h.
- Among the one-row resolutions, `assign_or_start` comes next because its wait
  of 14d 3h is the longest.
- The block column lists the distinct blocks in a resolution group. The
  `author_fix` group holds three different blocks.
- The artifacts column repeats the View 1 ordering inside the group.

This data is a fixture for reading the rules, not a record of any real work.
