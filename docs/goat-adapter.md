# GOAT adapter

[`scripts/agents/goat/run`](../scripts/agents/goat/run) launches GOAT
(Command Code) from the agent config, so `scripts/agent-launch.sh` can pick a
GOAT lane entry and pass its model id. Run `scripts/agents/goat/run --help` for
the interface and the environment knobs. This page records why it works the
way it does.

## Modes

| Mode | Agent permissions | Result |
| --- | --- | --- |
| `patch` | Read-only | One unified diff, checked and applied to the worktree, then named gate checks |
| `review` | Read-only | A result file whose first line is the `Model:` line |
| `write` | Writes under generated deny rules | Edits in a disposable worktree, then a scope gate |

The example config uses `patch` for the coding and docs lanes and `review` for
the review lanes. `write` is opt-in per lane entry.

`patch` is the default because a diff is reviewable before it touches the
tree: the adapter refuses a diff that names an absolute path, a `..`
component, `.git`, a rename or copy out of the tree, a symlink, or a
submodule, then runs `git apply --check` before `git apply`. New files are
marked intent-to-add (the path only, no content staged) so the named checks,
which read tracked files, see them. Nothing is committed.

## Why write mode needs a permission bypass

Headless print mode (`-p`) withholds file writes and shell commands unless
permissions are skipped with `--yolo`. A probe with `--permission-mode
dont-ask` plus `allow` rules for the target paths, and with `--tools-enable`,
still got `Tool "write_file" requires permissions`; `--tools-enable` only
re-enables planning-type tools. There is no write-only headless flag.

What does narrow a `--yolo` run: `deny` rules win in every mode, including
yolo. So write mode, and only write mode, pairs `--yolo` with a generated
`.commandcode/settings.local.json` that denies `Shell`, web fetches, every MCP
tool, and edits to `.git/**` and `.commandcode/**`. A test fails if any other
kit script passes `--yolo`.

## Write mode conditions

The maintainer approved write-enabled headless GOAT only under all of these:

1. The launch goes through this adapter, never a direct `--yolo` call.
2. The directory is a disposable worktree: a linked worktree (not the main
   checkout), clean, on a branch that is not `main`, `master`, or the
   remote's default branch, with no `.commandcode` folder. Anything else exits
   2 before the agent starts.
3. The agent runs under `env -i` with only `PATH`, a throwaway `HOME` and
   `TMPDIR` inside the run folder, `LANG`, `TERM`, and the GOAT API key. No
   GitHub token or other secret reaches it.
4. The caller declares the scope (repository-relative paths). After the run
   the adapter removes the generated settings and lists every changed, added,
   deleted, untracked, or newly ignored path. A path outside the scope, a
   sibling prefix such as `docsx` for scope `docs`, anything under `.git`, or
   a moved `HEAD` is a FAIL (exit 1), and the tree is left for inspection.
5. The adapter never stages, commits, pushes, or opens a pull request. The
   operator does that after the gate passes.

Residual risk: deny rules cannot express "everything outside the scope", and
under yolo a write outside the workspace admits a new root instead of
prompting. The scope gate catches anything inside the worktree; the throwaway
`HOME` takes writes aimed at the home folder. A write to another absolute path
is not caught by the gate, which is why write mode belongs on a disposable
machine or worktree only. Content changes to files that were already ignored
before the run are not visible to git either.

## Model line

Review mode writes `Model: <line>` as the first line of the result. The caller
sets the full line in `GOAT_MODEL_LINE`, for example `Example Model
(example/model-1) (Command Code / GOAT)`; without it the line is the model id
followed by `(Command Code / GOAT)`. The launcher does not export it, so the
environment of other adapters stays unchanged.

## Fail closed

A missing API key, a missing or unknown mode, a missing model, a path that is
not a git worktree, a symlinked worktree or brief, no diff, more than one diff,
or a diff that fails `git apply --check` exits 2 and nothing is applied. An
agent failure, a failing gate check, or a scope FAIL exits 1. The key value is
never printed; `--dry-run` shows it as `<set>` or `<missing>`.
