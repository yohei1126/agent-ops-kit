# Ingestion rules

This draft reads GitHub. It does not store a second copy of process state.

## Source of truth

- The source of truth for a decision is GitHub fetched at view time, just
  before the question.
- Fetch every input the rules and views need in one read pass (see
  [Fetch inputs](#fetch-inputs)).
- Render both views from that one fetch. Do not reuse an older fetch for a
  later question.
- A read may be cached for the duration of one render. It must not become a
  stored ledger.

## Fetch inputs

The rules in [`inference-rules.md`](inference-rules.md) and the columns in
[`views.md`](views.md) need all of the following in the same read pass:

- Open issues, without pull requests mixed in.
- Open pull requests, with the draft flag and `mergeable_state`.
- Issue timelines, used to find closing links to pull requests.
- Assignees and the author on each artifact, to fill the actors column and to
  answer who a block waits on.
- Requested reviewers, with their request times.
- Comment authors and the comment text, for the actors column and for
  decisions recorded in comments.
- Labels, for decisions and status shown on an artifact.
- Reviews, with state and `submitted_at`, for the stage and block rules.
- Check runs or status checks, with conclusion, status, and their start and
  completion times.
- Closed and merged pull requests with a closing link, with `merged_at` and
  `closed_at`, so `post_merge` and `rework_needed` can be told apart from an
  open pull request.

Do not fetch a subset and infer the rest. A missing input yields an empty
value, not a guess.

## Snapshots

- Scheduled snapshots are optional.
- If an operator keeps them, they answer one question only: did the bottleneck
  count drop since the last snapshot?
- A snapshot is not a source of truth for a decision. A decision always uses a
  fresh fetch.

## Out of scope

- Webhooks.
- A central write path.
- Agents writing process state by hand.
- A second, handwritten ledger.
- Any write to GitHub from this module.

## Facts that are not on GitHub

Leave these empty or weakly inferred:

- chat decisions
- deploy waits
- bot role names

Do not fill an empty column from memory or from a chat transcript. Weakly
inferred means the value may be shown with its source marked, or left empty.

## Fetch notes

- Read only. Do not add labels, comments, or state changes.
- A missing field is empty, not zero.
- Respect GitHub rate limits. One read pass per question is the default.
- If a fetch fails, show the failure. Do not replace it with a cached ledger.

## Related

- [`views.md`](views.md): the columns the fetch must fill.
- [`limits.md`](limits.md): what the fetch cannot know.
