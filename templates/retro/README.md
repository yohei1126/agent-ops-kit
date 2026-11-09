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
2. It posts exactly one Issue comment on the tracking Issue, using
   [`RETRO.md`](RETRO.md) as the body.
3. A pre-merge completion report must not use the `## RETRO` heading. Use
   another heading so the ingest step can tell the two apart.
4. A later `## RETRO` comment supersedes an earlier one at the same location.
   Ingest reads the newest marker at each location.

The tracking Issue is still the primary write-out. Do not post a retro
on a chat or on a second Issue.

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
| Scrub list | All five items below must pass |
| Owner | An operator bot routine, scheduled or event driven. CI never writes memory |
| Triggers | `pr-merged` immediate ingest (v1), plus a weekday sweep in v1.1 |
| Repo allowlist | An explicit list the operator maintains. Never an org-wide rule |
| Output | One shared-memory line of 300 characters or fewer, plus one FYI line |
| Idempotency | v1.1: key is the comment id, so one comment never records twice |

### Triggers in v1.1

Two triggers feed the same ingest path:

- **`pr-merged`** (v1): immediate ingest after a merge.
- **Scheduled sweep** (v1.1): every weekday at 18:00 Asia/Singapore (SGT), over
  pull requests merged in the last 14 days.

GitHub Issue comments cannot trigger the existing routine listeners, so late
ingest uses a scheduled sweep.

### Allowlisted repos

The allowlist stays an explicit list the operator maintains. There is no
org-wide rule, and this document does not widen it.

- `edgesentry/agent-hub`
- `yohei1126/agent-ops-kit`
- `edgesentry/ontographia`

## Scrub list

Apply the scrub list before posting:

- No personal or customer names.
- No local paths.
- No document or drive ids.
- No secrets or tokens.
- No quoted private repository content.

## Output line shape

`As of <date> (<repo>#<n> retro) <rule>`, at 300 characters or fewer. This is
the single shared-memory (`shared_profile`) fact. The same run sends one FYI
line to the coordinator. v1.1 keeps that FYI recipient unchanged.

## Idempotency (v1.1)

The comment id is the key. Ingest never records the same RETRO twice, and it
dedupes identical `shared_profile` text.

## Quiet runs and rejections

**v1.1: quiet runs.** With no `## RETRO` marker or no candidate comment, the
run writes no `shared_profile`, sends no FYI, and makes no external post.

**v1.1: no external posts.** A contract failure is reported to the operator in
chat only. No rejection note goes to an Issue, a pull request, or any other
external surface. A local journal for retry may exist, but it is not a post.

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
