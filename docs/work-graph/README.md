# Work graph (optional module)

This folder is an optional, documentation-only module. It shows how to read
existing GitHub facts as a small graph of agents, processes, artifacts,
decisions, and blocks, then answer two questions:

- What is stuck?
- What should we resolve first?

The module is not a dependency of the development loop, RETRO, or any other
kit path. Nothing here runs, and nothing here adds a runtime, a database, a
webhook, or a write path to GitHub.

## Status

The ontology in [`ontology.md`](ontology.md) is a draft. Its type names stay a
draft until the maintainer confirms them.

## File map

| File | Use |
| --- | --- |
| [`ontology.md`](ontology.md) | Draft types and relationships. |
| [`views.md`](views.md) | The two views, their columns, and the deterministic mapping. |
| [`inference-rules.md`](inference-rules.md) | Ordered stage and block rules from GitHub facts. |
| [`stage-mapping.md`](stage-mapping.md) | Inferred stages mapped to existing development-process steps. |
| [`seed-data.md`](seed-data.md) | Fictional data that fills both views. |
| [`ingestion.md`](ingestion.md) | Read-only ingestion rules and source-of-truth limits. |
| [`limits.md`](limits.md) | Known limits that this draft does not fix. |

## Boundaries

- Read GitHub at view time. Do not keep a second ledger.
- Do not add an external graph runtime, a server, or browser WASM.
- Do not add a hub snapshot, webhook, or central write path.
- Do not infer facts that are not on GitHub. Leave them empty or weakly
  inferred.
- Do not make this module a required step in the development loop.

## Related

- [Development loop templates](../../templates/dev-loop/README.md)
- [Development loop rules](../dev-loop-rules.md)
- [Contributing rules](../../CONTRIBUTING.md)
