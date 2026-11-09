# Retro template and ingest contract

A merged pull request can leave one durable lesson. This template turns that
lesson into a single short comment, so the fleet picks up the rule without chat
round-trips and without anyone crawling old chat threads.

This file documents version 1.1. Rows and sections marked **v1.1** are new or
changed. Unmarked text keeps the version 1 contract.

## Purpose

The post-merge retro produces one short shared rule line. The reader is another
bot that starts a later task in the same area. A rule that needs a conversation
to explain is too long for this path.

## Write-out convention

1. The implementing bot waits until the pull request merges.
2. It posts exactly one comment on the tracking Issue, using
   [`RETRO.md`](RETRO.md) as the body.
3. A pre-merge completion report must not use the `## RETRO` heading. Use
   another heading so the ingest step can tell the two apart.
4. One merged pull request yields one winner across both locations. If the
   tracking Issue and the PR conversation both hold a `## RETRO`, ingest picks
   the comment with the newest `created_at`. On a tie, the tracking Issue
   comment wins. The run writes one `shared_profile` line and sends one FYI.

The tracking Issue is the primary write-out. Do not post a retro on a chat or on
a second Issue.

**v1.1: late re-ingest.** After a pull request merges, a `## RETRO` comment may
also be added later on the tracking Issue or on the PR conversation of that
merged pull request. Within 14 days of the merge, on the allowlisted repos,
ingest must pick it up. This relaxes the v1 sentence that forbade a retro on a
pull request: the primary write-out stays the tracking Issue comment, and the
PR conversation is a second place that late ingest may read.

## Ingest contract

| Field | Contract |
| --- | --- |
| Marker | The comment starts with `## RETRO` as its first line |
| Source PR link | A `Source PR: URL` line directly under the marker |
| Max length | 1,500 characters for the whole comment |
| Scrub list | All five items below must pass at ingest time |
| Surfaces | Top-level issue comments on the merged PR and its linked Issue only |
| Owner | An operator bot routine, scheduled or event driven. CI never writes memory |
| Triggers | `pr-merged` immediate ingest (v1), plus weekday 18:00 SGT sweeps in v1.1 |
| Repo allowlist | Only the three repositories listed below. Never an org-wide rule |
| Output | One shared-memory line of 300 characters or fewer, plus one FYI line |
| Idempotency | v1.1: key is `(comment_id, updated_at)` |

### Triggers in v1.1

`pr-merged` and the scheduled sweep feed the same ingest path and scan the same
surfaces.

- **`pr-merged`** (v1): immediate ingest after a merge.
- **Scheduled sweep** (v1.1): every weekday at 18:00 Asia/Singapore (SGT).

GitHub Issue comments cannot trigger the existing routine listeners, so late
ingest uses a scheduled sweep.

Both triggers read top-level issue comments (`issues/{number}/comments`) on the
merged pull request and on its linked tracking Issue. They do not read pull
request or Issue description bodies, review submission bodies, or inline diff
review comments.

To find the tracking Issue, both triggers resolve the GitHub closing or linked
issue references for the merged pull request. Discovery is the same for the two
triggers.

### Sweep window

Eligibility is set by the comment, not by the sweep day. A `## RETRO` comment
posted with `comment.created_at <= merged_at + 14 days` (rolling 336 hours after
merge) on an allowlisted repository must be pickable.

- Tuesday to Friday sweeps select pull requests with
  `merged_at >= sweep_time - 14 days` (rolling 336 hours).
- Monday sweeps extend the lookback to `merged_at >= sweep_time - 17 days`
  (rolling 408 hours). The extra 3 days cover the Friday to Monday gap, so a
  comment still inside the 14-day post-merge window after Friday's sweep cannot
  be dropped.

### Allowlisted repos

The allowlist consists only of these three repositories (never an org-wide rule):

- `edgesentry/agent-hub`
- `yohei1126/agent-ops-kit`
- `edgesentry/ontographia`

## Scrub list

Authors apply the scrub list before posting, and the ingest routine enforces all
five items before recording.

- No personal or customer names.
- No local paths.
- No document or drive ids.
- No secrets or tokens.
- No quoted private repository content.

## Output line shape

`As of <date> (<repo>#<n> retro) <rule>`, at 300 characters or fewer. This is
the single shared-memory (`shared_profile`) fact. The same run sends one FYI
line to the coordinator. v1.1 keeps that FYI recipient unchanged.

- `<date>` is the date of ingest in SGT, as `YYYY-MM-DD`.
- `#<n>` is the tracking Issue number when one exists, otherwise the merged PR
  number.

## Idempotency and replacement (v1.1)

A later or edited `## RETRO` for the same `(repo#n retro)` overwrites the
existing `shared_profile` line: forget the old line and write the new one.

The idempotency key is `(comment_id, updated_at)`. An in-place edit can be
re-evaluated, and a new superseding comment replaces the prior line rather than
appending a second one. The routine records the ingested marker only after a
successful write.

## Quiet runs and rejections

**v1.1: quiet runs.** A run is quiet when it finds no `## RETRO`, no candidate
comment, or only candidates that are already ingested. A quiet run writes no
`shared_profile`, sends no coordinator FYI, sends no operator chat message, and
makes no external post.

**Contract failures.** At ingest time, a candidate that fails the marker, the
`Source PR:` link, the 1,500-character limit, or the scrub list is rejected.
The routine writes no `shared_profile` and sends no coordinator FYI. It reports
the failure in operator chat only, never on an external surface. Failure alerts
are deduplicated by `(comment_id, updated_at)`.

**v1.1: no external posts.** On every run outcome, the routine posts no
comments, rejection notes, reactions, labels, or status updates on GitHub Issues
or pull requests, or on any other external surface. A local journal for retry
may exist, but it is not a post.

## Out of scope for v1.1

- A live end-to-end listener test.
- CI writes to shared memory.
- Auto-review or allow-list changes.
- Weekly retro routines.
- Cross-chat scans.
- A `pr-comment` listener. v1.1 uses the cron sweep only.
- The routine implementation itself, which stays outside this docs change.

## Related

- [`RETRO.md`](RETRO.md): the copyable comment template.
- [Shared rules](../../docs/shared-rules.md): the rules that retros propose
  changes to.
