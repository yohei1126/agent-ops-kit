# Ontology draft

The graph has five types. The names are a draft and stay a draft until the
maintainer confirms them. Each type describes an existing GitHub fact or a
small inference over those facts. None of them is a new system of record.

## Types

| Type | Meaning | GitHub source |
| --- | --- | --- |
| Agent | An actor that can move an artifact or answer a decision. | User accounts on assignees, authors, reviewers, and comments. |
| Process | A step in the development loop that an artifact is in. | Inferred from artifact state; see [`inference-rules.md`](inference-rules.md). |
| Artifact | The unit of work: an issue, a pull request, or a linked pair. | Open issues and open pull requests. |
| Decision | A recorded choice that clears a block. | Review state, labels, and explicit comments. |
| Block | The reason an artifact is not moving. | Inferred from artifact state; see [`inference-rules.md`](inference-rules.md). |

## Relationships

| Subject | Relationship | Object | Notes |
| --- | --- | --- | --- |
| Agent | acts on | Artifact | Authorship, assignment, review, or comment. |
| Artifact | at | Process | One current stage per artifact, from the first matching rule. |
| Artifact | linked to | Artifact | A closing link between an issue and a pull request. |
| Block | blocks | Artifact | One primary block per view row. |
| Block | waits on | Agent | The actor expected to move the artifact next. |
| Block | clears at | Process | The stage transition that removes the block. |
| Decision | resolves | Block | A decision closes one block. |
| Decision | recorded on | Artifact | The issue or pull request that holds the decision. |
| Process | follows | Process | The normal order from the development loop. |
| Artifact | produces | Artifact | A merged pull request closes or advances an issue. |

## Reading rules

- An artifact is an issue, a pull request, or a linked pair. A view row uses
  one artifact id, such as `repo#issue-<n>` or `repo#pr-<n>`.
- A block is inferred, not stored. It exists only for the view render.
- A decision is read from GitHub at view time. When GitHub holds no decision,
  the decision is empty. Do not guess one.
- An agent is a GitHub identity. Role names such as "reviewer" or "builder"
  are often absent, so the actor may be a login only.
- Process names map to the existing development-process steps through the
  table in [`stage-mapping.md`](stage-mapping.md). They are not a new
  vocabulary and do not rename those steps.

## Type name status

The names Agent, Process, Artifact, Decision, and Block are placeholders for
this draft. Do not treat them as final schema names. A later implementation
may rename them without changing the two views.
