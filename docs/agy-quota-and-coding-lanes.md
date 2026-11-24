# Antigravity quota groups and coding lane order

Route each job to the `agy` quota group that matches its work type, and spend
spare headroom before it expires unused. When coding, follow the lane order
below.

Related: [`docs/tooling-and-cost.md`](tooling-and-cost.md),
[`docs/workstation-handoffs.md`](workstation-handoffs.md),
[`docs/shared-rules.md`](shared-rules.md).

## Route by quota group

`agy` exposes two separate model pools. Each pool has its own weekly and
5-hour limits, so exhausting one does not drain the other.

| Pool | Models | Route here |
| --- | --- | --- |
| Gemini | Gemini 4 Neon, Carbon, and Hydrogen, plus models still in `agy` until 2026-11-30 (Gemini 4 Argon and Gemini 3.8 Flash) | Docs, multimodal work, and high-judgment tasks. The review launcher defaults to Gemini 4 Carbon (`gemini-4-carbon-medium`) |
| Third-party | Claude Opus and Claude Sonnet, plus the GPT-OSS pool (GPT-OSS leaves `agy` on 2026-11-30) | Code changes, refactors, test fixes, review of diffs |

Gemini 4 Argon is not an independent pool. In `agy` it shares the general
Gemini quota, and Antigravity removes it on 2026-11-30 (see
[Choose a model](https://antigravity.google/docs/models/)). Unattended model
checks stay on `gemini-4-argon` through the Gemini API Batch runner. That
setting is separate from the `agy` review launcher and is unchanged.

Rules:

- Pick the pool from the job type, not from which model name is familiar.
- Prefer spare headroom over idle. If a pool has unused weekly capacity close to
  its reset, shift eligible work onto it instead of letting it expire.
- Do not move docs work onto the coding pool or coding work onto the docs pool
  only to save one launch. Cross-pool moves are for spare headroom.
- Use Carbon in `agy` for high-judgment review. Do not treat Argon as a
  separate reserve or as the `agy` review default.

## Coding lane order

Use the first lane that has capacity, then fall through.

1. **`agy` Claude pool.** Start here for coding while the pool has headroom.
2. **Workstation OpenCode with the Fireworks plan.** Burn the remaining
   included Fireworks capacity, then stop. Do not buy more capacity to keep
   this lane running.
3. **Workstation Command Code (Pro plan).** Use
   scripts/commandcode-wrapper.sh (login on the workstation, no API key) with
   the pinned lane models for ordinary coding while the workstation is
   online; when it is offline this lane is unavailable and the order falls
   through.

Fall through only when the earlier lane is exhausted or unavailable. Record the
lane used in the job `SUMMARY` so the weekly digest can report allocation (see
[weekly progress cost section](tooling-and-cost.md#weekly-progress-cost-section)).

## Related lanes

- Japanese article writing: [`docs/zenn-ja-writing-lane.md`](zenn-ja-writing-lane.md)
- OpenCode job shape: [`docs/opencode-thrift.md`](opencode-thrift.md)
