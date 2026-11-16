# Stage mapping to the development loop

The inferred stages reuse the step names that already exist in the development
loop. Do not add a parallel process vocabulary.

## Map

| Inferred stage | [`CHECKLIST.md`](../../templates/dev-loop/CHECKLIST.md) step | [`dev-loop-rules.md`](../dev-loop-rules.md) heading | [`dev-loop/README.md`](../../templates/dev-loop/README.md) |
| --- | --- | --- | --- |
| `planning` | [Before start](../../templates/dev-loop/CHECKLIST.md#before-start) | [Planning and briefs](../dev-loop-rules.md#planning-and-briefs) | [Order of use, item 1](../../templates/dev-loop/README.md#order-of-use) |
| `implementation` | [During the run](../../templates/dev-loop/CHECKLIST.md#during-the-run) and [Open the pull request](../../templates/dev-loop/CHECKLIST.md#open-the-pull-request) | None | [Order of use, item 4](../../templates/dev-loop/README.md#order-of-use) |
| `first_review` | [Route the first review](../../templates/dev-loop/CHECKLIST.md#route-the-first-review) | [Review gate](../dev-loop-rules.md#review-gate) | [Order of use, item 2](../../templates/dev-loop/README.md#order-of-use) |
| `changes_requested` | [Route the first review](../../templates/dev-loop/CHECKLIST.md#route-the-first-review) | [Review gate](../dev-loop-rules.md#review-gate) | [Order of use, item 3](../../templates/dev-loop/README.md#order-of-use) |
| `verification` | [During the run](../../templates/dev-loop/CHECKLIST.md#during-the-run) | [Verification and completion reports](../dev-loop-rules.md#verification-and-completion-reports) | None |
| `merge_ready` | [Open the pull request](../../templates/dev-loop/CHECKLIST.md#open-the-pull-request) | [Review gate](../dev-loop-rules.md#review-gate) | [Order of use, item 4](../../templates/dev-loop/README.md#order-of-use) |
| `post_merge` | [After merge](../../templates/dev-loop/CHECKLIST.md#after-merge) | [Deploy and publish setup](../dev-loop-rules.md#deploy-and-publish-setup) where the repository deploys | [Order of use, item 5](../../templates/dev-loop/README.md#order-of-use) |

## Stage notes

- `planning`: the work is an open issue with no open linked pull request. The
  matching steps are "Before start" and "Planning and briefs".
- `implementation`: the pull request is a draft. The matching steps are
  "During the run" and the draft default in "Open the pull request".
- `first_review`: the pull request is ready and needs a first review. The
  matching steps are "Route the first review" and "Review gate".
- `changes_requested`: a review asked for changes. The matching step is
  "Review gate", and the later review pass stays separate, per "Order of use"
  item 3.
- `verification`: checks or mergeability need work before merge. The matching
  steps are "During the run" and "Verification and completion reports".
- `merge_ready`: the pull request is approved. The matching step is "Open the
  pull request"; a draft becomes ready only after the operator explicitly says
  ready.
- `post_merge`: the pull request merged and the issue remains open. The
  matching steps are "After merge" and "Order of use" item 5. "Deploy and
  publish setup" applies only where the repository deploys.

## Not inferred

"Deploy and publish setup" is an existing step, but a deploy wait is not a
GitHub fact. It stays out of the graph and out of the view columns. See
[`limits.md`](limits.md).

## Related

- [`inference-rules.md`](inference-rules.md): the ordered stage and block
  rules.
- [`views.md`](views.md): the two views that consume the stage.
