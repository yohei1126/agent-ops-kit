# Known limits

These limits are part of the draft. Do not "fix" them by inventing facts.

## A draft pull request can look like a maintainer wait

GitHub records draft state, not intent. A draft that is still being worked on
may be inferred as waiting on the maintainer, especially when the author has
not pushed or commented recently. The view can show a wait that the author is
still working through.

## Bot role names are often absent

GitHub often shows only a login. A bot may have no role label, so the actors
column shows the identity, not "reviewer" or "builder". Do not infer a role
from a name.

## `wait_started_at` is an approximation

The start of a wait comes from the nearest GitHub event (see
[`views.md`](views.md)). A draft conversion, a review request, or a
mergeability recompute may not have a clean timestamp. When the event time is
missing, the fallback is the artifact `updated_at`, marked approximate.

## Deploy waits and six-line handoffs are not columns

Deploy waits, smoke checks, and six-line handoffs happen outside GitHub. They
are not facts in this graph and do not appear as columns. "Deploy and publish
setup" stays an existing process step, not a view row.

## No conflict inference from unknown

`mergeable_state` of `unknown` means GitHub has not computed a value. It is not
a conflict. The rules ignore it for conflicts and may show
`mergeability_unknown` as the block.

## Scope

These limits describe the draft. A later implementation may reduce them, but
this document does not add a fix that depends on data GitHub does not hold.
