# Ingest sources into a knowledge base

An assistant can turn shared links, inbox files, meeting notes, and
bookmarks into durable summaries, then keep a set of insight notes up
to date. This guide describes that workflow in platform-neutral terms,
so you can run it with any assistant and any document store.

## Folder layout

Keep the knowledge base in a document store (for example a cloud drive
or a notes app). Every record is an ordinary document in that store.

```text
Knowledge base/
  Source summaries/
    Inbox/
    Media/
    Bookmarks/
    Books/
    Lectures/
    Meeting notes/
  Insights/
  Daily digest/
```

Knowledge base is the root folder. Source summaries holds source
documents and the summaries made from them, sorted by kind:

- Inbox is the drop folder for unprocessed material, including reports
  written by another assistant or a scheduled task.
- Media holds ad hoc summaries of links shared in the assistant's
  chat.
- Bookmarks, Books, Lectures, and Meeting notes hold summaries of
  those source kinds.

Insights holds standing notes that the assistant updates after each
periodic ingest. Daily digest is reserved for day-level notes. This
guide does not define a digest routine.

Use these folder names, or map them to your own names in one place and
keep that mapping consistent.

## Standing rules

1. Leave Inbox originals in place. Never move or delete them.
2. Update Insights as the last step of each periodic ingest.
3. Treat financial or investment material as information only. Never
   give buy or sell advice.

## Capabilities the platform needs

The assistant, or a thin adapter around it, must provide the
capabilities in the table below. Fill each placeholder with the tool
your environment exposes. The rest of this guide names the capability,
not a vendor product.

| Capability | Purpose | Environment tool |
| --- | --- | --- |
| Read a URL | Fetch a shared link once | `<READ_URL>` |
| Read captions or a description | Summarize a video from text only | `<READ_CAPTIONS>` |
| Write a document | Create a summary or append an insight note | `<WRITE_DOCUMENT>` |
| List a folder | Find unprocessed Inbox items and existing summaries | `<LIST_FOLDER>` |
| Read a document | Compare titles, URLs, and insight text | `<READ_DOCUMENT>` |
| List calendar events | Find meetings in the processing window | `<LIST_EVENTS>` |
| Read a bookmarks source | Find bookmarks since the last run | `<LIST_BOOKMARKS>` |
| Run on a schedule | Start periodic ingest and bookmark jobs | `<SCHEDULER>` |
| Notify the operator | Report new work, or bookmark-job failures | `<NOTIFY>` |

## Ad hoc ingest

When the operator shares a link in the assistant's chat, including
when the message is only a question about that link, save a summary
document under Source summaries/Media.

Use this title pattern:

```text
YYYY-MM-DD <source>: <title>
```

Write the summary in the original language of the source. Reply in the
assistant's chat in the operator's language.

Include a neutral assessment. Flag claims that are exaggerated or
unverified.

For a video, summarize from captions and the description text only.
Do not analyze the video or audio track.

Fetch the source once with `<READ_URL>` or `<READ_CAPTIONS>`. Do not
fetch it again, and do not start a second assistant or a remote coding
job just to retrieve it.

## Periodic ingest

Run this job on the schedule you configure (`<SCHEDULE>`). Each run
processes items since the last successful run. Skip items that are
already summarized. After the run, report what was ingested and what
changed in Insights. Stay silent when nothing is new.

### Inbox items

1. List unprocessed items in Inbox, including reports produced by
   another assistant or a scheduled task.
2. Write a summary document in the matching Source summaries
   subfolder: Media, Bookmarks, Books, Lectures, or Meeting notes.
3. Leave the Inbox original in place. Do not move or delete it.

Treat an item as already summarized when an existing document matches
it by file name, title, or source URL.

### Meeting notes

For calendar events in the processing window, write summaries under
Source summaries/Meeting notes. Leave the original notes in place.

The processing window is the span since the last successful run, or
the window you configure for this environment. Do not hard-code a
weekday, clock time, or time zone into the workflow itself.

### Insights

Compare the source summaries created or updated in this run with the
existing Insights notes.

- When a summary relates to an existing insight, append a note that
  includes an evidence link and the date. Do not delete or rewrite
  earlier text. If the new source contradicts the insight, record the
  contradiction as a contradiction.
- Create a new insight only for a theme that appears in two or more
  sources. If no theme meets that bar, change nothing in Insights.

## Periodic bookmark ingest

Run a scheduled job that writes new items from the bookmarks source
into Source summaries/Bookmarks. If you split this job from periodic
ingest, give it its own `<SCHEDULE>` slot on the same `<SCHEDULER>`.

Stop when you reach `<MAX_ITEMS_PER_RUN>` items or `<BUDGET_PER_RUN>`,
whichever comes first. Fill those placeholders per environment.

Notify the operator only when credits are exhausted, a reconnect is
needed, or items were skipped. Stay silent on a clean run, including a
run that found nothing new.

## Edge cases

| Case | What to do |
| --- | --- |
| Duplicate detection | Match on file name, title, or source URL. If any of those match an existing summary, skip the item. |
| Edited or replaced source | If the source URL is the same and the title or content changed, update the existing summary in place, or append a dated revision. Do not create a second document for the same URL. Leave the Inbox original untouched. |
| Processing window boundaries | Include items whose timestamp falls in the processing window, from the end of the last successful run up to the start of this run. Exclude items already processed. An item that lands exactly on the boundary belongs in this run if it was not in the previous one. |
| Failure notification | For periodic ingest, tell the operator if the run could not list a folder, read a source, or write a document. For bookmark ingest, notify only on credit exhaustion, a needed reconnect, or skipped items. |
| No-op conditions | Stay silent on the ingest job when Inbox has no unprocessed items, the processing window has no new meeting notes, and no insight change meets the bar. Stay silent on the bookmark job when the bookmarks source has nothing new and the run had no failure. |

## Placeholders to fill per environment

Copy these and replace them with values or tool names for your setup:

- `<READ_URL>`, `<READ_CAPTIONS>`, `<WRITE_DOCUMENT>`,
  `<LIST_FOLDER>`, `<READ_DOCUMENT>`, `<LIST_EVENTS>`,
  `<LIST_BOOKMARKS>`, `<SCHEDULER>`, `<NOTIFY>`
- `<SCHEDULE>`, `<MAX_ITEMS_PER_RUN>`, `<BUDGET_PER_RUN>`
