# Filled coding-agent task with a multi-line comment before the result path

## Agent and model

agy / example-model

## Goal

Summarize the change for the reviewer.

## Context links

- Pull request: example-org/example-repo, branch review-change
- Files: docs/example.md
- Head SHA: example-head-sha

## Scope In-Out

In:

Review the listed files.

Out:

No code changes.

## Steps or review focus

Read the pull request and list risks by severity.

## Acceptance criteria and output format

- The result starts with `Model: <name/id>`.
- The result includes a VERDICT line and findings by severity.

## Constraints

- Do not merge; the maintainer merges.
- Do not change secrets or credentials.
- Work in a separate worktree.

## Where to write the result

<!--
write the review here
-->
/tmp/agent-task-result.md
