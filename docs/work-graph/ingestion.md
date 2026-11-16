# Ingestion rules

This draft reads GitHub. It does not store a second copy of process state.

## Source of truth

- The source of truth for a decision is GitHub fetched at view time, just
  before the question.
- Fetch open issues, open pull requests, linked pull request state, reviews,
  checks, mergeable state, and timestamps in one read pass.
- Render both views from that one fetch. Do not reuse an older fetch for a
  later question.
- A read may be cached for the duration of one render. It must not become a
  stored ledger.

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
